;;; src/restarts.lisp
;;; ABOUTME: Live condition suspension so restarts can actually be invoked

(in-package #:cl-mcp-server.restarts)

;;; ==========================================================================
;;; Rationale
;;;
;;; evaluate-lisp reports the restarts available on a condition, and then the
;;; stack unwinds and they are gone. Reporting a menu you cannot order from is
;;; the one place the MCP path is strictly weaker than SLIME: in SLIME the
;;; debugger holds the condition live and CONTINUE / USE-VALUE / STORE-VALUE
;;; are real choices.
;;;
;;; The obstacle is that MCP is request/response while a restart requires the
;;; signalling stack to still exist. Both can be true if the evaluation runs
;;; in its own thread:
;;;
;;;   1. worker signals -> HANDLER-BIND runs *without unwinding*
;;;   2. the handler registers the live condition and blocks on a semaphore
;;;   3. the main thread returns "suspended, here are the restarts"
;;;   4. a later invoke-restart call records a choice and wakes the worker
;;;   5. the worker, still inside the original handler, invokes the restart
;;;
;;; The restart therefore runs in its true dynamic environment, which is the
;;; whole point -- CONTINUE resumes the computation rather than restarting it.
;;;
;;; Safety properties, in rough order of how badly their absence would hurt:
;;;
;;;   - Every suspension has a deadline. A worker that is never answered
;;;     aborts itself rather than pinning a thread forever.
;;;   - Interactive restarts (USE-VALUE, STORE-VALUE, ...) are only invoked
;;;     when a value is supplied. Invoking one blind re-enters the debugger
;;;     and wedges the thread -- learned the hard way against SWANK.
;;;   - Suspensions are reaped, and abandoned ones can be listed and killed.
;;; ==========================================================================

(defparameter *suspension-timeout* 300
  "Seconds a suspended evaluation waits for a decision before self-aborting.
A suspension holds a live thread and its stack; it must not wait forever.")

(defparameter *max-suspensions* 16
  "Refuse new suspensions beyond this, so a loop of failing evaluations
cannot exhaust threads.")

(defvar *suspensions* (make-hash-table :test #'eql)
  "id -> SUSPENSION for every evaluation currently awaiting a decision.")

(defvar *suspensions-lock* (bt:make-lock "cl-mcp-suspensions"))

(defvar *suspension-counter* 0)

;;; ==========================================================================
;;; Suspension record
;;; ==========================================================================

(defstruct (suspension (:conc-name suspension-))
  id
  condition
  restarts          ; live RESTART objects, valid only while suspended
  restart-info      ; serialisable description of the above
  backtrace
  (decision-sem (bt:make-semaphore))   ; main -> worker: a choice was made
  (ready-sem (bt:make-semaphore))      ; worker -> main: suspended or done
  decision                             ; (:restart index . args) | :abort
  outcome                              ; :pending | :resumed | :aborted | :error
  outcome-text
  ;; Filled in by the worker so a resumed evaluation can report its real
  ;; result rather than a placeholder.
  finished-p
  values
  (stdout "")
  thread
  package-name
  ;; The deadline is captured per-suspension rather than read from the global
  ;; inside the worker: bt:make-thread does not inherit the caller's dynamic
  ;; bindings, so a rebound *suspension-timeout* would silently not apply to
  ;; the thread that actually enforces it.
  (timeout *suspension-timeout*)
  (created-at (get-universal-time)))

;;; ==========================================================================
;;; Restart classification
;;;
;;; A restart that reads a value from *QUERY-IO* cannot be invoked with no
;;; arguments: the read blocks or, under a null stream, signals -- and either
;;; way the worker never returns. CL does not expose "is this interactive"
;;; portably, so we use SBCL's interactive function when available and fall
;;; back to the well-known names.
;;; ==========================================================================

(defparameter *known-interactive-restarts*
  '("USE-VALUE" "STORE-VALUE" "RETURN-VALUE" "SPECIFY-VALUE" "SUPPLY-VALUE"
    "CONTINUE-WITH-VALUE" "SET-VALUE")
  "Restart names that conventionally prompt for a value.")

(defun restart-interactive-p (restart)
  "True when RESTART expects an argument supplied interactively."
  (let ((name (restart-name restart)))
    (or (and name
             (member (symbol-name name) *known-interactive-restarts*
                     :test #'string-equal)
             t)
        #+sbcl
        (and (ignore-errors (sb-kernel::restart-interactive-function restart))
             t)
        nil)))

(defun describe-restarts (condition)
  "Serialisable description of CONDITION's restarts, in invocation order."
  (loop for r in (compute-restarts condition)
        for i from 0
        collect (list :index i
                      :name (let ((n (restart-name r))) (and n (string n)))
                      :report (princ-to-string r)
                      :interactive-p (restart-interactive-p r))))

;;; ==========================================================================
;;; Registry
;;; ==========================================================================

(defun register-suspension (susp)
  (bt:with-lock-held (*suspensions-lock*)
    (setf (gethash (suspension-id susp) *suspensions*) susp)))

(defun unregister-suspension (id)
  (bt:with-lock-held (*suspensions-lock*)
    (remhash id *suspensions*)))

(defun find-suspension (id)
  (bt:with-lock-held (*suspensions-lock*)
    (gethash id *suspensions*)))

(defun live-suspensions ()
  "Suspensions still awaiting a decision, oldest first."
  (bt:with-lock-held (*suspensions-lock*)
    (sort (loop for s being the hash-values in *suspensions* collect s)
          #'< :key #'suspension-created-at)))

(defun suspension-count ()
  (bt:with-lock-held (*suspensions-lock*)
    (hash-table-count *suspensions*)))

(defun next-suspension-id ()
  (bt:with-lock-held (*suspensions-lock*)
    (incf *suspension-counter*)))

;;; ==========================================================================
;;; The worker side
;;; ==========================================================================

(defun %suspend-for-decision (susp condition)
  "Called from HANDLER-BIND in the worker, with CONDITION still live.

Publishes the suspension, blocks for a decision, then either invokes the
chosen restart (a non-local exit out of this handler) or returns normally so
the condition declines to the next handler."
  (setf (suspension-condition susp) condition
        (suspension-restarts susp) (compute-restarts condition)
        (suspension-restart-info susp) (describe-restarts condition)
        (suspension-backtrace susp)
        (ignore-errors (cl-mcp-server.error-format:format-backtrace))
        (suspension-outcome susp) :pending)
  (register-suspension susp)
  ;; Hand control back to the request thread, which reports the menu.
  (bt:signal-semaphore (suspension-ready-sem susp))
  (if (bt:wait-on-semaphore (suspension-decision-sem susp)
                            :timeout (suspension-timeout susp))
      (let ((decision (suspension-decision susp)))
        (cond
          ((eq decision :abort)
           (setf (suspension-outcome susp) :aborted)
           ;; Decline: let the enclosing handler-case unwind as usual.
           nil)
          ((and (consp decision) (eq (car decision) :restart))
           (destructuring-bind (index &rest args) (cdr decision)
             (let ((restart (nth index (suspension-restarts susp))))
               (setf (suspension-outcome susp) :resumed)
               ;; Non-local exit; control resumes at the restart's
               ;; establishment point with this stack still in place.
               (apply #'invoke-restart restart args))))
          (t (setf (suspension-outcome susp) :aborted) nil)))
      ;; Nobody answered in time. Decline and let the evaluation unwind so
      ;; the thread is not pinned indefinitely.
      (progn
        (setf (suspension-outcome susp) :aborted
              (suspension-outcome-text susp)
              (format nil "no decision within ~D second~:P; aborted"
                      (suspension-timeout susp)))
        nil)))

;;; ==========================================================================
;;; Standard restarts
;;;
;;; A worker thread inherits none of the restarts SLIME's debugger shows --
;;; those come from the REPL's own dynamic environment. Without establishing
;;; them, a TYPE-ERROR in a thread offers only ABORT, i.e. exactly the
;;; uninteresting choice. These are what make USE-VALUE and RETRY real.
;;; ==========================================================================

(defmacro with-standard-restarts (&body body)
  "Run BODY with RETRY / USE-VALUE / ABORT-EVALUATION established."
  (let ((done (gensym "DONE")))
    `(block ,done
       (loop
         (restart-case
             (return-from ,done (progn ,@body))
           (retry ()
             :report "Retry evaluating the form from the beginning.")
           (use-value (v)
             :report "Return a specified value instead."
             :interactive (lambda () (list (read)))
             (return-from ,done v))
           (abort-evaluation ()
             :report "Abort this evaluation and return NIL."
             (return-from ,done nil)))))))

;;; ==========================================================================
;;; Entry point
;;; ==========================================================================

(defstruct (eval-outcome (:conc-name outcome-))
  state              ; :completed | :suspended | :failed
  values             ; printed return values, when completed
  stdout
  error-text
  suspension-id
  restart-info
  condition-type
  condition-message)

(defun %print-values (values)
  (let ((*print-length* 100) (*print-level* 10) (*print-circle* t)
        (*print-pretty* t) (*print-readably* nil))
    (mapcar #'prin1-to-string values)))

(defun evaluate-suspendable (code-string &key package)
  "Evaluate CODE-STRING in a worker thread that suspends on error.

Returns an EVAL-OUTCOME. When the state is :suspended the condition is still
live and its restarts are invocable via RESUME-SUSPENSION until the timeout
elapses."
  (when (>= (suspension-count) *max-suspensions*)
    (return-from evaluate-suspendable
      (make-eval-outcome
       :state :failed
       :error-text (format nil "Too many suspended evaluations (~D). ~
Resolve or abandon them first; see list-suspensions."
                           (suspension-count)))))
  (let* ((susp (make-suspension :id (next-suspension-id)
                                :package-name (or package "COMMON-LISP-USER")))
         (pkg (or (find-package (string-upcase (or package "COMMON-LISP-USER")))
                  (find-package :cl-user)))
         (out (make-string-output-stream))
         (done nil)
         (values nil)
         (failure nil))
    (setf (suspension-thread susp)
          (bt:make-thread
           (lambda ()
             (unwind-protect
                  (handler-case
                      (let ((*package* pkg)
                            (*standard-output* out)
                            (*error-output* out)
                            (*query-io* (make-two-way-stream
                                         (make-string-input-stream "")
                                         out))
                            (*debug-io* (make-two-way-stream
                                         (make-string-input-stream "")
                                         out)))
                        (handler-bind
                            ((error (lambda (c) (%suspend-for-decision susp c))))
                          ;; Establish the restarts an interactive REPL would
                          ;; offer, so a suspended condition has useful choices
                          ;; and not just ABORT.
                          (setf values
                                (multiple-value-list
                                 (with-standard-restarts
                                   (eval (read-from-string code-string)))))
                          (setf done t
                                (suspension-values susp) values
                                (suspension-finished-p susp) t)))
                    (error (c)
                      (setf failure (cl-mcp-server.error-format:format-error c))))
               (setf (suspension-stdout susp) (get-output-stream-string out))
               (unregister-suspension (suspension-id susp))
               ;; Whether we finished, aborted or blew up, wake any waiter.
               (bt:signal-semaphore (suspension-ready-sem susp))))
           :name (format nil "cl-mcp-eval-~D" (suspension-id susp))))
    ;; Wait for the worker to either finish or suspend.
    (bt:wait-on-semaphore (suspension-ready-sem susp)
                          :timeout (1+ (suspension-timeout susp)))
    ;; NB: read stdout from the suspension, not the stream. The worker drains
    ;; the stream in its unwind-protect, so get-output-stream-string here
    ;; would race it and usually return "".
    (%collect-outcome susp :done done :values values :failure failure
                           :stdout (if (suspension-finished-p susp)
                                       (suspension-stdout susp)
                                       (get-output-stream-string out)))))

(defun %collect-outcome (susp &key done values failure stdout)
  (cond
    ((eq (suspension-outcome susp) :pending)
     (make-eval-outcome
      :state :suspended
      :suspension-id (suspension-id susp)
      :restart-info (suspension-restart-info susp)
      :condition-type (string (type-of (suspension-condition susp)))
      :condition-message (princ-to-string (suspension-condition susp))
      :stdout stdout))
    (done
     (make-eval-outcome :state :completed
                        :values (%print-values values)
                        :stdout stdout))
    (t
     (make-eval-outcome :state :failed
                        :error-text (or failure
                                        (suspension-outcome-text susp)
                                        "evaluation aborted")
                        :stdout stdout))))

;;; ==========================================================================
;;; Resuming
;;; ==========================================================================

(defun resume-suspension (id &key restart-index restart-name value (abort nil))
  "Answer suspension ID.

Supply RESTART-INDEX or RESTART-NAME to invoke a restart, VALUE for the
interactive ones, or ABORT to unwind. Returns an EVAL-OUTCOME describing what
the resumed evaluation went on to do."
  (let ((susp (find-suspension id)))
    (cond
      ((null susp)
       (make-eval-outcome
        :state :failed
        :error-text (format nil "No suspension ~A. It may have completed, ~
timed out, or never existed; see list-suspensions." id)))
      (t
       (let* ((info (suspension-restart-info susp))
              (index (cond (abort nil)
                           (restart-index restart-index)
                           (restart-name
                            (let ((hit (find restart-name info
                                             :key (lambda (e) (getf e :name))
                                             :test (lambda (a b)
                                                     (and b (string-equal a b))))))
                              (and hit (getf hit :index)))))))
         (cond
           (abort (%deliver susp :abort))
           ((null index)
            (make-eval-outcome
             :state :failed
             :error-text (format nil "No restart~@[ named ~A~] on suspension ~A."
                                 restart-name id)))
           ((>= index (length info))
            (make-eval-outcome
             :state :failed
             :error-text (format nil "Restart index ~D out of range (0-~D)."
                                 index (1- (length info)))))
           ((and (getf (nth index info) :interactive-p) (null value))
            ;; Refuse rather than wedge: an interactive restart invoked with
            ;; no argument re-enters the debugger and the worker never returns.
            (make-eval-outcome
             :state :failed
             :error-text
             (format nil "Restart ~A is interactive and needs a value. ~
Pass `value` (a Lisp form, e.g. \"42\")."
                     (or (getf (nth index info) :name) index))))
           (t
            (%deliver susp
                      (list* :restart index
                             (when value
                               (list (%read-value value
                                                  (suspension-package-name susp)))))))))))))

(defun %read-value (text package-name)
  "Read TEXT as a Lisp form in PACKAGE-NAME, with *READ-EVAL* disabled."
  (let ((*package* (or (find-package (string-upcase package-name))
                       (find-package :cl-user)))
        (*read-eval* nil))
    (read-from-string text)))

(defun %deliver (susp decision)
  "Record DECISION, wake the worker, and report what the evaluation did next.

After a restart the worker runs on to completion (or to another error), so
the honest answer is its real result -- reporting a bare \"restart invoked\"
would hide whether CONTINUE actually produced a value."
  (setf (suspension-decision susp) decision)
  (bt:signal-semaphore (suspension-decision-sem susp))
  (if (bt:wait-on-semaphore (suspension-ready-sem susp)
                            :timeout (suspension-timeout susp))
      (let ((finished (suspension-finished-p susp)))
        (cond
          ;; Worker ran to completion after the restart.
          (finished
           (make-eval-outcome :state :completed
                              :values (%print-values (suspension-values susp))
                              :stdout (suspension-stdout susp)))
          ;; It hit another error and suspended again.
          ((eq (suspension-outcome susp) :pending)
           (make-eval-outcome
            :state :suspended
            :suspension-id (suspension-id susp)
            :restart-info (suspension-restart-info susp)
            :condition-type (string (type-of (suspension-condition susp)))
            :condition-message (princ-to-string (suspension-condition susp))))
          (t
           (make-eval-outcome
            :state :failed
            :error-text (or (suspension-outcome-text susp)
                            "evaluation aborted")
            :stdout (suspension-stdout susp)))))
      (make-eval-outcome
       :state :failed
       :error-text "the resumed evaluation did not settle in time")))

(defun abandon-suspension (id)
  "Abort suspension ID, killing its thread if it will not unwind."
  (let ((susp (find-suspension id)))
    (if (null susp)
        (format nil "No suspension ~A." id)
        (progn
          (setf (suspension-decision susp) :abort)
          (bt:signal-semaphore (suspension-decision-sem susp))
          (sleep 0.2)
          (let ((thread (suspension-thread susp)))
            (when (and thread (bt:thread-alive-p thread))
              (ignore-errors (bt:destroy-thread thread))))
          (unregister-suspension id)
          (format nil "Suspension ~A abandoned." id)))))

;;; ==========================================================================
;;; Formatting
;;; ==========================================================================

(defun format-eval-outcome (outcome)
  "Render an EVAL-OUTCOME for MCP. Returns (values text error-p)."
  (let ((stdout (outcome-stdout outcome)))
    (flet ((with-stdout (body)
             (if (and stdout (plusp (length stdout)))
                 (concatenate 'string "[stdout]" (string #\Newline)
                              stdout (string #\Newline) body)
                 body)))
      (ecase (outcome-state outcome)
        (:completed
         (values (with-stdout
                     (format nil "~{=> ~A~%~}" (outcome-values outcome)))
                 nil))
        (:failed
         (values (with-stdout (or (outcome-error-text outcome) "failed")) t))
        (:suspended
         (values
          (with-stdout
              (with-output-to-string (s)
                (format s "[SUSPENDED ~D] ~A~%~A~%~%"
                        (outcome-suspension-id outcome)
                        (outcome-condition-type outcome)
                        (outcome-condition-message outcome))
                (format s "The condition is still live. Choose a restart with ~
invoke-restart, or abandon it with abandon-suspension.~%~%")
                (format s "[Restarts]~%")
                (dolist (r (outcome-restart-info outcome))
                  (format s "  ~D: [~A] ~A~@[  (needs a value)~*~]~%"
                          (getf r :index)
                          (or (getf r :name) "unnamed")
                          (getf r :report)
                          (getf r :interactive-p)))
                (format s "~%Expires in ~D second~:P.~%" *suspension-timeout*)))
          ;; A suspension is not a failure: it is an open question.
          nil))))))

(defun format-suspension-list ()
  "Render the live suspensions. Returns (values text error-p)."
  (let ((all (live-suspensions)))
    (if (null all)
        (values "No suspended evaluations." nil)
        (values
         (with-output-to-string (s)
           (format s "~D suspended evaluation~:P:~%~%" (length all))
           (dolist (susp all)
             (format s "  [~D] ~A~%       ~A~%       ~D restart~:P, ~D s old~%"
                     (suspension-id susp)
                     (string (type-of (suspension-condition susp)))
                     (princ-to-string (suspension-condition susp))
                     (length (suspension-restart-info susp))
                     (- (get-universal-time) (suspension-created-at susp)))))
         nil))))

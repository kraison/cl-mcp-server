;;; src/remote.lisp
;;; ABOUTME: Named SWANK targets, form classification, audit ledger

(in-package #:cl-mcp-server.remote)

;;; A live service is not a dev image: a mistake is not undoable. Every
;;; safety property here is client-side discipline, because SWANK itself is
;;; just EVAL -- no read-only mode, no sandbox. See
;;; docs/reference/remote-swank.md.

;;; ==========================================================================
;;; Targets
;;; ==========================================================================

(defvar *targets* (make-hash-table :test #'equal))
(defvar *connections* (make-hash-table :test #'equal))
(defvar *lock* (bt:make-lock "cl-mcp-remote"))

(defstruct (target (:conc-name target-))
  name host port
  (mode :observe)           ; :observe | :read | :developer
  (pre-arm-mode nil)        ; mode to restore on disarm; NIL when unarmed
  (max-print-length 200)
  (max-print-level 5))

(defun register-target (name host port &key (mode :observe)
                                            (max-print-length 200))
  "Register a named target. Names, not raw host/port, are what tools accept:
you cannot typo a port into production."
  (bt:with-lock-held (*lock*)
    (setf (gethash name *targets*)
          (make-target :name name :host host :port port :mode mode
                       :max-print-length max-print-length)))
  name)

(defun find-target (name)
  (bt:with-lock-held (*lock*) (gethash name *targets*)))

(defun list-targets ()
  (bt:with-lock-held (*lock*)
    (sort (loop for tg being the hash-values in *targets* collect tg)
          #'string< :key #'target-name)))

;;; ==========================================================================
;;; Tiering
;;;
;;; T0 observe   metadata: arglists, docs, apropos, source location
;;; T1 read      evaluates a form that reads state; risk is cost, not damage
;;; T2 redefine  defun/defmethod: recoverable by redefining back
;;; T2 state     setf/clrhash/load: usually no inverse
;;; T3 lifecycle quit, kill-thread, delete-package: outage-shaped
;;;
;;; Classification reads the form; it never evaluates it. This catches
;;; ACCIDENTS, not adversaries -- a macro can hide anything. Default-deny,
;;; the ledger and human approval are the real protections.
;;; ==========================================================================

(defparameter *lifecycle-operators*
  '("QUIT" "EXIT" "SB-EXT:QUIT" "SB-EXT:EXIT" "KILL-THREAD"
    "SB-THREAD:TERMINATE-THREAD" "DESTROY-THREAD" "DELETE-PACKAGE"
    "SB-EXT:SAVE-LISP-AND-DIE" "STOP" "SHUTDOWN" "STOP-SERVER"
    "UNINTERN" "SB-POSIX:KILL" "ABORT-THREAD"))

(defparameter *redefining-operators*
  '("DEFUN" "DEFMACRO" "DEFMETHOD" "DEFGENERIC" "ADD-METHOD"
    "REMOVE-METHOD")
  "Redefinition: recoverable by evaluating the previous definition.")

(defparameter *state-operators*
  '("SETF" "SETQ" "PSETF" "PSETQ" "INCF" "DECF" "PUSH" "POP" "PUSHNEW"
    "REMHASH" "CLRHASH" "SET" "MAKUNBOUND" "FMAKUNBOUND"
    "ROTATEF" "SHIFTF" "REPLACE" "FILL" "SORT" "NREVERSE" "NCONC"
    "DELETE" "CHANGE-CLASS" "TRACE" "UNTRACE"
    ;; Syntactically definitions, but not recoverable by re-evaluating
    ;; the previous form: redefining a class obsoletes live instances,
    ;; DEFVAR and friends alter global bindings, LOAD can do anything.
    "DEFCLASS" "DEFSTRUCT" "DEFVAR" "DEFPARAMETER" "DEFCONSTANT"
    "LOAD" "COMPILE-FILE" "REQUIRE")
  "State change: usually no inverse. SORT, DELETE, NCONC and NREVERSE
are destructive in CL and read as innocent.")

(defparameter *opaque-operators*
  '("EVAL" "READ" "READ-FROM-STRING" "FUNCALL" "APPLY" "COMPILE"
    "MACROEXPAND" "INTERN" "FIND-SYMBOL")
  "Operators whose effect cannot be determined by reading. Treated as
lifecycle: we would rather refuse a safe form than allow a destructive one.")

(defun classify-form (form-string)
  "Return (values tier reason) for FORM-STRING, by textual inspection."
  (let ((upper (string-upcase form-string)))
    (cond
      ((search "#." form-string)
       (values :lifecycle "read-eval (#.) can execute anything at read time"))
      ((%mentions upper *lifecycle-operators*)
       (values :lifecycle (format nil "lifecycle operator ~A"
                                  (%mentions upper *lifecycle-operators*))))
      ((%mentions upper *opaque-operators*)
       (values :lifecycle (format nil "~A hides its effect from inspection"
                                  (%mentions upper *opaque-operators*))))
      ((%mentions upper *state-operators*)
       (values :state (format nil "state operator ~A"
                              (%mentions upper *state-operators*))))
      ((%mentions upper *redefining-operators*)
       (values :redefine (format nil "redefining operator ~A"
                                 (%mentions upper *redefining-operators*))))
      (t (values :read nil)))))

(defparameter *session-ending-operators*
  '("QUIT" "EXIT" "SB-EXT:QUIT" "SB-EXT:EXIT" "SB-EXT:SAVE-LISP-AND-DIE")
  "Lifecycle operators that end the SWANK session. TERMINATE-THREAD and
DELETE-PACKAGE are lifecycle but leave the connection usable.")

(defun session-ending-form-p (form-string)
  (and (%mentions (string-upcase form-string) *session-ending-operators*) t))

(defun %mentions (upper operators)
  "First operator in OPERATORS appearing as a token of UPPER."
  (find-if (lambda (op) (%token-present-p upper op)) operators))

(defun %token-present-p (upper op)
  "True when OP appears delimited, so SETFOO does not match SETF."
  (let ((pos 0))
    (loop
      (let ((hit (search op upper :start2 pos)))
        (unless hit (return nil))
        (let ((before (if (zerop hit) #\Space (char upper (1- hit))))
              (after (if (>= (+ hit (length op)) (length upper))
                         #\Space
                         (char upper (+ hit (length op))))))
          (when (and (not (%symbol-char-p before))
                     (not (%symbol-char-p after)))
            (return t)))
        (setf pos (1+ hit))))))

(defun %symbol-char-p (ch)
  (or (alphanumericp ch) (find ch "-*+/<>=?!%_.")))

(defparameter *mode-permissions*
  '((:observe    . (:observe))
    (:read       . (:observe :read :inspect-registry))
    (:developer  . (:observe :read :inspect-registry
                    :redefine :state :lifecycle)))
  "Mode to permitted tiers. Modes are roles, not rungs: a future
:prod-maintenance clears a cache but must never redefine, so it is not a
subset of :developer. Adding a mode is adding a row.")

(defun tier-allowed-p (target tier)
  "Is TIER permitted by TARGET's mode? Default-deny: an unknown mode or
tier permits nothing."
  (and (member tier (cdr (assoc (target-mode target) *mode-permissions*)))
       t))

;;; ==========================================================================
;;; Ledger
;;;
;;; Without an answer to "what did the agent do to prod?", this feature
;;; should not exist. Every form sent to a target is recorded, including the
;;; refused ones -- an attempt is as interesting as a success.
;;; ==========================================================================

(defstruct (ledger-entry (:conc-name entry-))
  timestamp target tier form outcome detail)

(defvar *ledger* nil "Newest first.")

(defun record (target-name tier form outcome &optional detail)
  (bt:with-lock-held (*lock*)
    (push (make-ledger-entry :timestamp (get-universal-time)
                             :target target-name :tier tier :form form
                             :outcome outcome :detail detail)
          *ledger*))
  outcome)

(defun ledger-for (&optional target-name)
  (bt:with-lock-held (*lock*)
    (if target-name
        (remove target-name *ledger* :key #'entry-target :test-not #'equal)
        (copy-list *ledger*))))

(defun entry-time-string (entry)
  "HH:MM:SS for ENTRY. An audit trail without times cannot answer when."
  (multiple-value-bind (sec min hour) (decode-universal-time
                                       (entry-timestamp entry))
    (format nil "~2,'0D:~2,'0D:~2,'0D" hour min sec)))

;;; ==========================================================================
;;; Connection management
;;; ==========================================================================

(defun connection-for (target)
  "Reuse or open a connection to TARGET."
  (let* ((name (target-name target))
         (existing (bt:with-lock-held (*lock*) (gethash name *connections*))))
    (if (and existing (cl-mcp-server.swank-protocol::connected-p existing))
        existing
        (let ((conn (cl-mcp-server.swank-protocol:connect
                     (target-host target) (target-port target))))
          (bt:with-lock-held (*lock*) (setf (gethash name *connections*) conn))
          conn))))

(defun close-connection (name)
  (let ((conn (bt:with-lock-held (*lock*) (gethash name *connections*))))
    (when conn
      (cl-mcp-server.swank-protocol:disconnect conn)
      (bt:with-lock-held (*lock*) (remhash name *connections*))
      t)))

;;; ==========================================================================
;;; Arming
;;;
;;; Mutation is off until a target is armed, and a target may only be armed
;;; if it is allowlisted outside the session. There is no expiry: an armed
;;; target stays armed until disarmed, which is why the tools make armed
;;; state loud. See docs/reference/remote-swank.md.
;;; ==========================================================================

(defun target-armed-p (target)
  (and (target-pre-arm-mode target) t))

(defun arm-target (name &optional reason)
  "Put NAME into :developer mode. Returns (values target message)."
  (let ((target (find-target name)))
    (cond
      ((null target)
       (values nil (format nil "No target named ~A. Connect it first." name)))
      ((not (cl-mcp-server.remote-config:armable-target-p name))
       (record name :arm "" :refused
               (format nil "~A is not armable" name))
       (values nil
               (format nil "Target ~A is not armable.~%~%Add it to ~
~~/.config/cl-mcp-server/config.sexp:~%  (:armable-targets (~S))~%~%~
or set CL_MCP_ARMABLE_TARGETS. The allowlist lives outside the session ~
deliberately." name name)))
      ((target-armed-p target)
       (values target (format nil "~A is already armed." name)))
      (t
       (setf (target-pre-arm-mode target) (target-mode target)
             (target-mode target) :developer)
       (record name :arm "" :armed reason)
       (values target
               (format nil "~A is ARMED for development.~%~%Redefinition, ~
state changes and lifecycle forms are now permitted. It stays armed until ~
you call remote-disarm.~@[~%~%Reason: ~A~]" name reason))))))

(defun disarm-target (name)
  "Restore NAME's pre-arm mode. Returns (values target message)."
  (let ((target (find-target name)))
    (cond
      ((null target)
       (values nil (format nil "No target named ~A." name)))
      ((not (target-armed-p target))
       (values target (format nil "~A is not armed." name)))
      (t
       (let ((restored (target-pre-arm-mode target)))
         (setf (target-mode target) restored
               (target-pre-arm-mode target) nil)
         (record name :disarm "" :disarmed
                 (format nil "restored ~(~A~) mode" restored))
         (values target
                 (format nil "~A disarmed; back to ~(~A~) mode."
                         name restored)))))))

;;; ==========================================================================
;;; Cleanup
;;;
;;; Anything we leave behind on a service is our fault, and an abrupt
;;; disconnect is the normal case rather than the exception -- a timeout, a
;;; dropped socket, a killed agent. Cleanup actions are registered here so
;;; every future residue source (traces, suspensions) is swept by the same
;;; path rather than each growing its own.
;;; ==========================================================================

(defvar *cleanup-actions* nil
  "List of (label . function-of-target-name). Each returns a string.")

(defun register-cleanup (label fn)
  "Register FN to run when a target is disconnected with cleanup."
  (bt:with-lock-held (*lock*)
    (setf *cleanup-actions*
          (cons (cons label fn)
                (remove label *cleanup-actions* :key #'car :test #'equal))))
  label)

(defun run-cleanup (target-name)
  "Run every registered cleanup action against TARGET-NAME.

Each action is isolated: a failure is reported and the sweep continues, so
one unreachable step cannot strand the rest. Returns a list of (label
. outcome-string)."
  (let ((actions (bt:with-lock-held (*lock*) (copy-list *cleanup-actions*))))
    (loop for (label . fn) in (reverse actions)
          collect (cons label
                        (handler-case (funcall fn target-name)
                          (error (e)
                            (format nil "failed: ~A" (type-of e))))))))

;;; ==========================================================================
;;; Guarded evaluation
;;; ==========================================================================

(defun %wrap-with-print-limits (form target)
  "Bind print limits around FORM, in the remote image.

Enforcing limits on our side is not enough: (gethash k *huge-table*) can
flood or stall the service before a single byte reaches us."
  (format nil "(let ((*print-length* ~D) (*print-level* ~D) ~
(*print-circle* t) (*print-pretty* nil) (*print-readably* nil)) ~A)"
          (target-max-print-length target)
          (target-max-print-level target)
          form))

(defun remote-eval (target-name form &key (package "COMMON-LISP-USER")
                                          (tier-override nil))
  "Evaluate FORM on TARGET-NAME, subject to its mode. Returns a plist."
  (let ((target (find-target target-name)))
    (cond
      ((null target)
       (list :ok nil :error (format nil "No target ~A. Register it first."
                                    target-name)))
      (t
       (multiple-value-bind (tier reason) (classify-form form)
         (let ((tier (or tier-override tier)))
           (cond
             ((not (tier-allowed-p target tier))
              (record target-name tier form :refused reason)
              (list :ok nil :tier tier :refused t
                    :error (format nil
                                   "Refused: ~(~A~) tier~@[ (~A)~], but ~
target ~A is in ~(~A~) mode.~%~%Run it yourself if you intend it:~%  ~A"
                                   tier reason target-name
                                   (target-mode target) form)))
             (t
              (handler-case
                  (multiple-value-bind (result output)
                      (cl-mcp-server.swank-protocol:rex
                       (connection-for target)
                       (%wrap-with-print-limits form target)
                       :package package)
                    (record target-name tier form :ok)
                    (list :ok t :tier tier :result result :output output))
                (cl-mcp-server.swank-protocol:swank-error (e)
                  ;; One clause for the whole SWANK-ERROR family, because
                  ;; SWANK-ABORTED is a subclass and a form that kills the
                  ;; image can surface as either. Dispatching on the form
                  ;; first, the condition second, is what makes a quit read
                  ;; as terminated rather than as a bare remote error.
                  (cond
                    ((session-ending-form-p form)
                     (close-connection target-name)
                     (record target-name tier form :terminated)
                     (list :ok t :tier tier
                           :result (format nil "Target ~A terminated, as ~
instructed. The connection is closed." target-name)))
                    ((typep e 'cl-mcp-server.swank-protocol:swank-aborted)
                     (record target-name tier form :remote-error
                             (princ-to-string e))
                     (list :ok nil :tier tier
                           :error (princ-to-string e)
                           :restarts
                           (cl-mcp-server.swank-protocol:swank-aborted-restarts
                            e)))
                    (t
                     (record target-name tier form :error
                             (princ-to-string e))
                     (list :ok nil :tier tier :error (princ-to-string e)))))
                (error (e)
                  (record target-name tier form :error (princ-to-string e))
                  (list :ok nil :tier tier
                        :error (format nil "~A: ~A" (type-of e) e))))))))))))

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
  (mode :observe)           ; :observe | :read | :mutate
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
;;; T2 mutate    setf/defun/load: behaviour changes under live traffic
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

(defparameter *mutating-operators*
  '("SETF" "SETQ" "PSETF" "PSETQ" "INCF" "DECF" "PUSH" "POP" "PUSHNEW"
    "REMHASH" "CLRHASH" "SET" "DEFUN" "DEFMACRO" "DEFVAR" "DEFPARAMETER"
    "DEFCLASS" "DEFMETHOD" "DEFGENERIC" "DEFSTRUCT" "DEFCONSTANT"
    "LOAD" "COMPILE-FILE" "REQUIRE" "MAKUNBOUND" "FMAKUNBOUND"
    "ROTATEF" "SHIFTF" "REPLACE" "FILL" "SORT" "NREVERSE" "NCONC"
    "DELETE" "REMOVE-METHOD" "ADD-METHOD" "CHANGE-CLASS" "TRACE" "UNTRACE"))

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
      ((%mentions upper *mutating-operators*)
       (values :mutate (format nil "mutating operator ~A"
                               (%mentions upper *mutating-operators*))))
      (t (values :read nil)))))

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

(defun tier-allowed-p (target tier)
  "Is TIER permitted by TARGET's mode?

:INSPECT-REGISTRY is the remote inspector's bookkeeping -- defining its
handle table and bumping a counter. It is a genuine mutation of the target,
so it carries its own tier rather than masquerading as :read, and the ledger
records it under that name. It is permitted wherever :read is, because a
weak-pointer table cannot retain the service's data or change its behaviour."
  (let ((mode (target-mode target)))
    (case tier
      (:observe t)
      (:read (member mode '(:read :mutate)))
      (:inspect-registry (member mode '(:read :mutate)))
      (:mutate (eq mode :mutate))
      (:lifecycle nil)                  ; never automatic, in any mode
      (t nil))))

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
                (cl-mcp-server.swank-protocol:swank-aborted (e)
                  (record target-name tier form :remote-error
                          (princ-to-string e))
                  (list :ok nil :tier tier
                        :error (princ-to-string e)
                        :restarts
                        (cl-mcp-server.swank-protocol:swank-aborted-restarts
                         e)))
                (error (e)
                  (record target-name tier form :error (princ-to-string e))
                  (list :ok nil :tier tier
                        :error (format nil "~A: ~A" (type-of e) e))))))))))))

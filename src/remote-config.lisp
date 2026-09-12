;;; src/remote-config.lisp
;;; ABOUTME: The allowlist of targets that may be armed for mutation

(in-package #:cl-mcp-server.remote-config)

;;; This is the gate a session cannot open for itself: a target may only be
;;; armed if it is named here, outside the session. See
;;; docs/reference/remote-swank.md.

(define-condition config-error (error)
  ((detail :initarg :detail :reader config-error-detail))
  (:report (lambda (c s)
             (format s "config: ~A" (config-error-detail c)))))

(defparameter *config-path*
  (merge-pathnames ".config/cl-mcp-server/config.sexp"
                   (user-homedir-pathname)))

(defparameter *env-override* :unset
  "Value of CL_MCP_ARMABLE_TARGETS, or :UNSET to consult the real
environment. Tests bind NIL to mean 'no env var, read the file': NIL cannot
mean 'not overridden' or a test could not express that case and would
silently inherit the developer's own environment. \"\" is a real override
meaning 'nothing is armable'.")

(defvar *armable* :unread
  "Cached allowlist, or :UNREAD before the first read.")

(defun %split-commas (text)
  (let ((out '()) (start 0))
    (loop for i from 0 to (length text)
          when (or (= i (length text)) (char= #\, (char text i)))
            do (let ((piece (string-trim '(#\Space #\Tab)
                                         (subseq text start i))))
                 (when (plusp (length piece)) (push piece out))
                 (setf start (1+ i))))
    (nreverse out)))

(defun %read-form (path)
  "The first form in PATH, or NIL when there is no file. Signals
CONFIG-ERROR if it will not parse. One reader for every key the file
holds: :armable-targets is no longer its only one."
  (handler-case
      (with-open-file (in path :if-does-not-exist nil)
        (when in
          (let ((*read-eval* nil))   ; #. would run code at startup
            (read in nil nil))))
    (error (e)
      (error 'config-error
             :detail (format nil "~A is unreadable (~A)" path (type-of e))))))

(defun %read-file (path)
  "Allowlist from PATH. Only the first form is read; a second top-level
form is ignored."
  (mapcar #'string (getf (%read-form path) :armable-targets)))

(defvar *blackboard* :unread
  "Cached :BLACKBOARD target, or :UNREAD before the first read.")

(defun blackboard-target ()
  "The :BLACKBOARD plist from the config file, or NIL. A plist of :host
:port :role and optionally :instance :connect-timeout :request-timeout,
which BLACKBOARD.MCP:REGISTER-BLACKBOARD-TOOLS takes. NIL means the
blackboard tools are not registered and that system is never loaded.
The environment does not override this key: it names a service, not a
permission."
  (when (eq *blackboard* :unread)
    (setf *blackboard* (getf (%read-form *config-path*) :blackboard)))
  *blackboard*)

(defun reload-config ()
  "Re-read the allowlist. The environment REPLACES the file. The
:blackboard key is re-read on its next use."
  (setf *blackboard* :unread)
  (setf *armable*
        (let ((env (if (eq *env-override* :unset)
                       (sb-ext:posix-getenv "CL_MCP_ARMABLE_TARGETS")
                       *env-override*)))
          (if env
              (%split-commas env)
              (%read-file *config-path*)))))

(defun armable-targets ()
  (when (eq *armable* :unread) (reload-config))
  *armable*)

(defun armable-target-p (name)
  (and (member name (armable-targets) :test #'string=) t))

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

(defparameter *env-override* nil
  "Value of CL_MCP_ARMABLE_TARGETS, or NIL when unset. Bound in tests.")

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

(defun %read-file (path)
  "Allowlist from PATH. Signals CONFIG-ERROR if it will not parse."
  (handler-case
      (with-open-file (in path :if-does-not-exist nil)
        (when in
          (let* ((*read-eval* nil)   ; #. would run code at startup
                 (form (read in nil nil)))
            (mapcar #'string (getf form :armable-targets)))))
    (config-error (e) (error e))
    (error (e)
      (error 'config-error
             :detail (format nil "~A is unreadable (~A)" path (type-of e))))))

(defun reload-config ()
  "Re-read the allowlist. The environment REPLACES the file."
  (setf *armable*
        (let ((env (or *env-override*
                       (sb-ext:posix-getenv "CL_MCP_ARMABLE_TARGETS"))))
          (if env
              (%split-commas env)
              (%read-file *config-path*)))))

(defun armable-targets ()
  (when (eq *armable* :unread) (reload-config))
  *armable*)

(defun armable-target-p (name)
  (and (member name (armable-targets) :test #'string=) t))

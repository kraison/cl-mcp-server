;;; src/remote-config.lisp
;;; ABOUTME: The allowlist of targets that may be armed for mutation

(in-package #:cl-mcp-server.remote-config)

;;; This is the gate a session cannot open for itself: a target may only be
;;; armed if it is named here, outside the session, and pinned to the host
;;; and port that name means. A bare name pins nothing, since the session
;;; binds names to ports (GH #12). See docs/reference/remote-swank.md.

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
  "Cached allowlist, or :UNREAD before the first read. Each entry is
(NAME HOST PORT) when pinned, or (NAME) for a bare name.")

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

(defun %bad-entry (entry why)
  (error 'config-error
         :detail (format nil "armable target ~S: ~A" entry why)))

(defun %file-entry (item)
  "ITEM from the file as an allowlist entry: \"name\", or
(\"name\" :host \"h\" :port p), :host defaulting to 127.0.0.1."
  (typecase item
    ((or string symbol) (list (string item)))
    (cons
     (let ((name (car item)) (plist (cdr item)))
       (unless (typep name '(or string symbol))
         (%bad-entry item "the name must be a string"))
       (unless (and (alexandria:proper-list-p plist) (evenp (length plist))
                    (loop for key in plist by #'cddr
                          always (member key '(:host :port))))
         ;; An unknown key would be a typo, and :hots would pin 127.0.0.1.
         (%bad-entry item "expected (name :host \"h\" :port p)"))
       (let ((host (getf plist :host "127.0.0.1"))
             (port (getf plist :port)))
         (unless (stringp host) (%bad-entry item ":host must be a string"))
         (unless (typep port '(integer 1 65535))
           (%bad-entry item ":port must be a port number"))
         (list (string name) host port))))
    (t (%bad-entry item "expected a name or (name :host \"h\" :port p)"))))

(defun %env-entry (piece)
  "PIECE of CL_MCP_ARMABLE_TARGETS as an entry: NAME or NAME@HOST:PORT."
  (let ((at (position #\@ piece)))
    (if (null at)
        (list piece)
        (let* ((name (subseq piece 0 at))
               (endpoint (subseq piece (1+ at)))
               (colon (position #\: endpoint :from-end t))
               (port (and colon
                          (every #'digit-char-p (subseq endpoint (1+ colon)))
                          (plusp (- (length endpoint) colon 1))
                          (parse-integer endpoint :start (1+ colon)))))
          (unless (and (plusp (length name)) colon (plusp colon)
                       (typep port '(integer 1 65535)))
            (%bad-entry piece "expected NAME or NAME@HOST:PORT"))
          (list name (subseq endpoint 0 colon) port)))))

(defun %read-file (path)
  "Allowlist from PATH. Only the first form is read; a second top-level
form is ignored."
  (let ((targets (getf (%read-form path) :armable-targets)))
    (unless (alexandria:proper-list-p targets)
      (error 'config-error
             :detail (format nil "~A: :armable-targets must be a list"
                             path)))
    (mapcar #'%file-entry targets)))

(defun %refuse-duplicates (entries)
  "ENTRIES, unless a name appears twice: which pin it means is then
unknowable."
  (loop for (entry . rest) on entries
        when (find (first entry) rest :key #'first :test #'string=)
          do (%bad-entry (first entry) "listed more than once"))
  entries)

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
          (%refuse-duplicates
           (if env
               (mapcar #'%env-entry (%split-commas env))
               (%read-file *config-path*))))))

(defun %entries ()
  (when (eq *armable* :unread) (reload-config))
  *armable*)

(defun armable-targets ()
  "Names on the allowlist, pinned or not."
  (mapcar #'first (%entries)))

(defun armable-target-p (name)
  "Is NAME on the allowlist at all? Only a pinned name can be armed; see
ARMABLE-PIN."
  (and (find name (%entries) :key #'first :test #'string=) t))

(defun armable-pin (name)
  "(values host port) that NAME is pinned to, or NIL when NAME is bare or
not listed."
  (destructuring-bind (&optional entry-name host port)
      (find name (%entries) :key #'first :test #'string=)
    (declare (ignore entry-name))
    (when port (values host port))))

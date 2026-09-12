;;; src/server.lisp
;;; ABOUTME: CL-MCP-Server entry point — REPL tools over MCP

(in-package #:cl-mcp-server)

;;; The blackboard's tools, registered only when the config file names
;;; a target. FIND-SYMBOL rather than a direct call: this system's
;;; :DEPENDS-ON must not grow a blackboard entry -- the blackboard
;;; brings cl-llm and graph-db with it -- so the names are resolved at
;;; run time, after the conditional load. See docs/how-to/blackboard.md.

(defvar *blackboard-pool* nil
  "The connection pool the registered blackboard tools share, or NIL.")

(defun %blackboard-registry ()
  "Push the trees BLACKBOARD_ASDF_REGISTRY names onto ASDF's central
registry, ahead of everything else. Without it the load resolves an
older engine from quicklisp's local-projects and fails."
  (let ((registry (uiop:getenv "BLACKBOARD_ASDF_REGISTRY")))
    (when (and registry (plusp (length registry)))
      (dolist (dir (reverse (uiop:split-string registry :separator ":")))
        (when (plusp (length dir))
          (pushnew (uiop:ensure-directory-pathname dir)
                   asdf:*central-registry* :test #'equal))))))

(defun %blackboard-symbol (name)
  (or (find-symbol name "BLACKBOARD.MCP")
      (error "blackboard/mcp loaded but ~A is missing" name)))

(defun %close-blackboard ()
  "Say goodbye on the pool at exit. Never signals."
  (let ((pool *blackboard-pool*))
    (when pool
      (setf *blackboard-pool* nil)
      (ignore-errors
       (funcall (%blackboard-symbol "CLOSE-BLACKBOARD-TOOLS") pool)))))

(defun %register-blackboard (server)
  "Register the blackboard's tools on SERVER when the config file names
a :blackboard target; log one line to stderr and carry on when the
system will not load or the registrar signals. Returns the tool names,
or NIL."
  (let ((target (cl-mcp-server.remote-config:blackboard-target)))
    (when target
      (handler-case
          (progn
            (%blackboard-registry)
            (let ((*standard-output* *error-output*)
                  (*trace-output* *error-output*))
              (asdf:load-system "blackboard/mcp"))
            (multiple-value-bind (pool names)
                (funcall (%blackboard-symbol "REGISTER-BLACKBOARD-TOOLS")
                         server target)
              (setf *blackboard-pool* pool)
              (pushnew '%close-blackboard sb-ext:*exit-hooks*)
              names))
        (error (c)
          (format *error-output*
                  "~&cl-mcp-server: blackboard tools not registered: ~A~%"
                  c)
          (finish-output *error-output*)
          nil)))))

(defun start ()
  "Start the CL REPL MCP server. Reads from stdin, writes to stdout."
  (let ((server (cl-mcp:make-server :name "cl-mcp-server" :version "0.4.4"))
        (session (make-session)))
    (with-session (session)
      (cl-mcp-server.tools:define-builtin-tools server session)
      (%register-blackboard server)
      (cl-mcp:run-server server))))

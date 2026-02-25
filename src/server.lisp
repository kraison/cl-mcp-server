;;; src/server.lisp
;;; ABOUTME: CL-MCP-Server entry point — REPL tools over MCP

(in-package #:cl-mcp-server)

(defun start ()
  "Start the CL REPL MCP server. Reads from stdin, writes to stdout."
  (let ((server (cl-mcp:make-server :name "cl-mcp-server" :version "0.3.0"))
        (session (make-session)))
    (with-session (session)
      (cl-mcp-server.tools:define-builtin-tools server session)
      (cl-mcp:run-server server))))

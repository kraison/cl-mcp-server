;;; tests/packages.lisp
;;; ABOUTME: Test package definitions and helpers

(defpackage #:cl-mcp-server-tests
  (:use #:cl #:fiveam)
  (:export #:run-tests))

(in-package #:cl-mcp-server-tests)

(def-suite cl-mcp-server-tests
  :description "All tests for CL-MCP-Server")

(defun run-tests ()
  "Run all CL-MCP-Server tests."
  (run! 'cl-mcp-server-tests))

;;; Test Helpers

(defun make-test-server ()
  "Create a cl-mcp server with all builtin tools registered.
Returns (values server session)."
  (let ((server (cl-mcp:make-server :name "test-server" :version "0.1.0"))
        (session (cl-mcp-server.session:make-session)))
    (cl-mcp-server.session:with-session (session)
      (cl-mcp-server.tools:define-builtin-tools server session))
    (values server session)))

(defun test-server-registry (server)
  "Get the tool registry from a server."
  (cl-mcp::mcp-server-tools server))

(defun call-test-tool (server name args)
  "Call a tool on SERVER and return the text content as a string.
Extracts text from normalized content blocks."
  (let ((result (cl-mcp.tools:call-tool (test-server-registry server) name args)))
    (cdr (assoc "text" (first result) :test #'string=))))

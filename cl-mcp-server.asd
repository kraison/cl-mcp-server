;;; cl-mcp-server.asd
;;; ABOUTME: ASDF system definition for CL-MCP-Server

(asdf:defsystem #:cl-mcp-server
  :description "Model Context Protocol server for Common Lisp evaluation"
  :author "Abhijit Rao <quasi@quasilabs.com>"
  :license "MIT"
  :version "0.3.0"
  :serial t
  :depends-on (#:cl-mcp            ; MCP protocol framework
               #:alexandria        ; Utilities
               #:bordeaux-threads  ; Threading
               #:usocket           ; SWANK client transport
               #:trivial-backtrace) ; Portable backtraces
  :components ((:module "src"
                :components
                ((:file "packages")
                 (:file "conditions")
                 (:file "error-format")
                 (:file "session")
                 (:file "evaluator")
                 (:file "introspection")
                 (:file "asdf-tools")
                 (:file "profiling-tools")
                 (:file "telos-tools")
                 (:file "paren-tools")
                 (:file "file-tools")
                 (:file "hyperspec-data")
                 (:file "hyperspec")
                 (:file "quicklisp-tools")
                 (:file "restarts")
                 (:file "inspector")
                 (:file "trace-tools")
                 (:file "swank-protocol")
                 (:file "remote")
                 (:file "tools")
                 (:file "server"))))
  :in-order-to ((asdf:test-op (asdf:test-op #:cl-mcp-server/tests))))

(asdf:defsystem #:cl-mcp-server/tests
  :description "Tests for CL-MCP-Server"
  :depends-on (#:cl-mcp-server
               #:fiveam
               ;; Test-only. cl-mcp-server itself degrades gracefully when
               ;; telos is absent, but the name-resolution tests are only
               ;; meaningful against telos's real registry shape.
               #:telos)
  :components ((:module "tests"
                :components
                ((:file "packages")
                 (:file "telos-fixture")
                 (:file "error-format-tests")
                 (:file "session-tests")
                 (:file "evaluator-tests")
                 (:file "tools-tests")
                 (:file "introspection-tests")
                 (:file "asdf-tools-tests")
                 (:file "profiling-tools-tests")
                 (:file "paren-tools-tests")
                 (:file "file-tools-tests")
                 (:file "hyperspec-tests")
                 (:file "quicklisp-tools-tests")
                 (:file "telos-tools-tests")
                 (:file "remote-tests")
                 (:file "integration-tests"))))
  ;; NB: the suite must be named by the symbol interned in the test package,
  ;; not the keyword :cl-mcp-server-tests. FiveAM looks suites up by symbol
  ;; identity, so the keyword silently matches nothing and run! reports
  ;; "Didn't run anything...huh?" while exiting 0 -- green CI over 0 tests.
  :perform (asdf:test-op (o c)
             (unless (uiop:symbol-call :fiveam :run-all-tests
                                       :summary :end)
               (error "cl-mcp-server test suite failed"))))

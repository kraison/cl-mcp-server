;;; cl-mcp-server.asd
;;; ABOUTME: ASDF system definition for CL-MCP-Server

(asdf:defsystem #:cl-mcp-server
  :description "Model Context Protocol server for Common Lisp evaluation"
  :author "Abhijit Rao <quasi@quasilabs.com>"
  :license "MIT"
  :version "0.4.2"
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
                 (:file "remote-config")
                 (:file "remote")
                 (:file "remote-inspect")
                 (:file "tools")
                 (:file "server"))))
  :in-order-to ((asdf:test-op (asdf:test-op #:cl-mcp-server/tests))))

(asdf:defsystem #:cl-mcp-server/tests
  :description "Tests for CL-MCP-Server that need nothing beyond fiveam"
  :depends-on (#:cl-mcp-server
               #:fiveam)
  :components ((:module "tests"
                :components
                ((:file "packages")
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
                 (:file "remote-config-tests")
                 (:file "remote-tests")
                 (:file "remote-inspect-tests")
                 (:file "integration-tests"))))
  ;; NB: the suite must be named by the symbol interned in the test package,
  ;; not the keyword :cl-mcp-server-tests. FiveAM looks suites up by symbol
  ;; identity, so the keyword silently matches nothing and run! reports
  ;; "Didn't run anything...huh?" while exiting 0 -- green CI over 0 tests.
  ;;
  ;; The telos suites live in a separate system, pulled in as a real
  ;; dependency of THIS system's test-op -- but only when telos is actually
  ;; installed. Deciding at read time keeps it a dependency rather than a
  ;; load inside PERFORM, which ASDF deprecates as recursive OPERATE.
  ;;
  ;; They used to sit in this system behind a plain :depends-on, which meant
  ;; a machine without telos could not load it at all: 0 checks ran rather
  ;; than 1181. See issue #1.
  :in-order-to
  #.(if (asdf:find-system "telos" nil)
        '((asdf:test-op (asdf:load-op #:cl-mcp-server/tests-telos)))
        (progn (format *error-output*
                       "~&; cl-mcp-server: telos is not installed, so its ~
                        test suites are skipped.~%; Every other suite still ~
                        runs.~%")
               nil))
  :perform (asdf:test-op (o c)
             (unless (uiop:symbol-call :fiveam :run-all-tests
                                       :summary :end)
               (error "cl-mcp-server test suite failed"))))

(asdf:defsystem #:cl-mcp-server/tests-telos
  :description "Telos-dependent tests, separated so a missing telos cannot
take the rest of the suite down"
  :depends-on (#:cl-mcp-server/tests
               ;; Test-only, and deliberately the real library rather than a
               ;; mock: telos keys its registries by symbols interned in each
               ;; feature's own defining package, and a mock would drift from
               ;; that shape exactly as the wrapper once did -- which is the
               ;; bug these tests exist to catch.
               #:telos)
  :components ((:module "tests"
                :components
                ((:file "telos-fixture")
                 (:file "telos-tools-tests")))))

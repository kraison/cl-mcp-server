;;; tests/integration-tests.lisp
;;; ABOUTME: Integration tests via cl-mcp server API

(in-package #:cl-mcp-server-tests)

(def-suite integration-tests
  :description "MCP server integration tests"
  :in cl-mcp-server-tests)

(in-suite integration-tests)

;;; ==========================================================================
;;; Tool Registration Tests
;;; ==========================================================================

(test builtin-tools-registered
  "Test that define-builtin-tools registers all expected tools"
  (let* ((server (cl-mcp:make-server :name "test" :version "0.1.0"))
         (session (cl-mcp-server.session:make-session))
         (registry (cl-mcp:mcp-server-tools server)))
    (cl-mcp-server.session:with-session (session)
      (cl-mcp-server.tools:define-builtin-tools server session))
    (let ((tools (cl-mcp.tools:list-tools registry)))
      (is (>= (length tools) 20))
      ;; Spot-check key tools
      (dolist (name '("evaluate-lisp" "list-definitions" "reset-session"
                      "load-system" "describe-symbol" "validate-syntax"
                      "get-usage-guide" "configure-limits"))
        (is (not (null (cl-mcp.tools:get-tool registry name)))
            (format nil "Tool ~A should be registered" name))))))

;;; ==========================================================================
;;; Server Full Session Tests (via cl-mcp:run-server)
;;; ==========================================================================

(test server-full-session
  "Test a full MCP session from initialize through tool calls"
  (let* ((server (cl-mcp:make-server :name "cl-mcp-server" :version "0.3.0"))
         (session (cl-mcp-server.session:make-session))
         (input (make-string-input-stream
                 (format nil "~{~a~%~}"
                         '("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
                           "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
                           "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}"
                           "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"evaluate-lisp\",\"arguments\":{\"code\":\"(+ 1 2)\"}}}"))))
         (output (make-string-output-stream)))
    (cl-mcp-server.session:with-session (session)
      (cl-mcp-server.tools:define-builtin-tools server session)
      (cl-mcp:run-server server :input input :output output))
    (let* ((output-str (get-output-stream-string output))
           (lines (remove-if (lambda (s) (zerop (length s)))
                             (split-by-newline output-str))))
      ;; Should have 3 responses (initialize, tools/list, tools/call)
      ;; Notification doesn't generate a response
      (is (= 3 (length lines))))))

(defun split-by-newline (string)
  "Split STRING by newlines."
  (loop with start = 0
        for end = (position #\Newline string :start start)
        collect (subseq string start (or end (length string)))
        while end
        do (setf start (1+ end))))

;;; ==========================================================================
;;; Protocol-Level Tests (via JSON round-trip)
;;; ==========================================================================

(test server-initialize-response
  "Test that initialize response contains expected fields"
  (let* ((server (cl-mcp:make-server :name "cl-mcp-server" :version "0.3.0"))
         (session (cl-mcp-server.session:make-session))
         (input (make-string-input-stream
                 (format nil "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}~%")))
         (output (make-string-output-stream)))
    (cl-mcp-server.session:with-session (session)
      (cl-mcp-server.tools:define-builtin-tools server session)
      (cl-mcp:run-server server :input input :output output))
    (let* ((json-str (string-trim '(#\Newline) (get-output-stream-string output)))
           (parsed (yason:parse json-str :object-as :alist)))
      (is (string= "2.0" (cdr (assoc "jsonrpc" parsed :test #'string=))))
      (is (= 1 (cdr (assoc "id" parsed :test #'string=))))
      (let ((result (cdr (assoc "result" parsed :test #'string=))))
        (is (assoc "serverInfo" result :test #'string=))
        (is (assoc "capabilities" result :test #'string=))
        (is (assoc "protocolVersion" result :test #'string=))))))

(test server-unknown-method-returns-error
  "Test that unknown method returns JSON-RPC error"
  (let* ((server (cl-mcp:make-server :name "test" :version "0.1.0"))
         (session (cl-mcp-server.session:make-session))
         (input (make-string-input-stream
                 (format nil "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"unknown/method\",\"params\":{}}~%")))
         (output (make-string-output-stream)))
    (cl-mcp-server.session:with-session (session)
      (cl-mcp-server.tools:define-builtin-tools server session)
      (cl-mcp:run-server server :input input :output output))
    (let* ((json-str (string-trim '(#\Newline) (get-output-stream-string output)))
           (parsed (yason:parse json-str :object-as :alist)))
      (is (= 1 (cdr (assoc "id" parsed :test #'string=))))
      (let ((err (cdr (assoc "error" parsed :test #'string=))))
        (is (not (null err)))
        (is (= -32601 (cdr (assoc "code" err :test #'string=))))))))

(test server-notification-no-response
  "Test that notifications don't generate responses"
  (let* ((server (cl-mcp:make-server :name "test" :version "0.1.0"))
         (session (cl-mcp-server.session:make-session))
         (input (make-string-input-stream
                 (format nil "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}~%")))
         (output (make-string-output-stream)))
    (cl-mcp-server.session:with-session (session)
      (cl-mcp-server.tools:define-builtin-tools server session)
      (cl-mcp:run-server server :input input :output output))
    (is (string= "" (get-output-stream-string output)))))

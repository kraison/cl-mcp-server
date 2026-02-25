;;; src/conditions.lisp
;;; ABOUTME: REPL-specific condition definitions (extends cl-mcp.conditions)

(in-package #:cl-mcp-server.conditions)

(define-condition evaluation-timeout (cl-mcp.conditions:mcp-error)
  ((timeout-seconds
    :initarg :timeout-seconds
    :reader timeout-seconds
    :documentation "The timeout duration that was exceeded")
   (backtrace
    :initarg :backtrace
    :reader timeout-backtrace
    :initform nil
    :documentation "Stack trace captured at timeout"))
  (:report (lambda (c s)
             (format s "Evaluation exceeded ~A second timeout~@[~%~%Backtrace:~%~A~]"
                     (timeout-seconds c)
                     (timeout-backtrace c))))
  (:documentation "Signaled when code evaluation exceeds the configured timeout"))

;;; tests/paren-tools-tests.lisp
;;; ABOUTME: Tests for parenthesis matching tool

(in-package #:cl-mcp-server-tests)

(def-suite paren-tools-tests
  :description "Tests for parenthesis matching"
  :in cl-mcp-server-tests)

(in-suite paren-tools-tests)

;;; ==========================================================================
;;; Position Conversion Tests
;;; ==========================================================================

(test line-col-to-offset-first-line
  "Convert line 1, column 0 to offset 0"
  (is (= 0 (cl-mcp-server.paren-tools::line-col-to-offset "(hello)" 1 0))))

(test line-col-to-offset-second-line
  "Convert line 2, column 3 to correct offset"
  (let ((code (format nil "abc~%  (def)")))
    (is (= 7 (cl-mcp-server.paren-tools::line-col-to-offset code 2 3)))))

(test line-col-to-offset-invalid
  "Returns nil for out-of-range positions"
  (is (null (cl-mcp-server.paren-tools::line-col-to-offset "(hi)" 5 0))))

(test offset-to-line-col-basic
  "Convert offset back to line and column"
  (let ((code (format nil "abc~%  (def)")))
    (multiple-value-bind (line col)
        (cl-mcp-server.paren-tools::offset-to-line-col code 7)
      (is (= 2 line))
      (is (= 3 col)))))

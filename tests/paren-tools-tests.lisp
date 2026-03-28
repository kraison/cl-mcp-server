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

;;; ==========================================================================
;;; Forward Scan Tests
;;; ==========================================================================

(test scan-forward-simple
  "Find matching close paren for simple form"
  (is (= 4 (cl-mcp-server.paren-tools::scan-forward "(+ 1)" 0))))

(test scan-forward-nested
  "Find matching close paren skipping nested parens"
  (is (= 10 (cl-mcp-server.paren-tools::scan-forward "(+ (* 2 3))" 0))))

(test scan-forward-inner
  "Find matching close paren for inner open paren"
  (is (= 9 (cl-mcp-server.paren-tools::scan-forward "(+ (* 2 3))" 3))))

(test scan-forward-skip-string
  "Parens inside strings are ignored"
  (is (= 10 (cl-mcp-server.paren-tools::scan-forward "(foo \")\" x)" 0))))

(test scan-forward-skip-line-comment
  "Parens inside line comments are ignored"
  (let ((code (format nil "(foo ; )~%  bar)")))
    (is (= (1- (length code)) (cl-mcp-server.paren-tools::scan-forward code 0)))))

(test scan-forward-skip-block-comment
  "Parens inside #|...|# block comments are ignored"
  (is (= 14 (cl-mcp-server.paren-tools::scan-forward "(foo #| ) |# x)" 0))))

(test scan-forward-nested-block-comment
  "Nested block comments are handled"
  (is (= 20 (cl-mcp-server.paren-tools::scan-forward "(foo #| #| ) |# |# x)" 0))))

(test scan-forward-skip-char-literal
  "Character literal #\\( is not an open paren"
  (is (= 8 (cl-mcp-server.paren-tools::scan-forward "(foo #\\()" 0))))

(test scan-forward-skip-char-literal-close
  "Character literal #\\) is not a close paren"
  (is (= 8 (cl-mcp-server.paren-tools::scan-forward "(foo #\\))" 0))))

(test scan-forward-skip-pipe-escape
  "Pipe-escaped symbols |)(| are ignored"
  (is (= 11 (cl-mcp-server.paren-tools::scan-forward "(foo |)(| x)" 0))))

(test scan-forward-unmatched
  "Returns nil for unmatched open paren"
  (is (null (cl-mcp-server.paren-tools::scan-forward "(foo bar" 0))))

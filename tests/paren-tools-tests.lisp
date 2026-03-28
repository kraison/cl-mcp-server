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

;;; ==========================================================================
;;; Backward Scan Tests
;;; ==========================================================================

(test scan-backward-simple
  "Find matching open paren from close paren"
  (is (= 0 (cl-mcp-server.paren-tools::scan-backward "(+ 1)" 4))))

(test scan-backward-nested
  "Find matching open paren skipping nested parens"
  (is (= 0 (cl-mcp-server.paren-tools::scan-backward "(+ (* 2 3))" 10))))

(test scan-backward-inner
  "Find matching open paren for inner close paren"
  (is (= 3 (cl-mcp-server.paren-tools::scan-backward "(+ (* 2 3))" 9))))

(test scan-backward-skip-string
  "Parens inside strings are ignored when scanning backward"
  (is (= 0 (cl-mcp-server.paren-tools::scan-backward "(foo \"(\" x)" 10))))

(test scan-backward-skip-line-comment
  "Parens inside line comments are ignored when scanning backward"
  (let ((code (format nil "(foo~%  ; )~%  bar)")))
    (is (= 0 (cl-mcp-server.paren-tools::scan-backward code (1- (length code)))))))

(test scan-backward-skip-block-comment
  "Parens inside block comments are ignored when scanning backward"
  (is (= 0 (cl-mcp-server.paren-tools::scan-backward "(foo #| ( |# x)" 14))))

(test scan-backward-skip-char-literal
  "Character literal #\\) is not a close paren when scanning backward"
  (is (= 0 (cl-mcp-server.paren-tools::scan-backward "(foo #\\))" 8))))

(test scan-backward-skip-pipe-escape
  "Pipe-escaped symbols are ignored when scanning backward"
  (is (= 0 (cl-mcp-server.paren-tools::scan-backward "(foo |)(| x)" 11))))

(test scan-backward-unmatched
  "Returns nil for unmatched close paren"
  (is (null (cl-mcp-server.paren-tools::scan-backward "foo bar)" 7))))

;;; ==========================================================================
;;; Public API Tests
;;; ==========================================================================

(test find-matching-paren-forward
  "find-matching-paren finds close paren from open paren"
  (let ((result (cl-mcp-server.paren-tools:find-matching-paren "(+ 1 2)" 1 0)))
    (is (getf result :matched))
    (is (= 1 (getf result :match-line)))
    (is (= 6 (getf result :match-column)))
    (is (eq :forward (getf result :direction)))))

(test find-matching-paren-backward
  "find-matching-paren finds open paren from close paren"
  (let* ((code (format nil "(defun foo ()~%  (+ 1 2))"))
         ;; Line 2 = "  (+ 1 2))" — col 9 is the outer ), closing (defun ...)
         (result (cl-mcp-server.paren-tools:find-matching-paren code 2 9)))
    (is (getf result :matched))
    (is (= 1 (getf result :match-line)))
    (is (= 0 (getf result :match-column)))
    (is (eq :backward (getf result :direction)))))

(test find-matching-paren-not-a-paren
  "find-matching-paren returns error when not on a paren"
  (let ((result (cl-mcp-server.paren-tools:find-matching-paren "(+ 1)" 1 1)))
    (is (not (getf result :matched)))
    (is (getf result :error))))

(test find-matching-paren-out-of-range
  "find-matching-paren returns error for invalid position"
  (let ((result (cl-mcp-server.paren-tools:find-matching-paren "(hi)" 99 0)))
    (is (not (getf result :matched)))
    (is (getf result :error))))

(test find-matching-paren-unmatched
  "find-matching-paren returns error for unmatched paren"
  (let ((result (cl-mcp-server.paren-tools:find-matching-paren "(foo bar" 1 0)))
    (is (not (getf result :matched)))
    (is (getf result :error))))

(test format-match-result-forward
  "format-match-result produces readable output for forward match"
  (let ((result (cl-mcp-server.paren-tools:find-matching-paren "(+ 1 2)" 1 0)))
    (let ((output (cl-mcp-server.paren-tools:format-match-result result)))
      (is (search "line 1, column 6" output)))))

(test format-match-result-backward-with-context
  "format-match-result shows context lines for backward match"
  (let* ((code (format nil "(defun foo (a b)~%  (+ a~%     b))"))
         ;; Last close paren closes the defun — find its line+col
         (last-close-pos (1- (length code))))
    ;; Manually compute: "b))" — the last ) is at end of line 3
    ;; Line 3 = "     b))", the last ) is at column 7
    (multiple-value-bind (line col)
        (cl-mcp-server.paren-tools::offset-to-line-col code last-close-pos)
      (let* ((result (cl-mcp-server.paren-tools:find-matching-paren code line col))
             (output (cl-mcp-server.paren-tools:format-match-result result)))
        (is (search "defun" output))
        (is (search "line 1, column 0" output))))))

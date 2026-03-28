;;; src/paren-tools.lisp
;;; ABOUTME: Parenthesis matching tool for navigating Lisp source code
;;;
;;; Given source code and a cursor position (line + column), finds the
;;; matching delimiter and returns its position with surrounding context.
;;; Handles: strings, line comments, block comments (#|...|#),
;;; character literals (#\x), and pipe-escaped symbols (|...|).

(in-package #:cl-mcp-server.paren-tools)

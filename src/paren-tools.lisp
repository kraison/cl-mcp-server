;;; src/paren-tools.lisp
;;; ABOUTME: Parenthesis matching tool for navigating Lisp source code
;;;
;;; Given source code and a cursor position (line + column), finds the
;;; matching delimiter and returns its position with surrounding context.
;;; Handles: strings, line comments, block comments (#|...|#),
;;; character literals (#\x), and pipe-escaped symbols (|...|).

(in-package #:cl-mcp-server.paren-tools)

;;; ==========================================================================
;;; Position Conversion
;;; ==========================================================================

(defun line-col-to-offset (code line column)
  "Convert 1-based LINE and 0-based COLUMN to a 0-based character offset in CODE.
Returns nil if the position is out of range."
  (let ((current-line 1)
        (line-start 0))
    (when (= line 1)
      (return-from line-col-to-offset
        (if (< column (or (position #\Newline code) (length code)))
            column
            nil)))
    (loop for i from 0 below (length code)
          when (char= (char code i) #\Newline)
            do (incf current-line)
               (setf line-start (1+ i))
               (when (= current-line line)
                 (let ((offset (+ line-start column)))
                   (return-from line-col-to-offset
                     (if (<= offset (length code))
                         offset
                         nil)))))
    nil))

(defun offset-to-line-col (code offset)
  "Convert a 0-based character OFFSET to 1-based line and 0-based column.
Returns (values line column)."
  (let ((line 1)
        (line-start 0))
    (loop for i from 0 below (min offset (length code))
          when (char= (char code i) #\Newline)
            do (incf line)
               (setf line-start (1+ i)))
    (values line (- offset line-start))))

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

;;; ==========================================================================
;;; Skip Helpers
;;; ==========================================================================

(defun skip-string (code start)
  "Skip past a string literal starting after the opening quote.
Returns offset after closing quote, or nil if unterminated."
  (let ((i start)
        (len (length code)))
    (loop while (< i len)
          for ch = (char code i)
          do (cond
               ((char= ch #\\) (incf i 2))
               ((char= ch #\") (return-from skip-string (1+ i)))
               (t (incf i))))
    nil))

(defun skip-block-comment (code start)
  "Skip past a block comment starting after the opening #|.
Handles nested #|...|# comments.
Returns offset after closing |#, or nil if unterminated."
  (let ((i start)
        (len (length code))
        (depth 1))
    (loop while (and (< (1+ i) len) (plusp depth))
          do (cond
               ((and (char= (char code i) #\#)
                     (char= (char code (1+ i)) #\|))
                (incf depth)
                (incf i 2))
               ((and (char= (char code i) #\|)
                     (char= (char code (1+ i)) #\#))
                (decf depth)
                (incf i 2))
               (t (incf i))))
    (if (zerop depth) i nil)))

(defun skip-char-literal (code start)
  "Skip past a character literal starting after #\\.
Handles named characters like #\\Newline.
Returns offset after the character literal."
  (let ((len (length code)))
    (when (>= start len)
      (return-from skip-char-literal start))
    (if (and (< (1+ start) len)
             (alpha-char-p (char code start))
             (alpha-char-p (char code (1+ start))))
        (loop for i from start below len
              while (alpha-char-p (char code i))
              finally (return i))
        (1+ start))))

(defun skip-pipe-escape (code start)
  "Skip past a pipe-escaped symbol starting after the opening |.
Returns offset after closing |, or nil if unterminated."
  (let ((i start)
        (len (length code)))
    (loop while (< i len)
          do (cond
               ((char= (char code i) #\\) (incf i 2))
               ((char= (char code i) #\|) (return-from skip-pipe-escape (1+ i)))
               (t (incf i))))
    nil))

;;; ==========================================================================
;;; Forward Scanner
;;; ==========================================================================

(defun scan-forward (code start)
  "Scan forward from open paren at START to find matching close paren.
Returns the offset of the matching close paren, or nil if unmatched.
Skips: strings, line comments, block comments, character literals, pipe escapes."
  (let ((len (length code))
        (depth 1)
        (i (1+ start)))
    (loop while (and (< i len) (plusp depth))
          for ch = (char code i)
          do (cond
               ((char= ch #\")
                (setf i (skip-string code (1+ i)))
                (when (null i) (return-from scan-forward nil)))
               ((char= ch #\;)
                (setf i (or (position #\Newline code :start i) len)))
               ((and (char= ch #\#) (< (1+ i) len))
                (let ((next (char code (1+ i))))
                  (cond
                    ((char= next #\|)
                     (setf i (skip-block-comment code (+ i 2)))
                     (when (null i) (return-from scan-forward nil)))
                    ((char= next #\\)
                     (setf i (skip-char-literal code (+ i 2))))
                    (t (incf i)))))
               ((char= ch #\|)
                (setf i (skip-pipe-escape code (1+ i)))
                (when (null i) (return-from scan-forward nil)))
               ((char= ch #\()
                (incf depth)
                (incf i))
               ((char= ch #\))
                (decf depth)
                (if (zerop depth)
                    (return-from scan-forward i)
                    (incf i)))
               (t (incf i))))
    nil))

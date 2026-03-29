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
        (line-start 0)
        (len (length code)))
    (when (= line 1)
      (let ((offset column))
        (return-from line-col-to-offset
          (if (< offset len) offset nil))))
    (loop for i from 0 below len
          when (char= (char code i) #\Newline)
            do (incf current-line)
               (setf line-start (1+ i))
               (when (= current-line line)
                 (let ((offset (+ line-start column)))
                   (return-from line-col-to-offset
                     (if (< offset len) offset nil)))))
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

;;; ==========================================================================
;;; Context Map for Backward Scanning
;;; ==========================================================================

(defun build-context-map (code)
  "Build a boolean vector marking syntactically inert positions in CODE.
A position is inert if it's inside a string, comment, character literal,
or pipe-escaped symbol. Returns a simple bit vector where 1 = inert."
  (let* ((len (length code))
         (inert (make-array len :element-type 'bit :initial-element 0))
         (i 0))
    (loop while (< i len)
          for ch = (char code i)
          do (cond
               ((char= ch #\")
                (let ((end (skip-string code (1+ i))))
                  (if end
                      (progn
                        (loop for j from i below end
                              do (setf (aref inert j) 1))
                        (setf i end))
                      (progn
                        (loop for j from i below len
                              do (setf (aref inert j) 1))
                        (setf i len)))))
               ((char= ch #\;)
                (let ((end (or (position #\Newline code :start i) len)))
                  (loop for j from i below end
                        do (setf (aref inert j) 1))
                  (setf i end)))
               ((and (char= ch #\#) (< (1+ i) len))
                (let ((next (char code (1+ i))))
                  (cond
                    ((char= next #\|)
                     (let ((end (skip-block-comment code (+ i 2))))
                       (if end
                           (progn
                             (loop for j from i below end
                                   do (setf (aref inert j) 1))
                             (setf i end))
                           (progn
                             (loop for j from i below len
                                   do (setf (aref inert j) 1))
                             (setf i len)))))
                    ((char= next #\\)
                     (let ((end (skip-char-literal code (+ i 2))))
                       (loop for j from i below end
                             do (setf (aref inert j) 1))
                       (setf i end)))
                    (t (incf i)))))
               ((char= ch #\|)
                (let ((end (skip-pipe-escape code (1+ i))))
                  (if end
                      (progn
                        (loop for j from i below end
                              do (setf (aref inert j) 1))
                        (setf i end))
                      (progn
                        (loop for j from i below len
                              do (setf (aref inert j) 1))
                        (setf i len)))))
               (t (incf i))))
    inert))

;;; ==========================================================================
;;; Backward Scanner
;;; ==========================================================================

(defun scan-backward (code start)
  "Scan backward from close paren at START to find matching open paren.
Returns the offset of the matching open paren, or nil if unmatched."
  (let ((inert (build-context-map code))
        (depth 1)
        (i (1- start)))
    (loop while (and (>= i 0) (plusp depth))
          do (cond
               ((= 1 (aref inert i))
                (decf i))
               ((char= (char code i) #\()
                (decf depth)
                (if (zerop depth)
                    (return-from scan-backward i)
                    (decf i)))
               ((char= (char code i) #\))
                (incf depth)
                (decf i))
               (t (decf i))))
    nil))

;;; ==========================================================================
;;; Helper Functions
;;; ==========================================================================

(defun extract-context (code offset &key (radius 2))
  "Extract RADIUS lines above and below the line containing OFFSET.
Returns a list of (line-number . text) pairs."
  (multiple-value-bind (target-line col) (offset-to-line-col code offset)
    (declare (ignore col))
    (let* ((lines (coerce (uiop:split-string code :separator '(#\Newline))
                          'vector))
           (start (max 1 (- target-line radius)))
           (end (min (length lines) (+ target-line radius))))
      (loop for n from start to end
            collect (cons n (aref lines (1- n)))))))

;;; ==========================================================================
;;; Public API
;;; ==========================================================================

(defun find-matching-paren (code line column)
  "Find the matching parenthesis in CODE at LINE (1-based) and COLUMN (0-based).
Returns a plist with:
  :matched      — T if a match was found
  :direction    — :forward (from open) or :backward (from close)
  :source-line  — original line
  :source-column — original column
  :match-line   — 1-based line of match
  :match-column — 0-based column of match
  :context      — lines of code surrounding the match
  :error        — error message if no match"
  (let ((offset (line-col-to-offset code line column)))
    (cond
      ((or (null offset) (>= offset (length code)))
       (list :matched nil
             :error (format nil "Position out of range: line ~D, column ~D" line column)))
      (t
       (let ((ch (char code offset)))
         (cond
           ((char= ch #\()
            (let ((match (scan-forward code offset)))
              (if match
                  (multiple-value-bind (ml mc) (offset-to-line-col code match)
                    (list :matched t
                          :direction :forward
                          :source-line line
                          :source-column column
                          :match-line ml
                          :match-column mc
                          :context (extract-context code match)))
                  (list :matched nil
                        :error (format nil "Unmatched open paren at line ~D, column ~D"
                                       line column)))))
           ((char= ch #\))
            (let ((match (scan-backward code offset)))
              (if match
                  (multiple-value-bind (ml mc) (offset-to-line-col code match)
                    (list :matched t
                          :direction :backward
                          :source-line line
                          :source-column column
                          :match-line ml
                          :match-column mc
                          :context (extract-context code match)))
                  (list :matched nil
                        :error (format nil "Unmatched close paren at line ~D, column ~D"
                                       line column)))))
           (t
            (list :matched nil
                  :error (format nil "Character at line ~D, column ~D is '~C', not a parenthesis"
                                 line column ch)))))))))

(defun format-match-result (result)
  "Format a match result plist as a human-readable string."
  (with-output-to-string (s)
    (if (not (getf result :matched))
        (format s "No match: ~A" (getf result :error))
        (let ((dir (getf result :direction))
              (ml (getf result :match-line))
              (mc (getf result :match-column)))
          (format s "~A from line ~D, column ~D~%"
                  (if (eq dir :forward)
                      "Matching ) found"
                      "Matching ( found")
                  (getf result :source-line)
                  (getf result :source-column))
          (format s "Match at line ~D, column ~D~%~%" ml mc)
          (format s "Context:~%")
          (dolist (ctx (getf result :context))
            (let ((line-num (car ctx))
                  (line-text (cdr ctx)))
              (if (= line-num ml)
                  (format s "  ~4D: ~A  ◀ match~%" line-num line-text)
                  (format s "  ~4D: ~A~%" line-num line-text))))))))

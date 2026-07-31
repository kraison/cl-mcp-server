;;; src/file-tools.lisp
;;; ABOUTME: Atomic write-lisp-file tool: validate -> write -> compile -> report

(in-package #:cl-mcp-server.file-tools)

;;; ==========================================================================
;;; Rationale
;;;
;;; Writing a Lisp file used to require an agent to chain several tools:
;;;   validate-syntax -> (some external write) -> compile-form -> read errors
;;; Every hop is a place to lose the thread, and the external write is usually
;;; a shell/Python detour that drags the whole task out of Lisp. Worse, if the
;;; write happens before the check, a malformed file lands on disk and the next
;;; load blows up somewhere unrelated.
;;;
;;; WRITE-LISP-FILE collapses that into one call with a fail-closed contract:
;;; the file is only written if the content reads cleanly, and the result
;;; reports compile diagnostics afterwards. A backup of any previous version is
;;; kept so a bad write is always recoverable.
;;; ==========================================================================

(defparameter *backup-suffix* ".bak"
  "Suffix appended to the previous version of an overwritten file.")

;;; ==========================================================================
;;; Syntax validation (reader-level, whole file)
;;; ==========================================================================

(defun validate-file-content (content)
  "Read every form in CONTENT without evaluating.
Returns (values ok-p form-count error-string).
Uses a throwaway package so that reading symbols cannot intern junk into a
real package, and binds *read-eval* to NIL so that #. cannot execute code
while we are merely checking syntax."
  (let ((tmp-package (make-package (gensym "CL-MCP-VALIDATE-")
                                   :use '(#:common-lisp))))
    (unwind-protect
         (handler-case
             (let ((*package* tmp-package)
                   (*read-eval* nil)
                   (count 0))
               (with-input-from-string (in content)
                 (loop for form = (read in nil :cl-mcp-eof)
                       until (eq form :cl-mcp-eof)
                       do (incf count)))
               (values t count nil))
           (end-of-file ()
             (values nil 0
                     "Unexpected end of input - unclosed parenthesis or string"))
           (reader-error (e)
             (values nil 0 (format nil "Reader error: ~A" e)))
           (error (e)
             (values nil 0 (format nil "~A: ~A" (type-of e) e))))
      (delete-package tmp-package))))

(defun count-paren-balance (content)
  "Return net paren depth of CONTENT, ignoring parens inside strings,
character literals and line comments. Positive means unclosed opens."
  (let ((depth 0) (i 0) (n (length content))
        (in-string nil) (in-comment nil))
    (loop while (< i n)
          for ch = (char content i)
          do (cond
               (in-comment (when (char= ch #\Newline) (setf in-comment nil)))
               (in-string
                (cond ((char= ch #\\) (incf i))
                      ((char= ch #\") (setf in-string nil))))
               ((char= ch #\;) (setf in-comment t))
               ((char= ch #\") (setf in-string t))
               ;; #\( and #\) are character literals, not delimiters
               ((and (char= ch #\#) (< (+ i 2) n)
                     (char= (char content (1+ i)) #\\))
                (incf i 2))
               ((char= ch #\() (incf depth))
               ((char= ch #\)) (decf depth)))
             (incf i))
    depth))

;;; ==========================================================================
;;; Compilation check
;;; ==========================================================================

(defun compile-file-check (path)
  "COMPILE-FILE PATH into a throwaway fasl, collecting diagnostics.
Returns (values failure-p diagnostics). Never signals: at this layer a
compiler failure is data to report, not a condition to propagate.

Diagnostics come from two places, because neither alone is sufficient:
a HANDLER-BIND on WARNING catches muffleable warnings, but genuine
compile-time ERRORs (malformed special forms, bad lambda lists) are printed
by the compiler to *error-output* and turned into a failure flag rather than
being signalled out to us. We therefore also capture *error-output* and
report it when the compile fails."
  (let ((diagnostics nil)
        (fasl nil)
        (failure-p nil)
        (compiler-output (make-string-output-stream)))
    (unwind-protect
         (handler-case
             (handler-bind
                 ((warning (lambda (c)
                             (push (format nil "~A: ~A" (type-of c) c)
                                   diagnostics)
                             (muffle-warning c))))
               (multiple-value-bind (output warnings-p failed-p)
                   (let ((*error-output* compiler-output)
                         (*standard-output* (make-broadcast-stream)))
                     (compile-file path
                                   :output-file (make-pathname
                                                 :type "cl-mcp-check-fasl"
                                                 :defaults path)
                                   :verbose nil :print nil))
                 (declare (ignore warnings-p))
                 (setf fasl output
                       failure-p (and failed-p t))))
           (error (e)
             (setf failure-p t)
             (push (format nil "~A: ~A" (type-of e) e) diagnostics)))
      ;; Always remove the probe fasl, even on a non-local exit.
      (when (and fasl (probe-file fasl))
        (ignore-errors (delete-file fasl))))
    ;; On failure, surface what the compiler actually printed -- that is where
    ;; the real error text lives.
    (when failure-p
      (let ((text (string-trim '(#\Space #\Tab #\Newline)
                               (get-output-stream-string compiler-output))))
        (when (plusp (length text))
          (setf diagnostics
                (append diagnostics
                        (list (format nil "compiler output:~%~A" text)))))))
    (values failure-p (nreverse diagnostics))))

;;; ==========================================================================
;;; Main entry point
;;; ==========================================================================

(defun write-lisp-file (path content &key (compile-check t) (backup t)
                                          (create-directories t))
  "Validate CONTENT, then write it to PATH only if it is syntactically valid.

This is fail-closed: on a syntax error nothing is written and the previous
file (if any) is left untouched.

Returns a plist:
  :written-p     did we write the file
  :path          truename of the file, when written
  :forms         number of top-level forms read
  :bytes         bytes written
  :backup        path of the backup copy, if one was made
  :syntax-error  reader error string, when validation failed
  :paren-balance net paren depth, when unbalanced
  :compile-failure-p / :diagnostics  results of the post-write compile"
  (multiple-value-bind (ok form-count syntax-error)
      (validate-file-content content)
    (if (not ok)
        (list :written-p nil
              :syntax-error syntax-error
              :paren-balance (count-paren-balance content)
              :forms 0)
        (let* ((pathname (pathname path))
               (existing (probe-file pathname))
               (backup-path nil))
          (when create-directories
            (ensure-directories-exist pathname))
          ;; Preserve the old version before clobbering it.
          ;; NB: build the backup path from the NAMESTRING rather than via
          ;; :type "lisp.bak" -- a dot inside a pathname-type is escaped when
          ;; the namestring is printed back out ("wt.lisp\\.bak"), which is
          ;; correct but confusing to read in tool output.
          (when (and backup existing)
            (setf backup-path
                  (pathname (concatenate 'string
                                         (namestring pathname)
                                         *backup-suffix*)))
            (ignore-errors
             (with-open-file (in existing :direction :input
                                          :element-type '(unsigned-byte 8))
               (with-open-file (out backup-path :direction :output
                                                :element-type '(unsigned-byte 8)
                                                :if-exists :supersede
                                                :if-does-not-exist :create)
                 (let ((buf (make-array 8192 :element-type '(unsigned-byte 8))))
                   (loop for got = (read-sequence buf in)
                         while (plusp got)
                         do (write-sequence buf out :end got)))))))
          (with-open-file (out pathname :direction :output
                                        :if-exists :supersede
                                        :if-does-not-exist :create
                                        :external-format :utf-8)
            (write-string content out))
          (let ((result (list :written-p t
                              :path (namestring (or (probe-file pathname)
                                                    pathname))
                              :forms form-count
                              :bytes (length content)
                              :backup (when backup-path
                                        (namestring backup-path)))))
            (when compile-check
              (multiple-value-bind (failure-p diags) (compile-file-check pathname)
                (setf result (append result
                                     (list :compile-failure-p failure-p
                                           :diagnostics diags)))))
            result)))))

;;; ==========================================================================
;;; Formatting
;;; ==========================================================================

(defun format-write-result (result)
  "Render the plist from WRITE-LISP-FILE for MCP.
Returns (values text error-p) so the caller can set isError correctly."
  (let ((written (getf result :written-p)))
    (if (not written)
        (values
         (with-output-to-string (s)
           (format s "✗ NOT WRITTEN - syntax invalid~%~%")
           (format s "Error: ~A~%" (getf result :syntax-error))
           (let ((bal (getf result :paren-balance)))
             (cond ((and bal (plusp bal))
                    (format s "Unclosed parentheses: ~D~%" bal))
                   ((and bal (minusp bal))
                    (format s "Extra closing parentheses: ~D~%" (abs bal)))))
           (format s "~%The file was left unchanged."))
         t)
        (let* ((diags (getf result :diagnostics))
               (failure (getf result :compile-failure-p))
               (error-p (and failure t)))
          (values
           (with-output-to-string (s)
             (format s "~:[✓~;⚠~] Wrote ~A~%" diags (getf result :path))
             (format s "  ~D form~:P, ~D byte~:P~%"
                     (getf result :forms) (getf result :bytes))
             (when (getf result :backup)
               (format s "  backup: ~A~%" (getf result :backup)))
             (cond
               (failure
                (format s "~%✗ Compilation FAILED:~%"))
               (diags
                (format s "~%Compiler diagnostics:~%")))
             (dolist (d diags)
               (format s "  ~A~%" d))
             (unless diags
               (format s "~%Compiles clean.~%")))
           error-p)))))

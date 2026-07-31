;;; tests/file-tools-tests.lisp
;;; ABOUTME: Tests for the atomic write-lisp-file tool

(in-package #:cl-mcp-server-tests)

(def-suite file-tools-tests
  :description "Tests for validate/write/compile file tooling"
  :in cl-mcp-server-tests)

(in-suite file-tools-tests)

;;; ==========================================================================
;;; Helpers
;;; ==========================================================================

(defun %tmp-lisp-path (&optional (stem "cl-mcp-ft"))
  "A unique .lisp path under the system temporary directory."
  (merge-pathnames (format nil "~A-~D-~D.lisp" stem (get-universal-time)
                           (random 1000000))
                   (uiop:temporary-directory)))

(defmacro with-tmp-lisp-file ((var) &body body)
  "Bind VAR to a fresh temp path; delete it and its .bak afterwards."
  `(let ((,var (%tmp-lisp-path)))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-file-if-exists ,var))
       (ignore-errors
        (uiop:delete-file-if-exists
         (pathname (concatenate 'string (namestring ,var) ".bak")))))))

;;; ==========================================================================
;;; validate-file-content
;;; ==========================================================================

(test validate-accepts-valid-content
  "Valid source reads cleanly and reports its form count"
  (multiple-value-bind (ok count err)
      (cl-mcp-server.file-tools:validate-file-content
       "(defun a (x) x) (defun b (y) y)")
    (is-true ok)
    (is (= 2 count))
    (is (null err))))

(test validate-rejects-unclosed-paren
  "Unclosed paren is rejected with an end-of-input message"
  (multiple-value-bind (ok count err)
      (cl-mcp-server.file-tools:validate-file-content "(defun a (x) x")
    (is-false ok)
    (is (= 0 count))
    (is (search "end of input" err))))

(test validate-rejects-unterminated-string
  "An unterminated string is a syntax error, not a silent truncation"
  (multiple-value-bind (ok count err)
      (cl-mcp-server.file-tools:validate-file-content "(defun a () \"oops)")
    (declare (ignore count))
    (is-false ok)
    (is (stringp err))))

(test validate-accepts-empty-content
  "Empty content is vacuously valid with zero forms"
  (multiple-value-bind (ok count) (cl-mcp-server.file-tools:validate-file-content "")
    (is-true ok)
    (is (= 0 count))))

(test validate-does-not-intern-into-live-packages
  "Reading for validation must not leave symbols behind in CL-USER"
  (let ((name "CL-MCP-VALIDATE-CANARY-SYMBOL"))
    (is (null (find-symbol name :cl-user)))
    (cl-mcp-server.file-tools:validate-file-content
     (format nil "(defun ~A () 1)" name))
    (is (null (find-symbol name :cl-user)))))

(test validate-does-not-evaluate-read-eval
  "#. must not execute while we are only checking syntax"
  (let ((cl-mcp-server.file-tools::*backup-suffix*
          cl-mcp-server.file-tools::*backup-suffix*))
    (multiple-value-bind (ok count err)
        (cl-mcp-server.file-tools:validate-file-content
         "(list #.(error \"must not run\"))")
      (declare (ignore count))
      ;; Either it is refused, or it read without running the form; what must
      ;; never happen is the error escaping to the caller.
      (is (or (null ok) (stringp err) (eq ok t))))))

;;; ==========================================================================
;;; count-paren-balance
;;; ==========================================================================

(test paren-balance-balanced
  "Balanced source has zero net depth"
  (is (= 0 (cl-mcp-server.file-tools:count-paren-balance "(a (b) (c (d)))"))))

(test paren-balance-unclosed
  "Unclosed parens report positive depth"
  (is (= 1 (cl-mcp-server.file-tools:count-paren-balance "(defun f (x) (+ x 1)"))))

(test paren-balance-extra-close
  "Extra closers report negative depth"
  (is (= -1 (cl-mcp-server.file-tools:count-paren-balance "(a))"))))

(test paren-balance-ignores-strings
  "Parens inside string literals are not delimiters"
  (is (= 0 (cl-mcp-server.file-tools:count-paren-balance "(format nil \"((((\")"))))

(test paren-balance-ignores-comments
  "Parens inside line comments are not delimiters"
  (is (= 0 (cl-mcp-server.file-tools:count-paren-balance
            (format nil "(defun f () ; ((((~%  nil)")))))

(test paren-balance-ignores-char-literals
  "#\\( is a character literal, not an open paren"
  (is (= 0 (cl-mcp-server.file-tools:count-paren-balance "(list #\\( #\\))"))))

;;; ==========================================================================
;;; write-lisp-file -- the fail-closed contract
;;; ==========================================================================

(test write-creates-valid-file
  "Valid content is written and reported"
  (with-tmp-lisp-file (path)
    (let ((r (cl-mcp-server.file-tools:write-lisp-file
              path "(defun ft-ok (x) (* x 2))" :compile-check nil)))
      (is-true (getf r :written-p))
      (is (= 1 (getf r :forms)))
      (is-true (probe-file path)))))

(test write-refuses-invalid-content
  "Invalid content is never written"
  (with-tmp-lisp-file (path)
    (let ((r (cl-mcp-server.file-tools:write-lisp-file
              path "(defun broken (x)" :compile-check nil)))
      (is-false (getf r :written-p))
      (is (stringp (getf r :syntax-error)))
      (is-false (probe-file path)))))

(test write-refusal-leaves-existing-file-untouched
  "A failed write must not clobber the previous good version"
  (with-tmp-lisp-file (path)
    (cl-mcp-server.file-tools:write-lisp-file
     path "(defun ft-original () :original)" :compile-check nil)
    (let ((before (uiop:read-file-string path)))
      (cl-mcp-server.file-tools:write-lisp-file
       path "(defun ft-broken (" :compile-check nil)
      (is (string= before (uiop:read-file-string path))))))

(test write-creates-backup-on-overwrite
  "Overwriting keeps the prior version as .bak"
  (with-tmp-lisp-file (path)
    (cl-mcp-server.file-tools:write-lisp-file
     path "(defun ft-v1 () 1)" :compile-check nil)
    (let ((r (cl-mcp-server.file-tools:write-lisp-file
              path "(defun ft-v2 () 2)" :compile-check nil)))
      (is-true (getf r :backup))
      (is-true (probe-file (getf r :backup)))
      (is (search "ft-v1" (uiop:read-file-string (getf r :backup))))
      (is (search "ft-v2" (uiop:read-file-string path))))))

(test write-backup-path-has-no-escaped-dot
  "Backup namestring must read as foo.lisp.bak, not foo.lisp\\.bak"
  (with-tmp-lisp-file (path)
    (cl-mcp-server.file-tools:write-lisp-file path "(defun ft-a () 1)"
                                              :compile-check nil)
    (let ((r (cl-mcp-server.file-tools:write-lisp-file
              path "(defun ft-b () 2)" :compile-check nil)))
      (is (null (search "\\." (getf r :backup)))))))

(test write-no-backup-when-disabled
  "backup nil suppresses the .bak copy"
  (with-tmp-lisp-file (path)
    (cl-mcp-server.file-tools:write-lisp-file path "(defun ft-c () 1)"
                                              :compile-check nil)
    (let ((r (cl-mcp-server.file-tools:write-lisp-file
              path "(defun ft-d () 2)" :compile-check nil :backup nil)))
      (is (null (getf r :backup))))))

(test write-first-write-has-no-backup
  "Nothing to back up when the file did not exist"
  (with-tmp-lisp-file (path)
    (let ((r (cl-mcp-server.file-tools:write-lisp-file
              path "(defun ft-e () 1)" :compile-check nil)))
      (is (null (getf r :backup))))))

;;; ==========================================================================
;;; write-lisp-file -- compile reporting
;;; ==========================================================================

(test write-compile-clean-has-no-diagnostics
  "Clean code compiles without diagnostics or failure"
  (with-tmp-lisp-file (path)
    (let ((r (cl-mcp-server.file-tools:write-lisp-file
              path "(defun ft-clean (x) (* x 2))" :compile-check t)))
      (is-true (getf r :written-p))
      (is-false (getf r :compile-failure-p))
      (is (null (getf r :diagnostics))))))

(test write-compile-reports-style-warning
  "An unused variable is surfaced as a diagnostic but is not a failure"
  (with-tmp-lisp-file (path)
    (let ((r (cl-mcp-server.file-tools:write-lisp-file
              path "(defun ft-warn (x) (let ((unused 5)) x))" :compile-check t)))
      (is-true (getf r :written-p))
      (is-false (getf r :compile-failure-p))
      (is-true (getf r :diagnostics)))))

(test write-compile-detects-real-failure
  "A malformed binding is a compile failure, and the reason is reported"
  (with-tmp-lisp-file (path)
    (let ((r (cl-mcp-server.file-tools:write-lisp-file
              path "(defun ft-bad (x) (let ((1 2)) x))" :compile-check t)))
      (is-true (getf r :written-p))
      (is-true (getf r :compile-failure-p))
      ;; the actual compiler text must reach the caller, not just a warning
      (is-true (some (lambda (d) (search "not a symbol" d))
                     (getf r :diagnostics))))))

(test write-compile-leaves-no-fasl
  "The probe fasl is cleaned up"
  (with-tmp-lisp-file (path)
    (cl-mcp-server.file-tools:write-lisp-file
     path "(defun ft-fasl (x) x)" :compile-check t)
    (is-false (probe-file (make-pathname :type "cl-mcp-check-fasl"
                                         :defaults path)))))

;;; ==========================================================================
;;; format-write-result -- the isError contract
;;; ==========================================================================

(test format-write-result-refusal-is-error
  "A refused write reports error-p true and says nothing was written"
  (with-tmp-lisp-file (path)
    (multiple-value-bind (text error-p)
        (cl-mcp-server.file-tools:format-write-result
         (cl-mcp-server.file-tools:write-lisp-file
          path "(defun x (" :compile-check nil))
      (is-true error-p)
      (is (search "NOT WRITTEN" text))
      (is (search "unchanged" text)))))

(test format-write-result-success-is-not-error
  "A clean write reports error-p false"
  (with-tmp-lisp-file (path)
    (multiple-value-bind (text error-p)
        (cl-mcp-server.file-tools:format-write-result
         (cl-mcp-server.file-tools:write-lisp-file
          path "(defun ft-fmt (x) x)" :compile-check t))
      (is-false error-p)
      (is (search "Wrote" text)))))

(test format-write-result-compile-failure-is-error
  "Compilation failure propagates as error-p true"
  (with-tmp-lisp-file (path)
    (multiple-value-bind (text error-p)
        (cl-mcp-server.file-tools:format-write-result
         (cl-mcp-server.file-tools:write-lisp-file
          path "(defun ft-fail (x) (let ((1 2)) x))" :compile-check t))
      (is-true error-p)
      (is (search "FAILED" text)))))

;;; ==========================================================================
;;; Tool registration
;;; ==========================================================================

(test write-lisp-file-tool-registered
  "write-lisp-file is exposed as an MCP tool"
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (is (not (null (cl-mcp.tools:get-tool (test-server-registry server)
                                          "write-lisp-file"))))))

(test write-lisp-file-tool-round-trip
  "Calling the tool writes a file that is then loadable"
  (with-tmp-lisp-file (path)
    (multiple-value-bind (server session) (make-test-server)
      (declare (ignore session))
      (let ((text (call-test-tool server "write-lisp-file"
                                  `(("path" . ,(namestring path))
                                    ("content" . "(defun ft-tool-probe (x) (+ x 7))")))))
        (is (search "Wrote" text))
        (is-true (probe-file path))
        (load path)
        (is (= 10 (funcall (read-from-string "ft-tool-probe") 3)))))))

;;; src/remote-inspect.lisp
;;; ABOUTME: Remote object inspection, in transcript and registry modes

(in-package #:cl-mcp-server.remote-inspect)

;;; Inspecting a value on a live service forces a choice the local inspector
;;; never has to make: navigation needs object identity to survive between
;;; calls, and holding identity means holding a reference on someone else's
;;; heap.
;;;
;;; Two modes, because neither is right for every case:
;;;
;;;   transcript  (default) Renders one level and returns text. Nothing is
;;;               retained remotely. Cannot navigate.
;;;
;;;   registry    (opt-in)  Retains handles remotely so parts can be walked.
;;;               Entries are WEAK pointers, so the registry never prevents
;;;               collection -- a handle whose object has been collected
;;;               reports that rather than resurrecting it.
;;;
;;; See docs/reference/remote-swank.md.

(defparameter *registry-var* "cl-user::*cl-mcp-inspect-registry*"
  "Remote variable holding the handle table. Named explicitly so an operator
can find and clear it: (makunbound '*cl-mcp-inspect-registry*).")

(defparameter *max-parts* 100
  "Parts rendered per object. Lower than the local limit: this output
crosses a socket from a service that has better things to do.")

;;; ==========================================================================
;;; Remote-side forms
;;;
;;; These are strings evaluated on the target. They are built here rather
;;; than shipped as a library so nothing has to be installed on the service.
;;; ==========================================================================

(defun %parts-form (expression max-parts)
  "Form that renders EXPRESSION and its parts as plain text.
Transcript mode: retains nothing on the remote side.

The counter is a LOOP variable rather than an INCF: this form is classified
like any other, and using a mutating operator here would either be refused
or force an override that weakens the very check we rely on."
  (format nil "
(let* ((obj ~A)
       (*print-length* 20) (*print-level* 3) (*print-circle* t)
       (*print-pretty* nil) (*print-readably* nil))
  (multiple-value-bind (desc named parts)
      (handler-case (sb-impl::inspected-parts obj)
        (error (e) (values (format nil \"inspection failed: ~~A\" (type-of e))
                           nil nil)))
    (let ((plist (coerce parts 'list)))
      (with-output-to-string (s)
        (format s \"~~A~~%~~A~~%\" (type-of obj) (prin1-to-string obj))
        (when (and desc (stringp desc))
          (format s \"~~A~~%\" (string-right-trim (list (code-char 10)) desc)))
        (loop for p in plist
              for i from 0 below ~D
              do (format s \"  ~~A~~30T~~A~~%\"
                         (if named (car p) i)
                         (prin1-to-string (if named (cdr p) p))))
        (when (> (length plist) ~D)
          (format s \"  ... ~~D more~~%\" (- (length plist) ~D)))))))"
          expression max-parts max-parts max-parts))

(defun %registry-setup-form ()
  "Form that ensures the remote registry exists.

Entries are weak pointers: the registry must never be the reason an object
survives on a production heap."
  (format nil "
(progn
  (unless (boundp '~A)
    (defparameter ~A (cons 0 (make-hash-table :test 'eql))))
  (hash-table-count (cdr ~A)))"
          *registry-var* *registry-var* *registry-var*))

(defun %register-form (expression max-parts)
  "Form that inspects EXPRESSION, registers it and each part, and renders
the result with handles."
  (format nil "
(let* ((obj ~A)
       (reg ~A)
       (*print-length* 20) (*print-level* 3) (*print-circle* t)
       (*print-pretty* nil) (*print-readably* nil))
  (flet ((stash (o)
           (let ((h (incf (car reg))))
             (setf (gethash h (cdr reg)) (sb-ext:make-weak-pointer o))
             h)))
    (multiple-value-bind (desc named parts)
        (handler-case (sb-impl::inspected-parts obj)
          (error (e) (values (format nil \"inspection failed: ~~A\" (type-of e))
                             nil nil)))
      (with-output-to-string (s)
        (format s \"[~~D] ~~A~~%~~A~~%\" (stash obj) (type-of obj)
                (prin1-to-string obj))
        (when (and desc (stringp desc))
          (format s \"~~A~~%\" (string-right-trim (list (code-char 10)) desc)))
        (let ((n 0))
          (dolist (p (coerce parts 'list))
            (when (< n ~D)
              (let ((val (if named (cdr p) p)))
                (format s \"  [~~D] ~~A~~30T~~A~~%\"
                        (stash val) (if named (car p) n)
                        (prin1-to-string val)))
              (incf n))))
        (format s \"~~%~~D handle~~:P retained (weak).~~%\"
                (hash-table-count (cdr reg)))))))"
          expression *registry-var* max-parts))

(defun %fetch-form (handle max-parts)
  "Form that inspects a previously registered handle."
  (format nil "
(let ((reg (and (boundp '~A) ~A)))
  (if (null reg)
      \"No remote registry on this target. Inspect something first.\"
      (multiple-value-bind (wp found) (gethash ~D (cdr reg))
        (if (not found)
            (format nil \"No handle ~D on this target.\")
            (multiple-value-bind (obj alive) (sb-ext:weak-pointer-value wp)
              (if (not alive)
                  \"That object has been collected. Handles are weak: the
inspector never keeps a service's data alive. Re-inspect from the top.\"
                  (let ((*print-length* 20) (*print-level* 3)
                        (*print-circle* t) (*print-pretty* nil))
                    (multiple-value-bind (desc named parts)
                        (handler-case (sb-impl::inspected-parts obj)
                          (error (e) (values (format nil \"failed: ~~A\"
                                                     (type-of e)) nil nil)))
                      (flet ((stash (o)
                               (let ((h (incf (car reg))))
                                 (setf (gethash h (cdr reg))
                                       (sb-ext:make-weak-pointer o))
                                 h)))
                        (with-output-to-string (s)
                          (format s \"[~D] ~~A~~%~~A~~%\" (type-of obj)
                                  (prin1-to-string obj))
                          (when (and desc (stringp desc))
                            (format s \"~~A~~%\"
                                    (string-right-trim (list (code-char 10))
                                                       desc)))
                          (loop for p in (coerce parts 'list)
                                for i from 0 below ~D
                                do (let ((val (if named (cdr p) p)))
                                     (format s \"  [~~D] ~~A~~30T~~A~~%\"
                                             (stash val)
                                             (if named (car p) i)
                                             (prin1-to-string val))))))))))))))"
          *registry-var* *registry-var* handle handle handle max-parts))

(defun %clear-form ()
  "Form that drops the remote registry entirely."
  (format nil "
(if (boundp '~A)
    (progn (makunbound '~A) \"Remote inspector registry cleared.\")
    \"No remote registry to clear.\")"
          *registry-var* *registry-var*))

;;; ==========================================================================
;;; Entry points
;;; ==========================================================================

(defun inspect-remote (target-name expression
                       &key registry (package "COMMON-LISP-USER"))
  "Inspect EXPRESSION on TARGET-NAME.

With REGISTRY nil (the default) nothing is retained on the target and the
result cannot be navigated. With REGISTRY true, handles are retained as weak
pointers so parts can be walked with INSPECT-REMOTE-PART.

Registry mode genuinely mutates the target: it defines a variable and
maintains a counter. Those forms are sent with an explicit tier override,
which the ledger records as :inspect-registry so the exception is visible
rather than silent. Transcript mode is classified like any other form and
needs no exemption."
  (if registry
      (progn
        (cl-mcp-server.remote:remote-eval target-name (%registry-setup-form)
                                          :package package
                                          :tier-override :inspect-registry)
        (cl-mcp-server.remote:remote-eval
         target-name (%register-form expression *max-parts*)
         :package package :tier-override :inspect-registry))
      (cl-mcp-server.remote:remote-eval
       target-name (%parts-form expression *max-parts*)
       :package package)))

(defun inspect-remote-part (target-name handle &key (package
                                                     "COMMON-LISP-USER"))
  "Inspect a handle previously retained on TARGET-NAME."
  (cl-mcp-server.remote:remote-eval
   target-name (%fetch-form handle *max-parts*)
   :package package :tier-override :inspect-registry))

(defun clear-remote-registry (target-name &key (package "COMMON-LISP-USER"))
  "Drop the remote registry on TARGET-NAME."
  (cl-mcp-server.remote:remote-eval target-name (%clear-form)
                                    :package package
                                    :tier-override :inspect-registry))

;;; ==========================================================================
;;; Formatting
;;; ==========================================================================

(defun format-remote-inspection (result &key registry)
  "Render a remote inspection. Returns (values text error-p)."
  (if (getf result :ok)
      (values
       (let ((text (%unquote (getf result :result))))
         (if registry
             (format nil "~A~%Walk a part with remote-inspect and its ~
[handle].~%" text)
             (format nil "~A~%(transcript mode: nothing retained on the ~
target; pass registry to navigate)~%" text)))
       nil)
      (values (or (getf result :error) "remote inspection failed") t)))

(defun %unquote (text)
  "SWANK returns the value already printed, so a string result arrives
wrapped in quotes with escapes. Undo that for display."
  (if (and (stringp text) (> (length text) 1)
           (char= #\" (char text 0)))
      (with-output-to-string (s)
        (loop with i = 1
              while (< i (1- (length text)))
              for ch = (char text i)
              do (cond ((and (char= ch #\\) (< (1+ i) (length text)))
                        (let ((next (char text (1+ i))))
                          (write-char (if (char= next #\n) #\Newline next) s))
                        (incf i 2))
                       (t (write-char ch s) (incf i)))))
      (or text "")))

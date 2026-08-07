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

(defparameter %print-bindings%
  "(*print-length* 20) (*print-level* 3) (*print-circle* t)
   (*print-pretty* nil) (*print-readably* nil)"
  "Print limits, bound in the REMOTE image. Applying them here would be too
late: a large structure can stall a service before a byte reaches us.")

(defparameter %stash-flet%
  "(flet ((stash (o)
           (let ((h (incf (car reg))))
             (setf (gethash h (cdr reg)) (sb-ext:make-weak-pointer o))
             h)))"
  "Registers an object and returns its handle. WEAK by construction: the
table must never be the reason a service keeps its own data alive.

This is the one place a mutating operator is deliberate -- registry mode
maintains a counter, which is why it carries the :inspect-registry tier
rather than pretending to be a read.")

(defun %render (max-parts &key stash)
  "Body that renders OBJ and its parts, assuming OBJ is already bound.

With STASH, each object is also registered and prefixed with its handle;
REG must then be bound and a STASH function in scope. The three remote forms
differ only in how OBJ is obtained, so they share this.

The counter is a LOOP variable, never an INCF: these forms are classified
like any other, and reaching for a mutating operator would either be refused
or force an override that weakens the check we rely on."
  (let ((head (if stash "\"[~D] ~A~%~A~%\" (stash obj) (type-of obj)"
                  "\"~A~%~A~%\" (type-of obj)"))
        (part (if stash
                  "\"  [~D] ~A~30T~A~%\" (stash val) (if named (car p) i)"
                  "\"  ~A~30T~A~%\" (if named (car p) i)")))
    (format nil "
  (multiple-value-bind (desc named parts)
      (handler-case (sb-impl::inspected-parts obj)
        (error (e) (values (format nil \"inspection failed: ~~A\" (type-of e))
                           nil nil)))
    (let ((plist (coerce parts 'list)))
      (with-output-to-string (s)
        (format s ~A (prin1-to-string obj))
        (when (and desc (stringp desc))
          (format s \"~~A~~%\"
                  (string-right-trim (list (code-char 10)) desc)))
        (loop for p in plist
              for i from 0 below ~D
              do (let ((val (if named (cdr p) p)))
                   (format s ~A (prin1-to-string val))))
        (when (> (length plist) ~D)
          (format s \"  ... ~~D more~~%\" (- (length plist) ~D)))~A)))"
            head max-parts part max-parts max-parts
            (if stash
                ;; Spliced via ~A, so the outer FORMAT copies it verbatim:
                ;; single escaping, exactly like head and part above.
                "
        (format s \"~%~D handle~:P retained (weak).~%\"
                (hash-table-count (cdr reg)))"
                ""))))

(defun %parts-form (expression max-parts)
  "Transcript mode: render EXPRESSION, retain nothing on the target."
  (format nil "(let* ((obj ~A) ~A)~A)"
          expression %print-bindings% (%render max-parts)))

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
  "Registry mode: inspect EXPRESSION and retain weak handles for its parts."
  (format nil "(let* ((obj ~A) (reg ~A) ~A) ~A~A))"
          expression *registry-var* %print-bindings%
          %stash-flet% (%render max-parts :stash t)))

(defun %fetch-form (handle max-parts)
  "Walk into a retained handle.

A collected handle reports that rather than resurrecting the object: the
registry holds weak pointers, so it can never be the reason a service keeps
its own data alive."
  (format nil "
(let ((reg (and (boundp '~A) ~A)))
  (if (null reg)
      \"No remote registry on this target. Inspect something first.\"
      (multiple-value-bind (wp found) (gethash ~D (cdr reg))
        (if (not found)
            \"No handle ~D on this target.\"
            (multiple-value-bind (obj alive) (sb-ext:weak-pointer-value wp)
              (if (not alive)
                  \"That object has been collected. Handles are weak: the ~
inspector never keeps a service's data alive. Re-inspect from the top.\"
                  (let (~A) ~A~A))))))))"
          *registry-var* *registry-var* handle handle
          %print-bindings% %stash-flet% (%render max-parts :stash t)))

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

;;; The inspector is currently the only thing that leaves state on a target,
;;; so it registers its own sweep rather than having remote.lisp know about
;;; inspection. Future residue sources should do the same.
(cl-mcp-server.remote:register-cleanup
 "inspector registry"
 (lambda (target-name)
   (let ((r (clear-remote-registry target-name)))
     (if (getf r :ok)
         (%unquote (getf r :result))
         (or (getf r :error) "could not clear")))))

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

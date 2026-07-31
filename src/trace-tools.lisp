;;; src/trace-tools.lisp
;;; ABOUTME: trace/untrace, disassemble, macrostep, who-specializes

(in-package #:cl-mcp-server.trace-tools)

;;; ==========================================================================
;;; Rationale
;;;
;;; The remaining SLIME primitives, all thin wrappers over what SBCL already
;;; provides. The value is not the implementation but the fact that they are
;;; reachable without shelling out and without the agent having to remember
;;; that TRACE is a macro, that DISASSEMBLE prints rather than returns, or
;;; that stepping a macro one expansion at a time needs MACROEXPAND-1 in a
;;; loop rather than MACROEXPAND.
;;; ==========================================================================

(defun %resolve (name package)
  "Resolve NAME in PACKAGE to a symbol, or NIL."
  (let ((pkg (or (find-package (string-upcase (or package "COMMON-LISP-USER")))
                 (find-package :cl-user))))
    (or (find-symbol (string-upcase (string name)) pkg)
        (find-symbol (string-upcase (string name)) :cl))))

;;; ==========================================================================
;;; Tracing
;;;
;;; Trace output goes to *TRACE-OUTPUT*, which is not the value stream. The
;;; useful tool is therefore not "turn tracing on" but "run this form with
;;; these functions traced and give me the transcript" -- tracing that
;;; outlives the call would leak output into unrelated evaluations.
;;; ==========================================================================

(defvar *traced* nil
  "Symbols currently traced through this interface.")

(defun trace-functions (names &key package)
  "Trace each of NAMES. Returns a plist describing what happened."
  (let ((traced nil) (missing nil))
    (dolist (n names)
      (let ((sym (%resolve n package)))
        (cond ((and sym (fboundp sym))
               (handler-case
                   (progn (eval `(trace ,sym))
                          (pushnew sym *traced*)
                          (push (string sym) traced))
                 (error () (push (string n) missing))))
              (t (push (string n) missing)))))
    (list :traced (nreverse traced) :missing (nreverse missing))))

(defun untrace-functions (names &key package)
  "Untrace NAMES, or everything traced through here when NAMES is empty."
  (if (null names)
      (let ((all (copy-list *traced*)))
        (handler-case (eval '(untrace)) (error () nil))
        (setf *traced* nil)
        (list :untraced (mapcar #'string all)))
      (let ((done nil))
        (dolist (n names)
          (let ((sym (%resolve n package)))
            (when sym
              (handler-case (progn (eval `(untrace ,sym))
                                   (setf *traced* (remove sym *traced*))
                                   (push (string sym) done))
                (error () nil)))))
        (list :untraced (nreverse done)))))

(defun call-with-trace (code names &key package)
  "Trace NAMES, evaluate CODE, capture the trace transcript, then untrace.

This is the form that actually answers \"what did this call do?\" -- tracing
is scoped to the evaluation so it cannot bleed into later ones."
  (let ((transcript (make-string-output-stream))
        (values nil)
        (error-text nil)
        (pkg (or (find-package (string-upcase (or package "COMMON-LISP-USER")))
                 (find-package :cl-user))))
    (let ((setup (trace-functions names :package package)))
      (unwind-protect
           (handler-case
               (let ((*trace-output* transcript)
                     (*package* pkg))
                 (setf values (multiple-value-list
                               (eval (read-from-string code)))))
             (error (e) (setf error-text (format nil "~A: ~A" (type-of e) e))))
        (untrace-functions names :package package))
      (list :traced (getf setup :traced)
            :missing (getf setup :missing)
            :transcript (get-output-stream-string transcript)
            :values (mapcar (lambda (v)
                              (let ((*print-length* 50) (*print-level* 5))
                                (prin1-to-string v)))
                            values)
            :error error-text))))

(defun format-trace-result (info)
  "Render CALL-WITH-TRACE output. Returns (values text error-p)."
  (values
   (with-output-to-string (s)
     (let ((missing (getf info :missing)))
       (when missing
         (format s "Not traceable (undefined or not a function): ~{~A~^, ~}~%~%"
                 missing)))
     (format s "Traced: ~{~A~^, ~}~%" (or (getf info :traced) '("(none)")))
     (let ((tr (getf info :transcript)))
       (if (plusp (length tr))
           (format s "~%[Trace]~%~A" tr)
           (format s "~%(no trace output -- were the functions actually called?)~%")))
     (if (getf info :error)
         (format s "~%[ERROR] ~A~%" (getf info :error))
         (format s "~%~{=> ~A~%~}" (getf info :values))))
   (and (getf info :error) t)))

;;; ==========================================================================
;;; Disassembly
;;; ==========================================================================

(defun disassemble-function (name &key package)
  "Disassembled code for NAME, as a string."
  (let ((sym (%resolve name package)))
    (cond
      ((null sym) (list :found-p nil :reason "no such symbol"))
      ((not (fboundp sym)) (list :found-p nil :reason "not fbound"))
      (t (handler-case
             (list :found-p t
                   :name (format nil "~A::~A" (package-name (symbol-package sym))
                                 (symbol-name sym))
                   :text (with-output-to-string (s)
                           (let ((*standard-output* s))
                             (disassemble sym))))
           (error (e)
             (list :found-p nil
                   :reason (format nil "~A: ~A" (type-of e) e))))))))

(defun format-disassembly (info)
  (if (getf info :found-p)
      (values (format nil "~A~%~%~A" (getf info :name) (getf info :text)) nil)
      (values (format nil "Cannot disassemble: ~A" (getf info :reason)) t)))

;;; ==========================================================================
;;; Macro stepping
;;;
;;; macroexpand-form already offers one step or full expansion. Neither shows
;;; the intermediate stages of a macro that expands into other macros, which
;;; is exactly when an expansion is hard to follow.
;;; ==========================================================================

(defun macrostep (code &key package (max-steps 10))
  "Expand CODE one macro step at a time, recording each stage."
  (handler-case
      (let* ((pkg (or (find-package (string-upcase (or package "COMMON-LISP-USER")))
                      (find-package :cl-user)))
             (*package* pkg)
             (form (read-from-string code))
             (steps nil)
             (n 0))
        (loop
          (multiple-value-bind (expansion expanded-p) (macroexpand-1 form)
            (unless expanded-p (return))
            (incf n)
            (push (let ((*print-length* 60) (*print-level* 8) (*print-pretty* t))
                    (prin1-to-string expansion))
                  steps)
            (setf form expansion)
            (when (>= n max-steps) (return))))
        (list :found-p t
              :original (let ((*print-pretty* t)) (prin1-to-string
                                                  (read-from-string code)))
              :steps (nreverse steps)
              :exhausted-p (>= n max-steps)))
    (error (e) (list :found-p nil :reason (format nil "~A: ~A" (type-of e) e)))))

(defun format-macrostep (info)
  (if (not (getf info :found-p))
      (values (format nil "Cannot expand: ~A" (getf info :reason)) t)
      (values
       (with-output-to-string (s)
         (format s "Original:~%  ~A~%" (getf info :original))
         (let ((steps (getf info :steps)))
           (if (null steps)
               (format s "~%Not a macro form -- nothing to expand.~%")
               (loop for step in steps
                     for i from 1
                     do (format s "~%Step ~D:~%  ~A~%" i step))))
         (when (getf info :exhausted-p)
           (format s "~%(stopped at the step limit; expansion may continue)~%")))
       nil)))

;;; ==========================================================================
;;; who-specializes
;;; ==========================================================================

(defun who-specializes (class-name &key package)
  "Generic functions with methods specialized on CLASS-NAME."
  (let* ((sym (%resolve class-name package))
         (class (and sym (find-class sym nil))))
    (if (null class)
        (list :found-p nil :reason (format nil "no class named ~A" class-name))
        (let ((hits nil))
          (dolist (m (handler-case (sb-mop:specializer-direct-methods class)
                       (error () nil)))
            (let ((gf (sb-mop:method-generic-function m)))
              (when gf
                ;; NB: a generic function name may be a list -- (SETF FOO) for
                ;; every writer method -- so STRING would signal here. Print
                ;; the name instead.
                (push (list :gf (princ-to-string
                                 (sb-mop:generic-function-name gf))
                            :qualifiers (method-qualifiers m)
                            :specializers
                            (mapcar (lambda (sp)
                                      (cl-mcp-server.hyperspec:specializer-label sp))
                                    (sb-mop:method-specializers m)))
                      hits))))
          (list :found-p t
                :class (string (class-name class))
                :methods (sort hits #'string< :key (lambda (h) (getf h :gf))))))))

(defun format-who-specializes (info)
  (if (not (getf info :found-p))
      (values (format nil "Cannot look up: ~A" (getf info :reason)) t)
      (values
       (with-output-to-string (s)
         (let ((methods (getf info :methods)))
           (format s "~D method~:P specialized on ~A:~%~%"
                   (length methods) (getf info :class))
           (dolist (m methods)
             (format s "  ~A ~@[~{~A ~}~](~{~A~^, ~})~%"
                     (getf m :gf) (getf m :qualifiers) (getf m :specializers)))))
       nil)))

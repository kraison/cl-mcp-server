;;; src/inspector.lisp
;;; ABOUTME: SLIME-style object inspector with navigable handles

(in-package #:cl-mcp-server.inspector)

;;; ==========================================================================
;;; Rationale
;;;
;;; describe-symbol tells you about a NAME. The inspector tells you about a
;;; VALUE: what slots it has, what is in them, and -- crucially -- lets you
;;; walk into those slots without having written an accessor expression.
;;; That navigation is the whole point of slime-inspect; printing one level
;;; and stopping is just PRINT with extra steps.
;;;
;;; Navigation needs object identity to survive across MCP calls, so parts are
;;; handed back with integer handles into a session-scoped registry. A handle
;;; is only meaningful within one inspection lineage, and the registry is
;;; bounded so a walk through a large structure cannot retain everything it
;;; touched forever.
;;;
;;; We delegate the type-dispatch to SB-IMPL::INSPECTED-PARTS, which already
;;; has 12 methods covering conses, vectors, arrays, structures, standard
;;; objects, conditions, functions, symbols and pathnames. Reimplementing that
;;; dispatch would be strictly worse. Hash tables are the exception: SBCL
;;; inspects them as their internal STRUCTURE-OBJECT (15 implementation
;;; slots), which is never what someone means by "inspect this hash table".
;;; ==========================================================================

(defparameter *max-parts* 200
  "Maximum parts listed for one object. Long sequences are truncated.")

(defparameter *registry-limit* 500
  "Maximum objects retained for navigation. Oldest handles are evicted first;
an inspector should not be a memory leak with a UI.")

(defvar *registry* (make-hash-table :test #'eql)
  "handle -> object, for navigating into parts across calls.")

(defvar *registry-order* nil
  "Handles in insertion order, newest first, for bounded eviction.")

(defvar *registry-lock* (bt:make-lock "cl-mcp-inspector"))

(defvar *handle-counter* 0)

;;; ==========================================================================
;;; Registry
;;; ==========================================================================

(defun register-object (object)
  "Store OBJECT and return a handle for later navigation."
  (bt:with-lock-held (*registry-lock*)
    (let ((handle (incf *handle-counter*)))
      (setf (gethash handle *registry*) object)
      (push handle *registry-order*)
      ;; Evict oldest beyond the limit so a deep walk cannot pin arbitrary
      ;; amounts of heap.
      (when (> (hash-table-count *registry*) *registry-limit*)
        (let ((victims (nthcdr *registry-limit* *registry-order*)))
          (dolist (v victims) (remhash v *registry*))
          (setf *registry-order* (subseq *registry-order*
                                         0 (min *registry-limit*
                                                (length *registry-order*))))))
      handle)))

(defun lookup-object (handle)
  "Return (values object found-p) for HANDLE."
  (bt:with-lock-held (*registry-lock*)
    (multiple-value-bind (obj found) (gethash handle *registry*)
      (values obj found))))

(defun clear-registry ()
  (bt:with-lock-held (*registry-lock*)
    (clrhash *registry*)
    (setf *registry-order* nil)
    :cleared))

(defun registry-count ()
  (bt:with-lock-held (*registry-lock*)
    (hash-table-count *registry*)))

;;; ==========================================================================
;;; Part extraction
;;; ==========================================================================

(defun %safe-print (object &key (length 40) (level 3))
  "Print OBJECT defensively -- a broken PRINT-OBJECT method must not take the
inspector down with it."
  (handler-case
      (let ((*print-length* length) (*print-level* level)
            (*print-circle* t) (*print-readably* nil) (*print-pretty* nil))
        (prin1-to-string object))
    (error (e) (format nil "#<unprintable: ~A>" (type-of e)))))

(defun %hash-table-parts (table)
  "Entries of TABLE as (key-description . value).
SBCL inspects a hash table as its internal structure -- 15 implementation
slots -- which is never what the caller meant."
  (let ((parts nil) (n 0))
    (block collecting
      (maphash (lambda (k v)
                 (when (>= n *max-parts*) (return-from collecting))
                 (push (cons (format nil "key ~A"
                                     (%safe-print k :length 10 :level 2))
                             v)
                       parts)
                 (incf n))
               table))
    (nreverse parts)))

(defun object-parts (object)
  "Return (values description parts) where each part is (label . value)."
  (cond
    ;; Hash tables: entries, not implementation slots.
    ((hash-table-p object)
     (values (format nil "HASH-TABLE :test ~A, ~D entr~:@P"
                     (hash-table-test object) (hash-table-count object))
             (%hash-table-parts object)))
    (t
     (multiple-value-bind (description named-p parts)
         (handler-case (sb-impl::inspected-parts object)
           (error (e)
             (values (format nil "~A (inspection failed: ~A)"
                             (type-of object) (type-of e))
                     nil nil)))
       (values
        (string-right-trim '(#\Newline #\Space) (or description ""))
        (loop for part in (coerce parts 'list)
              for i from 0
              while (< i *max-parts*)
              collect (if named-p
                          (cons (princ-to-string (car part)) (cdr part))
                          (cons (format nil "~D" i) part))))))))

;;; ==========================================================================
;;; Inspection
;;; ==========================================================================

(defun %type-label (object)
  "A printable name for OBJECT's type.

NB: TYPE-OF returns a type SPECIFIER, which is frequently a list --
(INTEGER 0 4611686018427387903) for a fixnum, (SIMPLE-BASE-STRING 3) for a
string. Calling STRING on that signals, so specifiers must be printed, and
compound ones are reduced to their head to stay readable in a table."
  (let ((spec (handler-case (type-of object) (error () t))))
    (cond ((symbolp spec) (symbol-name spec))
          ((consp spec) (princ-to-string (car spec)))
          (t (princ-to-string spec)))))

(defstruct (inspection (:conc-name inspection-))
  handle
  type-name
  description
  printed
  parts        ; list of (label handle printed type)
  truncated-p
  error-text)

(defun inspect-object (object)
  "Produce an INSPECTION of OBJECT, registering it and its parts."
  (multiple-value-bind (description parts) (object-parts object)
    (make-inspection
     :handle (register-object object)
     :type-name (%type-label object)
     :description description
     :printed (%safe-print object :length 20 :level 4)
     :parts (mapcar (lambda (p)
                      (destructuring-bind (label . value) p
                        (list label
                              (register-object value)
                              (%safe-print value :length 12 :level 2)
                              (%type-label value))))
                    parts)
     :truncated-p (>= (length parts) *max-parts*))))

(defun inspect-expression (code &key package)
  "Evaluate CODE and inspect the result."
  (handler-case
      (let ((*package*
              (or (find-package
                   (string-upcase (or package "COMMON-LISP-USER")))
                  (find-package :cl-user))))
        (inspect-object (eval (read-from-string code))))
    (error (e)
      (make-inspection :error-text (format nil "~A: ~A" (type-of e) e)))))

(defun inspect-part (handle)
  "Inspect a previously registered object by HANDLE."
  (multiple-value-bind (object found) (lookup-object handle)
    (if found
        (inspect-object object)
        (make-inspection
         :error-text
         (format nil "No object with handle ~A. Handles expire once ~D objects ~
have been registered; re-run inspect to get fresh ones."
                 handle *registry-limit*)))))

;;; ==========================================================================
;;; Formatting
;;; ==========================================================================

(defun format-inspection (insp)
  "Render an INSPECTION for MCP. Returns (values text error-p)."
  (if (inspection-error-text insp)
      (values (inspection-error-text insp) t)
      (values
       (with-output-to-string (s)
         (format s "[~D] ~A~%"
                 (inspection-handle insp) (inspection-type-name insp))
         (format s "~A~%" (inspection-printed insp))
         (when (plusp (length (inspection-description insp)))
           (format s "~%~A~%" (inspection-description insp)))
         (let ((parts (inspection-parts insp)))
           (if (null parts)
               (format s "~%(no inspectable parts)~%")
               (progn
                 (format s "~%Parts:~%")
                 (dolist (p parts)
                   (destructuring-bind (label handle printed type) p
                     (format s "  [~D] ~20A ~A~@[  : ~A~]~%"
                             handle label printed type)))
                 (when (inspection-truncated-p insp)
                   (format s "  ... truncated at ~D parts~%" *max-parts*))
                 (format s "~%Inspect a part with inspect-object and its ~
[handle].~%")))))
       nil)))

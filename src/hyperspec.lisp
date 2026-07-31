;;; src/hyperspec.lisp
;;; ABOUTME: CLHS lookup, GF method enumeration, definition source

(in-package #:cl-mcp-server.hyperspec)

;;; ==========================================================================
;;; HyperSpec lookup (gap 2)
;;;
;;; The mapping symbol -> page is static data shipped in hyperspec-data.lisp,
;;; so resolution is local and instant. Only the URL we return points at the
;;; network. This is the equivalent of slime-hyperspec-lookup.
;;; ==========================================================================

(defparameter *hyperspec-root*
  "http://www.lispworks.com/documentation/HyperSpec/"
  "Base URL for the HyperSpec. Rebind to point at a local mirror.")

(defun hyperspec-url (name)
  "Return the CLHS URL for NAME, or NIL if it is not a standard CL symbol.
NAME may be a string or symbol, in any case, with or without a package
prefix -- only the symbol-name part is used, since the HyperSpec only
documents the COMMON-LISP package."
  (let* ((raw (string-downcase (string name)))
         (colon (position #\: raw :from-end t))
         (bare (if colon (subseq raw (1+ colon)) raw))
         (page (gethash bare *clhs-pages*)))
    (when page
      (concatenate 'string *hyperspec-root* "Body/" page))))

(defun lookup-hyperspec (name)
  "Look NAME up in the HyperSpec index.
Returns a plist (:name :url :found-p :suggestions). When the exact name is
absent we offer near matches, which is usually what you want after a typo
or when guessing at a name."
  (let* ((raw (string-downcase (string name)))
         (colon (position #\: raw :from-end t))
         (bare (if colon (subseq raw (1+ colon)) raw))
         (url (hyperspec-url bare)))
    (list :name bare
          :url url
          :found-p (and url t)
          :suggestions (unless url (hyperspec-suggestions bare)))))

(defun %edit-distance (a b &key (limit 3))
  "Levenshtein distance between A and B, capped at LIMIT for speed.
Returns LIMIT+1 if the true distance exceeds LIMIT."
  (let* ((la (length a)) (lb (length b)))
    (when (> (abs (- la lb)) limit)
      (return-from %edit-distance (1+ limit)))
    (let ((prev (make-array (1+ lb) :element-type 'fixnum))
          (cur (make-array (1+ lb) :element-type 'fixnum)))
      (dotimes (j (1+ lb)) (setf (aref prev j) j))
      (dotimes (i la)
        (setf (aref cur 0) (1+ i))
        (dotimes (j lb)
          (setf (aref cur (1+ j))
                (min (1+ (aref cur j))
                     (1+ (aref prev (1+ j)))
                     (+ (aref prev j)
                        (if (char= (char a i) (char b j)) 0 1)))))
        (rotatef prev cur))
      (aref prev lb))))

(defun hyperspec-suggestions (bare &key (limit 12))
  "Names in the CLHS index that are plausible intents for BARE.
Substring matches come first (you typed a prefix or fragment), then close
misspellings by edit distance -- without the latter a typo like \"positon\"
yields nothing at all, which is exactly when help is most wanted."
  (let ((substrings nil)
        (near nil))
    (maphash (lambda (k v)
               (declare (ignore v))
               (cond ((search bare k) (push k substrings))
                     ((<= (%edit-distance bare k :limit 2) 2)
                      (push (cons k (%edit-distance bare k :limit 2)) near))))
             *clhs-pages*)
    (let* ((subs (sort substrings
                       (lambda (a b)
                         (if (= (length a) (length b))
                             (string< a b)
                             (< (length a) (length b))))))
           (nears (mapcar #'car (sort near #'< :key #'cdr)))
           (all (remove-duplicates (append subs nears)
                                   :test #'string= :from-end t)))
      (subseq all 0 (min limit (length all))))))

(defun format-hyperspec-result (info)
  "Render a lookup-hyperspec plist for MCP.
Returns (values text error-p)."
  (if (getf info :found-p)
      (values (format nil "~A~%~%~A~%"
                      (string-upcase (getf info :name))
                      (getf info :url))
              nil)
      (values
       (with-output-to-string (s)
         (format s "~A is not a standard Common Lisp symbol.~%"
                 (string-upcase (getf info :name)))
         (let ((sug (getf info :suggestions)))
           (when sug
             (format s "~%Did you mean:~%")
             (dolist (x sug) (format s "  ~A~%" (string-upcase x)))))
         (format s "~%(The HyperSpec only covers the COMMON-LISP package. ~
For other symbols use describe-symbol.)~%"))
       t)))

;;; ==========================================================================
;;; Generic function method enumeration (gap 1)
;;;
;;; find-methods answers "what methods specialize on this CLASS?". The dual
;;; question -- "what methods does this GENERIC FUNCTION have, and on what?"
;;; -- was unreachable, yet it is the one that matters for dispatch-heavy
;;; APIs. EQL specializers in particular are effectively invisible otherwise:
;;; nothing in the arglist tells you that ALGORITHM must be one of four
;;; specific keywords, so you are reduced to guessing or reading source.
;;; ==========================================================================

(defun specializer-label (spec)
  "Human-readable label for a method specializer.
EQL specializers are rendered as (EQL <object>) because the object is the
whole point -- it is the literal value a caller has to pass."
  (typecase spec
    (sb-mop:eql-specializer
     (format nil "(EQL ~S)" (sb-mop:eql-specializer-object spec)))
    (class
     (let ((name (class-name spec)))
       (if name (princ-to-string name) (princ-to-string spec))))
    (t (princ-to-string spec))))

(defun generic-function-info (name &key (package "CL-USER"))
  "Describe the generic function NAME: its lambda list and every method,
with specializers and qualifiers. Returns a plist, or (:found-p NIL)."
  (let* ((pkg (or (find-package (string-upcase package))
                  (find-package :cl-user)))
         (sym (or (find-symbol (string-upcase (string name)) pkg)
                  (find-symbol (string-upcase (string name)) :cl))))
    (cond
      ((null sym) (list :found-p nil :reason :no-such-symbol))
      ((not (fboundp sym)) (list :found-p nil :reason :not-fbound))
      ((not (typep (fdefinition sym) 'generic-function))
       (list :found-p nil :reason :not-generic
             :kind (if (macro-function sym) :macro :function)))
      (t
       (let ((gf (fdefinition sym)))
         (list
          :found-p t
          :name (format nil "~A::~A" (package-name (symbol-package sym))
                        (symbol-name sym))
          :lambda-list (sb-mop:generic-function-lambda-list gf)
          :documentation (documentation gf 'function)
          :method-combination
          (ignore-errors
           (let ((mc (sb-mop:generic-function-method-combination gf)))
             (class-name (class-of mc))))
          :methods
          (mapcar
           (lambda (m)
             (list :qualifiers (method-qualifiers m)
                   :specializers (mapcar #'specializer-label
                                         (sb-mop:method-specializers m))
                   :documentation (documentation m t)))
           (sb-mop:generic-function-methods gf))))))))

(defun eql-specializer-values (info)
  "Collect the distinct EQL-specialized values per argument position.
This is the payoff: it turns \"ALGORITHM is some object\" into the actual
menu of accepted values."
  (let ((by-position (make-hash-table :test #'eql)))
    (dolist (m (getf info :methods))
      (loop for spec in (getf m :specializers)
            for i from 0
            do (when (and (stringp spec)
                          (> (length spec) 5)
                          (string= "(EQL " (subseq spec 0 5)))
                 (pushnew spec (gethash i by-position) :test #'string=))))
    (let ((result nil))
      (maphash (lambda (pos vals)
                 (push (cons pos (sort vals #'string<)) result))
               by-position)
      (sort result #'< :key #'car))))

(defun format-generic-function-info (info)
  "Render generic-function-info for MCP. Returns (values text error-p)."
  (if (not (getf info :found-p))
      (values
       (case (getf info :reason)
         (:no-such-symbol "No such symbol.")
         (:not-fbound "Symbol exists but is not fbound.")
         (:not-generic
          (format nil "Not a generic function (it is a ~(~A~)). ~
Use describe-symbol for its arglist."
                  (getf info :kind)))
         (t "Not found."))
       t)
      (values
       (with-output-to-string (s)
         (format s "~A [GENERIC-FUNCTION]~%" (getf info :name))
         (format s "  Lambda-list: ~A~%" (getf info :lambda-list))
         (when (getf info :method-combination)
           (format s "  Method combination: ~A~%"
                   (getf info :method-combination)))
         (when (getf info :documentation)
           (format s "  Documentation: ~A~%" (getf info :documentation)))
         ;; Lead with the EQL menu -- it is the highest-value line here.
         (let ((eqls (eql-specializer-values info)))
           (when eqls
             (format s "~%  Accepted EQL-specialized values:~%")
             (dolist (entry eqls)
               (format s "    argument ~D: ~{~A~^ ~}~%"
                       (car entry) (cdr entry)))))
         (let ((methods (getf info :methods)))
           (format s "~%  ~D method~:P:~%" (length methods))
           (dolist (m (sort (copy-list methods) #'string<
                            :key (lambda (m)
                                   (format nil "~{~A~^,~}"
                                           (getf m :specializers)))))
             (format s "    ~@[~{~A ~}~](~{~A~^, ~})~%"
                     (getf m :qualifiers)
                     (getf m :specializers)))))
       nil)))

;;; ==========================================================================
;;; Definition source (gap 4)
;;;
;;; Closes the last edit-loop gap: given a name, say which file and line it
;;; lives at, so an edit can be made without grepping the tree.
;;; ==========================================================================

(defun %source-location-plist (dspec kind)
  "Turn an sb-introspect definition-source into a plist."
  (let ((path (sb-introspect:definition-source-pathname dspec))
        (offset (sb-introspect:definition-source-character-offset dspec))
        (form-path (sb-introspect:definition-source-form-path dspec)))
    (list :kind kind
          :file (when path (namestring path))
          :character-offset offset
          :form-path form-path
          :line (when (and path offset) (%line-for-offset path offset)))))

(defun %line-for-offset (path offset)
  "1-based line number containing character OFFSET of PATH.

Caveat: SBCL records the offset of the enclosing toplevel form, which for a
definition preceded by comments points a few lines above the DEFUN itself.
It is a reliable jump target, not an exact cursor position. Definitions
loaded from a fasl carry no offset at all, in which case we report the file
only."
  (handler-case
      (with-open-file (in path :direction :input :external-format :utf-8)
        (let ((line 1))
          (dotimes (i offset line)
            (let ((ch (read-char in nil nil)))
              (cond ((null ch) (return line))
                    ((char= ch #\Newline) (incf line)))))))
    (error () nil)))

(defun find-definition-source (name &key (package "CL-USER"))
  "Locate where NAME is defined. Returns a plist with :found-p and :locations,
covering function, macro, generic function, methods, class, variable and
structure definitions."
  (let* ((pkg (or (find-package (string-upcase package))
                  (find-package :cl-user)))
         (sym (or (find-symbol (string-upcase (string name)) pkg)
                  (find-symbol (string-upcase (string name)) :cl))))
    (if (null sym)
        (list :found-p nil)
        (let ((locations nil))
          (flet ((collect (kind)
                   (handler-case
                       (dolist (d (sb-introspect:find-definition-sources-by-name
                                   sym kind))
                         (let ((pl (%source-location-plist d kind)))
                           (when (getf pl :file)
                             (pushnew pl locations :test #'equal))))
                     (error () nil))))
            (mapc #'collect '(:function :macro :generic-function :method
                              :class :structure :variable :constant
                              :type :condition :package)))
          (list :found-p (and locations t)
                :name (format nil "~A::~A"
                              (package-name (symbol-package sym))
                              (symbol-name sym))
                :locations (nreverse locations))))))

(defun format-definition-source (info)
  "Render find-definition-source for MCP. Returns (values text error-p)."
  (if (not (getf info :found-p))
      (values "No source location found. (Built-in, or compiled without ~
source info.)" t)
      (values
       (with-output-to-string (s)
         (format s "~A~%~%" (getf info :name))
         (dolist (loc (getf info :locations))
           (format s "  ~(~A~)~%" (getf loc :kind))
           (format s "    ~A~@[:~D~]~%"
                   (getf loc :file) (getf loc :line))))
       nil)))

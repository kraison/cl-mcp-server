;;; tests/hyperspec-tests.lisp
;;; ABOUTME: Tests for CLHS lookup, GF method enumeration, definition source

(in-package #:cl-mcp-server-tests)

(def-suite hyperspec-tests
  :description "Tests for hyperspec lookup and introspection primitives"
  :in cl-mcp-server-tests)

(in-suite hyperspec-tests)

;;; ==========================================================================
;;; Fixtures
;;;
;;; A local generic function with EQL specializers, so the enumeration tests
;;; do not depend on any external system being loaded.
;;; ==========================================================================

(defgeneric hs-fixture-dispatch (object mode)
  (:documentation "Fixture GF for specializer enumeration tests."))

(defmethod hs-fixture-dispatch ((object integer) (mode (eql :fast))) :fast)
(defmethod hs-fixture-dispatch ((object integer) (mode (eql :slow))) :slow)
(defmethod hs-fixture-dispatch ((object string) (mode (eql :fast))) :string-fast)
(defmethod hs-fixture-dispatch ((object t) (mode t)) :fallback)

(defun hs-fixture-plain-function (x) (1+ x))

;;; ==========================================================================
;;; HyperSpec lookup
;;; ==========================================================================

(test clhs-table-is-populated
  "The shipped CLHS index has a plausible number of entries"
  (is (> (hash-table-count cl-mcp-server.hyperspec:*clhs-pages*) 500)))

(test clhs-resolves-known-function
  "A standard function resolves to its documented page"
  (let ((url (cl-mcp-server.hyperspec:hyperspec-url "mapcar")))
    (is (stringp url))
    (is (search "f_mapc_.htm" url))))

(test clhs-resolves-macro
  "Macros resolve too, not just functions"
  (is (search "m_w_open.htm"
              (cl-mcp-server.hyperspec:hyperspec-url "with-open-file"))))

(test clhs-is-case-insensitive
  "Lookup does not care about case"
  (is (string= (cl-mcp-server.hyperspec:hyperspec-url "CAR")
               (cl-mcp-server.hyperspec:hyperspec-url "car"))))

(test clhs-strips-package-prefix
  "A package-qualified name resolves on its symbol-name"
  (is (string= (cl-mcp-server.hyperspec:hyperspec-url "car")
               (cl-mcp-server.hyperspec:hyperspec-url "cl:car"))))

(test clhs-unknown-symbol-returns-nil
  "Non-standard symbols have no page"
  (is (null (cl-mcp-server.hyperspec:hyperspec-url
             "definitely-not-a-standard-cl-symbol"))))

(test clhs-lookup-reports-found
  "lookup-hyperspec sets found-p for a hit"
  (let ((info (cl-mcp-server.hyperspec:lookup-hyperspec "position")))
    (is-true (getf info :found-p))
    (is (stringp (getf info :url)))))

(test clhs-lookup-suggests-on-typo
  "A transposition still yields the intended symbol"
  (let ((info (cl-mcp-server.hyperspec:lookup-hyperspec "positon")))
    (is-false (getf info :found-p))
    (is (member "position" (getf info :suggestions) :test #'string=))))

(test clhs-lookup-suggests-on-prefix
  "A partial name suggests the full one"
  (let ((info (cl-mcp-server.hyperspec:lookup-hyperspec "make-hash")))
    (is-false (getf info :found-p))
    (is (member "make-hash-table" (getf info :suggestions) :test #'string=))))

(test clhs-format-hit-is-not-error
  "A successful lookup is not an error and shows the URL"
  (multiple-value-bind (text error-p)
      (cl-mcp-server.hyperspec:format-hyperspec-result
       (cl-mcp-server.hyperspec:lookup-hyperspec "mapcar"))
    (is-false error-p)
    (is (search "http" text))))

(test clhs-format-miss-is-error
  "A miss reports error-p true"
  (multiple-value-bind (text error-p)
      (cl-mcp-server.hyperspec:format-hyperspec-result
       (cl-mcp-server.hyperspec:lookup-hyperspec "no-such-cl-symbol-xyzzy"))
    (is-true error-p)
    (is (search "not a standard" text))))

;;; ==========================================================================
;;; Generic function / method enumeration
;;; ==========================================================================

(test gf-info-finds-generic-function
  "A generic function is recognised and its methods collected"
  (let ((info (cl-mcp-server.hyperspec:generic-function-info
               "hs-fixture-dispatch" :package "CL-MCP-SERVER-TESTS")))
    (is-true (getf info :found-p))
    (is (= 4 (length (getf info :methods))))))

(test gf-info-reports-lambda-list
  "The real lambda list is returned"
  (let ((info (cl-mcp-server.hyperspec:generic-function-info
               "hs-fixture-dispatch" :package "CL-MCP-SERVER-TESTS")))
    (is (= 2 (length (getf info :lambda-list))))))

(test gf-info-rejects-plain-function
  "A non-generic function is reported as such, not silently empty"
  (let ((info (cl-mcp-server.hyperspec:generic-function-info
               "hs-fixture-plain-function" :package "CL-MCP-SERVER-TESTS")))
    (is-false (getf info :found-p))
    (is (eq :not-generic (getf info :reason)))))

(test gf-info-unknown-symbol
  "An unknown name is reported distinctly"
  (let ((info (cl-mcp-server.hyperspec:generic-function-info
               "no-such-gf-xyzzy" :package "CL-MCP-SERVER-TESTS")))
    (is-false (getf info :found-p))
    (is (eq :no-such-symbol (getf info :reason)))))

(test specializer-label-renders-eql-value
  "EQL specializers render with their object, which is the callable value"
  (let ((label (cl-mcp-server.hyperspec:specializer-label
                (sb-mop:intern-eql-specializer :fast))))
    (is (search "EQL" label))
    (is (search "FAST" label))))

(test specializer-label-renders-class-name
  "Class specializers render as the bare class name"
  (is (string= "INTEGER"
               (cl-mcp-server.hyperspec:specializer-label (find-class 'integer)))))

(test eql-values-enumerated-by-position
  "The accepted EQL values are collected for the dispatching argument"
  (let* ((info (cl-mcp-server.hyperspec:generic-function-info
                "hs-fixture-dispatch" :package "CL-MCP-SERVER-TESTS"))
         (eqls (cl-mcp-server.hyperspec:eql-specializer-values info))
         (arg1 (cdr (assoc 1 eqls))))
    ;; argument 1 (0-based) is MODE, specialized on :fast and :slow
    (is-true arg1)
    (is-true (some (lambda (s) (search "FAST" s)) arg1))
    (is-true (some (lambda (s) (search "SLOW" s)) arg1))))

(test eql-values-deduplicated
  "A value specialized in several methods is listed once"
  (let* ((info (cl-mcp-server.hyperspec:generic-function-info
                "hs-fixture-dispatch" :package "CL-MCP-SERVER-TESTS"))
         (arg1 (cdr (assoc 1 (cl-mcp-server.hyperspec:eql-specializer-values info)))))
    ;; :fast appears in two methods but must appear once here
    (is (= 1 (count-if (lambda (s) (search "FAST" s)) arg1)))))

(test gf-format-includes-eql-section
  "The formatted output leads with the EQL menu"
  (multiple-value-bind (text error-p)
      (cl-mcp-server.hyperspec:format-generic-function-info
       (cl-mcp-server.hyperspec:generic-function-info
        "hs-fixture-dispatch" :package "CL-MCP-SERVER-TESTS"))
    (is-false error-p)
    (is (search "Accepted EQL-specialized values" text))
    (is (search "4 methods" text))))

(test gf-format-not-generic-is-error
  "Asking about a plain function reports error-p true"
  (multiple-value-bind (text error-p)
      (cl-mcp-server.hyperspec:format-generic-function-info
       (cl-mcp-server.hyperspec:generic-function-info
        "hs-fixture-plain-function" :package "CL-MCP-SERVER-TESTS"))
    (is-true error-p)
    (is (search "Not a generic function" text))))

;;; ==========================================================================
;;; Definition source
;;; ==========================================================================

(test definition-source-finds-function
  "A function defined in this image reports a source file"
  (let ((info (cl-mcp-server.hyperspec:find-definition-source
               "write-lisp-file" :package "CL-MCP-SERVER.FILE-TOOLS")))
    (is-true (getf info :found-p))
    (is-true (some (lambda (loc) (search "file-tools" (getf loc :file)))
                   (getf info :locations)))))

(test definition-source-reports-kind
  "Locations carry the kind of definition"
  (let ((info (cl-mcp-server.hyperspec:find-definition-source
               "write-lisp-file" :package "CL-MCP-SERVER.FILE-TOOLS")))
    (is-true (every (lambda (loc) (keywordp (getf loc :kind)))
                    (getf info :locations)))))

(test definition-source-unknown-symbol
  "An unknown symbol is not found"
  (let ((info (cl-mcp-server.hyperspec:find-definition-source
               "no-such-symbol-xyzzy" :package "CL-USER")))
    (is-false (getf info :found-p))))

(test definition-source-format-miss-is-error
  "A miss reports error-p true"
  (multiple-value-bind (text error-p)
      (cl-mcp-server.hyperspec:format-definition-source
       (cl-mcp-server.hyperspec:find-definition-source
        "no-such-symbol-xyzzy" :package "CL-USER"))
    (declare (ignore text))
    (is-true error-p)))

(test definition-source-format-hit-is-not-error
  "A hit reports error-p false and names the file"
  (multiple-value-bind (text error-p)
      (cl-mcp-server.hyperspec:format-definition-source
       (cl-mcp-server.hyperspec:find-definition-source
        "write-lisp-file" :package "CL-MCP-SERVER.FILE-TOOLS"))
    (is-false error-p)
    (is (search ".lisp" text))))

;;; ==========================================================================
;;; Tool registration
;;; ==========================================================================

(test hyperspec-tools-registered
  "All three introspection tools are exposed over MCP"
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (dolist (name '("hyperspec-lookup" "describe-generic-function"
                    "find-definition-source"))
      (is (not (null (cl-mcp.tools:get-tool (test-server-registry server) name)))
          "tool ~A should be registered" name))))

(test hyperspec-lookup-tool-call
  "Calling hyperspec-lookup returns a URL"
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (is (search "http" (call-test-tool server "hyperspec-lookup"
                                       '(("name" . "mapcar")))))))

(test describe-generic-function-tool-call
  "Calling describe-generic-function surfaces the EQL values"
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (let ((text (call-test-tool server "describe-generic-function"
                                '(("name" . "hs-fixture-dispatch")
                                  ("package" . "CL-MCP-SERVER-TESTS")))))
      (is (search "Accepted EQL-specialized values" text)))))

(test find-definition-source-tool-call
  "Calling find-definition-source returns a path"
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (is (search ".lisp"
                (call-test-tool server "find-definition-source"
                                '(("name" . "write-lisp-file")
                                  ("package" . "CL-MCP-SERVER.FILE-TOOLS")))))))

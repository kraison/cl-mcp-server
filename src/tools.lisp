;;; src/tools.lisp
;;; ABOUTME: MCP tool definitions for CL REPL (registers on cl-mcp server)

(in-package #:cl-mcp-server.tools)

;;; ==========================================================================
;;; Tool Definitions
;;; ==========================================================================

(defun string-to-keyword (string valid-keywords)
  "Convert STRING to a keyword if it matches one of VALID-KEYWORDS.
Returns the matching keyword or nil. Comparison is case-insensitive."
  (find string valid-keywords
        :test #'string-equal
        :key #'symbol-name))

(defun define-builtin-tools (server session)
  "Register the built-in REPL tools on SERVER, closing over SESSION."

  ;; ========================================================================
  ;; Usage Guide - Call first to understand best practices
  ;; ========================================================================

  (cl-mcp:register-tool server "get-usage-guide"
   :description "Get the recommended workflow guide for using this Lisp MCP server effectively. RECOMMENDED: Call this when starting a new session to learn best practices for incremental development, syntax validation, and effective tool usage."
   :schema `(("type" . "object")
             ("properties" . ,(make-hash-table :test #'equal)))
   :handler (lambda (args)
              (declare (ignore args))
              (get-usage-guide-content)))

  ;; evaluate-lisp: Evaluate Common Lisp code with enhanced feedback
  (cl-mcp:register-tool server "evaluate-lisp"
   :description "Evaluate Common Lisp code in the current session. The code is evaluated in sequence and the result of the last form is returned. Output to *standard-output* is captured."
   :schema '(("type" . "object")
             ("required" . ("code"))
             ("properties" . (("code" . (("type" . "string")
                                         ("description" . "Common Lisp code to evaluate")))
                              ("package" . (("type" . "string")
                                            ("description" . "Package context for evaluation (default: CL-USER)")))
                              ("capture-time" . (("type" . "boolean")
                                                 ("description" . "Include timing information in result"))))))
   :handler (lambda (args)
              (let* ((code (cdr (assoc "code" args :test #'string=)))
                     (pkg (cdr (assoc "package" args :test #'string=)))
                     (capture-time (cdr (assoc "capture-time" args :test #'string=)))
                     (result (evaluate-code code :package pkg :capture-time capture-time)))
                ;; Track definitions in the session
                (when (and session (result-definitions result))
                  (setf (session-definitions session)
                        (append (result-definitions result)
                                (session-definitions session))))
                ;; Phase C: Store structured error in session for later inspection
                (when (and session (result-structured-error result))
                  (setf (session-last-error session) (result-structured-error result)))
                ;; Report tool-domain failure via MCP isError so clients can
                ;; distinguish a signalled condition from a successful eval.
                (values (format-result result)
                        (not (result-success-p result))))))

  ;; list-definitions: List definitions in the current session
  (cl-mcp:register-tool server "list-definitions"
   :description "List all definitions (functions, variables, macros) in the current session."
   :schema `(("type" . "object")
             ("properties" . (("type" . (("type" . "string")
                                         ("description" . "Optional filter: function, variable, or macro")
                                         ("enum" . ("function" "variable" "macro")))))))
   :handler (lambda (args)
              (let ((type-filter (cdr (assoc "type" args :test #'string=))))
                (format-definitions session
                                    :type (when type-filter
                                            (string-to-keyword type-filter '(:function :variable :macro)))))))

  ;; reset-session: Reset the session to a fresh state
  (cl-mcp:register-tool server "reset-session"
   :description "Reset the session to a fresh state, clearing all definitions and loaded systems."
   :schema `(("type" . "object")
             ("properties" . ,(make-hash-table :test #'equal)))
   :handler (lambda (args)
              (declare (ignore args))
              (cl-mcp-server.session:reset-session session)
              "Session reset successfully."))

  ;; load-system: Load an ASDF system
  (cl-mcp:register-tool server "load-system"
   :description "Load an ASDF system by name. The system must be findable by ASDF."
   :schema '(("type" . "object")
             ("required" . ("system-name"))
             ("properties" . (("system-name" . (("type" . "string")
                                                ("description" . "Name of the ASDF system to load"))))))
   :handler (lambda (args)
              (let ((system-name (cdr (assoc "system-name" args :test #'string=))))
                (handler-case
                    (progn
                      (asdf:load-system system-name)
                      (push system-name (session-loaded-systems session))
                      (format nil "System ~a loaded successfully." system-name))
                  (error (c)
                    (format nil "Error loading system ~a: ~a" system-name c))))))

  ;; configure-limits: Configure evaluation safety limits
  (cl-mcp:register-tool server "configure-limits"
   :description "Configure evaluation safety limits. Returns current configuration after any changes."
   :schema '(("type" . "object")
             ("properties" . (("timeout" . (("type" . "integer")
                                            ("description" . "Evaluation timeout in seconds (default: 30). Set to 0 to disable (not recommended).")))
                              ("max-output" . (("type" . "integer")
                                               ("description" . "Maximum output characters to capture (default: 100000)"))))))
   :handler (lambda (args)
              (let ((timeout (cdr (assoc "timeout" args :test #'string=)))
                    (max-output (cdr (assoc "max-output" args :test #'string=))))
                ;; Apply changes if provided
                (when timeout
                  (setf cl-mcp-server.evaluator:*evaluation-timeout*
                        (if (zerop timeout) nil timeout)))
                (when max-output
                  (setf cl-mcp-server.evaluator:*max-output-chars* max-output))
                ;; Return current configuration
                (format nil "Current limits:~%  timeout: ~A seconds~A~%  max-output: ~A characters"
                        (or cl-mcp-server.evaluator:*evaluation-timeout* "disabled")
                        (if cl-mcp-server.evaluator:*evaluation-timeout* "" " (WARNING: no timeout)")
                        cl-mcp-server.evaluator:*max-output-chars*))))

  ;; ========================================================================
  ;; Phase A: Introspection Tools
  ;; ========================================================================

  ;; describe-symbol: Get comprehensive symbol information
  (cl-mcp:register-tool server "describe-symbol"
   :description "Get comprehensive information about a Lisp symbol including its type, value, documentation, arglist, and source location. Uses SBCL introspection for detailed information."
   :schema '(("type" . "object")
             ("required" . ("name"))
             ("properties" . (("name" . (("type" . "string")
                                         ("description" . "Symbol name to describe")))
                              ("package" . (("type" . "string")
                                            ("description" . "Package name (defaults to CL-USER)"))))))
   :handler (lambda (args)
              (let* ((name (cdr (assoc "name" args :test #'string=)))
                     (pkg-name (cdr (assoc "package" args :test #'string=)))
                     (pkg (if pkg-name
                              (find-package (string-upcase pkg-name))
                              (find-package "CL-USER"))))
                (if (not pkg)
                    (format nil "Package ~A not found" pkg-name)
                    (multiple-value-bind (sym status)
                        (find-symbol (string-upcase name) pkg)
                      (if sym
                          (format-symbol-info (introspect-symbol sym))
                          (format nil "Symbol ~A not found in package ~A (status: ~A)"
                                  name (package-name pkg) status)))))))

  ;; apropos-search: Search for symbols matching a pattern
  (cl-mcp:register-tool server "apropos-search"
   :description "Search for symbols matching a pattern. Returns symbol names, types, and packages. Useful for discovering available functions, variables, and classes."
   :schema '(("type" . "object")
             ("required" . ("pattern"))
             ("properties" . (("pattern" . (("type" . "string")
                                            ("description" . "Search pattern (case-insensitive substring)")))
                              ("package" . (("type" . "string")
                                            ("description" . "Limit search to this package (optional)")))
                              ("type" . (("type" . "string")
                                         ("description" . "Filter by type: function, macro, variable, class, generic-function")
                                         ("enum" . ("function" "macro" "variable" "class" "generic-function")))))))
   :handler (lambda (args)
              (let* ((pattern (cdr (assoc "pattern" args :test #'string=)))
                     (pkg-name (cdr (assoc "package" args :test #'string=)))
                     (type-str (cdr (assoc "type" args :test #'string=)))
                     (type-kw (when type-str
                                (string-to-keyword type-str '(:function :macro :variable :class :generic-function)))))
                (if (and pkg-name (not (find-package (string-upcase pkg-name))))
                    (format nil "Package ~A not found" pkg-name)
                    (let ((results (introspect-apropos pattern
                                                       :package pkg-name
                                                       :type type-kw)))
                      (format-apropos-results results pattern))))))

  ;; who-calls: Find all functions that call a specified function
  (cl-mcp:register-tool server "who-calls"
   :description "Find all functions that call the specified function. Uses SBCL's cross-reference database to track callers."
   :schema '(("type" . "object")
             ("required" . ("name"))
             ("properties" . (("name" . (("type" . "string")
                                         ("description" . "Function name to find callers of")))
                              ("package" . (("type" . "string")
                                            ("description" . "Package name (defaults to CL-USER)"))))))
   :handler (lambda (args)
              (let* ((name (cdr (assoc "name" args :test #'string=)))
                     (pkg-name (cdr (assoc "package" args :test #'string=)))
                     (pkg (if pkg-name
                              (find-package (string-upcase pkg-name))
                              (find-package "CL-USER"))))
                (if (not pkg)
                    (format nil "Package ~A not found" pkg-name)
                    (let ((sym (find-symbol (string-upcase name) pkg)))
                      (if sym
                          (let ((results (introspect-who-calls sym)))
                            (format-who-calls-results results sym))
                          (format nil "Symbol ~A not found in package ~A" name (package-name pkg))))))))

  ;; who-references: Find all code that references a variable
  (cl-mcp:register-tool server "who-references"
   :description "Find all code that references (reads) the specified variable or constant. Uses SBCL's cross-reference database."
   :schema '(("type" . "object")
             ("required" . ("name"))
             ("properties" . (("name" . (("type" . "string")
                                         ("description" . "Variable name to find references to")))
                              ("package" . (("type" . "string")
                                            ("description" . "Package name (defaults to CL-USER)"))))))
   :handler (lambda (args)
              (let* ((name (cdr (assoc "name" args :test #'string=)))
                     (pkg-name (cdr (assoc "package" args :test #'string=)))
                     (pkg (if pkg-name
                              (find-package (string-upcase pkg-name))
                              (find-package "CL-USER"))))
                (if (not pkg)
                    (format nil "Package ~A not found" pkg-name)
                    (let ((sym (find-symbol (string-upcase name) pkg)))
                      (if sym
                          (let ((results (introspect-who-references sym)))
                            (format-who-references-results results sym))
                          (format nil "Symbol ~A not found in package ~A" name (package-name pkg))))))))

  ;; macroexpand-form: Expand macros in a form
  (cl-mcp:register-tool server "macroexpand-form"
   :description "Expand macros in a Lisp form. Useful for understanding macro transformations and debugging macro usage."
   :schema '(("type" . "object")
             ("required" . ("form"))
             ("properties" . (("form" . (("type" . "string")
                                         ("description" . "Lisp form to expand (as a string)")))
                              ("full" . (("type" . "boolean")
                                         ("description" . "If true, fully expand all macros recursively. Default: false (one step only)")))
                              ("package" . (("type" . "string")
                                            ("description" . "Package context for reading the form (defaults to CL-USER)"))))))
   :handler (lambda (args)
              (let* ((form-str (cdr (assoc "form" args :test #'string=)))
                     (full (cdr (assoc "full" args :test #'string=)))
                     (pkg-name (cdr (assoc "package" args :test #'string=)))
                     (pkg (if pkg-name
                              (find-package (string-upcase pkg-name))
                              (find-package "CL-USER"))))
                (if (not pkg)
                    (format nil "Package ~A not found" pkg-name)
                    (handler-case
                        (let ((result (introspect-macroexpand form-str :full full :package pkg)))
                          (format-macroexpand-result result))
                      (error (e)
                        (format nil "Error expanding form: ~A" e)))))))

  ;; validate-syntax: Validate code syntax without evaluation
  (cl-mcp:register-tool server "validate-syntax"
   :description "Check if Common Lisp code is syntactically valid without evaluating it. Detects unbalanced parentheses, reader errors, and other syntax issues. Use this to verify code before saving or executing."
   :schema '(("type" . "object")
             ("required" . ("code"))
             ("properties" . (("code" . (("type" . "string")
                                         ("description" . "Common Lisp code to validate"))))))
   :handler (lambda (args)
              (let* ((code (cdr (assoc "code" args :test #'string=)))
                     (result (introspect-validate-syntax code)))
                (format-validate-result result))))

  ;; ========================================================================
  ;; Phase B: Enhanced Evaluation Tools
  ;; ========================================================================

  ;; ========================================================================
  ;; Quicklisp: read-only, offline dist introspection
  ;; ========================================================================

  ;; quicklisp-dry-run: what would quickload actually do?
  (cl-mcp:register-tool server "quicklisp-dry-run"
   :description "Show exactly what (ql:quickload SYSTEM) would download, WITHOUT downloading anything. Reports the full transitive dependency tree, which systems are already installed, which would be fetched, and the total archive size. CALL THIS BEFORE quickload for any system you have not loaded before: quickload is an irreversible network action whose blast radius is otherwise invisible. Read-only and offline - it queries the local dist index."
   :schema '(("type" . "object")
             ("required" . ("system"))
             ("properties" . (("system" . (("type" . "string")
                                           ("description" . "Quicklisp system name")))))) 
   :handler (lambda (args)
              (let ((name (cdr (assoc "system" args :test #'string=))))
                (multiple-value-bind (text error-p)
                    (format-ql-dry-run (ql-dry-run name))
                  (values text error-p)))))

  ;; quicklisp-system-info: everything the dist knows about one system
  (cl-mcp:register-tool server "quicklisp-system-info"
   :description "Get full Quicklisp metadata for a system: whether it is already installed, its direct dependencies (each marked installed or not), the release and project it comes from, archive size and URL, on-disk location, and sibling systems from the same release. Use this to evaluate a library before committing to it. Read-only and offline."
   :schema '(("type" . "object")
             ("required" . ("system"))
             ("properties" . (("system" . (("type" . "string")
                                           ("description" . "Quicklisp system name"))))))
   :handler (lambda (args)
              (let ((name (cdr (assoc "system" args :test #'string=))))
                (multiple-value-bind (text error-p)
                    (format-ql-system-info (ql-system-info name))
                  (values text error-p)))))

  ;; quicklisp-search: ranked search with install state
  (cl-mcp:register-tool server "quicklisp-search"
   :description "Search Quicklisp for systems matching a term. Unlike a bare name list, this marks each result [installed] or [available], shows its release, and ranks real entry points above -test/-doc/subsystem noise. Use this to find the right system name before quicklisp-system-info or quickload."
   :schema '(("type" . "object")
             ("required" . ("term"))
             ("properties" . (("term" . (("type" . "string")
                                         ("description" . "Search term (matches system names and descriptions)")))
                              ("limit" . (("type" . "integer")
                                          ("description" . "Maximum results to show (default: 40)"))))))
   :handler (lambda (args)
              (let ((term (cdr (assoc "term" args :test #'string=)))
                    (limit (cdr (assoc "limit" args :test #'string=))))
                (multiple-value-bind (text error-p)
                    (format-ql-search-results
                     (ql-search-systems term :limit (or limit 40)))
                  (values text error-p)))))

  ;; quicklisp-who-depends-on: reverse dependencies
  (cl-mcp:register-tool server "quicklisp-who-depends-on"
   :description "List the Quicklisp systems that directly depend on a given system. Answers 'what would break if this changed?' and, when judging an unfamiliar library, 'is anything actually using this?' - a reasonable proxy for maturity. Read-only and offline."
   :schema '(("type" . "object")
             ("required" . ("system"))
             ("properties" . (("system" . (("type" . "string")
                                           ("description" . "Quicklisp system name")))
                              ("limit" . (("type" . "integer")
                                          ("description" . "Maximum results to show (default: 60)"))))))
   :handler (lambda (args)
              (let ((name (cdr (assoc "system" args :test #'string=)))
                    (limit (cdr (assoc "limit" args :test #'string=))))
                (multiple-value-bind (text error-p)
                    (format-ql-who-depends-on
                     (ql-who-depends-on name :limit (or limit 60)))
                  (values text error-p)))))

  ;; quicklisp-dist-status: environment health
  (cl-mcp:register-tool server "quicklisp-dist-status"
   :description "Report the health of the local Quicklisp installation: client version, dist version, how many systems are available, how many releases are installed, and whether a newer dist exists. A stale dist explains many otherwise-confusing 'system not found' failures. Reports only - it never updates anything."
   :schema `(("type" . "object")
             ("properties" . ,(make-hash-table :test #'equal)))
   :handler (lambda (args)
              (declare (ignore args))
              (multiple-value-bind (text error-p)
                  (format-ql-dist-status (ql-dist-status))
                (values text error-p))))

  (cl-mcp:register-tool server "describe-generic-function"
   :description "List every method of a generic function with its specializers and qualifiers, including EQL specializers. USE THIS BEFORE CALLING ANY GENERIC FUNCTION whose arguments select behaviour (an ALGORITHM, MODE, KIND or TYPE parameter): the lambda list alone cannot tell you which values are accepted, but the EQL specializers enumerate them exactly. Complements find-methods, which answers the dual question (what specializes on a CLASS)."
   :schema '(("type" . "object")
             ("required" . ("name"))
             ("properties" . (("name" . (("type" . "string")
                                         ("description" . "Generic function name")))
                              ("package" . (("type" . "string")
                                            ("description" . "Package name (default: CL-USER)"))))))
   :handler (lambda (args)
              (let* ((name (cdr (assoc "name" args :test #'string=)))
                     (pkg (cdr (assoc "package" args :test #'string=)))
                     (info (generic-function-info name
                                                  :package (or pkg "CL-USER"))))
                (multiple-value-bind (text error-p)
                    (format-generic-function-info info)
                  (values text error-p)))))

  ;; hyperspec-lookup: symbol -> CLHS URL, resolved from a local table
  (cl-mcp:register-tool server "hyperspec-lookup"
   :description "Get the Common Lisp HyperSpec URL for a standard CL symbol. The symbol->page index is shipped locally so lookup needs no network. Use this for authoritative semantics of standard operators (edge cases, argument conventions, return values) instead of recalling them from memory."
   :schema '(("type" . "object")
             ("required" . ("name"))
             ("properties" . (("name" . (("type" . "string")
                                         ("description" . "Standard CL symbol name, e.g. \"mapcar\" or \"with-open-file\""))))))
   :handler (lambda (args)
              (let ((name (cdr (assoc "name" args :test #'string=))))
                (multiple-value-bind (text error-p)
                    (format-hyperspec-result (lookup-hyperspec name))
                  (values text error-p)))))

  ;; find-definition-source: jump to definition
  (cl-mcp:register-tool server "find-definition-source"
   :description "Find the file and line where a symbol is defined, for functions, macros, generic functions, individual methods, classes, structures, types, conditions and variables. Use this INSTEAD OF grepping the source tree: it asks the running image where a definition actually came from, so it is exact even for code loaded from elsewhere."
   :schema '(("type" . "object")
             ("required" . ("name"))
             ("properties" . (("name" . (("type" . "string")
                                         ("description" . "Symbol name to locate")))
                              ("package" . (("type" . "string")
                                            ("description" . "Package name (default: CL-USER)"))))))
   :handler (lambda (args)
              (let* ((name (cdr (assoc "name" args :test #'string=)))
                     (pkg (cdr (assoc "package" args :test #'string=))))
                (multiple-value-bind (text error-p)
                    (format-definition-source
                     (find-definition-source name :package (or pkg "CL-USER")))
                  (values text error-p)))))

  (cl-mcp:register-tool server "write-lisp-file"
   :description "Write Common Lisp source to a file ATOMICALLY AND SAFELY: the content is parsed first and the file is written ONLY if it is syntactically valid, then compiled to report warnings and type errors. PREFER THIS over any shell/editor tool for creating or overwriting .lisp files -- it cannot leave a malformed file on disk, it keeps a .bak of the previous version, and it returns compiler diagnostics in the same call. Returns isError:true if the content is invalid (nothing written) or if compilation fails."
   :schema '(("type" . "object")
             ("required" . ("path" "content"))
             ("properties" . (("path" . (("type" . "string")
                                         ("description" . "Absolute path of the file to write")))
                              ("content" . (("type" . "string")
                                            ("description" . "Full Common Lisp source text for the file")))
                              ("compile-check" . (("type" . "boolean")
                                                  ("description" . "Compile after writing to surface warnings and type errors (default: true)")))
                              ("backup" . (("type" . "boolean")
                                           ("description" . "Keep a .bak copy of the previous version (default: true)"))))))
   :handler (lambda (args)
              (flet ((arg (k default)
                       (let ((cell (assoc k args :test #'string=)))
                         (if cell (cdr cell) default))))
                (let ((result (write-lisp-file
                               (arg "path" nil)
                               (arg "content" "")
                               :compile-check (not (eq (arg "compile-check" t) :false))
                               :backup (not (eq (arg "backup" t) :false)))))
                  (multiple-value-bind (text error-p) (format-write-result result)
                    (values text error-p))))))

  ;; compile-form: Compile code without evaluating it
  (cl-mcp:register-tool server "compile-form"
   :description "Compile Common Lisp code without executing it. Catches compilation warnings, type errors, and other issues that only appear at compile time. Useful for checking code correctness before evaluation."
   :schema '(("type" . "object")
             ("required" . ("code"))
             ("properties" . (("code" . (("type" . "string")
                                         ("description" . "Common Lisp code to compile")))
                              ("package" . (("type" . "string")
                                            ("description" . "Package context for compilation (default: CL-USER)"))))))
   :handler (lambda (args)
              (let* ((code (cdr (assoc "code" args :test #'string=)))
                     (pkg-name (cdr (assoc "package" args :test #'string=)))
                     (result (introspect-compile-form code :package (or pkg-name "CL-USER"))))
                (format-compile-result result))))

  ;; time-execution: Execute code with detailed timing
  (cl-mcp:register-tool server "time-execution"
   :description "Execute code with detailed timing and memory allocation information. Returns real time, run time, GC time, and bytes allocated. Useful for profiling and performance analysis."
   :schema '(("type" . "object")
             ("required" . ("code"))
             ("properties" . (("code" . (("type" . "string")
                                         ("description" . "Common Lisp code to execute and time")))
                              ("package" . (("type" . "string")
                                            ("description" . "Package context for execution (default: CL-USER)"))))))
   :handler (lambda (args)
              (let* ((code (cdr (assoc "code" args :test #'string=)))
                     (pkg-name (cdr (assoc "package" args :test #'string=)))
                     (result (evaluate-code code :package pkg-name :capture-time t)))
                (format-timing-result result))))

  ;; ========================================================================
  ;; Phase C: Error Intelligence Tools
  ;; ========================================================================

  ;; describe-last-error: Get detailed info about the most recent error
  (cl-mcp:register-tool server "describe-last-error"
   :description "Get detailed information about the most recent error. Returns the error type, message, available restarts, and backtrace from the last failed evaluation. Useful for diagnosing why code failed."
   :schema `(("type" . "object")
             ("properties" . ,(make-hash-table :test #'equal)))
   :handler (lambda (args)
              (declare (ignore args))
              (if (and session (session-last-error session))
                  (cl-mcp-server.error-format:format-structured-error
                   (session-last-error session))
                  "No error recorded in this session. Run some code that causes an error first.")))

  ;; get-backtrace: Get stack trace from the last error
  (cl-mcp:register-tool server "get-backtrace"
   :description "Get the stack trace from the most recent error. Shows the call stack at the point where the error occurred, with frame numbers and function calls. Use max-frames to limit output."
   :schema '(("type" . "object")
             ("properties" . (("max-frames" . (("type" . "integer")
                                               ("description" . "Maximum number of frames to return (default: 20)"))))))
   :handler (lambda (args)
              (let ((max-frames (or (cdr (assoc "max-frames" args :test #'string=)) 20)))
                (if (and session (session-last-error session))
                    (cl-mcp-server.error-format:format-backtrace-detail
                     (session-last-error session) :max-frames max-frames)
                    "No error recorded in this session. Run some code that causes an error first."))))

  ;; ========================================================================
  ;; Phase D: CLOS Intelligence Tools
  ;; ========================================================================

  ;; class-info: Get complete class information
  (cl-mcp:register-tool server "class-info"
   :description "Get complete information about a CLOS class including its slots, superclasses, subclasses, and metaclass. Works with any class in the running image."
   :schema '(("type" . "object")
             ("required" . ("class"))
             ("properties" . (("class" . (("type" . "string")
                                          ("description" . "Class name to inspect")))
                              ("package" . (("type" . "string")
                                            ("description" . "Package name (defaults to CL-USER)"))))))
   :handler (lambda (args)
              (let* ((class-name (cdr (assoc "class" args :test #'string=)))
                     (pkg-name (cdr (assoc "package" args :test #'string=)))
                     (pkg (if pkg-name
                              (find-package (string-upcase pkg-name))
                              (find-package "CL-USER"))))
                (if (not pkg)
                    (format nil "Package ~A not found" pkg-name)
                    (let ((sym (find-symbol (string-upcase class-name) pkg)))
                      (if (and sym (find-class sym nil))
                          (handler-case
                              (format-class-info (introspect-class sym))
                            (error (e)
                              (format nil "Error inspecting class: ~A" e)))
                          (format nil "Class ~A not found in package ~A"
                                  class-name (package-name pkg))))))))

  ;; find-methods: Find all methods specialized on a class
  (cl-mcp:register-tool server "find-methods"
   :description "Find all methods that are specialized on a given class. Shows the generic function name, qualifiers, and specializers for each method. Useful for understanding what operations are available on a class."
   :schema '(("type" . "object")
             ("required" . ("class"))
             ("properties" . (("class" . (("type" . "string")
                                          ("description" . "Class name to find methods for")))
                              ("package" . (("type" . "string")
                                            ("description" . "Package name (defaults to CL-USER)")))
                              ("include-inherited" . (("type" . "boolean")
                                                      ("description" . "Include methods from superclasses (default: false)"))))))
   :handler (lambda (args)
              (let* ((class-name (cdr (assoc "class" args :test #'string=)))
                     (pkg-name (cdr (assoc "package" args :test #'string=)))
                     (include-inherited (cdr (assoc "include-inherited" args :test #'string=)))
                     (pkg (if pkg-name
                              (find-package (string-upcase pkg-name))
                              (find-package "CL-USER"))))
                (if (not pkg)
                    (format nil "Package ~A not found" pkg-name)
                    (let ((sym (find-symbol (string-upcase class-name) pkg)))
                      (if (and sym (find-class sym nil))
                          (handler-case
                              (let ((results (introspect-find-methods sym
                                                                      :include-inherited include-inherited)))
                                (format-find-methods-results results sym))
                            (error (e)
                              (format nil "Error finding methods: ~A" e)))
                          (format nil "Class ~A not found in package ~A"
                                  class-name (package-name pkg))))))))

  ;; ========================================================================
  ;; Phase E: ASDF & Quicklisp Integration Tools
  ;; ========================================================================

  ;; describe-system: Get ASDF system information
  (cl-mcp:register-tool server "describe-system"
   :description "Get comprehensive information about an ASDF system including its version, description, author, license, components, and dependencies. Use this to understand a system's structure before loading."
   :schema '(("type" . "object")
             ("required" . ("system"))
             ("properties" . (("system" . (("type" . "string")
                                           ("description" . "Name of the ASDF system"))))))
   :handler (lambda (args)
              (let ((system-name (cdr (assoc "system" args :test #'string=))))
                (handler-case
                    (format-system-info (introspect-system system-name))
                  (error (e)
                    (format nil "Error: ~A" e))))))

  ;; system-dependencies: Get dependency graph
  (cl-mcp:register-tool server "system-dependencies"
   :description "Get the dependency graph for an ASDF system. Can show just direct dependencies or include all transitive dependencies."
   :schema '(("type" . "object")
             ("required" . ("system"))
             ("properties" . (("system" . (("type" . "string")
                                           ("description" . "Name of the ASDF system")))
                              ("transitive" . (("type" . "boolean")
                                               ("description" . "Include all transitive dependencies (default: false)"))))))
   :handler (lambda (args)
              (let ((system-name (cdr (assoc "system" args :test #'string=)))
                    (transitive (cdr (assoc "transitive" args :test #'string=))))
                (handler-case
                    (format-system-dependencies
                     (introspect-system-dependencies system-name :transitive transitive))
                  (error (e)
                    (format nil "Error: ~A" e))))))

  ;; list-local-systems: Find systems in local projects
  (cl-mcp:register-tool server "list-local-systems"
   :description "List all ASDF systems available locally (from Quicklisp local-projects and ASDF source registry). Shows system names and their .asd file locations."
   :schema `(("type" . "object")
             ("properties" . ,(make-hash-table :test #'equal)))
   :handler (lambda (args)
              (declare (ignore args))
              (handler-case
                  (format-local-systems (introspect-local-systems))
                (error (e)
                  (format nil "Error: ~A" e)))))

  ;; find-system-file: Locate a system's .asd file
  (cl-mcp:register-tool server "find-system-file"
   :description "Find the .asd file for an ASDF system. Returns the full path to the system definition file."
   :schema '(("type" . "object")
             ("required" . ("system"))
             ("properties" . (("system" . (("type" . "string")
                                           ("description" . "Name of the ASDF system to locate"))))))
   :handler (lambda (args)
              (let* ((system-name (cdr (assoc "system" args :test #'string=)))
                     (result (introspect-find-system-file system-name)))
                (if (getf result :found)
                    (format nil "System: ~A~%Location: ~A"
                            (getf result :name)
                            (getf result :pathname))
                    (format nil "System ~A not found" system-name)))))

  ;; quickload: Load via Quicklisp
  (cl-mcp:register-tool server "quickload"
   :description "Load an ASDF system via Quicklisp. Will automatically download the system and its dependencies if not already installed. Safer than load-system for external dependencies."
   :schema '(("type" . "object")
             ("required" . ("system"))
             ("properties" . (("system" . (("type" . "string")
                                           ("description" . "Name of the system to load")))
                              ("verbose" . (("type" . "boolean")
                                            ("description" . "Show detailed loading output (default: false)"))))))
   :handler (lambda (args)
              (let ((system-name (cdr (assoc "system" args :test #'string=)))
                    (verbose (cdr (assoc "verbose" args :test #'string=))))
                (handler-case
                    (progn
                      (let ((result (introspect-quickload system-name :verbose verbose)))
                        (when session
                          (push (getf result :system) (session-loaded-systems session)))
                        (format-quickload-result result)))
                  (error (e)
                    (format nil "Error loading ~A: ~A" system-name e))))))

  ;; NB: the old quicklisp-search was registered here. It returned bare system
  ;; names with no install state and no ranking, and its "pattern" argument
  ;; collided with the richer replacement registered earlier in this function
  ;; (same tool name = last registration wins, silently). Removed in favour of
  ;; the quicklisp-tools version, which takes "term" and reports install state.

  ;; load-file: Load a single Lisp file
  (cl-mcp:register-tool server "load-file"
   :description "Load a single Lisp file into the running image. Can optionally compile the file first. Use this for loading individual files that aren't part of an ASDF system."
   :schema '(("type" . "object")
             ("required" . ("path"))
             ("properties" . (("path" . (("type" . "string")
                                         ("description" . "Path to the Lisp file to load")))
                              ("compile" . (("type" . "boolean")
                                            ("description" . "Compile the file before loading (default: false)")))
                              ("package" . (("type" . "string")
                                            ("description" . "Package context for loading (default: CL-USER)"))))))
   :handler (lambda (args)
              (let ((path (cdr (assoc "path" args :test #'string=)))
                    (compile (cdr (assoc "compile" args :test #'string=)))
                    (package (or (cdr (assoc "package" args :test #'string=)) "CL-USER")))
                (handler-case
                    (format-load-file-result
                     (introspect-load-file path :compile compile :package package))
                  (error (e)
                    (format nil "Error loading file: ~A" e))))))

  ;; ========================================================================
  ;; Phase F: Profiling Tools
  ;; ========================================================================

  ;; profile-code: Statistical profiling with sb-sprof
  (cl-mcp:register-tool server "profile-code"
   :description "Profile code using statistical sampling. Runs the code while collecting stack samples to identify hot spots. Supports CPU time, wall-clock time, or allocation profiling modes."
   :schema '(("type" . "object")
             ("required" . ("code"))
             ("properties" . (("code" . (("type" . "string")
                                         ("description" . "Common Lisp code to profile")))
                              ("mode" . (("type" . "string")
                                         ("description" . "Profiling mode: cpu (default), time (wall-clock), or alloc (memory)")
                                         ("enum" . ("cpu" "time" "alloc"))))
                              ("max-samples" . (("type" . "integer")
                                                ("description" . "Maximum samples to collect (default: 1000)")))
                              ("sample-interval" . (("type" . "number")
                                                    ("description" . "Seconds between samples (default: 0.01)")))
                              ("report-type" . (("type" . "string")
                                                ("description" . "Report format: flat (default) or graph")
                                                ("enum" . ("flat" "graph"))))
                              ("package" . (("type" . "string")
                                            ("description" . "Package context for evaluation (default: CL-USER)"))))))
   :handler (lambda (args)
              (let* ((code (cdr (assoc "code" args :test #'string=)))
                     (mode-str (cdr (assoc "mode" args :test #'string=)))
                     (mode (if mode-str
                               (or (string-to-keyword mode-str '(:cpu :time :alloc))
                                   :cpu)
                               :cpu))
                     (max-samples (or (cdr (assoc "max-samples" args :test #'string=)) 1000))
                     (sample-interval (or (cdr (assoc "sample-interval" args :test #'string=)) 0.01))
                     (report-type-str (cdr (assoc "report-type" args :test #'string=)))
                     (report-type (if report-type-str
                                      (or (string-to-keyword report-type-str '(:flat :graph))
                                          :flat)
                                      :flat))
                     (package (or (cdr (assoc "package" args :test #'string=)) "CL-USER")))
                (handler-case
                    (format-profile-code-result
                     (introspect-profile-code code
                                              :mode mode
                                              :max-samples max-samples
                                              :sample-interval sample-interval
                                              :report-type report-type
                                              :package package))
                  (error (e)
                    (format nil "Profiling error: ~A" e))))))

  ;; profile-functions: Deterministic profiling of specific functions
  (cl-mcp:register-tool server "profile-functions"
   :description "Manage deterministic profiling of specific functions. Tracks exact call counts and time spent. Use 'start' to begin profiling functions, 'report' to see results, 'stop' to end profiling."
   :schema '(("type" . "object")
             ("required" . ("action"))
             ("properties" . (("action" . (("type" . "string")
                                           ("description" . "Action: start, stop, report, reset, or status")
                                           ("enum" . ("start" "stop" "report" "reset" "status"))))
                              ("functions" . (("type" . "array")
                                              ("items" . (("type" . "string")))
                                              ("description" . "Function names to profile (for 'start' action)")))
                              ("package" . (("type" . "string")
                                            ("description" . "Package name - profile all functions in this package (for 'start' action)"))))))
   :handler (lambda (args)
              (let* ((action-str (cdr (assoc "action" args :test #'string=)))
                     (action (string-to-keyword action-str '(:start :stop :report :reset :status)))
                     (functions (cdr (assoc "functions" args :test #'string=)))
                     (package (cdr (assoc "package" args :test #'string=))))
                (handler-case
                    (format-profile-functions-result
                     (introspect-profile-functions action
                                                   :functions functions
                                                   :package package))
                  (error (e)
                    (format nil "Profiling error: ~A" e))))))

  ;; memory-report: Get memory usage and GC statistics
  (cl-mcp:register-tool server "memory-report"
   :description "Get detailed memory usage report including heap statistics and garbage collection information. Useful for understanding memory consumption and GC behavior."
   :schema '(("type" . "object")
             ("properties" . (("verbosity" . (("type" . "string")
                                              ("description" . "Detail level: default, detailed (t), or minimal (nil)")
                                              ("enum" . ("default" "detailed" "minimal"))))
                              ("gc-first" . (("type" . "boolean")
                                             ("description" . "Run garbage collection before reporting (default: false)"))))))
   :handler (lambda (args)
              (let* ((verbosity-str (cdr (assoc "verbosity" args :test #'string=)))
                     (verbosity (cond ((string-equal verbosity-str "detailed") t)
                                      ((string-equal verbosity-str "minimal") nil)
                                      (t :default)))
                     (gc-first (cdr (assoc "gc-first" args :test #'string=))))
                (handler-case
                    (format-memory-report
                     (introspect-memory-report :verbosity verbosity :gc-first gc-first))
                  (error (e)
                    (format nil "Memory report error: ~A" e))))))

  ;; allocation-profile: Profile memory allocations
  (cl-mcp:register-tool server "allocation-profile"
   :description "Profile memory allocation in code. Shows where memory is being allocated, helping identify allocation hot spots and potential memory optimization opportunities."
   :schema '(("type" . "object")
             ("required" . ("code"))
             ("properties" . (("code" . (("type" . "string")
                                         ("description" . "Common Lisp code to profile for allocations")))
                              ("max-samples" . (("type" . "integer")
                                                ("description" . "Maximum allocation samples to collect (default: 1000)")))
                              ("package" . (("type" . "string")
                                            ("description" . "Package context for evaluation (default: CL-USER)"))))))
   :handler (lambda (args)
              (let* ((code (cdr (assoc "code" args :test #'string=)))
                     (max-samples (or (cdr (assoc "max-samples" args :test #'string=)) 1000))
                     (package (or (cdr (assoc "package" args :test #'string=)) "CL-USER")))
                (handler-case
                    (format-allocation-profile-result
                     (introspect-allocation-profile code
                                                    :max-samples max-samples
                                                    :package package))
                  (error (e)
                    (format nil "Allocation profiling error: ~A" e))))))

  ;; ========================================================================
  ;; Parenthesis Matching Tool
  ;; ========================================================================

  (cl-mcp:register-tool server "match-paren"
   :description "Find the matching parenthesis in Lisp source code. Given a cursor position on a paren, returns the position of its match with surrounding context. Essential for navigating nested Lisp expressions."
   :schema '(("type" . "object")
             ("required" . ("code" "line" "column"))
             ("properties" . (("code" . (("type" . "string")
                                         ("description" . "Lisp source code")))
                              ("line" . (("type" . "integer")
                                         ("description" . "1-based line number of the parenthesis")))
                              ("column" . (("type" . "integer")
                                           ("description" . "0-based column number of the parenthesis"))))))
   :handler (lambda (args)
              (let ((code (cdr (assoc "code" args :test #'string=)))
                    (line (cdr (assoc "line" args :test #'string=)))
                    (column (cdr (assoc "column" args :test #'string=))))
                (cond
                  ((not (stringp code))
                   "Error: 'code' parameter must be a string")
                  ((not (integerp line))
                   "Error: 'line' parameter must be an integer")
                  ((not (integerp column))
                   "Error: 'column' parameter must be an integer")
                  (t (format-match-result
                      (find-matching-paren code line column)))))))

  ;; ========================================================================
  ;; Telos Intent Introspection Tools (only when telos is loaded)
  ;; ========================================================================

  ;; telos-list-features: List all defined features
  (cl-mcp:register-tool server "telos-list-features"
   :description "List all telos features defined in loaded systems. Features organize code by purpose and provide queryable intent. Returns nothing if telos is not loaded."
   :schema `(("type" . "object")
             ("properties" . (("filter" . (("type" . "string")
                                           ("description" . "Optional substring to filter feature names"))))))
   :handler (lambda (args)
              (let ((filter (cdr (assoc "filter" args :test #'string=))))
                (format-list-features (introspect-list-features filter)))))

  ;; telos-feature-intent: Get full intent for a feature
  (cl-mcp:register-tool server "telos-feature-intent"
   :description "Get the full intent definition for a telos feature, including purpose, goals, constraints, assumptions, and failure modes."
   :schema '(("type" . "object")
             ("required" . ("feature"))
             ("properties" . (("feature" . (("type" . "string")
                                            ("description" . "Feature name (e.g., 'rrd-memory-backend')"))))))
   :handler (lambda (args)
              (let ((feature-name (cdr (assoc "feature" args :test #'string=))))
                (format-feature-intent
                 (introspect-feature-intent feature-name)
                 feature-name))))

  ;; telos-get-intent: Get intent for any symbol
  (cl-mcp:register-tool server "telos-get-intent"
   :description "Get the intent attached to a function, class, or condition. Shows purpose, role, assumptions, and failure modes."
   :schema '(("type" . "object")
             ("required" . ("name"))
             ("properties" . (("name" . (("type" . "string")
                                         ("description" . "Symbol name to query")))
                              ("package" . (("type" . "string")
                                            ("description" . "Package name (default: current package)"))))))
   :handler (lambda (args)
              (let ((name (cdr (assoc "name" args :test #'string=)))
                    (package (cdr (assoc "package" args :test #'string=))))
                (format-get-intent (introspect-get-intent name package)))))

  ;; telos-intent-chain: Trace intent from symbol to root feature
  (cl-mcp:register-tool server "telos-intent-chain"
   :description "Trace the intent hierarchy from a function or class up to its root feature. Shows how code fits into the larger design."
   :schema '(("type" . "object")
             ("required" . ("name"))
             ("properties" . (("name" . (("type" . "string")
                                         ("description" . "Symbol name to trace")))
                              ("package" . (("type" . "string")
                                            ("description" . "Package name (default: current package)"))))))
   :handler (lambda (args)
              (let ((name (cdr (assoc "name" args :test #'string=)))
                    (package (cdr (assoc "package" args :test #'string=))))
                (format-intent-chain (introspect-intent-chain name package)))))

  ;; telos-feature-members: List members of a feature
  (cl-mcp:register-tool server "telos-feature-members"
   :description "List all functions and classes that belong to a telos feature."
   :schema '(("type" . "object")
             ("required" . ("feature"))
             ("properties" . (("feature" . (("type" . "string")
                                            ("description" . "Feature name to query"))))))
   :handler (lambda (args)
              (let ((feature-name (cdr (assoc "feature" args :test #'string=))))
                (format-feature-members
                 (introspect-feature-members feature-name)
                 feature-name))))

  ;; telos-feature-decisions: Get decisions for a feature
  (cl-mcp:register-tool server "telos-feature-decisions"
   :description "Get the decisions recorded for a telos feature. Shows what was chosen, what was rejected, and why. Decisions capture the rationale behind design choices."
   :schema '(("type" . "object")
             ("required" . ("feature"))
             ("properties" . (("feature" . (("type" . "string")
                                            ("description" . "Feature name to query decisions for"))))))
   :handler (lambda (args)
              (let ((feature-name (cdr (assoc "feature" args :test #'string=))))
                (format-feature-decisions
                 (introspect-feature-decisions feature-name)
                 feature-name))))

  ;; telos-list-decisions: List all decisions across features
  (cl-mcp:register-tool server "telos-list-decisions"
   :description "List all recorded decisions across all telos features. Shows a summary of what was chosen and rejected for each feature."
   :schema `(("type" . "object")
             ("properties" . ,(make-hash-table :test #'equal)))
   :handler (lambda (args)
              (declare (ignore args))
              (format-list-decisions (introspect-list-decisions)))))

;;; ==========================================================================
;;; Usage Guide Content
;;; ==========================================================================

(defun get-usage-guide-content ()
  "Return the usage guide for effective MCP server usage."
  "# CL-MCP-Server Usage Guide

## Rule 0: Don't guess — ask the image

Before calling ANY function you have not called before in this session,
retrieve its signature. Guessing feels cheaper than a tool call. It is not:
a wrong guess costs an error, a re-read, and a retry, and silently wrong
guesses cost far more. One lookup is cheaper than one wrong guess.

| Before you... | Call | Why |
|---------------|------|-----|
| call an unfamiliar function | `describe-symbol` | real lambda list, not a remembered one |
| call a generic function with a mode/algorithm/kind argument | `describe-generic-function` | EQL specializers enumerate the accepted values; the lambda list cannot |
| rely on a standard CL operator's edge-case behaviour | `hyperspec-lookup` | authoritative semantics |
| grep for where something is defined | `find-definition-source` | asks the image, exact |
| write a .lisp file | `write-lisp-file` | fail-closed: invalid content is never written |
| guess whether a name exists | `apropos-search` | cheap discovery |

The image knows. Ask it.

## Quick Start

This server provides a persistent Common Lisp REPL accessible via MCP tools.
Definitions persist across calls within a session.

## Available Tools

| Tool | Purpose | When to Use |
|------|---------|-------------|
| evaluate-lisp | Execute code, persist definitions | Main development tool |
| describe-generic-function | Methods + EQL specializers of a GF | BEFORE calling a GF with a mode/algorithm arg |
| hyperspec-lookup | CLHS URL for a standard symbol | Authoritative semantics of CL operators |
| find-definition-source | File and line of a definition | Instead of grepping the tree |
| write-lisp-file | Validate, write, compile in one call | Creating/overwriting .lisp files |
| validate-syntax | Check paren balance, syntax | BEFORE saving files |
| compile-form | Type check without execution | Pre-commit verification |
| describe-symbol | Inspect symbols | Understanding APIs |
| apropos-search | Find symbols by pattern | Discovering functions |
| macroexpand-form | Expand macros | Debug macro usage |
| time-execution | Profile with timing | Performance analysis |
| describe-last-error | Get last error details | After an error occurs |
| get-backtrace | Get error stack trace | Diagnosing errors |
| class-info | Inspect CLOS classes | Understanding class structure |
| find-methods | Find methods on a class | Discovering class operations |
| describe-system | Get ASDF system info | Before loading systems |
| system-dependencies | Get dependency graph | Understanding dependencies |
| list-local-systems | Find local systems | Discovering available systems |
| quickload | Load via Quicklisp | Loading external libraries |
| quicklisp-search | Search Quicklisp | Finding libraries |
| load-file | Load a Lisp file | Loading individual files |
| profile-code | Statistical profiling | Finding performance hot spots |
| profile-functions | Deterministic profiling | Exact timing of specific functions |
| memory-report | Memory usage stats | Understanding memory consumption |
| allocation-profile | Allocation profiling | Finding allocation hot spots |
| telos-list-features | List intent features | Understanding code organization |
| telos-feature-intent | Get feature intent | Understanding WHY code exists |
| telos-get-intent | Get symbol intent | Purpose of function/class |
| telos-intent-chain | Trace intent hierarchy | Code to feature relationship |
| telos-feature-members | List feature members | What belongs to a feature |
| telos-feature-decisions | Get feature decisions | Why design choices were made |
| telos-list-decisions | List all decisions | Overview of all design decisions |
| list-definitions | Show session state | Review what's defined |
| reset-session | Clear all state | Start fresh |

## Recommended Workflow

### 1. Incremental Development
Build up code piece by piece, testing as you go:

```
evaluate-lisp: (defun helper (x) (1+ x))     ; Define
evaluate-lisp: (helper 5)                     ; Test -> 6
evaluate-lisp: (defun main (lst) (mapcar #'helper lst))
evaluate-lisp: (main '(1 2 3))                ; Test -> (2 3 4)
```

### 2. Validate Before Save (CRITICAL)
ALWAYS validate syntax before writing Lisp files:

```
1. Prepare new file content
2. Call validate-syntax with full content
3. If valid: save file
4. If invalid: fix errors, repeat step 2
```

This prevents parenthesis mismatches that are hard to debug.

### 3. Explore Before Implementing
Use introspection to understand existing code:

```
apropos-search: pattern=\"hash\"       ; Find hash-related functions
describe-symbol: name=\"gethash\"      ; Understand the API
```

### 4. Type Check Before Commit
Use compile-form for thorough checking:

```
compile-form catches type errors that evaluate-lisp misses
```

## Common Patterns

### Define and Test
```lisp
evaluate-lisp: (defun factorial (n)
                 (if (<= n 1) 1 (* n (factorial (1- n)))))
evaluate-lisp: (mapcar #'factorial '(1 2 3 4 5))
```

### Capture Timing
```lisp
evaluate-lisp with capture-time=true for timing info
```

### Package Context
```lisp
evaluate-lisp with package=\"MY-PACKAGE\" for specific package context
```

## Anti-Patterns to Avoid

1. **Don't save without validation** - Always call validate-syntax first
2. **Don't write large untested code** - Build incrementally
3. **Don't guess APIs** - Use apropos-search and describe-symbol
4. **Don't ignore compile warnings** - Use compile-form

## Error Recovery

- Syntax errors: Use validate-syntax to find the issue
- Runtime errors: Server catches all errors, won't crash
- Lost state: Use list-definitions to see what's defined
- Fresh start: Use reset-session

## Session Persistence

- Functions, variables, macros persist across calls
- Loaded systems (via load-system) persist
- Package context can be set per-call

Call list-definitions to see current session state.")

;;; src/packages.lisp
;;; ABOUTME: Package definitions for CL-MCP-Server (uses cl-mcp library)

;;; Slim conditions package — only REPL-specific conditions
;;; All JSON-RPC error conditions come from cl-mcp.conditions
(defpackage #:cl-mcp-server.conditions
  (:use #:cl #:cl-mcp.conditions)
  (:shadowing-import-from #:cl-mcp.conditions #:parse-error)
  (:export
   ;; Re-export from cl-mcp.conditions for backward compat
   #:mcp-error
   #:json-rpc-error
   #:parse-error
   #:invalid-request
   #:method-not-found
   #:invalid-params
   #:internal-error
   #:error-code
   #:error-message
   #:error-data
   ;; REPL-specific
   #:evaluation-timeout
   #:timeout-seconds
   #:timeout-backtrace))

(defpackage #:cl-mcp-server.error-format
  (:use #:cl)
  (:export
   #:format-condition
   #:format-error
   #:format-warning
   #:format-backtrace
   #:*max-backtrace-depth*
   #:*print-backtrace-p*
   #:with-error-capture
   ;; Phase C: Structured error capture
   #:capture-structured-error
   #:format-structured-error
   #:format-backtrace-detail))

(defpackage #:cl-mcp-server.session
  (:use #:cl #:cl-mcp.conditions)
  (:shadowing-import-from #:cl-mcp.conditions #:parse-error)
  (:export
   #:*session*
   #:session
   #:make-session
   #:session-package
   #:session-loaded-systems
   #:session-definitions
   #:session-last-error
   #:reset-session
   #:list-definitions
   #:format-definitions
   #:switch-package
   #:with-session))

(defpackage #:cl-mcp-server.evaluator
  (:use #:cl
        #:cl-mcp-server.session
        #:cl-mcp-server.error-format
        #:cl-mcp-server.conditions)
  (:shadowing-import-from #:cl-mcp-server.conditions #:parse-error)
  (:export
   #:evaluate-code
   #:evaluation-result
   #:make-evaluation-result
   #:result-values
   #:result-stdout
   #:result-stderr
   #:result-warnings
   #:result-error
   #:result-structured-error
   #:result-success-p
   #:result-definitions
   #:result-timing
   #:result-package
   #:format-result
   #:format-timing-result
   ;; Timeout configuration
   #:*evaluation-timeout*
   #:*max-output-chars*
   #:*include-backtrace-in-evaluate-response*))

(defpackage #:cl-mcp-server.introspection
  (:use #:cl)
  (:export
   ;; Symbol type classification
   #:symbol-type-info
   ;; A.1: describe-symbol
   #:introspect-symbol
   #:format-symbol-info
   ;; A.2: apropos-search
   #:introspect-apropos
   #:format-apropos-results
   ;; A.3: who-calls
   #:introspect-who-calls
   #:format-who-calls-results
   ;; who-references
   #:introspect-who-references
   #:format-who-references-results
   ;; A.4: macroexpand-form
   #:introspect-macroexpand
   #:format-macroexpand-result
   ;; A.5: validate-syntax
   #:introspect-validate-syntax
   #:format-validate-result
   ;; B.2: compile-form
   #:introspect-compile-form
   #:format-compile-result
   ;; D.1: class-info
   #:introspect-slot
   #:introspect-class
   #:format-slot-info
   #:format-class-info
   ;; D.2: find-methods
   #:introspect-method
   #:introspect-find-methods
   #:format-method-info
   #:format-find-methods-results
   ;; Helper
   #:resolve-symbol))

(defpackage #:cl-mcp-server.asdf-tools
  (:use #:cl)
  (:export
   ;; E.1: describe-system
   #:introspect-system
   #:format-system-info
   #:collect-components
   ;; E.3: quickload / quicklisp-search
   #:quicklisp-available-p
   #:introspect-quickload
   #:format-quickload-result
   ;; E.4: system-dependencies
   #:introspect-system-dependencies
   #:format-system-dependencies
   ;; E.5: list-local-systems / find-system-file
   #:introspect-local-systems
   #:format-local-systems
   #:introspect-find-system-file
   ;; E.6: load-file
   #:introspect-load-file
   #:format-load-file-result
   ;; Helper
   #:normalize-dependency))

(defpackage #:cl-mcp-server.profiling-tools
  (:use #:cl)
  (:export
   ;; F.1: profile-code (statistical profiling)
   #:introspect-profile-code
   #:format-profile-code-result
   ;; F.2: profile-functions (deterministic profiling)
   #:*profiled-functions*
   #:introspect-profile-functions
   #:format-profile-functions-result
   ;; F.3: memory-report
   #:introspect-memory-report
   #:format-memory-report
   ;; F.4: allocation-profile
   #:introspect-allocation-profile
   #:format-allocation-profile-result))

(defpackage #:cl-mcp-server.telos-tools
  (:use #:cl)
  (:export
   ;; Availability check
   #:telos-available-p
   ;; Name resolution
   #:resolve-feature-name
   #:resolve-feature
   #:qualified-name
   ;; Introspection
   #:introspect-list-features
   #:introspect-feature-intent
   #:introspect-get-intent
   #:introspect-intent-chain
   #:introspect-feature-members
   #:introspect-feature-decisions
   #:introspect-list-decisions
   ;; Formatting
   #:format-list-features
   #:format-feature-intent
   #:format-get-intent
   #:format-intent-chain
   #:format-feature-members
   #:format-feature-decisions
   #:format-list-decisions))

(defpackage #:cl-mcp-server.paren-tools
  (:use #:cl)
  (:export
   #:find-matching-paren
   #:format-match-result))

(defpackage #:cl-mcp-server.file-tools
  (:use #:cl)
  (:export
   #:write-lisp-file
   #:format-write-result
   #:validate-file-content
   #:count-paren-balance
   #:compile-file-check
   #:*backup-suffix*))

(defpackage #:cl-mcp-server.hyperspec
  (:use #:cl)
  (:export
   ;; CLHS lookup
   #:lookup-hyperspec
   #:hyperspec-url
   #:format-hyperspec-result
   #:*hyperspec-root*
   #:*clhs-pages*
   ;; generic function / method enumeration
   #:generic-function-info
   #:format-generic-function-info
   #:eql-specializer-values
   #:specializer-label
   ;; definition source
   #:find-definition-source
   #:format-definition-source))

(defpackage #:cl-mcp-server.quicklisp-tools
  (:use #:cl)
  (:export
   ;; NB: QUICKLISP-AVAILABLE-P is deliberately NOT exported here --
   ;; cl-mcp-server.asdf-tools already exports a function of that name and
   ;; tools.lisp :uses both packages, so exporting it would be a name
   ;; conflict. It remains internal and callable as
   ;; cl-mcp-server.quicklisp-tools::quicklisp-available-p.
   #:quicklisp-unavailable
   ;; NB: names are ql-prefixed. cl-mcp-server.asdf-tools already exports
   ;; SYSTEM-INFO / FORMAT-SYSTEM-INFO, and tools.lisp :uses both packages,
   ;; so unprefixed names here would be a package conflict at load time.
   #:ql-dry-run
   #:format-ql-dry-run
   #:ql-system-info
   #:format-ql-system-info
   #:ql-search-systems
   #:format-ql-search-results
   #:ql-who-depends-on
   #:format-ql-who-depends-on
   #:ql-dist-status
   #:format-ql-dist-status
   #:collect-dependencies
   #:system-installed-p
   #:human-bytes))

(defpackage #:cl-mcp-server.restarts
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads))
  (:export
   #:evaluate-suspendable
   #:resume-suspension
   #:abandon-suspension
   #:live-suspensions
   #:suspension-count
   #:format-eval-outcome
   #:format-suspension-list
   #:restart-interactive-p
   #:describe-restarts
   #:*suspension-timeout*
   #:*max-suspensions*))

(defpackage #:cl-mcp-server.inspector
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads))
  ;; CLEAR-REGISTRY and REGISTRY-COUNT stay internal: useful at a REPL via
  ;; `::`, but no tool reaches them, and an exported name with no consumer is
  ;; API we would have to keep.
  (:export
   #:inspect-object
   #:inspect-expression
   #:inspect-part
   #:format-inspection
   #:object-parts
   #:*max-parts*
   #:*registry-limit*))

(defpackage #:cl-mcp-server.trace-tools
  (:use #:cl)
  (:export
   #:call-with-trace
   #:format-trace-result
   #:trace-functions
   #:untrace-functions
   #:disassemble-function
   #:format-disassembly
   #:macrostep
   #:format-macrostep
   #:who-specializes
   #:format-who-specializes))

(defpackage #:cl-mcp-server.swank-protocol
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads))
  (:export
   #:connect
   #:disconnect
   #:rex
   #:swank-error
   #:swank-aborted
   #:swank-aborted-restarts
   #:swank-aborted-condition
   #:*call-timeout*
   #:*connect-timeout*))

(defpackage #:cl-mcp-server.remote
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads))
  ;; CLASSIFY-FORM and TIER-ALLOWED-P stay internal: they are the guts of
  ;; REMOTE-EVAL, not an interface anything outside calls.
  (:export
   #:register-target
   #:find-target
   #:list-targets
   #:target-name
   #:target-host
   #:target-port
   #:target-mode
   #:remote-eval
   #:close-connection
   #:ledger-for
   #:entry-time-string
   #:entry-target
   #:entry-tier
   #:entry-form
   #:entry-outcome
   #:entry-detail))

(defpackage #:cl-mcp-server.tools
  (:use #:cl
        #:cl-mcp-server.evaluator
        #:cl-mcp-server.session
        #:cl-mcp-server.introspection
        #:cl-mcp-server.asdf-tools
        #:cl-mcp-server.profiling-tools
        #:cl-mcp-server.telos-tools
        #:cl-mcp-server.paren-tools
        #:cl-mcp-server.file-tools
        #:cl-mcp-server.hyperspec
        #:cl-mcp-server.quicklisp-tools)
  (:export
   #:define-builtin-tools
   #:get-usage-guide-content))

(defpackage #:cl-mcp-server
  (:use #:cl
        #:cl-mcp-server.session)
  (:export
   #:start))

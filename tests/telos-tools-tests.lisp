;;; tests/telos-tools-tests.lisp
;;; ABOUTME: Tests for telos feature-name resolution and result formatting.
;;;
;;; Two tiers:
;;;   1. Pure resolver/formatter tests over synthetic data (no telos needed).
;;;   2. End-to-end tests against real features registered by telos-fixture.

(in-package #:cl-mcp-server-tests)

(def-suite telos-tools-tests
  :description "Telos name resolution and result formatting"
  :in cl-mcp-server-tests)

(in-suite telos-tools-tests)

;;; ==========================================================================
;;; Tier 1: resolve-feature-name over synthetic candidates
;;; ==========================================================================

(defparameter *synthetic-candidates*
  (list 'cl-mcp-server-tests.widget::sample-widget-feature
        'cl-mcp-server-tests.widget::silent-widget-feature
        'cl-mcp-server-tests.widget::duplicated-feature
        'cl-mcp-server-tests.gadget::duplicated-feature)
  "Symbols interned in packages the resolver must not have to guess.")

(test resolve-bare-lowercase-name
  "THE BUG: a bare lowercase name must resolve to a symbol in a foreign package."
  (is (eq 'cl-mcp-server-tests.widget::sample-widget-feature
          (cl-mcp-server.telos-tools:resolve-feature-name
           "sample-widget-feature" *synthetic-candidates*))))

(test resolve-bare-uppercase-name
  "Resolution is case-insensitive, so the uppercase spelling works too."
  (is (eq 'cl-mcp-server-tests.widget::sample-widget-feature
          (cl-mcp-server.telos-tools:resolve-feature-name
           "SAMPLE-WIDGET-FEATURE" *synthetic-candidates*))))

(test resolve-surrounding-whitespace
  "Leading and trailing whitespace is trimmed."
  (is (eq 'cl-mcp-server-tests.widget::sample-widget-feature
          (cl-mcp-server.telos-tools:resolve-feature-name
           "  sample-widget-feature  " *synthetic-candidates*))))

(test resolve-double-colon-qualified-name
  "A package-qualified name resolves through the named package."
  (is (eq 'cl-mcp-server-tests.gadget::duplicated-feature
          (cl-mcp-server.telos-tools:resolve-feature-name
           "cl-mcp-server-tests.gadget::duplicated-feature" *synthetic-candidates*))))

(test resolve-single-colon-qualified-name
  "A single colon is accepted as well; agents do not track external-ness."
  (is (eq 'cl-mcp-server-tests.widget::duplicated-feature
          (cl-mcp-server.telos-tools:resolve-feature-name
           "cl-mcp-server-tests.widget:duplicated-feature" *synthetic-candidates*))))

(test resolve-leading-colon-keyword-spelling
  "A leading colon is the keyword spelling an agent reaches for; accept it."
  (is (eq 'cl-mcp-server-tests.widget::sample-widget-feature
          (cl-mcp-server.telos-tools:resolve-feature-name
           ":sample-widget-feature" *synthetic-candidates*))))

(test resolve-keyword-input
  "A keyword symbol resolves by name, not by EQ, so old call sites still work."
  (is (eq 'cl-mcp-server-tests.widget::sample-widget-feature
          (cl-mcp-server.telos-tools:resolve-feature-name
           :sample-widget-feature *synthetic-candidates*))))

(test resolve-empty-string-returns-nil
  "An empty name resolves to NIL rather than matching something surprising."
  (is (null (cl-mcp-server.telos-tools:resolve-feature-name
             "" *synthetic-candidates*)))
  (is (null (cl-mcp-server.telos-tools:resolve-feature-name
             "   " *synthetic-candidates*))))

(test resolve-symbol-input-passes-through
  "A symbol that is already a registry key resolves to itself."
  (is (eq 'cl-mcp-server-tests.widget::sample-widget-feature
          (cl-mcp-server.telos-tools:resolve-feature-name
           'cl-mcp-server-tests.widget::sample-widget-feature *synthetic-candidates*))))

(test resolve-unknown-name-returns-nil
  "An unregistered name resolves to NIL, not to a freshly interned symbol."
  (is (null (cl-mcp-server.telos-tools:resolve-feature-name
             "no-such-feature" *synthetic-candidates*))))

(test resolve-unknown-package-returns-nil
  "A qualified name in a package that does not exist resolves to NIL."
  (is (null (cl-mcp-server.telos-tools:resolve-feature-name
             "no.such.package::duplicated-feature" *synthetic-candidates*))))

(test resolve-qualified-name-not-registered-returns-nil
  "A qualified name for a real symbol that is not a candidate resolves to NIL."
  (is (null (cl-mcp-server.telos-tools:resolve-feature-name
             "cl-mcp-server-tests.widget::widget-member-function"
             *synthetic-candidates*))))

(test resolve-ambiguous-name-reports-all-hits
  "A bare name matching two packages returns the extra hits, never a silent pick."
  (multiple-value-bind (key extras)
      (cl-mcp-server.telos-tools:resolve-feature-name
       "duplicated-feature" *synthetic-candidates*)
    (is (not (null key)))
    (is (= 1 (length extras)))
    (is (= 2 (length (remove-duplicates (cons key extras)))))))

(test resolve-qualified-name-is-never-ambiguous
  "Qualifying an otherwise-ambiguous name yields exactly one hit."
  (multiple-value-bind (key extras)
      (cl-mcp-server.telos-tools:resolve-feature-name
       "cl-mcp-server-tests.gadget::duplicated-feature" *synthetic-candidates*)
    (is (eq 'cl-mcp-server-tests.gadget::duplicated-feature key))
    (is (null extras))))

;;; ==========================================================================
;;; Tier 1: error messages must not conflate the three failure modes
;;; ==========================================================================

(defun mentions-not-loaded-p (text)
  "True if TEXT blames telos for not being loaded."
  (or (search "not loaded" (string-downcase text))
      (search "not be loaded" (string-downcase text))))

(test not-found-message-does-not-blame-telos
  "A missing feature must not be reported as telos being unloaded."
  (let ((text (cl-mcp-server.telos-tools:format-feature-decisions
               '(:status :not-found :name "no-such-feature"
                 :feature-count 111 :suggestions nil)
               "no-such-feature")))
    (is (not (mentions-not-loaded-p text)))
    (is (search "111" text))))

(test not-found-message-offers-suggestions
  "Close matches are offered so the agent can recover in one step."
  (let ((text (cl-mcp-server.telos-tools:format-feature-decisions
               '(:status :not-found :name "widget"
                 :feature-count 4
                 :suggestions ("SAMPLE-WIDGET-FEATURE" "SILENT-WIDGET-FEATURE"))
               "widget")))
    (is (search "SAMPLE-WIDGET-FEATURE" text))))

(test empty-decisions-is-distinguishable-from-missing
  "A found feature with no decisions reads differently from a missing feature."
  (let ((found (cl-mcp-server.telos-tools:format-feature-decisions
                '(:status :ok :feature nil :decisions nil)
                "silent-widget-feature"))
        (missing (cl-mcp-server.telos-tools:format-feature-decisions
                  '(:status :not-found :name "ghost-feature"
                    :feature-count 4 :suggestions nil)
                  "ghost-feature")))
    (is (string/= found missing))
    (is (not (mentions-not-loaded-p found)))))

(test unavailable-message-says-telos-is-not-loaded
  "When telos genuinely is not loaded, say so, and say how to load it."
  (let ((text (cl-mcp-server.telos-tools:format-feature-decisions
               '(:status :unavailable) "anything")))
    (is (mentions-not-loaded-p text))
    (is (search "quickload" (string-downcase text)))))

(test ambiguous-message-lists-candidates
  "An ambiguous name reports every candidate rather than picking one."
  (let ((text (cl-mcp-server.telos-tools:format-feature-decisions
               '(:status :ambiguous :name "duplicated-feature"
                 :candidates ("A::DUPLICATED-FEATURE" "B::DUPLICATED-FEATURE"))
               "duplicated-feature")))
    (is (search "A::DUPLICATED-FEATURE" text))
    (is (search "B::DUPLICATED-FEATURE" text))))

(test intent-not-found-message-does-not-blame-telos
  "The same message split applies to feature-intent."
  (let ((text (cl-mcp-server.telos-tools:format-feature-intent
               '(:status :not-found :name "no-such-feature"
                 :feature-count 7 :suggestions nil)
               "no-such-feature")))
    (is (not (mentions-not-loaded-p text)))
    (is (search "7" text))))

(test members-not-found-message-does-not-blame-telos
  "And to feature-members."
  (let ((text (cl-mcp-server.telos-tools:format-feature-members
               '(:status :not-found :name "no-such-feature"
                 :feature-count 7 :suggestions nil)
               "no-such-feature")))
    (is (not (mentions-not-loaded-p text)))))

(test empty-members-is-distinguishable-from-missing
  "A feature with no members is a legitimate answer, not a lookup failure."
  (let ((found (cl-mcp-server.telos-tools:format-feature-members
                '(:status :ok :feature nil :members nil)
                "silent-widget-feature"))
        (missing (cl-mcp-server.telos-tools:format-feature-members
                  '(:status :not-found :name "ghost-feature"
                    :feature-count 4 :suggestions nil)
                  "ghost-feature")))
    (is (string/= found missing))
    (is (not (mentions-not-loaded-p found)))))

;;; ==========================================================================
;;; Tier 2: end-to-end against real telos registries
;;; ==========================================================================

(test end-to-end-bare-name-finds-decisions
  "Acceptance 1: a bare feature name returns that feature's decisions."
  (let ((result (cl-mcp-server.telos-tools:introspect-feature-decisions
                 "sample-widget-feature")))
    (is (eq :ok (getf result :status)))
    (is (eq 'cl-mcp-server-tests.widget::sample-widget-feature
            (getf result :feature)))
    (is (= 2 (length (getf result :decisions))))
    (is (member :own-package (getf result :decisions)
                :key (lambda (d) (getf d :id))))))

(test end-to-end-qualified-name-finds-same-decisions
  "Acceptance 2: the package-qualified spelling returns the same decisions."
  (let ((bare (cl-mcp-server.telos-tools:introspect-feature-decisions
               "sample-widget-feature"))
        (qualified (cl-mcp-server.telos-tools:introspect-feature-decisions
                    "cl-mcp-server-tests.widget::sample-widget-feature")))
    (is (eq :ok (getf qualified :status)))
    (is (equal (getf bare :decisions) (getf qualified :decisions)))))

(test end-to-end-bare-name-finds-intent
  "Acceptance 3: purpose, goals, constraints and failure modes come back."
  (let ((result (cl-mcp-server.telos-tools:introspect-feature-intent
                 "sample-widget-feature")))
    (is (eq :ok (getf result :status)))
    (let ((intent (getf result :intent)))
      (is (stringp (getf intent :purpose)))
      (is (not (null (getf intent :goals))))
      (is (not (null (getf intent :constraints))))
      (is (not (null (getf intent :failure-modes)))))))

(test end-to-end-missing-feature-reports-count
  "Acceptance 4: a missing feature is reported with the registry size."
  (let ((result (cl-mcp-server.telos-tools:introspect-feature-decisions
                 "no-such-feature")))
    (is (eq :not-found (getf result :status)))
    (is (plusp (getf result :feature-count)))
    (is (not (mentions-not-loaded-p
              (cl-mcp-server.telos-tools:format-feature-decisions
               result "no-such-feature"))))))

(test end-to-end-registered-feature-with-no-decisions
  "Acceptance 5: an empty decision list is :ok, not :not-found."
  (let ((result (cl-mcp-server.telos-tools:introspect-feature-decisions
                 "silent-widget-feature")))
    (is (eq :ok (getf result :status)))
    (is (null (getf result :decisions)))))

(test end-to-end-list-features-still-works
  "Acceptance 6: regression guard on the tool that never resolved a name."
  (let ((result (cl-mcp-server.telos-tools:introspect-list-features nil)))
    (is (eq :ok (getf result :status)))
    (is (member 'cl-mcp-server-tests.widget::sample-widget-feature
                (getf result :features)
                :key (lambda (f) (getf f :name))))
    (is (search "sample-widget-feature"
                (string-downcase
                 (cl-mcp-server.telos-tools:format-list-features result))))))

(test end-to-end-bare-name-finds-members
  "feature-members resolves a bare name and lists the registered function."
  (let ((result (cl-mcp-server.telos-tools:introspect-feature-members
                 "sample-widget-feature")))
    (is (eq :ok (getf result :status)))
    (is (member 'cl-mcp-server-tests.widget::widget-member-function
                (getf (getf result :members) :functions)))))

(test end-to-end-ambiguous-name-is-reported
  "A genuinely ambiguous bare name is reported, never silently disambiguated."
  (let ((result (cl-mcp-server.telos-tools:introspect-feature-intent
                 "duplicated-feature")))
    (is (eq :ambiguous (getf result :status)))
    (is (= 2 (length (getf result :candidates))))))

(test end-to-end-get-intent-without-package-argument
  "telos-get-intent resolves a bare symbol name via telos's own registries."
  (let ((result (cl-mcp-server.telos-tools:introspect-get-intent
                 "widget-member-function" nil)))
    (is (eq :ok (getf result :status)))
    (is (eq 'cl-mcp-server-tests.widget::widget-member-function
            (getf result :name)))))

(test end-to-end-intent-chain-without-package-argument
  "telos-intent-chain resolves a bare symbol name and walks up to the feature."
  (let ((result (cl-mcp-server.telos-tools:introspect-intent-chain
                 "widget-member-function" nil)))
    (is (eq :ok (getf result :status)))
    (is (member 'cl-mcp-server-tests.widget::sample-widget-feature
                (getf result :chain)
                :key (lambda (entry) (getf entry :name))))))

(test end-to-end-defclass-i-class-is-findable-by-bare-name
  "defclass/i classes live on the metaobject, in no registry. Find them anyway."
  (let ((result (cl-mcp-server.telos-tools:introspect-get-intent
                 "widget-member-class" nil)))
    (is (eq :ok (getf result :status)))
    (is (eq 'cl-mcp-server-tests.widget::widget-member-class (getf result :name)))
    (is (stringp (getf (getf result :intent) :purpose)))))

(test end-to-end-defclass-i-class-by-qualified-name
  "The qualifier must be honoured on the class path too, not just the registry."
  (let ((result (cl-mcp-server.telos-tools:introspect-get-intent
                 "cl-mcp-server-tests.widget::widget-member-class" nil)))
    (is (eq :ok (getf result :status)))
    (is (eq 'cl-mcp-server-tests.widget::widget-member-class (getf result :name)))))

(test end-to-end-defclass-i-class-is-labelled-a-class
  "A class must not be reported as :kind :function."
  (is (eq :class (getf (cl-mcp-server.telos-tools:introspect-get-intent
                        "widget-member-class" nil)
                       :kind))))

(test end-to-end-defclass-i-class-has-an-intent-chain
  "The metaobject path also has to work for intent-chain."
  (let ((result (cl-mcp-server.telos-tools:introspect-intent-chain
                 "widget-member-class" nil)))
    (is (eq :ok (getf result :status)))
    (is (member 'cl-mcp-server-tests.widget::sample-widget-feature
                (getf result :chain)
                :key (lambda (entry) (getf entry :name))))))

;;; ==========================================================================
;;; Tier 2: a broken telos must be reported as broken, never as empty
;;; ==========================================================================

(defmacro with-broken-telos ((function-name) &body body)
  "Run BODY with telos's FUNCTION-NAME stubbed to signal, then restore it."
  (let ((saved (gensym "SAVED")))
    `(let ((,saved (fdefinition ',function-name)))
       (unwind-protect
            (progn
              (setf (fdefinition ',function-name)
                    (lambda (&rest args)
                      (declare (ignore args))
                      (error "simulated telos failure")))
              ,@body)
         (setf (fdefinition ',function-name) ,saved)))))

(test broken-list-features-is-reported-as-an-error
  "A failing telos:list-features must not become 'No feature named X'."
  (with-broken-telos (telos:list-features)
    (let ((result (cl-mcp-server.telos-tools:introspect-feature-decisions
                   "sample-widget-feature")))
      (is (eq :error (getf result :status))))))

(test broken-list-features-never-fabricates-a-registry-count
  "The regression that matters: never assert '0 features are registered'."
  (with-broken-telos (telos:list-features)
    (let ((text (cl-mcp-server.telos-tools:format-feature-decisions
                 (cl-mcp-server.telos-tools:introspect-feature-decisions
                  "sample-widget-feature")
                 "sample-widget-feature")))
      (is (null (search "0 features are registered" text)))
      (is (null (search "No feature named" text)))
      (is (search "Telos failed" text)))))

(test broken-feature-decisions-is-not-reported-as-empty
  "A failing lookup must not masquerade as 'records no decisions'."
  (with-broken-telos (telos:feature-decisions)
    (let ((text (cl-mcp-server.telos-tools:format-feature-decisions
                 (cl-mcp-server.telos-tools:introspect-feature-decisions
                  "sample-widget-feature")
                 "sample-widget-feature")))
      (is (null (search "records no decisions" text)))
      (is (search "Telos failed" text)))))

(test broken-feature-members-is-not-reported-as-empty
  "Likewise for members: absent and broken are different answers."
  (with-broken-telos (telos:feature-members)
    (let ((text (cl-mcp-server.telos-tools:format-feature-members
                 (cl-mcp-server.telos-tools:introspect-feature-members
                  "sample-widget-feature")
                 "sample-widget-feature")))
      (is (null (search "has no members" text)))
      (is (search "Telos failed" text)))))

(test broken-decision-accessor-does-not-fabricate-fields
  "A decision whose id cannot be read must not be rendered as '(unnamed)' --
that reads as a property of the decision rather than a failure to look."
  (with-broken-telos (telos::decision-id)
    (let ((text (cl-mcp-server.telos-tools:format-feature-decisions
                 (cl-mcp-server.telos-tools:introspect-feature-decisions
                  "sample-widget-feature")
                 "sample-widget-feature")))
      (is (null (search "(unnamed)" text)))
      (is (search "Telos failed" text)))))

(test broken-decision-chose-does-not-silently-drop-the-field
  "An unreadable :chose must not simply vanish from the rendered decision."
  (with-broken-telos (telos::decision-chose)
    (let ((text (cl-mcp-server.telos-tools:format-feature-decisions
                 (cl-mcp-server.telos-tools:introspect-feature-decisions
                  "sample-widget-feature")
                 "sample-widget-feature")))
      (is (search "Telos failed" text)))))

(test broken-class-intent-does-not-deny-an-intentful-class
  "symbol-has-telos-intent-p must not answer 'no' when it merely failed to ask."
  (with-broken-telos (telos::class-intent)
    (let ((text (cl-mcp-server.telos-tools:format-get-intent
                 (cl-mcp-server.telos-tools:introspect-get-intent
                  "widget-member-class" nil))))
      (is (null (search "carries no telos intent" text)))
      (is (search "Telos failed" text)))))

(test broken-feature-intent-does-not-blank-every-purpose
  "The inner feature-intent call in list-features must be checked too."
  (with-broken-telos (telos::feature-intent)
    (let ((text (cl-mcp-server.telos-tools:format-list-features
                 (cl-mcp-server.telos-tools:introspect-list-features nil))))
      (is (null (search "Features (" text)))
      (is (search "Telos failed" text)))))

;;; ==========================================================================
;;; Tier 2: tool handlers must never signal (RULE-001)
;;; ==========================================================================

(test non-string-package-argument-does-not-signal
  "The package argument needs the same coercion the name argument gets."
  (let ((server (make-test-server)))
    (dolist (bad (list 42 3.5 (list "a" "b")))
      (finishes (call-test-tool server "telos-get-intent"
                                (list (cons "name" "widget-member-function")
                                      (cons "package" bad))))
      (finishes (call-test-tool server "telos-intent-chain"
                                (list (cons "name" "widget-member-function")
                                      (cons "package" bad)))))))

(test symbol-without-intent-is-not-claimed-known-to-telos
  "CL:CAR exists, but telos has never heard of it. Say that accurately."
  (let ((text (cl-mcp-server.telos-tools:format-get-intent
               (cl-mcp-server.telos-tools:introspect-get-intent "car" "cl"))))
    (is (null (search "known to telos" text)))
    (is (search "no telos intent" text))))

(test ambiguous-symbol-is-not-called-a-feature
  "The ambiguity message takes its noun from the query, not a hardcoded word."
  (let ((text (cl-mcp-server.telos-tools:format-get-intent
               '(:status :ambiguous :name "x" :candidates ("A::X" "B::X")))))
    (is (null (search "features share it" text)))
    (is (search "symbols share it" text))))

(test non-string-feature-argument-does-not-signal
  "The MCP schema says string, but nothing enforces it; handlers must not raise."
  (let ((server (make-test-server)))
    (finishes (call-test-tool server "telos-feature-decisions"
                              (list (cons "feature" 5))))
    (finishes (call-test-tool server "telos-feature-intent"
                              (list (cons "feature" 5))))
    (finishes (call-test-tool server "telos-feature-members"
                              (list (cons "feature" 5))))
    (finishes (call-test-tool server "telos-get-intent"
                              (list (cons "name" 5))))
    (finishes (call-test-tool server "telos-intent-chain"
                              (list (cons "name" 5))))))

(test suggestions-are-package-qualified-and-deduplicated
  "A suggestion is only actionable if it disambiguates."
  (let ((suggestions (cl-mcp-server.telos-tools::suggest-names
                      "duplicated" (telos:list-features nil))))
    (is (= 2 (length suggestions)))
    (is (= 2 (length (remove-duplicates suggestions :test #'string=))))
    (is (every (lambda (s) (search "::" s)) suggestions))))

(test very-short-names-suggest-nothing
  "A one-character needle matches every candidate, which is noise, not help."
  (is (null (cl-mcp-server.telos-tools::suggest-names
             "" (telos:list-features nil))))
  (is (null (cl-mcp-server.telos-tools::suggest-names
             "a" (telos:list-features nil)))))

;;; ==========================================================================
;;; Tier 2: through the actual MCP tool handlers
;;; ==========================================================================

(test tool-telos-feature-decisions-accepts-bare-name
  "The registered MCP tool, not just the helper, resolves a bare name."
  (let* ((server (make-test-server))
         (text (call-test-tool server "telos-feature-decisions"
                               '(("feature" . "sample-widget-feature")))))
    (is (search "OWN-PACKAGE" (string-upcase text)))
    (is (not (mentions-not-loaded-p text)))))

(test tool-telos-feature-intent-accepts-bare-name
  "Likewise for telos-feature-intent."
  (let* ((server (make-test-server))
         (text (call-test-tool server "telos-feature-intent"
                               '(("feature" . "sample-widget-feature")))))
    (is (search "Purpose:" text))
    (is (not (mentions-not-loaded-p text)))))

(test tool-telos-feature-decisions-missing-feature-message
  "The tool's missing-feature message does not send agents chasing load order."
  (let* ((server (make-test-server))
         (text (call-test-tool server "telos-feature-decisions"
                               '(("feature" . "definitely-not-a-feature")))))
    (is (not (mentions-not-loaded-p text)))))

;;; src/telos-tools.lisp
;;; ABOUTME: Telos intent introspection tools for MCP
;;;
;;; Provides tools for querying code intent when telos is loaded.
;;; All functions gracefully handle the case where telos is not available.
;;;
;;; NAME RESOLUTION
;;;
;;; Telos registries are EQ hash tables keyed by symbols interned in each
;;; feature's OWN defining package (GHOST.ARENA::ARENA-SQUARE-FEATURE, not
;;; :ARENA-SQUARE-FEATURE and not TELOS::ARENA-SQUARE-FEATURE). Interning a
;;; fresh symbol from the caller's string therefore produces a key that is
;;; never EQ to the registry's, and every lookup misses.
;;;
;;; So we never intern. We enumerate the registry's own keys and match by
;;; SYMBOL-NAME. See RESOLVE-FEATURE-NAME.
;;;
;;; RESULT CONTRACT
;;;
;;; Every INTROSPECT- function returns a plist carrying a :STATUS, so the
;;; formatters can tell apart four situations a single NIL used to conflate:
;;;
;;;   (:status :unavailable)                       telos is not loaded
;;;   (:status :error      :detail ...)            telos is loaded and broke
;;;   (:status :not-found  :name ... :feature-count N :suggestions (...))
;;;   (:status :ambiguous  :name ... :candidates (...))
;;;   (:status :ok         ...payload...)          payload may legitimately be empty
;;;
;;; :ERROR earns its place: if a telos call that signals is reported as an empty
;;; result, the tool ends up asserting things like "0 features are registered" --
;;; a fabricated fact, and the same misleading message in new clothes.

(in-package #:cl-mcp-server.telos-tools)

;;; ==========================================================================
;;; Telos Availability Check
;;; ==========================================================================

(defun telos-available-p ()
  "Return T if telos is loaded and available."
  (and (find-package :telos) t))

(defun telos-symbol (name)
  "Return telos's symbol NAME, or NIL if telos is not loaded or lacks it."
  (let ((pkg (find-package :telos)))
    (when pkg
      (find-symbol (string name) pkg))))

(defun telos-call (name &rest args)
  "Call telos's function NAME with ARGS.

Returns (values result status). STATUS is :OK, :MISSING when the loaded telos
has no such function, or the CONDITION that was signalled.

Callers that report a fact to the agent MUST inspect STATUS. Collapsing a
signalled error into an empty result is how a broken telos comes to state
\"0 features are registered\" -- a confident, fabricated answer, and the very
class of misleading message this file exists to eliminate."
  (let ((sym (telos-symbol name)))
    (if (not (and sym (fboundp sym)))
        (values nil :missing)
        (handler-case (values (apply sym args) :ok)
          (error (condition) (values nil condition))))))

(defun telos-failure (status context)
  "Build an :error result plist from a non-:OK TELOS-CALL STATUS, else NIL.
CONTEXT names the telos operation, so the message points at the real fault."
  (case status
    (:ok nil)
    (:missing
     (list :status :error
           :detail (format nil "The loaded telos provides no ~A. This server ~
expects a newer telos, or telos is only partly loaded." context)))
    (t
     (list :status :error
           :detail (format nil "Telos signalled an error inside ~A: ~A"
                           context status)))))

(defun telos-intent-entry (symbol)
  "Return (values intent kind status) for SYMBOL via telos's own classifier.
Kept separate from TELOS-CALL because GET-INTENT-ENTRY is the one telos
function whose second value we need."
  (let ((fn (telos-symbol :get-intent-entry)))
    (if (not (and fn (fboundp fn)))
        (values nil nil :missing)
        (handler-case
            (multiple-value-bind (intent kind) (funcall fn symbol)
              (values intent kind :ok))
          (error (condition) (values nil nil condition))))))

;;; ==========================================================================
;;; Name Resolution
;;; ==========================================================================

(defun split-package-qualifier (string)
  "Split STRING at a package marker.
Returns (values package-name symbol-name) for \"pkg::sym\" or \"pkg:sym\",
or (values NIL string) when STRING carries no qualifier.

A leading colon (\":arena-square-feature\") is not a qualifier -- it is the
keyword spelling an agent reaches for -- so it is stripped and treated as bare."
  (let ((colon (position #\: string)))
    (cond
      ((null colon) (values nil string))
      ((zerop colon) (values nil (string-left-trim ":" string)))
      (t (values (subseq string 0 colon)
                 (string-left-trim ":" (subseq string colon)))))))

(defun find-package-forgivingly (name)
  "Find package NAME, trying the string as given and then upcased."
  (or (find-package name)
      (find-package (string-upcase name))))

(defun resolve-feature-name (name candidates)
  "Resolve NAME to the matching symbol in CANDIDATES.

NAME may be a symbol, a bare string (\"arena-square-feature\") or a
package-qualified string (\"ghost.arena::arena-square-feature\"). Matching is
case-insensitive on SYMBOL-NAME; no symbol is ever interned, because an
interned symbol would not be EQ to the registry's own key.

Returns (values key extras). KEY is the resolved candidate or NIL. EXTRAS holds
any additional candidates with the same SYMBOL-NAME, so callers can report an
ambiguity instead of silently picking one."
  (flet ((by-name (string)
           (let ((hits (remove-if-not
                        (lambda (candidate)
                          (string-equal (symbol-name candidate) string))
                        candidates)))
             (values (first hits) (rest hits)))))
    (cond
      ;; Already a registry key: use it verbatim.
      ((and (symbolp name) (member name candidates :test #'eq))
       (values name nil))
      ;; Some other symbol: fall back to matching on its name.
      ((symbolp name)
       (by-name (symbol-name name)))
      ((not (stringp name))
       (values nil nil))
      (t
       (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) name)))
         (multiple-value-bind (pkg-name sym-name)
             (split-package-qualifier trimmed)
           (if pkg-name
               ;; Qualified: resolve through the named package. An explicit
               ;; package is a promise, so we do not fall back to name matching.
               (let ((pkg (find-package-forgivingly pkg-name)))
                 (when pkg
                   (let ((sym (or (find-symbol sym-name pkg)
                                  (find-symbol (string-upcase sym-name) pkg))))
                     (when (and sym (member sym candidates :test #'eq))
                       (values sym nil)))))
               ;; Bare: SYM-NAME, not TRIMMED -- a leading colon has been
               ;; stripped by SPLIT-PACKAGE-QUALIFIER and must stay stripped.
               (by-name sym-name))))))))

(defun name-designator (name)
  "Coerce NAME to a string or symbol.
The MCP schema says these arguments are strings, but nothing enforces it, and a
tool handler must never signal (RULE-001)."
  (if (or (stringp name) (symbolp name)) name (princ-to-string name)))

(defun suggest-names (name candidates &key (limit 5))
  "Return up to LIMIT candidate names that plausibly match NAME.
Substring containment in either direction: cheap, and it catches the two ways
an agent misremembers a name (too short, or too long). Names are returned
package-qualified, because a suggestion is only actionable if it is unambiguous.
Needles under two characters match everything, so they suggest nothing."
  (let ((needle (string-downcase
                 (string-trim '(#\Space #\Tab) (string (name-designator name))))))
    (if (< (length needle) 2)
        '()
        (let ((hits (remove-duplicates
                     (loop for candidate in candidates
                           for candidate-name = (string-downcase (symbol-name candidate))
                           when (or (search needle candidate-name)
                                    (search candidate-name needle))
                             collect (qualified-name candidate))
                     :test #'string= :from-end t)))
          (subseq hits 0 (min limit (length hits)))))))

(defun qualified-name (symbol)
  "Render SYMBOL with its package, the spelling that disambiguates it."
  (let ((pkg (symbol-package symbol)))
    (if pkg
        (format nil "~A::~A" (package-name pkg) (symbol-name symbol))
        (format nil "#:~A" (symbol-name symbol)))))

(defun all-feature-names ()
  "Return (values feature-symbols failure).
FAILURE is an :error plist when telos itself failed. It must be propagated, not
discarded: this list is the sole source of the \"N features are registered\"
count, so a swallowed failure here becomes a fabricated fact in the message."
  (multiple-value-bind (features status) (telos-call :list-features nil)
    (values features (telos-failure status "list-features"))))

(defun resolve-feature (name)
  "Resolve feature NAME against telos's registry.
Returns a plist: (:status :unavailable), (:status :error ...),
(:status :not-found ...), (:status :ambiguous ...), or (:status :ok :feature SYM)."
  (if (not (telos-available-p))
      (list :status :unavailable)
      (multiple-value-bind (candidates failure) (all-feature-names)
        (or failure
            (let ((name (name-designator name)))
              (multiple-value-bind (key extras) (resolve-feature-name name candidates)
                (cond
                  ((null key)
                   (list :status :not-found
                         :name name
                         :feature-count (length candidates)
                         :suggestions (suggest-names name candidates)))
                  (extras
                   (list :status :ambiguous
                         :name name
                         :candidates (mapcar #'qualified-name (cons key extras))))
                  (t
                   (list :status :ok :feature key)))))))))

;;; ==========================================================================
;;; Symbol Resolution (for get-intent / intent-chain)
;;; ==========================================================================

(defun telos-known-symbols ()
  "Collect every symbol telos has attached intent to, by scanning its registries.

Their key shapes differ: the entity registry is keyed by (kind symbol) lists and
the method registry by (generic-name . specializers), so we normalise here.

INCOMPLETE BY CONSTRUCTION: defclass/i stores a class's intent in a slot on the
INTENTFUL-CLASS metaobject and writes to no registry at all, so intentful
classes cannot appear here. INTENTFUL-CLASS-SYMBOLS covers them separately."
  (let ((symbols '()))
    (flet ((scan (registry-name key-symbol)
             (let ((var (telos-symbol registry-name)))
               (when (and var (boundp var))
                 (maphash (lambda (k v)
                            (declare (ignore v))
                            (let ((sym (funcall key-symbol k)))
                              (when (symbolp sym) (push sym symbols))))
                          (symbol-value var))))))
      (scan :*entity-intent-registry* (lambda (k) (and (consp k) (second k))))
      (scan :*class-intent-registry* #'identity)
      (scan :*method-intent-registry* (lambda (k) (and (consp k) (car k))))
      (scan :*feature-registry* #'identity))
    (remove-duplicates symbols :test #'eq)))

(defun intentful-class-symbols (name)
  "Find symbols named NAME that name a class carrying telos intent.

Needed because defclass/i leaves no registry entry to enumerate -- the intent
lives on the metaobject. So this is the one place we sweep the image, and it is
a last resort only: the cheap SYMBOL-NAME comparison runs first, and FIND-CLASS
only for the handful of symbols that match by name."
  (multiple-value-bind (pkg-name sym-name)
      (split-package-qualifier (string (name-designator name)))
    (let ((found '())
          (failure nil))
      (flet ((consider (sym)
               ;; PUSHNEW because DO-ALL-SYMBOLS may visit an inherited symbol
               ;; more than once. IGNORE-ERRORS on FIND-CLASS only: a broken
               ;; metaobject must not take down a name lookup, but a broken
               ;; CLASS-INTENT must be reported, not read as "no intent".
               (let ((class (ignore-errors (find-class sym nil))))
                 (when class
                   (multiple-value-bind (intent status) (telos-call :class-intent class)
                     (when (and (null failure) (not (eq status :ok)))
                       (setf failure (telos-failure status "class-intent")))
                     (when intent (pushnew sym found :test #'eq)))))))
        (if pkg-name
            ;; Qualified: the qualifier must still be honoured here, or a
            ;; package-qualified class name would fall through to not-found.
            (let ((pkg (find-package-forgivingly pkg-name)))
              (when pkg
                (let ((sym (or (find-symbol (string-upcase sym-name) pkg)
                               (find-symbol sym-name pkg))))
                  (when sym (consider sym)))))
            (do-all-symbols (sym)
              (when (string-equal (symbol-name sym) sym-name)
                (consider sym)))))
      (values found failure))))

(defun symbol-has-telos-intent-p (symbol)
  "Return (values has-intent failure); telos intent by any route, metaobject included.

FAILURE must be propagated. Collapsing a broken telos into \"no intent\" is
exactly how this predicate would come to deny a class that demonstrably carries
intent -- the case the caller's comment warns about."
  (let ((failure nil))
    (flet ((probe (name &rest args)
             (multiple-value-bind (value status) (apply #'telos-call name args)
               (when (and (null failure) (not (eq status :ok)))
                 (setf failure (telos-failure status (string-downcase (string name)))))
               value)))
      (let* ((entity (probe :get-intent symbol))
             (class (unless entity
                      (let ((c (ignore-errors (find-class symbol nil))))
                        (when c (probe :class-intent c)))))
             (feature (unless (or entity class) (probe :feature-intent symbol))))
        (values (or entity class feature) failure)))))

(defun resolve-intent-symbol (name package-name)
  "Resolve NAME to a symbol carrying telos intent.

When PACKAGE-NAME is given, look only there. Otherwise try the ambient *PACKAGE*
first, then match telos's own registry keys by name, then sweep for intentful
classes -- the same reason feature names cannot be interned applies here.

Returns a plist with :status :unavailable, :error, :not-found, :ambiguous, or
:ok with :symbol."
  (if (not (telos-available-p))
      (list :status :unavailable)
      (multiple-value-bind (features failure) (all-feature-names)
        (or failure
            (let ((name (name-designator name))
                  (candidates (telos-known-symbols))
                  (feature-count (length features)))
              (flet ((not-found (detail extra-candidates)
                       (list :status :not-found
                             :name name
                             :detail detail
                             :feature-count feature-count
                             :suggestions (suggest-names name extra-candidates))))
                (cond
                  (package-name
                   ;; PACKAGE-NAME needs the same coercion NAME gets:
                   ;; FIND-PACKAGE and STRING-UPCASE both signal on a number.
                   (let ((pkg (find-package-forgivingly
                               (name-designator package-name))))
                     (cond
                       ((null pkg)
                        (not-found (format nil "No package named ~A." package-name) '()))
                       (t
                        (let ((sym (or (find-symbol (string-upcase (string name)) pkg)
                                       (find-symbol (string name) pkg))))
                          (if sym
                              (list :status :ok :symbol sym)
                              (not-found (format nil "No symbol named ~A in ~A."
                                                 name (package-name pkg))
                                         candidates)))))))
                  (t
                   ;; The ambient package wins when it knows the name AND telos
                   ;; actually has intent for it. The intent check must ask telos
                   ;; rather than test registry membership: a defclass/i class is
                   ;; in no registry, and rejecting it here would report "carries
                   ;; no telos intent" about a class that demonstrably does.
                   (let* ((local (or (find-symbol (string-upcase (string name)) *package*)
                                     (find-symbol (string name) *package*)))
                          (local-intent nil)
                          (local-failure nil))
                     (when local
                       (multiple-value-setq (local-intent local-failure)
                         (symbol-has-telos-intent-p local)))
                     (cond
                       (local-failure local-failure)
                       ((and local local-intent) (list :status :ok :symbol local))
                       (t
                        (multiple-value-bind (key extras)
                            (resolve-feature-name name candidates)
                           (cond
                             (extras
                              (list :status :ambiguous
                                    :name name
                                    :candidates (mapcar #'qualified-name (cons key extras))))
                             (key (list :status :ok :symbol key))
                             (t
                              ;; Last resort: an intentful class, invisible to
                              ;; every registry.
                              (multiple-value-bind (classes class-failure)
                                  (intentful-class-symbols name)
                                (cond
                                  (class-failure class-failure)
                                  ((cdr classes)
                                   (list :status :ambiguous
                                         :name name
                                         :candidates (mapcar #'qualified-name classes)))
                                  (classes (list :status :ok :symbol (first classes)))
                                  (t
                                   (not-found
                                    (format nil "No symbol named ~A carries telos intent."
                                            name)
                                    candidates))))))))))))))))))

;;; ==========================================================================
;;; Introspection Functions
;;; ==========================================================================

(defun introspect-list-features (&optional filter)
  "List all defined features, optionally filtered by name substring.
Returns (:status :ok :features (plists...)) or a failure plist."
  (if (not (telos-available-p))
      (list :status :unavailable)
      (multiple-value-bind (features status) (telos-call :list-features filter)
        (or (telos-failure status "list-features")
            (let ((failure nil)
                  (entries '()))
              (dolist (feat features)
                ;; The inner FEATURE-INTENT call needs checking too. Swallowed,
                ;; it renders every feature with its purpose silently gone --
                ;; a reader concludes none of them records one.
                (multiple-value-bind (intent intent-status) (telos-call :feature-intent feat)
                  (cond
                    ((not (eq intent-status :ok))
                     (when (null failure)
                       (setf failure (telos-failure intent-status "feature-intent"))))
                    (t
                     (multiple-value-bind (plist plist-failure)
                         (if intent (intent-to-plist intent) (values nil nil))
                       (when (null failure) (setf failure plist-failure))
                       (push (list :name feat
                                   :purpose (getf plist :purpose)
                                   :belongs-to (getf plist :belongs-to))
                             entries))))))
              (or failure
                  (list :status :ok :features (nreverse entries))))))))

(defun introspect-feature-intent (feature-name)
  "Get full intent for a feature by name.
FEATURE-NAME may be a string (bare or package-qualified) or a symbol."
  (let ((resolved (resolve-feature feature-name)))
    (if (not (eq :ok (getf resolved :status)))
        resolved
        (let ((feature (getf resolved :feature)))
          (multiple-value-bind (intent status) (telos-call :feature-intent feature)
            (or (telos-failure status "feature-intent")
                (multiple-value-bind (plist failure)
                    (if intent (intent-to-plist intent) (values nil nil))
                  (or failure
                      ;; A registered key with no intent struct is rare, but it
                      ;; is a found-and-empty answer, not a lookup failure.
                      (list :status :ok :feature feature :intent plist)))))))))

(defun introspect-get-intent (symbol-name &optional package-name)
  "Get intent for a function, class, struct, or condition."
  (let ((resolved (resolve-intent-symbol symbol-name package-name)))
    (if (not (eq :ok (getf resolved :status)))
        resolved
        (let ((sym (getf resolved :symbol)))
          ;; Ask telos to classify. GET-INTENT-ENTRY covers functions, structs,
          ;; conditions and classes, and reports which -- so a defclass/i class
          ;; is no longer mislabelled :FUNCTION. It signals on a genuinely
          ;; ambiguous name, which TELOS-INTENT-ENTRY turns into :error rather
          ;; than a silent wrong answer.
          (multiple-value-bind (intent kind status) (telos-intent-entry sym)
            (or (telos-failure status "get-intent-entry")
                (if (null intent)
                    (list :status :ok :kind :unknown :name sym :intent nil)
                    (multiple-value-bind (plist failure) (intent-to-plist intent)
                      (or failure
                          (list :status :ok :kind kind :name sym :intent plist))))))))))

(defun introspect-intent-chain (symbol-name &optional package-name)
  "Trace intent from a symbol up to its root feature.
Returns the chain from most specific to root."
  (let ((resolved (resolve-intent-symbol symbol-name package-name)))
    (if (not (eq :ok (getf resolved :status)))
        resolved
        (let ((sym (getf resolved :symbol)))
          (multiple-value-bind (chain status) (telos-call :intent-chain sym)
            (or (telos-failure status "intent-chain")
                (list :status :ok :name sym :chain chain)))))))

(defun introspect-feature-members (feature-name)
  "List all functions, classes and sub-features belonging to a feature."
  (let ((resolved (resolve-feature feature-name)))
    (if (not (eq :ok (getf resolved :status)))
        resolved
        (let ((feature (getf resolved :feature)))
          (multiple-value-bind (members status) (telos-call :feature-members feature)
            (or (telos-failure status "feature-members")
                (list :status :ok :feature feature :members members)))))))

(defun introspect-feature-decisions (feature-name)
  "Get decisions for a feature by name.
An empty decision list is an :ok result, not a failure."
  (let ((resolved (resolve-feature feature-name)))
    (if (not (eq :ok (getf resolved :status)))
        resolved
        (let ((feature (getf resolved :feature)))
          (multiple-value-bind (decisions status)
              (telos-call :feature-decisions feature)
            (or (telos-failure status "feature-decisions")
                (multiple-value-bind (plists failure) (decisions-to-plists decisions)
                  (or failure
                      (list :status :ok :feature feature :decisions plists)))))))))

(defun introspect-list-decisions ()
  "Get all decisions across all features.
Returns (:status :ok :decisions ALIST) where ALIST maps a qualified feature
name string to its decision plists."
  (if (not (telos-available-p))
      (list :status :unavailable)
      (multiple-value-bind (all-decisions status) (telos-call :list-decisions)
        (or (telos-failure status "list-decisions")
            (let ((failure nil)
                  (entries '()))
              (dolist (entry all-decisions)
                (multiple-value-bind (plists this-failure)
                    (decisions-to-plists (cdr entry))
                  (when (null failure) (setf failure this-failure))
                  (push (cons (qualified-name (car entry)) plists) entries)))
              (or failure
                  (list :status :ok :decisions (nreverse entries))))))))

;;; ==========================================================================
;;; Helper Functions
;;; ==========================================================================

;;; Both converters return (values plist failure). A field that could not be
;;; read must never be rendered as an absent field: "(unnamed)" reads as a
;;; property of the decision, not as a failure to look at it.

(defun intent-slot (intent name)
  "Return (values value status) for INTENT's slot NAME."
  (let ((slot (telos-symbol name)))
    (if (null slot)
        (values nil :missing)
        (handler-case (values (slot-value intent slot) :ok)
          (error (condition) (values nil condition))))))

(defun intent-to-plist (intent)
  "Convert a telos:intent struct to a plist. Returns (values plist failure)."
  (let ((failure nil))
    (flet ((field (name)
             (multiple-value-bind (value status) (intent-slot intent name)
               (when (and (null failure) (not (eq status :ok)))
                 (setf failure (telos-failure status (format nil "intent slot ~A" name))))
               value)))
      (values (list :purpose (field :purpose)
                    :role (field :role)
                    :belongs-to (field :belongs-to)
                    :goals (field :goals)
                    :constraints (field :constraints)
                    :assumptions (field :assumptions)
                    :failure-modes (field :failure-modes))
              failure))))

(defun decision-to-plist (decision)
  "Convert a telos:decision struct to a plist. Returns (values plist failure)."
  (let ((failure nil))
    (flet ((field (accessor)
             (multiple-value-bind (value status) (telos-call accessor decision)
               (when (and (null failure) (not (eq status :ok)))
                 (setf failure (telos-failure status (string-downcase (string accessor)))))
               value)))
      (values (list :id (field :decision-id)
                    :chose (field :decision-chose)
                    :over (field :decision-over)
                    :because (field :decision-because)
                    :date (field :decision-date)
                    :decided-by (field :decision-decided-by))
              failure))))

(defun decisions-to-plists (decisions)
  "Convert DECISIONS, returning (values plists failure)."
  (let ((failure nil)
        (plists '()))
    (dolist (decision decisions (values (nreverse plists) failure))
      (multiple-value-bind (plist this-failure) (decision-to-plist decision)
        (when (null failure) (setf failure this-failure))
        (push plist plists)))))

;;; ==========================================================================
;;; Shared Failure Formatting
;;; ==========================================================================
;;;
;;; These three messages are deliberately distinct. Collapsing them into
;;; "(or telos not loaded)" costs real debugging time: a registered feature
;;; that fails to resolve looks exactly like a system that never loaded, and
;;; sends the reader off chasing stale FASLs.

(defparameter +telos-unavailable-message+
  "Telos is not loaded in this image. Load it with (ql:quickload :telos), then
reload the system that defines your features so its deffeature forms run."
  "Said only when the TELOS package genuinely does not exist.")

(defun format-not-found (result what)
  "Format a :not-found RESULT for WHAT (\"feature\", \"symbol\")."
  (let ((count (or (getf result :feature-count) 0)))
    (with-output-to-string (s)
      (format s "No ~A named ~A." what (getf result :name))
      (when (getf result :detail)
        (format s " ~A" (getf result :detail)))
      (format s "~%Telos is loaded and ~D feature~:P ~:[are~;is~] registered."
              count (= 1 count))
      (let ((suggestions (getf result :suggestions)))
        (when suggestions
          (format s "~%Closest matches: ~{~A~^, ~}" suggestions)))
      (format s "~%Use telos-list-features to see what is registered."))))

(defun format-error (result)
  "Format an :error RESULT -- telos itself failed.
Reported as its own outcome so that a broken telos is never dressed up as an
empty or missing result, which would send the reader hunting for the wrong bug."
  (format nil "Telos failed while answering this query. ~A~%~
This is a fault in telos or a stale FASL, not a missing feature -- the registry ~
count and contents reported by other telos tools may be wrong until it is fixed."
          (getf result :detail)))

(defun format-ambiguous (result what)
  "Format an :ambiguous RESULT for WHAT (\"feature\", \"symbol\")."
  (format nil "The name ~A is ambiguous: ~D ~A~P share it.~%~{  ~A~%~}~
Qualify it with a package, e.g. \"~A\"."
          (getf result :name)
          (length (getf result :candidates))
          what
          (length (getf result :candidates))
          (getf result :candidates)
          (first (getf result :candidates))))

(defun format-failure (result what)
  "Format any non-:ok RESULT, or NIL if RESULT is :ok."
  (case (getf result :status)
    (:unavailable +telos-unavailable-message+)
    (:error (format-error result))
    (:not-found (format-not-found result what))
    (:ambiguous (format-ambiguous result what))
    (t nil)))

;;; ==========================================================================
;;; Formatting Functions
;;; ==========================================================================

(defun format-list-features (result)
  "Format feature list for output."
  (or (format-failure result "feature")
      (let ((features (getf result :features)))
        (if (null features)
            "Telos is loaded, but no features are registered. Load a system whose
source contains deffeature forms."
            (with-output-to-string (s)
              (format s "Features (~D):~%~%" (length features))
              (dolist (f features)
                (format s "~A~%" (getf f :name))
                (when (getf f :purpose)
                  (format s "  Purpose: ~A~%" (getf f :purpose)))
                (when (getf f :belongs-to)
                  (format s "  Parent: ~A~%" (getf f :belongs-to)))
                (format s "~%")))))))

(defun format-feature-intent (result feature-name)
  "Format a feature's intent for output."
  (or (format-failure result "feature")
      (let ((intent (getf result :intent)))
        (if (null intent)
            (format nil "Feature ~A is registered but has no intent recorded."
                    (or (getf result :feature) feature-name))
            (with-output-to-string (s)
              (format s "Feature: ~A~%~%" (or (getf result :feature) feature-name))
              (format-intent-fields s intent))))))

(defun format-get-intent (result)
  "Format intent query result."
  (or (format-failure result "symbol")
      (let ((intent (getf result :intent)))
        (if (null intent)
            ;; Not "known to telos" -- reaching here via an explicit package
            ;; argument means only that the symbol exists in that package.
            (format nil "~A has no telos intent recorded."
                    (getf result :name))
            (with-output-to-string (s)
              (format s "~A (~A)~%~%" (getf result :name) (getf result :kind))
              (format-intent-fields s intent))))))

(defun format-intent-chain (result)
  "Format intent chain for output."
  (or (format-failure result "symbol")
      (let ((chain (getf result :chain)))
        (if (null chain)
            (format nil "~A has no intent chain: it carries no intent and
belongs to no feature." (getf result :name))
            (with-output-to-string (s)
              (format s "Intent Chain (~D levels):~%~%" (length chain))
              (loop for entry in chain
                    for i from 1
                    do (format s "~D. [~A] ~A~%" i (getf entry :type) (getf entry :name))
                       (when (getf entry :role)
                         (format s "   Role: ~A~%" (getf entry :role)))
                       (when (getf entry :purpose)
                         (format s "   Purpose: ~A~%" (getf entry :purpose)))
                       (when (getf entry :failure-modes)
                         (format s "   Failure modes: ~{~A~^, ~}~%"
                                 (mapcar #'first (getf entry :failure-modes))))
                       (format s "~%")))))))

(defun format-feature-members (result feature-name)
  "Format feature members for output."
  (or (format-failure result "feature")
      (let* ((members (getf result :members))
             (name (or (getf result :feature) feature-name))
             (functions (getf members :functions))
             (classes (getf members :classes))
             (structs (getf members :structs))
             (conditions (getf members :conditions))
             (methods (getf members :methods))
             (features (getf members :features)))
        (if (not (or functions classes structs conditions methods features))
            (format nil "Feature ~A has no members. Nothing declares itself part
of it via (:feature ~A)." name name)
            (with-output-to-string (s)
              (format s "Members of ~A:~%~%" name)
              (flet ((section (label items)
                       (when items
                         (format s "~A (~D):~%" label (length items))
                         (dolist (item items)
                           (format s "  ~A~%" item))
                         (format s "~%"))))
                (section "Functions" functions)
                (section "Classes" classes)
                (section "Structs" structs)
                (section "Conditions" conditions)
                (section "Methods" methods)
                (section "Sub-features" features)))))))

(defun format-feature-decisions (result feature-name)
  "Format a feature's decisions for output."
  (or (format-failure result "feature")
      (let ((decisions (getf result :decisions))
            (name (or (getf result :feature) feature-name)))
        (if (null decisions)
            (format nil "Feature ~A is registered but records no decisions.
Add them with the :decisions clause of deffeature." name)
            (with-output-to-string (s)
              (format s "Decisions for ~A (~D):~%~%" name (length decisions))
              (loop for dec in decisions
                    for i from 1
                    do (format s "~D. ~A~%" i (or (getf dec :id) "(unnamed)"))
                       (when (getf dec :chose)
                         (format s "   Chose: ~A~%" (getf dec :chose)))
                       (when (getf dec :over)
                         (format s "   Over: ~{~A~^, ~}~%" (getf dec :over)))
                       (when (getf dec :because)
                         (format s "   Because: ~A~%" (getf dec :because)))
                       (when (getf dec :decided-by)
                         (format s "   Decided by: ~A~%" (getf dec :decided-by)))
                       (when (getf dec :date)
                         (format s "   Date: ~A~%" (getf dec :date)))
                       (format s "~%")))))))

(defun format-list-decisions (result)
  "Format all decisions across features for output."
  (or (format-failure result "feature")
      (let ((all-decisions (getf result :decisions)))
        (if (null all-decisions)
            "Telos is loaded, but no feature records any decisions."
            (with-output-to-string (s)
              (let ((total (loop for (nil . decs) in all-decisions sum (length decs))))
                (format s "Decisions across ~D feature~:P (~D total):~%~%"
                        (length all-decisions) total))
              (loop for (feature-name . decisions) in all-decisions
                    do (format s "~A (~D):~%" feature-name (length decisions))
                       (dolist (dec decisions)
                         (format s "  ~A: chose ~A"
                                 (or (getf dec :id) "(unnamed)")
                                 (or (getf dec :chose) "?"))
                         (when (getf dec :over)
                           (format s " over ~{~A~^, ~}" (getf dec :over)))
                         (format s "~%"))
                       (format s "~%")))))))

(defun format-intent-fields (stream plist)
  "Format intent fields to a stream."
  (when (getf plist :purpose)
    (format stream "Purpose: ~A~%~%" (getf plist :purpose)))
  (when (getf plist :role)
    (format stream "Role: ~A~%~%" (getf plist :role)))
  (when (getf plist :belongs-to)
    (format stream "Belongs to: ~A~%~%" (getf plist :belongs-to)))
  (flet ((section (label items)
           (when items
             (format stream "~A:~%" label)
             (dolist (item items)
               (format stream "  ~A: ~A~%" (first item) (second item)))
             (format stream "~%"))))
    (section "Goals" (getf plist :goals))
    (section "Constraints" (getf plist :constraints))
    (section "Assumptions" (getf plist :assumptions))
    (section "Failure Modes" (getf plist :failure-modes))))

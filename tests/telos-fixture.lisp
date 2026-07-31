;;; tests/telos-fixture.lisp
;;; ABOUTME: Telos features defined in throwaway packages, reproducing the
;;; real-world registry shape.
;;;
;;; Telos registries are EQ hash tables keyed by symbols interned in each
;;; feature's OWN defining package. A wrapper that interns a fresh symbol in
;;; :keyword, *package*, or :telos can never produce an EQ key. These fixtures
;;; live in packages the wrapper cannot guess, so any regression to
;;; intern-based resolution fails the suite.

(defpackage #:cl-mcp-server-tests.widget
  (:use #:cl))

(defpackage #:cl-mcp-server-tests.gadget
  (:use #:cl))

(in-package #:cl-mcp-server-tests.widget)

(telos:deffeature sample-widget-feature
  :purpose "Exercise telos name resolution from a foreign package."
  :goals ((:resolvable "A bare name must resolve to this feature."))
  :constraints ((:no-interning "Resolution must not intern fresh symbols."))
  :assumptions ((:eq-registry "The registry is keyed by EQ on symbols."))
  :failure-modes ((:wrong-package "Interning in :keyword misses this key."))
  :decisions ((:id :own-package
               :chose "Define the feature in its own package"
               :over ("Define it in CL-USER")
               :because "That is what real projects do, and it is what broke the wrapper."
               :date "2026-07-28"
               :decided-by "quasi")
              (:id :two-decisions
               :chose "Record two decisions"
               :over ("Record one")
               :because "Counting proves the whole list survives resolution.")))

;;; A feature that deliberately records NO decisions. Distinguishing this from
;;; a missing feature is an explicit acceptance criterion.
(telos:deffeature silent-widget-feature
  :purpose "A registered feature with an empty decision list.")

(telos:defun/i widget-member-function ()
  (:feature sample-widget-feature)
  (:purpose "Give SAMPLE-WIDGET-FEATURE a member to list.")
  :ok)

;;; defclass/i stores intent on the INTENTFUL-CLASS metaobject and writes to NO
;;; registry, so it cannot be found by enumerating registries the way functions
;;; can. Without this fixture the enumeration path looks correct and reports
;;; "carries no telos intent" about a class that demonstrably does.
(telos:defclass/i widget-member-class ()
  ((id :initform nil))
  (:feature sample-widget-feature)
  (:purpose "Give SAMPLE-WIDGET-FEATURE a class member defined via defclass/i."))

;;; Ambiguity fixture: the same symbol-name registered from two packages.
(telos:deffeature duplicated-feature
  :purpose "Ambiguity fixture, widget side.")

(in-package #:cl-mcp-server-tests.gadget)

(telos:deffeature duplicated-feature
  :purpose "Ambiguity fixture, gadget side.")

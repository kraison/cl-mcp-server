;;; tests/remote-tests.lisp
;;; ABOUTME: Tests for SWANK protocol parsing and remote safety tiering

(in-package #:cl-mcp-server-tests)

(def-suite remote-tests
  :description "Tests for remote SWANK access and its safety model"
  :in cl-mcp-server-tests)

(in-suite remote-tests)

;;; These run without a network. The safety-critical logic -- deciding what
;;; a form would do before sending it -- is pure, and that is deliberate:
;;; a classifier that needed a live service to test would not get tested.

;;; ==========================================================================
;;; Wire protocol parsing
;;; ==========================================================================

(test lisp-string-escapes-quotes
  "Forms containing strings survive the wire intact"
  (is (string= "\"(car \\\"x\\\")\""
               (cl-mcp-server.swank-protocol::%lisp-string "(car \"x\")"))))

(test lisp-string-escapes-backslash
  "A backslash is escaped, not dropped"
  (is (string= "\"a\\\\b\""
               (cl-mcp-server.swank-protocol::%lisp-string "a\\b"))))

(test first-string-extracts-contents
  (is (string= "hello"
               (cl-mcp-server.swank-protocol::%first-string
                "(:write-string \"hello\" 1)"))))

(test first-string-resolves-escapes
  "An escaped quote inside the payload is not a terminator"
  (is (string= "say \"hi\""
               (cl-mcp-server.swank-protocol::%first-string
                "(:x \"say \\\"hi\\\"\")"))))

(test nth-token-picks-fields
  "Used on the :ping path; a mistake here wedges a connection"
  (let ((raw "(:ping 5 17)"))
    (is (string= "5" (cl-mcp-server.swank-protocol::%nth-token raw 1)))
    (is (string= "17" (cl-mcp-server.swank-protocol::%nth-token raw 2)))))

(test nth-token-out-of-range
  (is (null (cl-mcp-server.swank-protocol::%nth-token "(:ping 5 17)" 9))))

(test nth-token-handles-symbols
  (is (string= "tag-9"
               (cl-mcp-server.swank-protocol::%nth-token "(:ping t tag-9)" 2))))

(test trailing-integer-finds-request-id
  (is (= 42 (cl-mcp-server.swank-protocol::%trailing-integer
             "(:return (:ok nil) 42)"))))

(test classify-return-ok
  (multiple-value-bind (kind payload id)
      (cl-mcp-server.swank-protocol::%classify "(:return (:ok (\"\" \"3\")) 7)")
    (declare (ignore payload))
    (is (eq :return kind))
    (is (= 7 id))))

(test classify-ping
  (is (eq :ping (cl-mcp-server.swank-protocol::%classify "(:ping 1 2)"))))

(test classify-write-string
  (is (eq :write-string
          (cl-mcp-server.swank-protocol::%classify "(:write-string \"x\")"))))

(test split-eval-result-separates-output-from-value
  "eval-and-grab-output answers (output value); both halves must survive"
  (multiple-value-bind (value output)
      (cl-mcp-server.swank-protocol::%split-eval-result
       "((\"printed\" \"42\"))")
    (is (string= "42" value))
    (is (string= "printed" output))))

;;; ==========================================================================
;;; Classification -- the safety-critical part
;;; ==========================================================================

(defun tier-of (form)
  (cl-mcp-server.remote::classify-form form))

(defun read-target (name)
  "Register NAME in :read mode. The port is deliberately closed: nothing
here should ever reach the network, so a connection attempt errors rather
than quietly succeeding."
  (cl-mcp-server.remote:register-target name "127.0.0.1" 1 :mode :read)
  name)

(test classify-plain-read
  (is (eq :read (tier-of "(+ 1 2)")))
  (is (eq :read (tier-of "(hash-table-count *cache*)"))))

(test classify-setf-is-mutate
  (is (eq :state (tier-of "(setf *x* 1)"))))

(test classify-defun-is-mutate
  (is (eq :redefine (tier-of "(defun foo () 1)"))))

(test classify-load-is-mutate
  (is (eq :state (tier-of "(load \"/tmp/x.lisp\")"))))

(test classify-quit-is-lifecycle
  (is (eq :lifecycle (tier-of "(sb-ext:quit)")))
  (is (eq :lifecycle (tier-of "(quit)"))))

(test classify-thread-kill-is-lifecycle
  (is (eq :lifecycle (tier-of "(sb-thread:terminate-thread th)"))))

(test classify-delete-package-is-lifecycle
  (is (eq :lifecycle (tier-of "(delete-package :foo)"))))

(test classify-opaque-operators-are-lifecycle
  "eval and friends hide their effect, so they are refused rather than
allowed -- refusing a safe form is cheaper than allowing a destructive one"
  (is (eq :lifecycle (tier-of "(eval form)")))
  (is (eq :lifecycle (tier-of "(funcall f 1)")))
  (is (eq :lifecycle (tier-of "(apply f args)"))))

(test classify-read-eval-is-lifecycle
  "#. executes at read time, before classification could help"
  (is (eq :lifecycle (tier-of "(list #.(launch))"))))

(test classify-does-not-match-substrings
  "SETTLE-ACCOUNT must not be mistaken for SETF, or the classifier would
refuse ordinary application code and be turned off"
  (is (eq :read (tier-of "(settle-account 5)")))
  (is (eq :read (tier-of "(defungle-thing)")))
  (is (eq :read (tier-of "(my-loader)"))))

(test classify-reports-a-reason
  (multiple-value-bind (tier reason) (tier-of "(setf *x* 1)")
    (is (eq :state tier))
    (is (search "SETF" reason))))

;;; ==========================================================================
;;; Tier gating
;;; ==========================================================================

(defun make-test-target (mode)
  (cl-mcp-server.remote::make-target :name "t" :host "h" :port 1 :mode mode))

(test observe-mode-permits-only-observe
  (let ((tg (make-test-target :observe)))
    (is-true (cl-mcp-server.remote::tier-allowed-p tg :observe))
    (is-false (cl-mcp-server.remote::tier-allowed-p tg :read))
    (is-false (cl-mcp-server.remote::tier-allowed-p tg :state))))

(test read-mode-permits-read-not-mutate
  (let ((tg (make-test-target :read)))
    (is-true (cl-mcp-server.remote::tier-allowed-p tg :read))
    (is-false (cl-mcp-server.remote::tier-allowed-p tg :state))))

(test lifecycle-refused-below-developer
  "Lifecycle is permitted in :developer -- restarting your own dev image is
ordinary work. Below developer it is always refused."
  (dolist (mode '(:observe :read))
    (is-false (cl-mcp-server.remote::tier-allowed-p
               (make-test-target mode) :lifecycle)
              "lifecycle must be refused in ~A mode" mode)))

;;; ==========================================================================
;;; Print limits
;;; ==========================================================================

(test print-limits-are-bound-in-the-remote-form
  "Limits must travel with the form: applying them locally is too late,
since a huge structure can stall the service before we see a byte"
  (let* ((tg (make-test-target :read))
         (wrapped (cl-mcp-server.remote::%wrap-with-print-limits
                   "(gethash k *big*)" tg)))
    (is (search "*print-length*" wrapped))
    (is (search "*print-level*" wrapped))
    (is (search "(gethash k *big*)" wrapped))))

;;; ==========================================================================
;;; Targets and refusal
;;; ==========================================================================

(test unknown-target-is-reported-not-signalled
  (let ((r (cl-mcp-server.remote:remote-eval "no-such-target-xyzzy" "(+ 1 2)")))
    (is-false (getf r :ok))
    (is (search "No target" (getf r :error)))))

(test refusal-does-not-connect
  "A refused form must be refused before any socket is opened -- the port
here is closed, so reaching the network would error rather than refuse"
  (read-target "test-refuse")
  (let ((r (cl-mcp-server.remote:remote-eval "test-refuse" "(sb-ext:quit)")))
    (is-false (getf r :ok))
    (is-true (getf r :refused))
    (is (eq :lifecycle (getf r :tier)))))

(test refusal-shows-the-form-for-a-human
  (read-target "test-refuse2")
  (let ((r (cl-mcp-server.remote:remote-eval "test-refuse2" "(setf *x* 1)")))
    (is (search "Run it yourself" (getf r :error)))
    (is (search "(setf *x* 1)" (getf r :error)))))

;;; ==========================================================================
;;; Ledger
;;; ==========================================================================

(test ledger-records-refusals
  "An attempted destructive call is as interesting as a successful one"
  (read-target "test-ledger")
  (cl-mcp-server.remote:remote-eval "test-ledger" "(sb-ext:quit)")
  (let ((entries (cl-mcp-server.remote:ledger-for "test-ledger")))
    (is-true entries)
    (is (eq :refused (cl-mcp-server.remote:entry-outcome (first entries))))
    (is (search "quit" (cl-mcp-server.remote:entry-form (first entries))))))

(test ledger-entries-carry-a-time
  (read-target "test-time")
  (cl-mcp-server.remote:remote-eval "test-time" "(setf *x* 1)")
  (let ((entry (first (cl-mcp-server.remote:ledger-for "test-time"))))
    (is (= 8 (length (cl-mcp-server.remote:entry-time-string entry))))))

(test ledger-filters-by-target
  (read-target "test-a")
  (read-target "test-b")
  (cl-mcp-server.remote:remote-eval "test-a" "(sb-ext:quit)")
  (let ((entries (cl-mcp-server.remote:ledger-for "test-b")))
    (is (every (lambda (e)
                 (string= "test-b" (cl-mcp-server.remote:entry-target e)))
               entries))))

;;; ==========================================================================
;;; Tool registration
;;; ==========================================================================

(test remote-tools-registered
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (dolist (name '("remote-connect" "remote-eval" "remote-targets"
                    "remote-ledger" "remote-disconnect"))
      (is (not (null (cl-mcp.tools:get-tool
                      (test-server-registry server) name)))
          "tool ~A should be registered" name))))

(test remote-eval-tool-refuses-lifecycle
  "End to end through the tool layer, not just the internals"
  (read-target "test-tool")
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (let ((text (call-test-tool server "remote-eval"
                                '(("target" . "test-tool")
                                  ("code" . "(sb-ext:quit)")))))
      (is (search "Refused" text)))))

;;; ==========================================================================
;;; Modes are roles, not rungs
;;;
;;; :prod-maintenance clears a cache but must never defun, so it is not a
;;; subset of :developer. A ladder cannot express that; the table can.
;;; ==========================================================================

(defun mode-target (mode)
  (cl-mcp-server.remote::make-target :name "m" :host "h" :port 1 :mode mode))

(test redefine-is-refused-in-read-mode
  (is-false (cl-mcp-server.remote::tier-allowed-p
             (mode-target :read) :redefine)))

(test state-is-refused-in-read-mode
  (is-false (cl-mcp-server.remote::tier-allowed-p
             (mode-target :read) :state)))

(test developer-allows-redefine-and-state
  (is-true (cl-mcp-server.remote::tier-allowed-p
            (mode-target :developer) :redefine))
  (is-true (cl-mcp-server.remote::tier-allowed-p
            (mode-target :developer) :state)))

(test developer-allows-lifecycle
  "The user's call: restarting your own dev image is ordinary work"
  (is-true (cl-mcp-server.remote::tier-allowed-p
            (mode-target :developer) :lifecycle)))

(test lifecycle-still-refused-below-developer
  (is-false (cl-mcp-server.remote::tier-allowed-p
             (mode-target :read) :lifecycle))
  (is-false (cl-mcp-server.remote::tier-allowed-p
             (mode-target :observe) :lifecycle)))

(test unknown-mode-permits-nothing
  "Default-deny: a typo in a mode name must not open a gate"
  (is-false (cl-mcp-server.remote::tier-allowed-p
             (mode-target :typo) :read)))

(test unknown-tier-permits-nothing
  (is-false (cl-mcp-server.remote::tier-allowed-p
             (mode-target :developer) :no-such-tier)))

;;; ==========================================================================
;;; :redefine vs :state
;;;
;;; Code can be redefined back; state often cannot. The ledger needs to say
;;; which one a session did.
;;; ==========================================================================

(test defun-classifies-as-redefine
  (is (eq :redefine (tier-of "(defun f (x) x)"))))

(test defmethod-classifies-as-redefine
  (is (eq :redefine (tier-of "(defmethod m ((x t)) x)"))))

(test setf-classifies-as-state
  (is (eq :state (tier-of "(setf *x* 1)"))))

(test clrhash-classifies-as-state
  (is (eq :state (tier-of "(clrhash *cache*)"))))

(test destructive-list-operators-classify-as-state
  "sort, delete, nconc and nreverse read as innocent and are not"
  (dolist (form '("(sort *rankings* #'>)" "(delete 3 *items*)"
                  "(nconc *a* *b*)" "(nreverse *log*)"))
    (is (eq :state (tier-of form)) "~A should be :state" form)))

(test defclass-classifies-as-state
  "Redefining a class obsoletes live instances and updates them lazily"
  (is (eq :state (tier-of "(defclass c () ())"))))

(test defstruct-classifies-as-state
  (is (eq :state (tier-of "(defstruct s a b)"))))

(test load-classifies-as-state
  "load can do anything; it is not recoverable by re-evaluating a defun"
  (is (eq :state (tier-of "(load \"/tmp/x.lisp\")"))))

(test reads-are-still-reads
  (is (eq :read (tier-of "(hash-table-count *cache*)"))))

;;; ==========================================================================
;;; Arming
;;; ==========================================================================

(defmacro with-armable ((&rest names) &body body)
  "Run BODY with NAMES as the allowlist."
  `(let ((cl-mcp-server.remote-config::*armable* (list ,@names)))
     ,@body))

(test arming-is-refused-when-not-allowlisted
  "The gate: a session must not be able to arm a target it chose"
  (with-armable ()
    (read-target "not-listed")
    (multiple-value-bind (target message)
        (cl-mcp-server.remote:arm-target "not-listed")
      (is (null target))
      (is (search "not armable" message)))))

(test arming-succeeds-when-allowlisted
  (with-armable ("armable-one")
    (read-target "armable-one")
    (is (not (null (cl-mcp-server.remote:arm-target "armable-one"))))
    (is (eq :developer
            (cl-mcp-server.remote::target-mode
             (cl-mcp-server.remote::find-target "armable-one"))))))

(test disarm-restores-the-pre-arm-mode
  "A target registered in :observe must not come back as :read -- that is
privilege escalation disguised as cleanup"
  (with-armable ("obs")
    (cl-mcp-server.remote:register-target "obs" "127.0.0.1" 1 :mode :observe)
    (cl-mcp-server.remote:arm-target "obs")
    (cl-mcp-server.remote:disarm-target "obs")
    (is (eq :observe
            (cl-mcp-server.remote::target-mode
             (cl-mcp-server.remote::find-target "obs"))))))

(test disarm-restores-read-for-a-read-target
  (with-armable ("rd")
    (read-target "rd")
    (cl-mcp-server.remote:arm-target "rd")
    (cl-mcp-server.remote:disarm-target "rd")
    (is (eq :read
            (cl-mcp-server.remote::target-mode
             (cl-mcp-server.remote::find-target "rd"))))))

(test arming-twice-does-not-lose-the-pre-arm-mode
  "Idempotent: a second arm must not record :developer as the mode to
return to"
  (with-armable ("twice")
    (cl-mcp-server.remote:register-target "twice" "127.0.0.1" 1
                                          :mode :observe)
    (cl-mcp-server.remote:arm-target "twice")
    (cl-mcp-server.remote:arm-target "twice")
    (cl-mcp-server.remote:disarm-target "twice")
    (is (eq :observe
            (cl-mcp-server.remote::target-mode
             (cl-mcp-server.remote::find-target "twice"))))))

(test disarming-an-unarmed-target-is-harmless
  (with-armable ("calm")
    (read-target "calm")
    (multiple-value-bind (target message)
        (cl-mcp-server.remote:disarm-target "calm")
      (declare (ignore target))
      (is (search "not armed" message)))))

(test arming-is-a-ledger-event
  (with-armable ("logged")
    (read-target "logged")
    (cl-mcp-server.remote:arm-target "logged" "fixing the parser")
    (let ((entries (cl-mcp-server.remote:ledger-for "logged")))
      (is (find :arm entries :key #'cl-mcp-server.remote:entry-tier))
      (is (find-if (lambda (e)
                     (search "fixing the parser"
                             (or (cl-mcp-server.remote:entry-detail e) "")))
                   entries)))))

(test disarming-is-a-ledger-event
  (with-armable ("logged2")
    (read-target "logged2")
    (cl-mcp-server.remote:arm-target "logged2")
    (cl-mcp-server.remote:disarm-target "logged2")
    (is (find :disarm (cl-mcp-server.remote:ledger-for "logged2")
              :key #'cl-mcp-server.remote:entry-tier))))

(test armed-target-reports-armed
  (with-armable ("flagged")
    (read-target "flagged")
    (cl-mcp-server.remote:arm-target "flagged")
    (is-true (cl-mcp-server.remote:target-armed-p
              (cl-mcp-server.remote::find-target "flagged")))))

(test arming-an-unknown-target-does-not-crash
  "find-target returns NIL rather than signalling, so a typo in a target
name would otherwise hit a struct accessor on NIL"
  (with-armable ("real-one")
    (multiple-value-bind (target message)
        (cl-mcp-server.remote:arm-target "no-such-target")
      (is (null target))
      (is (search "No target named" message)))))

(test disarming-an-unknown-target-does-not-crash
  (multiple-value-bind (target message)
      (cl-mcp-server.remote:disarm-target "no-such-target")
    (is (null target))
    (is (search "No target named" message))))

(test arm-tools-are-registered
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (dolist (name '("remote-arm" "remote-disarm"))
      (is (not (null (cl-mcp.tools:get-tool
                      (test-server-registry server) name)))
          "tool ~A should be registered" name))))

(test arm-tool-refuses-when-not-allowlisted
  (with-armable ()
    (read-target "tool-refused")
    (multiple-value-bind (server session) (make-test-server)
      (declare (ignore session))
      (is (search "not armable"
                  (call-test-tool server "remote-arm"
                                  '(("target" . "tool-refused"))))))))

(test targets-listing-marks-armed
  "No clock means visibility does the clock's job"
  (with-armable ("visible")
    (read-target "visible")
    (cl-mcp-server.remote:arm-target "visible")
    (multiple-value-bind (server session) (make-test-server)
      (declare (ignore session))
      (is (search "ARMED"
                  (call-test-tool server "remote-targets" '()))))))

(test disarm-tool-errors-on-unknown-target
  "Matches remote-arm: a target that does not exist is an error, not a
quiet success. 'Not armed' remains a success, since disarm is idempotent.

call-test-tool discards isError, so this asserts on the handler directly."
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (let ((handler (cl-mcp.tools:tool-handler
                    (cl-mcp.tools:get-tool (test-server-registry server)
                                           "remote-disarm"))))
      (multiple-value-bind (text err)
          (funcall handler '(("target" . "no-such-target-at-all")))
        (is-true err)
        (is (search "No target named" text))))))

(test disarm-tool-succeeds-on-unarmed-target
  (with-armable ("calm-one")
    (read-target "calm-one")
    (multiple-value-bind (server session) (make-test-server)
      (declare (ignore session))
      (let ((handler (cl-mcp.tools:tool-handler
                      (cl-mcp.tools:get-tool (test-server-registry server)
                                             "remote-disarm"))))
        (multiple-value-bind (text err)
            (funcall handler '(("target" . "calm-one")))
          (is-false err)
          (is (search "not armed" text)))))))

(test session-ending-operators-are-recognised
  "quit ends the session; terminate-thread does not"
  (is-true (cl-mcp-server.remote::session-ending-form-p "(sb-ext:quit)"))
  (is-true (cl-mcp-server.remote::session-ending-form-p "(exit)"))
  (is-true (cl-mcp-server.remote::session-ending-form-p
            "(sb-ext:save-lisp-and-die \"x\")"))
  (is-false (cl-mcp-server.remote::session-ending-form-p
             "(sb-thread:terminate-thread th)"))
  (is-false (cl-mcp-server.remote::session-ending-form-p
             "(delete-package :foo)")))

(test swank-aborted-is-a-subclass-of-swank-error
  "The live bug behind the single-clause handler in remote-eval: a quit that
surfaced as SWANK-ABORTED hit that clause first and reported 'remote error:
NIL' instead of 'terminated'. Ordering alone cannot fix it, so the handler
dispatches on the FORM before the condition type."
  (is-true (subtypep 'cl-mcp-server.swank-protocol:swank-aborted
                     'cl-mcp-server.swank-protocol:swank-error)))

(defun %count-substring (needle haystack)
  (loop with n = 0 with pos = 0
        for hit = (search needle haystack :start2 pos)
        while hit do (incf n) (setf pos (1+ hit))
        finally (return n)))

(test remote-eval-has-one-swank-error-clause
  "Two sibling clauses would silently re-introduce the bug: whichever came
first would shadow the other for the whole family.

Resolves the path through ASDF: a relative pathname would make this pass or
fail depending on the caller's working directory."
  (let* ((path (asdf:system-relative-pathname :cl-mcp-server
                                              "src/remote.lisp"))
         (src (with-open-file (in path)
                (let ((text (make-string (file-length in))))
                  (subseq text 0 (read-sequence text in))))))
    (is (= 1 (%count-substring "swank-protocol:swank-error (e)" src))
        "expected exactly one swank-error handler clause")
    (is (= 0 (%count-substring "swank-protocol:swank-aborted (e)" src))
        "swank-aborted must not have its own sibling clause")))

(test reconnecting-does-not-silently-disarm
  "Re-registering an armed target used to replace the struct, dropping
pre-arm-mode. The ledger would then show an :arm with no :disarm while the
target was in fact unarmed -- audit and reality disagreeing."
  (with-armable ("rearm")
    (cl-mcp-server.remote:register-target "rearm" "127.0.0.1" 1 :mode :read)
    (cl-mcp-server.remote:arm-target "rearm")
    (cl-mcp-server.remote:register-target "rearm" "127.0.0.1" 1 :mode :read)
    (let ((tg (cl-mcp-server.remote::find-target "rearm")))
      (is-true (cl-mcp-server.remote:target-armed-p tg)
               "reconnect must not drop arming")
      (is (eq :developer (cl-mcp-server.remote::target-mode tg))))))

(test reconnecting-updates-host-and-port
  (cl-mcp-server.remote:register-target "moved" "127.0.0.1" 1 :mode :read)
  (cl-mcp-server.remote:register-target "moved" "127.0.0.1" 4321 :mode :read)
  (let ((tg (cl-mcp-server.remote::find-target "moved")))
    (is (= 4321 (cl-mcp-server.remote:target-port tg)))))

(test disarm-after-reconnect-restores-the-registered-mode
  "The mode passed on reconnect becomes the mode disarm returns to."
  (with-armable ("rejoin")
    (cl-mcp-server.remote:register-target "rejoin" "127.0.0.1" 1
                                          :mode :observe)
    (cl-mcp-server.remote:arm-target "rejoin")
    (cl-mcp-server.remote:register-target "rejoin" "127.0.0.1" 1 :mode :read)
    (cl-mcp-server.remote:disarm-target "rejoin")
    (is (eq :read (cl-mcp-server.remote::target-mode
                   (cl-mcp-server.remote::find-target "rejoin"))))))

(test termination-is-probed-not-inferred-from-the-form
  "A form that merely MENTIONS quit can fail before reaching it. Inferring
termination from the form text closed a healthy connection and wrote a false
:terminated into the ledger -- reproduced live before this was fixed.

Nothing listens on port 1, so the probe must report the target as dead;
the point here is that the probe is consulted at all."
  (is-false (cl-mcp-server.remote::target-responds-p "no-such-target"))
  (cl-mcp-server.remote:register-target "dead-probe" "127.0.0.1" 1
                                        :mode :read)
  (is-false (cl-mcp-server.remote::target-responds-p "dead-probe")))

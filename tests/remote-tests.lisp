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

(defmacro with-armable ((&rest entries) &body body)
  "Run BODY with ENTRIES as the allowlist. A string is pinned to
127.0.0.1:1, where read-target registers; a list is an entry as written,
(NAME) for a bare name or (NAME HOST PORT)."
  `(let ((cl-mcp-server.remote-config::*armable*
           (mapcar (lambda (entry)
                     (if (consp entry) entry (list entry "127.0.0.1" 1)))
                   ',entries)))
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

(defun %remote-source ()
  "Text of src/remote.lisp, resolved through ASDF so the working directory
does not decide whether a test passes."
  (with-open-file (in (asdf:system-relative-pathname :cl-mcp-server
                                                     "src/remote.lisp"))
    (let ((text (make-string (file-length in))))
      (subseq text 0 (read-sequence text in)))))

(test remote-eval-has-one-swank-error-clause
  "Two sibling clauses would silently re-introduce the bug: whichever came
first would shadow the other for the whole family.

Resolves the path through ASDF: a relative pathname would make this pass or
fail depending on the caller's working directory."
  (let ((src (%remote-source)))
    ;; Counts the clause in REMOTE-EVAL specifically -- target-responds-p
    ;; has its own swank-error clause, which is unrelated.
    (is (= 1 (%count-substring
              "(typep e 'cl-mcp-server.swank-protocol:swank-aborted)" src))
        "swank-aborted must be handled by typep inside the one clause")
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

Asserts the guard is present in source: a behavioural test would need a
service that survives a failing quit-form, which the live checks cover.
Reverting the guard makes this fail."
  (let ((src (%remote-source)))
    (is (= 1 (%count-substring "(null (target-responds-p target-name))" src))
        "termination must test for NIL, not falsiness: :INCONCLUSIVE is
not death"))
  ;; The three-state contract the guard above depends on. Pinning only the
  ;; call site says nothing about the callee: target-responds-p must still
  ;; be capable of returning :INCONCLUSIVE, or (null ...) is guarding a
  ;; distinction that no longer exists.
  (is (= 1 (%count-substring "(inconclusive :inconclusive)"
                             (%remote-source)))
      "target-responds-p must still distinguish inconclusive from dead")
  (is-false (cl-mcp-server.remote::target-responds-p "no-such-target"))
  (cl-mcp-server.remote:register-target "dead-probe" "127.0.0.1" 1
                                        :mode :read)
  (is-false (cl-mcp-server.remote::target-responds-p "dead-probe")))

(test reregistering-a-moved-target-drops-the-cached-connection
  "A cached socket points at the OLD host/port. Keeping it would send an
armed target's redefinitions to the previous image -- the 'typo a port into
production' failure the design exists to prevent.

Behavioural, and pins the condition in BOTH directions: a source-text check
alone let the guard be inverted (invalidate only UNMOVED targets) with the
whole suite still green."
  (flet ((stub (name)
           (setf (gethash name cl-mcp-server.remote::*connections*)
                 (cl-mcp-server.swank-protocol::make-swank-connection
                  :socket nil :stream nil)))
         (cached-p (name)
           (nth-value 1 (gethash name
                                 cl-mcp-server.remote::*connections*))))
    ;; Moved: the cached connection must go.
    (cl-mcp-server.remote:register-target "movetest" "127.0.0.1" 1
                                          :mode :read)
    (stub "movetest")
    (cl-mcp-server.remote:register-target "movetest" "127.0.0.1" 2
                                          :mode :read)
    (is-false (cached-p "movetest") "a moved target must drop its socket")
    ;; Host, not just port: the guard has two halves and each needs pinning.
    (stub "movetest")
    (cl-mcp-server.remote:register-target "movetest" "127.0.0.2" 2
                                          :mode :read)
    (is-false (cached-p "movetest") "a host change must drop the socket too")
    ;; Unmoved: it must survive, or every reconnect churns the connection.
    (stub "movetest")
    (cl-mcp-server.remote:register-target "movetest" "127.0.0.2" 2
                                          :mode :read)
    (is-true (cached-p "movetest")
             "an unmoved target must keep its socket")
    ;; Do not leave a half-built stub in the global table for later tests.
    (remhash "movetest" cl-mcp-server.remote::*connections*)))

(test reconnecting-updates-the-host-too
  "The port-only test would not notice the host copy being dropped."
  (cl-mcp-server.remote:register-target "hostmove" "127.0.0.1" 1 :mode :read)
  (cl-mcp-server.remote:register-target "hostmove" "127.0.0.2" 1 :mode :read)
  (is (string= "127.0.0.2"
               (cl-mcp-server.remote:target-host
                (cl-mcp-server.remote::find-target "hostmove")))))

;;; ==========================================================================
;;; Framing and dropped connections (GH #11)
;;;
;;; A plain listener stands in for the service: what the client does when
;;; the far end closes or garbles a frame needs no SWANK. The SWANK round
;;; trips are in swank-wire-tests.lisp.
;;; ==========================================================================

(defun %cyrillic-pri ()
  "Two two-octet characters and one ASCII one, built from code points so
this file stays ASCII."
  (coerce (list (code-char #x41F) (code-char #x440) #\i) 'string))

(defmacro with-listener ((server port) &body body)
  `(let* ((,server (usocket:socket-listen "127.0.0.1" 0
                                          :reuse-address t
                                          :element-type '(unsigned-byte 8)))
          (,port (usocket:get-local-port ,server)))
     (unwind-protect (progn ,@body)
       (usocket:socket-close ,server))))

(defun %accept (server)
  "The next connection on SERVER, or NIL after two seconds."
  (when (usocket:wait-for-input server :timeout 2 :ready-only t)
    (usocket:socket-accept server :element-type '(unsigned-byte 8))))

(defun %write-raw (peer text)
  (let ((stream (usocket:socket-stream peer)))
    (write-sequence (map '(vector (unsigned-byte 8)) #'char-code text) stream)
    (finish-output stream)))

(defun %await-state (conn state)
  "Poll CONN for up to two seconds until it reaches STATE; return the last
state seen. The far end's close reaches us asynchronously."
  (loop repeat 100
        for seen = (cl-mcp-server.swank-protocol:connection-state conn)
        until (eq seen state)
        do (sleep 0.02)
        finally (return seen)))

(test frame-header-counts-utf-8-octets
  "Counting characters said 3 here: SWANK read a truncated form and
dropped the connection"
  (let ((frame (cl-mcp-server.swank-protocol::%frame (%cyrillic-pri))))
    (is (string= "000005" (map 'string #'code-char (subseq frame 0 6))))
    (is (= 11 (length frame))))
  (is (string= "000007(+ 1 2)"
               (map 'string #'code-char
                    (cl-mcp-server.swank-protocol::%frame "(+ 1 2)")))))

(test a-closed-peer-is-seen-without-blocking
  "LISTEN is NIL at EOF, so a dropped socket read as idle, was reused, and
failed later as BROKEN-PIPE"
  (with-listener (server port)
    (let ((conn (cl-mcp-server.swank-protocol:connect "127.0.0.1" port))
          (peer (%accept server)))
      (unwind-protect
           (progn
             (is (eq :open
                     (cl-mcp-server.swank-protocol:connection-state conn)))
             (usocket:socket-close peer)
             (is (eq :peer-closed (%await-state conn :peer-closed))))
        (cl-mcp-server.swank-protocol:disconnect conn)))))

(defun %drain (peer)
  "Read whatever PEER has been sent, so that closing it sends FIN, not the
RST that closing over unread data sends."
  (let ((stream (usocket:socket-stream peer)))
    (when (usocket:wait-for-input peer :timeout 2 :ready-only t)
      (loop while (listen stream) do (read-byte stream)))))

(test a-peer-closing-mid-call-is-reported-at-once
  "The old LISTEN poll ran out the whole timeout on a cleanly closed socket,
since LISTEN is NIL at EOF, then blamed a slow form"
  (with-listener (server port)
    (cl-mcp-server.remote:register-target "dropper" "127.0.0.1" port
                                          :mode :read)
    (let* ((closer (bordeaux-threads:make-thread
                    (lambda ()
                      (let ((peer (%accept server)))
                        (when peer
                          (%drain peer)
                          (sleep 0.3)
                          (usocket:socket-close peer))))))
           (start (get-internal-real-time))
           (r (let ((cl-mcp-server.swank-protocol:*call-timeout* 10))
                (cl-mcp-server.remote:remote-eval "dropper" "(+ 1 2)")))
           (elapsed (/ (- (get-internal-real-time) start)
                       internal-time-units-per-second)))
      (bordeaux-threads:join-thread closer)
      (is-false (getf r :ok))
      (is (search "connection lost" (getf r :error)))
      (is (< elapsed 5) "took ~,1Fs; the timeout was 10s" elapsed)
      (is (eq :closed (cl-mcp-server.swank-protocol:connection-state
                       (gethash "dropper"
                                cl-mcp-server.remote::*connections*)))))
    (cl-mcp-server.remote:close-connection "dropper")))

(test a-reset-mid-call-is-a-lost-connection
  "Closing over our unread request sends RST. Arriving while we wait, it
fails the read with a stream error, which must close the connection
rather than leak out raw. Arriving earlier, it reads as EOF instead."
  (with-listener (server port)
    (let* ((conn (cl-mcp-server.swank-protocol:connect "127.0.0.1" port))
           (resetter (bordeaux-threads:make-thread
                      (lambda ()
                        (let ((peer (%accept server)))
                          ;; No wait-for-input here: its LISTEN would
                          ;; read our request into Lisp's buffer, and an
                          ;; empty kernel queue closes with FIN.
                          (when peer
                            (sleep 0.3)
                            (usocket:socket-close peer)))))))
      (unwind-protect
           (signals cl-mcp-server.swank-protocol:swank-connection-lost
             (cl-mcp-server.swank-protocol:rex conn "(+ 1 2)" :timeout 5))
        (bordeaux-threads:join-thread resetter)
        (cl-mcp-server.swank-protocol:disconnect conn)))))

(test a-junk-header-is-a-lost-connection-not-a-parse-error
  "A header read from mid-payload leaked SIMPLE-PARSE-ERROR and left the
desynchronised connection cached (GH #11, first comment)"
  (with-listener (server port)
    (let ((conn (cl-mcp-server.swank-protocol:connect "127.0.0.1" port))
          (peer (%accept server)))
      (unwind-protect
           (progn
             (%write-raw peer "E900(:")
             (signals cl-mcp-server.swank-protocol:swank-connection-lost
               (cl-mcp-server.swank-protocol:rex conn "(+ 1 2)" :timeout 2))
             (is (eq :closed
                     (cl-mcp-server.swank-protocol:connection-state conn))))
        (usocket:socket-close peer)
        (cl-mcp-server.swank-protocol:disconnect conn)))))

(test a-signed-header-is-not-a-frame
  "PARSE-INTEGER reads +00002 as 2: it would swallow two octets of garbage
and wait out the timeout rather than report the stream lost"
  (with-listener (server port)
    (let ((conn (cl-mcp-server.swank-protocol:connect "127.0.0.1" port))
          (peer (%accept server)))
      (unwind-protect
           (progn
             (%write-raw peer "+00002ab")
             (signals cl-mcp-server.swank-protocol:swank-connection-lost
               (cl-mcp-server.swank-protocol:rex conn "(+ 1 2)" :timeout 2)))
        (usocket:socket-close peer)
        (cl-mcp-server.swank-protocol:disconnect conn)))))

(test a-write-to-a-dropped-socket-is-a-lost-connection
  "BROKEN-PIPE leaked out raw, and the dead socket stayed cached. The first
write after the far end closes can succeed, so keep writing."
  (with-listener (server port)
    (let ((conn (cl-mcp-server.swank-protocol:connect "127.0.0.1" port)))
      (usocket:socket-close (%accept server))
      (unwind-protect
           (let ((lost
                   (loop repeat 50
                         thereis
                         (handler-case
                             (progn (cl-mcp-server.swank-protocol::%send
                                     conn "(x)")
                                    (sleep 0.02)
                                    nil)
                           (cl-mcp-server.swank-protocol:swank-connection-lost
                               ()
                             t)))))
             (is-true lost)
             (is (eq :closed
                     (cl-mcp-server.swank-protocol:connection-state conn))))
        (cl-mcp-server.swank-protocol:disconnect conn)))))

(test connection-for-replaces-a-socket-the-service-closed
  "remote-connect on a name whose socket had died failed on that socket
instead of opening a new one"
  (with-listener (server port)
    (cl-mcp-server.remote:register-target "replaced" "127.0.0.1" port
                                          :mode :read)
    (let ((tg (cl-mcp-server.remote::find-target "replaced")))
      (multiple-value-bind (c1 r1) (cl-mcp-server.remote::connection-for tg)
        (is-false r1)
        (usocket:socket-close (%accept server))
        (is (eq :peer-closed (%await-state c1 :peer-closed))
            "the far end's close must land before the replacement is tested")
        (multiple-value-bind (c2 r2)
            (cl-mcp-server.remote::connection-for tg)
          (let ((peer (%accept server)))
            (is-true r2)
            (is (not (eq c1 c2)))
            (is-true peer "the replacement must reach the service")
            (is (eq :closed
                    (cl-mcp-server.swank-protocol:connection-state c1))
                "our end of the dead socket must be closed too")
            (is (eq c2 (cl-mcp-server.remote::connection-for tg))
                "an open connection is reused")
            (when peer (usocket:socket-close peer))))))
    (cl-mcp-server.remote:close-connection "replaced")))

(defun %stalled-read (prefix)
  "Read a reply from a peer that sends PREFIX, then nothing until we hang
up or four seconds pass. Returns (values condition seconds)."
  (with-listener (server port)
    (let* ((conn (let ((cl-mcp-server.swank-protocol:*stall-timeout* 1))
                   (cl-mcp-server.swank-protocol:connect "127.0.0.1" port)))
           (peer (%accept server))
           (staller (bordeaux-threads:make-thread
                     (lambda ()
                       (%write-raw peer prefix)
                       (usocket:wait-for-input peer :timeout 4)
                       (usocket:socket-close peer))))
           (start (get-internal-real-time)))
      (unwind-protect
           (values (handler-case
                       (progn (cl-mcp-server.swank-protocol::%read-message
                               conn :timeout 5)
                              nil)
                     (error (e) e))
                   (/ (- (get-internal-real-time) start)
                      internal-time-units-per-second))
        (cl-mcp-server.swank-protocol:disconnect conn)
        (bordeaux-threads:join-thread staller)))))

(test a-stalled-frame-is-a-lost-connection
  "A peer that sends part of a frame and stops is given up on after
*STALL-TIMEOUT*. The bound used to be a usocket default (GH #15)."
  (dolist (prefix '("000" "000010("))
    (multiple-value-bind (condition seconds) (%stalled-read prefix)
      (is (typep condition
                 'cl-mcp-server.swank-protocol:swank-connection-lost)
          "~S: got ~A" prefix condition)
      (is (< seconds 3)
          "~S: took ~,1Fs; the stall bound was 1s" prefix seconds))))

(test a-reply-slower-than-the-stall-bound-still-arrives
  "*STALL-TIMEOUT* bounds a frame already started. The wait for a reply
to start is *CALL-TIMEOUT*'s, so a slow form is not a stall (GH #15)."
  (with-listener (server port)
    (let* ((conn (let ((cl-mcp-server.swank-protocol:*stall-timeout* 1))
                   (cl-mcp-server.swank-protocol:connect "127.0.0.1" port)))
           (peer (%accept server))
           (replier (bordeaux-threads:make-thread
                     (lambda () (sleep 2) (%write-raw peer "000003(1)")))))
      (unwind-protect
           (is (equal "(1)"
                      (cl-mcp-server.swank-protocol::%read-message
                       conn :timeout 5)))
        (bordeaux-threads:join-thread replier)
        (usocket:socket-close peer)
        (cl-mcp-server.swank-protocol:disconnect conn)))))

;;; ==========================================================================
;;; Pinned names (GH #12)
;;;
;;; The allowlist lives outside the session; the binding of a name to an
;;; endpoint did not, so a session could arm "dev" at prod's port.
;;; ==========================================================================

(defun %ledger-refusals (name tier)
  (count-if (lambda (e)
              (and (eq tier (cl-mcp-server.remote:entry-tier e))
                   (eq :refused (cl-mcp-server.remote:entry-outcome e))))
            (cl-mcp-server.remote:ledger-for name)))

(test arming-is-refused-for-a-bare-name
  "A name alone does not say which image may be changed"
  (with-armable (("bare-one"))
    (read-target "bare-one")
    (multiple-value-bind (target message)
        (cl-mcp-server.remote:arm-target "bare-one")
      (is (null target))
      (is (search "name only" message))
      (is (search (concatenate 'string "(:armable-targets ((\"bare-one\" "
                               ":host \"127.0.0.1\" :port 1)))")
                  message)
          "the refusal must say how to pin it: ~A" message))
    (is (eq :read (cl-mcp-server.remote::target-mode
                   (cl-mcp-server.remote::find-target "bare-one"))))
    (is (= 1 (%ledger-refusals "bare-one" :arm)))))

(test arming-is-refused-when-the-endpoint-is-not-the-pin
  "Registration already refuses this; arm checks again in case the pin
arrived after the registration"
  (with-armable ()
    (read-target "pinned-later"))
  (with-armable (("pinned-later" "127.0.0.1" 4107))
    (multiple-value-bind (target message)
        (cl-mcp-server.remote:arm-target "pinned-later")
      (is (null target))
      (is (search "pinned to 127.0.0.1:4107" message) "~A" message))
    (is-false (cl-mcp-server.remote:target-armed-p
               (cl-mcp-server.remote::find-target "pinned-later")))))

(test arming-a-pinned-name-at-its-endpoint-succeeds
  (with-armable (("pinned-ok" "127.0.0.1" 4107))
    (cl-mcp-server.remote:register-target "pinned-ok" "127.0.0.1" 4107
                                          :mode :read)
    (is (not (null (cl-mcp-server.remote:arm-target "pinned-ok"))))
    (is (eq :developer
            (cl-mcp-server.remote::target-mode
             (cl-mcp-server.remote::find-target "pinned-ok"))))))

(test connect-refuses-a-pinned-name-at-another-endpoint
  "The repro in GH #12: \"dev\" registered at the port of another image"
  (with-armable (("pinned-dev" "127.0.0.1" 4107))
    (signals cl-mcp-server.remote:pin-mismatch
      (cl-mcp-server.remote:register-target "pinned-dev" "127.0.0.1" 4108))
    (signals cl-mcp-server.remote:pin-mismatch
      (cl-mcp-server.remote:register-target "pinned-dev" "127.0.0.2" 4107))
    (is (null (cl-mcp-server.remote::find-target "pinned-dev"))
        "a refused registration must register nothing")
    (is (= 2 (%ledger-refusals "pinned-dev" :connect)))))

(test a-pinned-target-cannot-be-moved
  "Re-registering moves a target; a pinned one must stay put"
  (with-armable (("pinned-stay" "127.0.0.1" 4107))
    (cl-mcp-server.remote:register-target "pinned-stay" "127.0.0.1" 4107)
    (signals cl-mcp-server.remote:pin-mismatch
      (cl-mcp-server.remote:register-target "pinned-stay" "127.0.0.1" 4108))
    (is (= 4107 (cl-mcp-server.remote:target-port
                 (cl-mcp-server.remote::find-target "pinned-stay"))))))

(test connect-tool-reports-a-pin-mismatch-as-an-error
  "Through the tool, without probing: the refusal is the whole answer"
  (with-armable (("pinned-tool" "127.0.0.1" 4107))
    (multiple-value-bind (server session) (make-test-server)
      (declare (ignore session))
      (let ((handler (cl-mcp.tools:tool-handler
                      (cl-mcp.tools:get-tool (test-server-registry server)
                                             "remote-connect"))))
        (multiple-value-bind (text err)
            (funcall handler '(("name" . "pinned-tool") ("port" . 4108)))
          (is-true err)
          (is (search "pinned to 127.0.0.1:4107" text) "~A" text))))))

(test targets-listing-marks-pinned-names
  (with-armable ("shown-pinned" ("shown-bare"))
    (read-target "shown-pinned")
    (read-target "shown-bare")
    (multiple-value-bind (server session) (make-test-server)
      (declare (ignore session))
      (let* ((text (call-test-tool server "remote-targets" '()))
             (lines (uiop:split-string text :separator '(#\Newline))))
        (flet ((line-for (name)
                 (find-if (lambda (l) (search name l)) lines)))
          (is (search "[pinned]" (line-for "shown-pinned ")))
          (is-false (search "[pinned]" (line-for "shown-bare "))))))))

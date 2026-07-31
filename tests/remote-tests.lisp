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

(test classify-plain-read
  (is (eq :read (tier-of "(+ 1 2)")))
  (is (eq :read (tier-of "(hash-table-count *cache*)"))))

(test classify-setf-is-mutate
  (is (eq :mutate (tier-of "(setf *x* 1)"))))

(test classify-defun-is-mutate
  (is (eq :mutate (tier-of "(defun foo () 1)"))))

(test classify-load-is-mutate
  (is (eq :mutate (tier-of "(load \"/tmp/x.lisp\")"))))

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
    (is (eq :mutate tier))
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
    (is-false (cl-mcp-server.remote::tier-allowed-p tg :mutate))))

(test read-mode-permits-read-not-mutate
  (let ((tg (make-test-target :read)))
    (is-true (cl-mcp-server.remote::tier-allowed-p tg :read))
    (is-false (cl-mcp-server.remote::tier-allowed-p tg :mutate))))

(test lifecycle-never-allowed
  "No mode permits lifecycle. This is the property that keeps a stray
(sb-ext:quit) from taking down a service."
  (dolist (mode '(:observe :read :mutate))
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
  (cl-mcp-server.remote:register-target "test-refuse" "127.0.0.1" 1 :mode :read)
  (let ((r (cl-mcp-server.remote:remote-eval "test-refuse" "(sb-ext:quit)")))
    (is-false (getf r :ok))
    (is-true (getf r :refused))
    (is (eq :lifecycle (getf r :tier)))))

(test refusal-shows-the-form-for-a-human
  (cl-mcp-server.remote:register-target "test-refuse2" "127.0.0.1" 1
                                        :mode :read)
  (let ((r (cl-mcp-server.remote:remote-eval "test-refuse2" "(setf *x* 1)")))
    (is (search "Run it yourself" (getf r :error)))
    (is (search "(setf *x* 1)" (getf r :error)))))

;;; ==========================================================================
;;; Ledger
;;; ==========================================================================

(test ledger-records-refusals
  "An attempted destructive call is as interesting as a successful one"
  (cl-mcp-server.remote:register-target "test-ledger" "127.0.0.1" 1 :mode :read)
  (cl-mcp-server.remote:remote-eval "test-ledger" "(sb-ext:quit)")
  (let ((entries (cl-mcp-server.remote:ledger-for "test-ledger")))
    (is-true entries)
    (is (eq :refused (cl-mcp-server.remote:entry-outcome (first entries))))
    (is (search "quit" (cl-mcp-server.remote:entry-form (first entries))))))

(test ledger-entries-carry-a-time
  (cl-mcp-server.remote:register-target "test-time" "127.0.0.1" 1 :mode :read)
  (cl-mcp-server.remote:remote-eval "test-time" "(setf *x* 1)")
  (let ((entry (first (cl-mcp-server.remote:ledger-for "test-time"))))
    (is (= 8 (length (cl-mcp-server.remote:entry-time-string entry))))))

(test ledger-filters-by-target
  (cl-mcp-server.remote:register-target "test-a" "127.0.0.1" 1 :mode :read)
  (cl-mcp-server.remote:register-target "test-b" "127.0.0.1" 1 :mode :read)
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
  (cl-mcp-server.remote:register-target "test-tool" "127.0.0.1" 1 :mode :read)
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (let ((text (call-test-tool server "remote-eval"
                                '(("target" . "test-tool")
                                  ("code" . "(sb-ext:quit)")))))
      (is (search "Refused" text)))))

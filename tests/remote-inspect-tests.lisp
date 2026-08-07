;;; tests/remote-inspect-tests.lisp
;;; ABOUTME: Tests for remote inspection in transcript and registry modes

(in-package #:cl-mcp-server-tests)

(def-suite remote-inspect-tests
  :description "Tests for the remote object inspector"
  :in cl-mcp-server-tests)

(in-suite remote-inspect-tests)

;;; These run without a network. What matters here is the SHAPE of the forms
;;; we would send: they are built as text in this image and read by another,
;;; so a reader-level mistake fails on the far side where it is expensive to
;;; diagnose.

(defun setup-form ()
  (cl-mcp-server.remote-inspect::%registry-setup-form))

(defun parts-form (expr)
  (cl-mcp-server.remote-inspect::%parts-form expr 100))

(defun register-form (expr)
  (cl-mcp-server.remote-inspect::%register-form expr 100))

(defun fetch-form (handle)
  (cl-mcp-server.remote-inspect::%fetch-form handle 100))

;;; ==========================================================================
;;; Generated forms must READ
;;;
;;; The forms are assembled by FORMAT and evaluated remotely. If one does not
;;; read, the failure surfaces on the service as a reader error with no
;;; useful context. Reading them here is the cheapest place to catch that.
;;; ==========================================================================

(defun reads-cleanly-p (text)
  "True when TEXT reads as a single form without interning junk."
  (let ((pkg (make-package (gensym "RI-TEST-") :use '(#:common-lisp))))
    (unwind-protect
         (handler-case
             (let ((*package* pkg) (*read-eval* nil))
               (with-input-from-string (in text)
                 (read in)
                 t))
           (error () nil))
      (delete-package pkg))))

(test transcript-form-reads
  (is-true (reads-cleanly-p (parts-form "(list 1 2)"))))

(test registry-setup-form-reads
  (is-true (reads-cleanly-p (setup-form))))

(test register-form-reads
  (is-true (reads-cleanly-p (register-form "(list 1 2)"))))

(test fetch-form-reads
  (is-true (reads-cleanly-p (fetch-form 7))))

(test clear-form-reads
  (is-true (reads-cleanly-p (cl-mcp-server.remote-inspect::%clear-form))))

(test forms-avoid-escaped-character-literals
  "A #\\Newline written into a generated form arrives at the remote reader
as #\\ followed by \\Newline and fails there. (code-char 10) needs no
escaping and survives the round trip -- this cost a debug cycle once."
  (dolist (form (list (parts-form "(list 1)") (register-form "(list 1)")
                      (fetch-form 1)))
    (is (null (search "#\\\\" form))
        "generated form must not contain a doubly-escaped character literal")))

;;; ==========================================================================
;;; Transcript mode must not mutate
;;;
;;; The default mode's whole claim is that it retains nothing. If its form
;;; classified as mutating, either it would be refused or we would have to
;;; weaken the classifier -- and the classifier is the safety model.
;;; ==========================================================================

(test transcript-form-classifies-as-read
  (is (eq :read (cl-mcp-server.remote::classify-form
                 (parts-form "(list 1 2 3)")))))

(test transcript-form-has-no-mutating-operators
  "Belt and braces: the form itself must be free of setf/incf/defparameter"
  (let ((form (string-upcase (parts-form "(list 1)"))))
    (dolist (op '("INCF" "SETF" "SETQ" "DEFPARAMETER" "PUSH"))
      (is (null (search op form))
          "transcript form must not contain ~A" op))))

(test registry-forms-do-mutate
  "Registry mode genuinely mutates; it must not pretend otherwise"
  (is (member (cl-mcp-server.remote::classify-form (setup-form))
              '(:mutate :lifecycle))))

;;; ==========================================================================
;;; The inspect-registry tier
;;; ==========================================================================

(defun target-in (mode)
  (cl-mcp-server.remote::make-target :name "ri" :host "h" :port 1 :mode mode))

(test inspect-registry-allowed-where-read-is
  (is-true (cl-mcp-server.remote::tier-allowed-p
            (target-in :read) :inspect-registry)))

(test inspect-registry-refused-in-observe-mode
  "Observe mode promises metadata only; retaining handles is more than that"
  (is-false (cl-mcp-server.remote::tier-allowed-p
             (target-in :observe) :inspect-registry)))

(test inspect-registry-does-not-unlock-lifecycle
  "The override must widen exactly one tier, not open the gate"
  (is-false (cl-mcp-server.remote::tier-allowed-p
             (target-in :read) :lifecycle)))

;;; ==========================================================================
;;; Weak retention is stated, not assumed
;;; ==========================================================================

(test registry-uses-weak-pointers
  "The registry must never be the reason a service keeps an object alive"
  (let ((form (register-form "(list 1)")))
    (is (search "make-weak-pointer" form))))

(test fetch-checks-liveness
  "A collected handle must report that, not resurrect or crash"
  (let ((form (fetch-form 3)))
    (is (search "weak-pointer-value" form))
    (is (search "collected" form))))

;;; ==========================================================================
;;; Print limits travel with every form
;;; ==========================================================================

(test all-remote-forms-bind-print-limits
  "A service must not be asked to render an unbounded structure"
  (dolist (form (list (parts-form "*x*") (register-form "*x*") (fetch-form 1)))
    (is (search "*print-length*" form))
    (is (search "*print-level*" form))))

;;; ==========================================================================
;;; Output unwrapping
;;; ==========================================================================

(test unquote-resolves-escapes
  (is (string= (format nil "a~%b")
               (cl-mcp-server.remote-inspect::%unquote "\"a\\nb\""))))

(test unquote-passes-through-plain-text
  (is (string= "plain" (cl-mcp-server.remote-inspect::%unquote "plain"))))

(test unquote-handles-nil
  (is (string= "" (cl-mcp-server.remote-inspect::%unquote nil))))

;;; ==========================================================================
;;; Formatting
;;; ==========================================================================

(test format-transcript-says-nothing-retained
  "The default mode's guarantee should be visible in its output"
  (multiple-value-bind (text err)
      (cl-mcp-server.remote-inspect:format-remote-inspection
       (list :ok t :result "\"CONS\""))
    (is-false err)
    (is (search "nothing retained" text))))

(test format-registry-offers-navigation
  (multiple-value-bind (text err)
      (cl-mcp-server.remote-inspect:format-remote-inspection
       (list :ok t :result "\"[1] CONS\"") :registry t)
    (is-false err)
    (is (search "handle" text))))

(test format-failure-is-an-error
  (multiple-value-bind (text err)
      (cl-mcp-server.remote-inspect:format-remote-inspection
       (list :ok nil :error "unreachable"))
    (is-true err)
    (is (search "unreachable" text))))

;;; ==========================================================================
;;; Tool registration
;;; ==========================================================================

(test remote-inspect-tools-registered
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (dolist (name '("remote-inspect" "remote-inspect-clear"))
      (is (not (null (cl-mcp.tools:get-tool
                      (test-server-registry server) name)))
          "tool ~A should be registered" name))))

(test remote-inspect-requires-code-or-handle
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (is (search "Supply either"
                (call-test-tool server "remote-inspect"
                                '(("target" . "nowhere")))))))

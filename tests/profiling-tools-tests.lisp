;;; tests/profiling-tools-tests.lisp
;;; ABOUTME: Tests for Phase F profiling tools

(in-package #:cl-mcp-server-tests)

(def-suite profiling-tools-tests
  :description "Tests for profiling and performance analysis tools"
  :in cl-mcp-server-tests)

(in-suite profiling-tools-tests)

;;; ==========================================================================
;;; Statistical Profiling Tests (profile-code)
;;; ==========================================================================

(test introspect-profile-code-basic
  "introspect-profile-code returns profiling results"
  (let ((result (cl-mcp-server.profiling-tools:introspect-profile-code
                 "(+ 1 2)"
                 :mode :cpu
                 :max-samples 100)))
    (is (listp result))
    (is (getf result :success))
    (is (eq :cpu (getf result :mode)))
    (is (stringp (getf result :report)))))

(test introspect-profile-code-modes
  "introspect-profile-code accepts different modes"
  ;; CPU mode
  (let ((result (cl-mcp-server.profiling-tools:introspect-profile-code
                 "(list 1 2 3)" :mode :cpu)))
    (is (eq :cpu (getf result :mode))))
  ;; Time mode
  (let ((result (cl-mcp-server.profiling-tools:introspect-profile-code
                 "(list 1 2 3)" :mode :time)))
    (is (eq :time (getf result :mode)))))

(test introspect-profile-code-error-handling
  "introspect-profile-code handles errors gracefully"
  (let ((result (cl-mcp-server.profiling-tools:introspect-profile-code
                 "(error \"test error\")")))
    (is (null (getf result :success)))
    (is (search "test error" (getf result :result)))))

(test format-profile-code-result-output
  "format-profile-code-result produces readable output"
  (let* ((result (cl-mcp-server.profiling-tools:introspect-profile-code
                  "(+ 1 2)"))
         (formatted (cl-mcp-server.profiling-tools:format-profile-code-result
                     result)))
    (is (stringp formatted))
    (is (search "Profiling" formatted))))

;;; ==========================================================================
;;; Deterministic Profiling Tests (profile-functions)
;;; ==========================================================================

(test introspect-profile-functions-status
  "introspect-profile-functions returns status"
  (let ((result (cl-mcp-server.profiling-tools:introspect-profile-functions
                 :status)))
    (is (listp result))
    (is (eq :status (getf result :action)))))

(test introspect-profile-functions-reset
  "introspect-profile-functions reset works"
  (let ((result (cl-mcp-server.profiling-tools:introspect-profile-functions
                 :reset)))
    (is (eq :reset (getf result :action)))))

(test introspect-profile-functions-report-empty
  "introspect-profile-functions report works when empty"
  (cl-mcp-server.profiling-tools:introspect-profile-functions :stop)
  (let ((result (cl-mcp-server.profiling-tools:introspect-profile-functions
                 :report)))
    (is (eq :report (getf result :action)))))

(test format-profile-functions-result-status
  "format-profile-functions-result formats status"
  (let* ((result (cl-mcp-server.profiling-tools:introspect-profile-functions
                  :status))
         (formatted
          (cl-mcp-server.profiling-tools:format-profile-functions-result
           result)))
    (is (stringp formatted))))

;;; ==========================================================================
;;; Memory Report Tests
;;; ==========================================================================

(test introspect-memory-report-basic
  "introspect-memory-report returns memory info"
  (let ((result (cl-mcp-server.profiling-tools:introspect-memory-report)))
    (is (listp result))
    (is (stringp (getf result :room)))
    (is (numberp (getf result :gc-run-time-ms)))))

(test introspect-memory-report-verbosity
  "introspect-memory-report respects verbosity"
  (let ((default (cl-mcp-server.profiling-tools:introspect-memory-report
                  :verbosity :default))
        (minimal (cl-mcp-server.profiling-tools:introspect-memory-report
                  :verbosity nil)))
    (is (stringp (getf default :room)))
    (is (stringp (getf minimal :room)))))

(test introspect-memory-report-gc-option
  "introspect-memory-report gc-first option works"
  (let ((result (cl-mcp-server.profiling-tools:introspect-memory-report
                 :gc-first t)))
    (is (getf result :gc-triggered))))

(test memory-report-survives-gc-of-compiled-code
  "SBCL's ROOM walks code space without the allocator lock. After a GC
the finalizer thread frees dead code under that lock, and a walk that
overlaps it fails an AVER. 2000 dead functions lost the race 16 times
in 16 before the retry (GH #13)."
  (let ((failures 0))
    (dotimes (round 2)
      (dotimes (i 2000)
        (compile nil `(lambda (x) (+ x ,i (length (list x ,i))))))
      (handler-case (cl-mcp-server.profiling-tools:introspect-memory-report
                     :gc-first t)
        (sb-int:bug () (incf failures))))
    (is (zerop failures) "~D of 2 reports failed an AVER" failures)))

(defun %with-room-always-failing (thunk)
  "THUNK's value, or the condition it signalled, while ROOM always fails."
  (sb-int:encapsulate 'room 'gh-13
                      (lambda (f &rest args)
                        (declare (ignore f args))
                        (sb-int:bug "simulated: ROOM keeps failing")))
  (unwind-protect (handler-case (funcall thunk) (error (e) e))
    (sb-int:unencapsulate 'room 'gh-13)))

(test memory-report-surfaces-a-room-that-keeps-failing
  "The retry must give up and report, not return an empty report
(RULE-007)."
  (is (typep (%with-room-always-failing
              (lambda ()
                (cl-mcp-server.profiling-tools:introspect-memory-report)))
             'sb-int:bug)))

(test format-memory-report-output
  "format-memory-report produces readable output"
  (let* ((result (cl-mcp-server.profiling-tools:introspect-memory-report))
         (formatted (cl-mcp-server.profiling-tools:format-memory-report
                     result)))
    (is (stringp formatted))
    (is (search "GC Statistics" formatted))
    (is (search "Dynamic space" formatted))))

;;; ==========================================================================
;;; Allocation Profiling Tests
;;; ==========================================================================

(test introspect-allocation-profile-basic
  "introspect-allocation-profile returns allocation info"
  (let ((result (cl-mcp-server.profiling-tools:introspect-allocation-profile
                 "(make-list 10)"
                 :max-samples 100)))
    (is (listp result))
    (is (getf result :success))
    (is (stringp (getf result :report)))))

(test introspect-allocation-profile-error-handling
  "introspect-allocation-profile handles errors"
  (let ((result (cl-mcp-server.profiling-tools:introspect-allocation-profile
                 "(error \"alloc test\")")))
    (is (null (getf result :success)))))

(test format-allocation-profile-result-output
  "format-allocation-profile-result produces readable output"
  (let* ((result (cl-mcp-server.profiling-tools:introspect-allocation-profile
                  "(list 1 2 3)"))
         (formatted
          (cl-mcp-server.profiling-tools:format-allocation-profile-result
           result)))
    (is (stringp formatted))
    (is (search "Allocation" formatted))))

;;; ==========================================================================
;;; Tool Registration Tests
;;; ==========================================================================

(test profile-code-tool-registered
  "profile-code tool is registered"
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (is (not (null (cl-mcp.tools:get-tool (test-server-registry server)
                    "profile-code"))))))

(test profile-functions-tool-registered
  "profile-functions tool is registered"
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (is (not (null (cl-mcp.tools:get-tool (test-server-registry server)
                    "profile-functions"))))))

(test memory-report-tool-registered
  "memory-report tool is registered"
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (is (not (null (cl-mcp.tools:get-tool (test-server-registry server)
                    "memory-report"))))))

(test allocation-profile-tool-registered
  "allocation-profile tool is registered"
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (is (not (null (cl-mcp.tools:get-tool (test-server-registry server)
                    "allocation-profile"))))))

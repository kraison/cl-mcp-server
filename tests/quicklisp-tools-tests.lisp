;;; tests/quicklisp-tools-tests.lisp
;;; ABOUTME: Tests for read-only Quicklisp dist introspection

(in-package #:cl-mcp-server-tests)

(def-suite quicklisp-tools-tests
  :description "Tests for Quicklisp dry-run, system info, search"
  :in cl-mcp-server-tests)

(in-suite quicklisp-tools-tests)

;;; ==========================================================================
;;; Test strategy
;;;
;;; Dist contents change every month, so asserting on exact versions, system
;;; counts or download sizes would produce tests that rot. Instead we assert
;;; on STRUCTURE (plist shape, invariants, orderings) and on a handful of
;;; systems that are effectively permanent fixtures of Quicklisp -- alexandria
;;; and cl-ppcre have been present continuously for over a decade and are
;;; depended on by hundreds of others.
;;;
;;; Every test is skipped when Quicklisp is absent, so the suite still passes
;;; in a bare image.
;;; ==========================================================================

(defun ql-present-p ()
  (cl-mcp-server.quicklisp-tools::quicklisp-available-p))

(defmacro when-ql (&body body)
  "Run BODY only if Quicklisp is available; otherwise pass trivially."
  `(if (ql-present-p)
       (progn ,@body)
       (is-true t "Quicklisp not available; test skipped")))

;;; ==========================================================================
;;; human-bytes
;;; ==========================================================================

(test human-bytes-scales-units
  "Byte counts render in a sensible unit"
  (is (search "B" (cl-mcp-server.quicklisp-tools:human-bytes 512)))
  (is (search "KB" (cl-mcp-server.quicklisp-tools:human-bytes 2048)))
  (is (search "MB" (cl-mcp-server.quicklisp-tools:human-bytes (* 5 1024 1024)))))

(test human-bytes-handles-nil
  "An unknown size does not crash the formatter"
  (is (string= "unknown" (cl-mcp-server.quicklisp-tools:human-bytes nil))))

;;; ==========================================================================
;;; collect-dependencies
;;; ==========================================================================

(test collect-dependencies-includes-root
  "The root system appears in its own closure"
  (when-ql
    (let ((names (cl-mcp-server.quicklisp-tools:collect-dependencies "cl-ppcre")))
      (is-true (member "cl-ppcre" names :test #'string-equal)))))

(test collect-dependencies-is-transitive
  "Indirect dependencies are reached, not just direct ones"
  (when-ql
    ;; drakma -> cl+ssl -> cffi -> babel : babel is not a direct requirement
    (let ((names (cl-mcp-server.quicklisp-tools:collect-dependencies "drakma")))
      (is-true (member "drakma" names :test #'string-equal))
      (is-true (member "babel" names :test #'string-equal))
      (is (> (length names) 5)))))

(test collect-dependencies-deduplicates
  "A diamond dependency is visited once"
  (when-ql
    (let ((names (cl-mcp-server.quicklisp-tools:collect-dependencies "drakma")))
      (is (= (length names)
             (length (remove-duplicates names :test #'string-equal)))))))

(test collect-dependencies-unknown-system
  "An unknown root is reported as unresolvable rather than erroring"
  (when-ql
    (multiple-value-bind (names unknown)
        (cl-mcp-server.quicklisp-tools:collect-dependencies
         "definitely-not-a-real-system-xyzzy")
      (is (null names))
      (is (= 1 (length unknown))))))

;;; ==========================================================================
;;; dry-run
;;; ==========================================================================

(test dry-run-finds-known-system
  "A real system resolves and reports a plausible tree"
  (when-ql
    (let ((info (cl-mcp-server.quicklisp-tools:ql-dry-run "cl-ppcre")))
      (is-true (getf info :found-p))
      (is (>= (getf info :total) 1)))))

(test dry-run-unknown-system
  "An unknown system is a clean miss, not an error"
  (when-ql
    (let ((info (cl-mcp-server.quicklisp-tools:ql-dry-run "no-such-system-xyzzy")))
      (is-false (getf info :found-p)))))

(test dry-run-accounting-is-consistent
  "present + missing accounts for every system in the tree"
  (when-ql
    (let* ((info (cl-mcp-server.quicklisp-tools:ql-dry-run "drakma"))
           (total (getf info :total))
           (present (getf info :present))
           (missing (length (getf info :missing))))
      (is (= total (+ present missing))))))

(test dry-run-installed-system-downloads-nothing
  "A fully installed system reports no downloads"
  (when-ql
    ;; cl-ppcre is a dependency of the MCP server itself, so it is installed.
    (let ((info (cl-mcp-server.quicklisp-tools:ql-dry-run "cl-ppcre")))
      (is (null (getf info :missing)))
      (is (zerop (or (getf info :download-bytes) 0))))))

(test dry-run-does-not-install
  "Dry run must not change what is installed -- that is its whole purpose"
  (when-ql
    (let ((before (cl-mcp-server.quicklisp-tools::system-installed-p "drakma")))
      (cl-mcp-server.quicklisp-tools:ql-dry-run "drakma")
      (is (eq before
              (cl-mcp-server.quicklisp-tools::system-installed-p "drakma"))))))

(test format-dry-run-miss-is-error
  "A miss reports error-p true and suggests search"
  (when-ql
    (multiple-value-bind (text error-p)
        (cl-mcp-server.quicklisp-tools:format-ql-dry-run
         (cl-mcp-server.quicklisp-tools:ql-dry-run "no-such-system-xyzzy"))
      (is-true error-p)
      (is (search "quicklisp-search" text)))))

(test format-dry-run-hit-is-not-error
  "A hit is not an error and names the system"
  (when-ql
    (multiple-value-bind (text error-p)
        (cl-mcp-server.quicklisp-tools:format-ql-dry-run
         (cl-mcp-server.quicklisp-tools:ql-dry-run "cl-ppcre"))
      (is-false error-p)
      (is (search "cl-ppcre" text)))))

;;; ==========================================================================
;;; system-info
;;; ==========================================================================

(test system-info-known-system
  "A known system reports its identity and dependencies"
  (when-ql
    (let ((info (cl-mcp-server.quicklisp-tools:ql-system-info "cl-ppcre")))
      (is-true (getf info :found-p))
      (is (string-equal "cl-ppcre" (getf info :name)))
      (is-true (getf info :installed-p)))))

(test system-info-reports-dependencies
  "Direct requirements are listed"
  (when-ql
    (let ((info (cl-mcp-server.quicklisp-tools:ql-system-info "drakma")))
      (is-true (member "cl-ppcre" (getf info :requires) :test #'string-equal)))))

(test system-info-requires-is-sorted
  "Requirements come back in a stable order"
  (when-ql
    (let ((req (getf (cl-mcp-server.quicklisp-tools:ql-system-info "drakma")
                     :requires)))
      (is (equal req (sort (copy-list req) #'string<))))))

(test system-info-unknown-system
  "An unknown system is a clean miss"
  (when-ql
    (is-false (getf (cl-mcp-server.quicklisp-tools:ql-system-info
                     "no-such-system-xyzzy")
                    :found-p))))

(test format-system-info-shows-install-state
  "Formatted output distinguishes installed from available"
  (when-ql
    (multiple-value-bind (text error-p)
        (cl-mcp-server.quicklisp-tools:format-ql-system-info
         (cl-mcp-server.quicklisp-tools:ql-system-info "cl-ppcre"))
      (is-false error-p)
      (is (search "installed" text)))))

(test format-system-info-miss-is-error
  "A miss reports error-p true"
  (when-ql
    (multiple-value-bind (text error-p)
        (cl-mcp-server.quicklisp-tools:format-ql-system-info
         (cl-mcp-server.quicklisp-tools:ql-system-info "no-such-system-xyzzy"))
      (declare (ignore text))
      (is-true error-p))))

;;; ==========================================================================
;;; search
;;; ==========================================================================

(test search-finds-known-system
  "Searching for a known name finds it"
  (when-ql
    (let* ((result (cl-mcp-server.quicklisp-tools:ql-search-systems "cl-ppcre"))
           (names (mapcar (lambda (e) (getf e :name)) (getf result :entries))))
      (is-true (member "cl-ppcre" names :test #'string-equal)))))

(test search-ranks-exact-match-first
  "An exact name match outranks its own subsystems"
  (when-ql
    (let* ((result (cl-mcp-server.quicklisp-tools:ql-search-systems "cl-ppcre"))
           (first-name (getf (first (getf result :entries)) :name)))
      (is (string-equal "cl-ppcre" first-name)))))

(test search-marks-install-state
  "Entries carry an install flag, which is what the old tool lacked"
  (when-ql
    (let* ((result (cl-mcp-server.quicklisp-tools:ql-search-systems "cl-ppcre"))
           (entry (find "cl-ppcre" (getf result :entries)
                        :key (lambda (e) (getf e :name)) :test #'string-equal)))
      (is-true entry)
      (is-true (getf entry :installed-p)))))

(test search-respects-limit
  "The limit caps the number of entries returned"
  (when-ql
    (let ((result (cl-mcp-server.quicklisp-tools:ql-search-systems "cl" :limit 3)))
      (is (<= (length (getf result :entries)) 3)))))

(test search-no-matches-is-error
  "A search with no hits reports error-p true"
  (when-ql
    (multiple-value-bind (text error-p)
        (cl-mcp-server.quicklisp-tools:format-ql-search-results
         (cl-mcp-server.quicklisp-tools:ql-search-systems "zzzz-no-such-thing-zzzz"))
      (declare (ignore text))
      (is-true error-p))))

;;; ==========================================================================
;;; who-depends-on
;;; ==========================================================================

(test who-depends-on-popular-library
  "A widely used library has dependents"
  (when-ql
    (let ((info (cl-mcp-server.quicklisp-tools:ql-who-depends-on "alexandria")))
      (is (> (getf info :total) 10)))))

(test who-depends-on-respects-limit
  "The limit caps the listing but not the reported total"
  (when-ql
    (let ((info (cl-mcp-server.quicklisp-tools:ql-who-depends-on
                 "alexandria" :limit 5)))
      (is (<= (length (getf info :users)) 5))
      (is (> (getf info :total) 5)))))

(test who-depends-on-unknown-is-not-error
  "An unknown system yields an empty list, not a failure"
  (when-ql
    (multiple-value-bind (text error-p)
        (cl-mcp-server.quicklisp-tools:format-ql-who-depends-on
         (cl-mcp-server.quicklisp-tools:ql-who-depends-on "no-such-system-xyzzy"))
      (is-false error-p)
      (is (search "Nothing in the dist" text)))))

;;; ==========================================================================
;;; dist-status
;;; ==========================================================================

(test dist-status-reports-a-dist
  "At least one enabled dist is described"
  (when-ql
    (let ((info (cl-mcp-server.quicklisp-tools:ql-dist-status)))
      (is-true (getf info :dists))
      (is-true (getf (first (getf info :dists)) :version)))))

(test dist-status-counts-are-plausible
  "Installed releases never exceed available systems"
  (when-ql
    (let ((d (first (getf (cl-mcp-server.quicklisp-tools:ql-dist-status) :dists))))
      (is (<= (getf d :installed-releases) (getf d :provided-systems))))))

(test format-dist-status-is-not-error
  "Status rendering always succeeds"
  (when-ql
    (multiple-value-bind (text error-p)
        (cl-mcp-server.quicklisp-tools:format-ql-dist-status
         (cl-mcp-server.quicklisp-tools:ql-dist-status))
      (is-false error-p)
      (is (search "Quicklisp" text)))))

;;; ==========================================================================
;;; Tool registration
;;; ==========================================================================

(test quicklisp-tools-registered
  "All five Quicklisp tools are exposed over MCP"
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (dolist (name '("quicklisp-dry-run" "quicklisp-system-info"
                    "quicklisp-search" "quicklisp-who-depends-on"
                    "quicklisp-dist-status"))
      (is (not (null (cl-mcp.tools:get-tool (test-server-registry server) name)))
          "tool ~A should be registered" name))))

(test quicklisp-search-tool-takes-term
  "The registered search tool is the new one (term), not the old one (pattern)"
  (multiple-value-bind (server session) (make-test-server)
    (declare (ignore session))
    (let* ((tool (cl-mcp.tools:get-tool (test-server-registry server)
                                        "quicklisp-search"))
           (schema (cl-mcp.tools:tool-input-schema tool))
           (required (cdr (assoc "required" schema :test #'string=))))
      (is (member "term" required :test #'string=)))))

(test quicklisp-dry-run-tool-call
  "Calling the dry-run tool reports download cost"
  (when-ql
    (multiple-value-bind (server session) (make-test-server)
      (declare (ignore session))
      (let ((text (call-test-tool server "quicklisp-dry-run"
                                  '(("system" . "cl-ppcre")))))
        (is (search "cl-ppcre" text))
        (is (search "dependency tree" text))))))

(test quicklisp-system-info-tool-call
  "Calling the info tool reports dependencies"
  (when-ql
    (multiple-value-bind (server session) (make-test-server)
      (declare (ignore session))
      (is (search "Requires" (call-test-tool server "quicklisp-system-info"
                                             '(("system" . "drakma"))))))))

(test quicklisp-dist-status-tool-call
  "Calling the status tool reports the dist"
  (when-ql
    (multiple-value-bind (server session) (make-test-server)
      (declare (ignore session))
      (is (search "Quicklisp" (call-test-tool server "quicklisp-dist-status" nil))))))

;;; tests/remote-config-tests.lisp
;;; ABOUTME: Tests for the armable-target allowlist

(in-package #:cl-mcp-server-tests)

(def-suite remote-config-tests
  :description "Allowlist file and environment precedence"
  :in cl-mcp-server-tests)

(in-suite remote-config-tests)

(defmacro with-config ((&key file env) &body body)
  "Run BODY with a temporary config FILE and environment override ENV.
FILE is written verbatim; NIL means no file exists. ENV is the value of
CL_MCP_ARMABLE_TARGETS; :unset means the variable is absent."
  `(let* ((dir (merge-pathnames
                (format nil "cl-mcp-test-~D/" (random 100000))
                #p"/tmp/"))
          (path (merge-pathnames "config.sexp" dir)))
     (unwind-protect
          (progn
            (ensure-directories-exist dir)
            (when ,file
              (with-open-file (s path :direction :output
                                      :if-exists :supersede)
                (write-string ,file s)))
            (let ((cl-mcp-server.remote-config::*config-path* path)
                  (cl-mcp-server.remote-config::*env-override*
                    ,(if (eq env :unset) nil env)))
              (cl-mcp-server.remote-config:reload-config)
              ,@body))
       (ignore-errors (uiop:delete-directory-tree
                       dir :validate t :if-does-not-exist :ignore)))))

(test no-config-means-nothing-is-armable
  "A missing file is not an error; it means nothing may be armed"
  (with-config (:file nil :env :unset)
    (is (null (cl-mcp-server.remote-config:armable-targets)))
    (is-false (cl-mcp-server.remote-config:armable-target-p "anything"))))

(test file-names-armable-targets
  (with-config (:file "(:armable-targets (\"scratch\" \"dev\"))" :env :unset)
    (is-true (cl-mcp-server.remote-config:armable-target-p "scratch"))
    (is-true (cl-mcp-server.remote-config:armable-target-p "dev"))
    (is-false (cl-mcp-server.remote-config:armable-target-p "prod"))))

(test env-replaces-file-entirely
  "Override REPLACES rather than merges: merge cannot express removal"
  (with-config (:file "(:armable-targets (\"scratch\"))" :env "other")
    (is-true (cl-mcp-server.remote-config:armable-target-p "other"))
    (is-false (cl-mcp-server.remote-config:armable-target-p "scratch"))))

(test empty-env-means-nothing-armable
  "The escape hatch: an empty override disables arming entirely"
  (with-config (:file "(:armable-targets (\"scratch\"))" :env "")
    (is (null (cl-mcp-server.remote-config:armable-targets)))))

(test env-list-is-comma-separated-and-trimmed
  (with-config (:file nil :env " a , b ,c ")
    (is (equal '("a" "b" "c")
               (cl-mcp-server.remote-config:armable-targets)))))

(test malformed-config-is-reported-not-swallowed
  "A config that fails to parse must not silently become one that permits
nothing: the two are indistinguishable to the user at the moment it matters"
  (signals cl-mcp-server.remote-config:config-error
    (with-config (:file "(:armable-targets (\"unclosed" :env :unset)
      nil)))

(test read-eval-is-disabled
  "#. in a config file would be arbitrary code execution at startup"
  (signals cl-mcp-server.remote-config:config-error
    (with-config (:file "(:armable-targets (#.(error \"pwned\")))"
                  :env :unset)
      nil)))

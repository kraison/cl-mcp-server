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
  "#. in a config file would be arbitrary code execution at startup.

The payload must SUCCEED if evaluated, not throw. With (error \"pwned\") the
test passed either way: *read-eval* nil makes the reader signal, and
*read-eval* t makes the payload itself signal, and both become a
config-error. A payload that quietly returns a value is the only version
that can tell the two worlds apart."
  (handler-case
      (with-config (:file "(:armable-targets (#.(cl:string 'cl-user::pwned)))"
                    :env :unset)
        ;; Reached only if #. was evaluated and produced a usable string,
        ;; i.e. read-eval executed code from the config file.
        (is-false (cl-mcp-server.remote-config:armable-target-p "PWNED")
                  "read-eval executed the payload in the config file"))
    (cl-mcp-server.remote-config:config-error ()
      ;; The expected path: the reader refused #. outright.
      (is-true t))))

(test blackboard-target-is-the-config-file-s-plist
  "The :blackboard key beside :armable-targets; both are read from the
one form, and the allowlist is unchanged by the second key"
  (with-config (:file "(:armable-targets (\"scratch\")
 :blackboard (:host \"127.0.0.1\" :port 1 :role \"claude-code\"))"
                :env :unset)
    (is-true (cl-mcp-server.remote-config:armable-target-p "scratch"))
    (is (equal '(:host "127.0.0.1" :port 1 :role "claude-code")
               (cl-mcp-server.remote-config:blackboard-target)))))

(test no-blackboard-key-means-no-blackboard-tools
  "Absent key, absent file: NIL, so nothing is loaded and nothing is
registered. The environment override does not reach this key."
  (with-config (:file "(:armable-targets (\"scratch\"))" :env "other")
    (is (null (cl-mcp-server.remote-config:blackboard-target))))
  (with-config (:file nil :env :unset)
    (is (null (cl-mcp-server.remote-config:blackboard-target)))))

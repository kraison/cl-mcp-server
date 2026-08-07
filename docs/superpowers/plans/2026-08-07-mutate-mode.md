# Mutate Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an agent redefine functions and change state on a running Lisp
service it owns, behind a gate that cannot be opened from inside the session.

**Architecture:** Permission moves from a hard-coded `case` to a table
mapping mode → permitted tiers, so a future mode is a new row. The single
`:mutate` tier splits into `:redefine` and `:state`. A target may only be
armed into `:developer` mode if a config file (overridable by an environment
variable) names it as armable.

**Tech Stack:** SBCL, ASDF, FiveAM, `cl-mcp`. No new dependencies.

## Global Constraints

- **80-column hard limit** on all Lisp code, comments, docstrings and strings.
- **Spaces only, never tabs.**
- Comments state the non-obvious fact briefly and point elsewhere; no essays.
- Canonical suite must stay green: `1223` checks before this work begins.
- Design spec: `docs/superpowers/specs/2026-08-07-mutate-mode-design.md`
- Read config with `*read-eval*` bound to `nil`.
- Do Lisp work through the `lisp` MCP tools; do not shell out to `sbcl`
  except to run the canonical suite.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `src/remote-config.lisp` | **New.** Reads the armable-targets allowlist from file and environment. Knows nothing about targets or tiers. |
| `src/remote.lisp` | Modified. Mode table, tier split, arm/disarm. |
| `src/tools.lisp` | Modified. `remote-arm`, `remote-disarm` tools; armed state in `remote-targets` and `remote-connect`. |
| `src/swank-protocol.lisp` | Modified. Distinguish "target terminated" from "timed out". |
| `tests/remote-config-tests.lisp` | **New.** Allowlist precedence and parsing. |
| `tests/remote-tests.lisp` | Modified. Mode table, tier split, arm/disarm. |
| `cl-mcp-server.asd` | Modified. Register both new files. |

`remote-config.lisp` is separate because it is the only part that touches
the filesystem and the environment, and it must be testable without a
target. It is loaded **before** `remote.lisp`.

---

### Task 1: The allowlist

**Files:**
- Create: `src/remote-config.lisp`
- Create: `tests/remote-config-tests.lisp`
- Modify: `src/packages.lisp` (add package, before `cl-mcp-server.remote`)
- Modify: `cl-mcp-server.asd` (add `remote-config` before `remote`;
  add `remote-config-tests` before `remote-tests`)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `(armable-target-p name)` → generalized boolean
  - `(armable-targets)` → list of strings
  - `(reload-config)` → list of strings, re-reads file and environment
  - `*config-path*` → default `~/.config/cl-mcp-server/config.sexp`
  - condition `config-error` with reader `config-error-detail`

- [ ] **Step 1: Write the failing tests**

Create `tests/remote-config-tests.lisp`:

```lisp
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
```

- [ ] **Step 2: Run tests to verify they fail**

```
sbcl --non-interactive \
  --eval '(ql:quickload :cl-mcp-server/tests :silent t)' \
  --eval '(asdf:test-system :cl-mcp-server)' 2>&1 | tail -20
```

Expected: FAIL — package `CL-MCP-SERVER.REMOTE-CONFIG` does not exist.

- [ ] **Step 3: Add the package**

In `src/packages.lisp`, immediately **before** `cl-mcp-server.remote`:

```lisp
(defpackage #:cl-mcp-server.remote-config
  (:use #:cl)
  (:export
   #:armable-target-p
   #:armable-targets
   #:reload-config
   #:config-error
   #:config-error-detail))
```

- [ ] **Step 4: Write the implementation**

Create `src/remote-config.lisp`:

```lisp
;;; src/remote-config.lisp
;;; ABOUTME: The allowlist of targets that may be armed for mutation

(in-package #:cl-mcp-server.remote-config)

;;; This is the gate a session cannot open for itself: a target may only be
;;; armed if it is named here, outside the session. See
;;; docs/reference/remote-swank.md.

(define-condition config-error (error)
  ((detail :initarg :detail :reader config-error-detail))
  (:report (lambda (c s)
             (format s "config: ~A" (config-error-detail c)))))

(defparameter *config-path*
  (merge-pathnames ".config/cl-mcp-server/config.sexp"
                   (user-homedir-pathname)))

(defparameter *env-override* nil
  "Value of CL_MCP_ARMABLE_TARGETS, or NIL when unset. Bound in tests.")

(defvar *armable* :unread
  "Cached allowlist, or :UNREAD before the first read.")

(defun %split-commas (text)
  (let ((out '()) (start 0))
    (loop for i from 0 to (length text)
          when (or (= i (length text)) (char= #\, (char text i)))
            do (let ((piece (string-trim '(#\Space #\Tab)
                                         (subseq text start i))))
                 (when (plusp (length piece)) (push piece out))
                 (setf start (1+ i))))
    (nreverse out)))

(defun %read-file (path)
  "Allowlist from PATH. Signals CONFIG-ERROR if it will not parse."
  (handler-case
      (with-open-file (in path :if-does-not-exist nil)
        (when in
          (let* ((*read-eval* nil)   ; #. would run code at startup
                 (form (read in nil nil)))
            (mapcar #'string (getf form :armable-targets)))))
    (config-error (e) (error e))
    (error (e)
      (error 'config-error
             :detail (format nil "~A is unreadable (~A)" path (type-of e))))))

(defun reload-config ()
  "Re-read the allowlist. The environment REPLACES the file."
  (setf *armable*
        (let ((env (or *env-override*
                       (sb-ext:posix-getenv "CL_MCP_ARMABLE_TARGETS"))))
          (if env
              (%split-commas env)
              (%read-file *config-path*)))))

(defun armable-targets ()
  (when (eq *armable* :unread) (reload-config))
  *armable*)

(defun armable-target-p (name)
  (and (member name (armable-targets) :test #'string=) t))
```

- [ ] **Step 5: Register both files**

In `cl-mcp-server.asd`, in `:components` of the main system, add
`(:file "remote-config")` immediately **before** `(:file "remote")`.

In the test system components, add `(:file "remote-config-tests")`
immediately **before** `(:file "remote-tests")`.

- [ ] **Step 6: Run tests to verify they pass**

```
sbcl --non-interactive \
  --eval '(ql:quickload :cl-mcp-server/tests :silent t)' \
  --eval '(asdf:test-system :cl-mcp-server)' 2>&1 | grep -E "Did |Pass:|Fail:"
```

Expected: PASS, with the check count above 1223 and `Fail: 0`.

- [ ] **Step 7: Verify the 80-column rule**

```
python3 tools/check-line-length.py src/remote-config.lisp \
  tests/remote-config-tests.lisp
```

Expected: `0 line(s) over 80 columns`. Fix any that appear.

- [ ] **Step 8: Commit**

```bash
git add src/remote-config.lisp tests/remote-config-tests.lisp \
        src/packages.lisp cl-mcp-server.asd
git commit -m "feat(remote): allowlist of targets that may be armed

The gate a session cannot open for itself. File at
~/.config/cl-mcp-server/config.sexp, replaced entirely by
CL_MCP_ARMABLE_TARGETS when set -- merge semantics cannot express removal.

Read with *read-eval* nil: #. in a config file would be arbitrary code
execution at startup. A missing file means nothing is armable; a malformed
one is an error rather than silently the same thing."
```

---

### Task 2: Modes as a table, and the tier split

**Files:**
- Modify: `src/remote.lisp` (replace `*mutating-operators*`,
  `classify-form`, `tier-allowed-p`)
- Modify: `tests/remote-tests.lisp` (append)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `*mode-permissions*` — alist of `(mode . (tier ...))`
  - `(tier-allowed-p target tier)` — unchanged signature
  - `classify-form` now returns `:redefine` or `:state` where it returned
    `:mutate`; `:observe`, `:read` and `:lifecycle` are unchanged
  - `*redefining-operators*`, `*state-operators*` replace
    `*mutating-operators*`

- [ ] **Step 1: Write the failing tests**

Append to `tests/remote-tests.lisp`:

```lisp
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
```

- [ ] **Step 2: Run tests to verify they fail**

```
sbcl --non-interactive \
  --eval '(ql:quickload :cl-mcp-server/tests :silent t)' \
  --eval '(asdf:test-system :cl-mcp-server)' 2>&1 | grep -E "Fail:"
```

Expected: FAIL — `:redefine` is not yet a tier, so these classify as
`:mutate` and `tier-allowed-p` returns NIL for it.

- [ ] **Step 3: Replace the operator lists**

In `src/remote.lisp`, replace the whole `*mutating-operators*` defparameter
with these two:

```lisp
(defparameter *redefining-operators*
  '("DEFUN" "DEFMACRO" "DEFMETHOD" "DEFGENERIC" "ADD-METHOD"
    "REMOVE-METHOD")
  "Redefinition: recoverable by evaluating the previous definition.")

(defparameter *state-operators*
  '("SETF" "SETQ" "PSETF" "PSETQ" "INCF" "DECF" "PUSH" "POP" "PUSHNEW"
    "REMHASH" "CLRHASH" "SET" "MAKUNBOUND" "FMAKUNBOUND"
    "ROTATEF" "SHIFTF" "REPLACE" "FILL" "SORT" "NREVERSE" "NCONC"
    "DELETE" "CHANGE-CLASS" "TRACE" "UNTRACE"
    ;; Syntactically definitions, but not recoverable by re-evaluating the
    ;; previous form: redefining a class obsoletes live instances, DEFVAR
    ;; and friends alter global bindings, LOAD can do anything.
    "DEFCLASS" "DEFSTRUCT" "DEFVAR" "DEFPARAMETER" "DEFCONSTANT"
    "LOAD" "COMPILE-FILE" "REQUIRE")
  "State change: usually no inverse. SORT, DELETE, NCONC and NREVERSE are
destructive in CL and read as innocent.")
```

- [ ] **Step 4: Update `classify-form`**

In `src/remote.lisp`, replace the single `*mutating-operators*` clause in
`classify-form` with two clauses, keeping the surrounding clauses as they
are. `:state` is tested **before** `:redefine` so that a form doing both is
classified by its least recoverable part:

```lisp
      ((%mentions upper *state-operators*)
       (values :state (format nil "state operator ~A"
                              (%mentions upper *state-operators*))))
      ((%mentions upper *redefining-operators*)
       (values :redefine (format nil "redefining operator ~A"
                                 (%mentions upper *redefining-operators*))))
```

- [ ] **Step 5: Replace `tier-allowed-p` with a table**

In `src/remote.lisp`, replace the whole `tier-allowed-p` defun with:

```lisp
(defparameter *mode-permissions*
  '((:observe    . (:observe))
    (:read       . (:observe :read :inspect-registry))
    (:developer  . (:observe :read :inspect-registry
                    :redefine :state :lifecycle)))
  "Mode to permitted tiers. Modes are roles, not rungs: a future
:prod-maintenance clears a cache but must never redefine, so it is not a
subset of :developer. Adding a mode is adding a row.")

(defun tier-allowed-p (target tier)
  "Is TIER permitted by TARGET's mode? Default-deny: an unknown mode or
tier permits nothing."
  (and (member tier (cdr (assoc (target-mode target) *mode-permissions*)))
       t))
```

- [ ] **Step 6: Update the tiering comment block**

In `src/remote.lisp`, replace the `T2 mutate` line of the header comment
above `*lifecycle-operators*` with:

```lisp
;;; T2 redefine  defun/defmethod: recoverable by redefining back
;;; T2 state     setf/clrhash/load: usually no inverse
```

- [ ] **Step 7: Run tests to verify they pass**

```
sbcl --non-interactive \
  --eval '(ql:quickload :cl-mcp-server/tests :silent t)' \
  --eval '(asdf:test-system :cl-mcp-server)' 2>&1 | grep -E "Did |Pass:|Fail:"
```

Expected: PASS, `Fail: 0`. Existing tests that assert `:mutate` will need
updating to `:state` — that is expected and correct.

- [ ] **Step 8: Verify 80 columns and commit**

```bash
python3 tools/check-line-length.py src/remote.lisp tests/remote-tests.lisp
git add src/remote.lisp tests/remote-tests.lisp
git commit -m "refactor(remote): modes as a table, :mutate splits in two

tier-allowed-p was a case with permissions smeared across five branches.
Modes are roles rather than rungs -- a future :prod-maintenance clears a
cache but must never defun, so it is not a subset of :developer -- so the
permission becomes a table and a new mode is a new row.

:mutate splits into :redefine and :state. Code can be redefined back; state
usually cannot, and the ledger should say which a session did. defclass,
defstruct, defvar and load classify as :state despite their syntax: none is
recoverable by re-evaluating the previous form.

:state is tested before :redefine so a form doing both is named by its least
recoverable part."
```

---

### Task 3: Arm and disarm

**Files:**
- Modify: `src/remote.lisp` (target struct, arm/disarm functions)
- Modify: `src/packages.lisp` (export the new functions)
- Modify: `tests/remote-tests.lisp` (append)

**Interfaces:**
- Consumes: `armable-target-p` from Task 1; `*mode-permissions*` from Task 2.
- Produces:
  - `(arm-target name &optional reason)` → `(values target-or-nil message)`
  - `(disarm-target name)` → `(values target-or-nil message)`
  - `(target-armed-p target)` → generalized boolean
  - `target-pre-arm-mode` slot accessor

- [ ] **Step 1: Write the failing tests**

Append to `tests/remote-tests.lisp`:

```lisp
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
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `ARM-TARGET` is undefined.

- [ ] **Step 3: Add the slot**

In `src/remote.lisp`, replace the `target` defstruct with:

```lisp
(defstruct (target (:conc-name target-))
  name host port
  (mode :observe)           ; :observe | :read | :developer
  (pre-arm-mode nil)        ; mode to restore on disarm; NIL when unarmed
  (max-print-length 200)
  (max-print-level 5))
```

- [ ] **Step 4: Write arm and disarm**

In `src/remote.lisp`, after `close-connection`:

```lisp
;;; ==========================================================================
;;; Arming
;;;
;;; Mutation is off until a target is armed, and a target may only be armed
;;; if it is allowlisted outside the session. There is no expiry: an armed
;;; target stays armed until disarmed, which is why the tools make armed
;;; state loud. See docs/reference/remote-swank.md.
;;; ==========================================================================

(defun target-armed-p (target)
  (and (target-pre-arm-mode target) t))

(defun arm-target (name &optional reason)
  "Put NAME into :developer mode. Returns (values target message)."
  (let ((target (find-target name)))
    (cond
      ((not (cl-mcp-server.remote-config:armable-target-p name))
       (record name :arm "" :refused
               (format nil "~A is not armable" name))
       (values nil
               (format nil "Target ~A is not armable.~%~%Add it to ~
~~/.config/cl-mcp-server/config.sexp:~%  (:armable-targets (~S))~%~%~
or set CL_MCP_ARMABLE_TARGETS. The allowlist lives outside the session ~
deliberately." name name)))
      ((target-armed-p target)
       (values target (format nil "~A is already armed." name)))
      (t
       (setf (target-pre-arm-mode target) (target-mode target)
             (target-mode target) :developer)
       (record name :arm "" :armed reason)
       (values target
               (format nil "~A is ARMED for development.~%~%Redefinition, ~
state changes and lifecycle forms are now permitted. It stays armed until ~
you call remote-disarm.~@[~%~%Reason: ~A~]" name reason))))))

(defun disarm-target (name)
  "Restore NAME's pre-arm mode. Returns (values target message)."
  (let ((target (find-target name)))
    (if (not (target-armed-p target))
        (values target (format nil "~A is not armed." name))
        (let ((restored (target-pre-arm-mode target)))
          (setf (target-mode target) restored
                (target-pre-arm-mode target) nil)
          (record name :disarm "" :disarmed
                  (format nil "restored ~(~A~) mode" restored))
          (values target
                  (format nil "~A disarmed; back to ~(~A~) mode."
                          name restored))))))
```

- [ ] **Step 5: Export them**

In `src/packages.lisp`, add to the `cl-mcp-server.remote` `:export` list:

```lisp
   #:arm-target
   #:disarm-target
   #:target-armed-p
```

- [ ] **Step 6: Run tests to verify they pass**

Expected: PASS, `Fail: 0`.

- [ ] **Step 7: Verify 80 columns and commit**

```bash
python3 tools/check-line-length.py src/remote.lisp tests/remote-tests.lisp
git add src/remote.lisp src/packages.lisp tests/remote-tests.lisp
git commit -m "feat(remote): arm and disarm a target for development

Mutation stays off until a target is armed, and arming is refused unless the
target is allowlisted outside the session -- that is the gate the agent
cannot open for itself.

Disarm restores the mode the target had BEFORE arming, not :read. A target
registered in :observe that came back as :read would be more permissive than
it started: privilege escalation disguised as cleanup. Arming twice is
idempotent and does not overwrite the stored mode.

Both are ledger events, with the reason recorded verbatim."
```

---

### Task 4: The tools

**Files:**
- Modify: `src/tools.lisp` (two new tools; armed state in two existing ones)
- Modify: `tests/remote-tests.lisp` (append)

**Interfaces:**
- Consumes: `arm-target`, `disarm-target`, `target-armed-p` from Task 3.
- Produces: MCP tools `remote-arm` and `remote-disarm`. Tool count goes
  from 61 to 63.

- [ ] **Step 1: Write the failing tests**

Append to `tests/remote-tests.lisp`:

```lisp
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
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — tool `remote-arm` is not registered.

- [ ] **Step 3: Register the tools**

In `src/tools.lisp`, immediately after the `remote-disconnect`
registration:

```lisp
  (cl-mcp:register-tool server "remote-arm"
   :description "Arm a target for development: permits redefinition, state changes and lifecycle forms on a RUNNING service. Refused unless the target is allowlisted in ~/.config/cl-mcp-server/config.sexp or CL_MCP_ARMABLE_TARGETS -- the allowlist lives outside the session so a session cannot escalate itself. There is NO expiry: the target stays armed until remote-disarm. Use only on a service you own and are actively developing."
   :schema '(("type" . "object")
             ("required" . ("target"))
             ("properties" . (("target" . (("type" . "string")
                                           ("description" . "Registered target name")))
                              ("reason" . (("type" . "string")
                                           ("description" . "Why, recorded verbatim in the ledger"))))))
   :handler (lambda (args)
              (flet ((arg (k) (cdr (assoc k args :test #'string=))))
                (multiple-value-bind (target message)
                    (cl-mcp-server.remote:arm-target (arg "target")
                                                     (arg "reason"))
                  (values message (null target))))))

  (cl-mcp:register-tool server "remote-disarm"
   :description "Disarm a target, restoring the mode it had before arming. Call this when finished developing against a live service."
   :schema '(("type" . "object")
             ("required" . ("target"))
             ("properties" . (("target" . (("type" . "string")
                                           ("description" . "Target name"))))))
   :handler (lambda (args)
              (multiple-value-bind (target message)
                  (cl-mcp-server.remote:disarm-target
                   (cdr (assoc "target" args :test #'string=)))
                (declare (ignore target))
                message)))
```

- [ ] **Step 4: Make armed state visible in `remote-targets`**

In `src/tools.lisp`, in the `remote-targets` handler, replace the line that
formats each target with:

```lisp
                          (format s "  ~A~30T~A:~D  ~(~A~)~:[~; [ARMED]~]~%"
                                  (cl-mcp-server.remote:target-name tg)
                                  (cl-mcp-server.remote:target-host tg)
                                  (cl-mcp-server.remote:target-port tg)
                                  (cl-mcp-server.remote:target-mode tg)
                                  (cl-mcp-server.remote:target-armed-p tg))
```

- [ ] **Step 5: Report armed state on reconnect**

In `src/tools.lisp`, in the `remote-connect` handler, append to the success
message so a reconnect to an armed target says so. Replace the
`"Mutating and lifecycle forms will be refused."` literal with:

```lisp
                                 (if (cl-mcp-server.remote:target-armed-p
                                      (cl-mcp-server.remote::find-target
                                       name))
                                     "This target is ARMED: mutation ~
is permitted."
                                     "Mutating and lifecycle forms will ~
be refused.")
```

- [ ] **Step 6: Run tests to verify they pass**

Expected: PASS, `Fail: 0`.

- [ ] **Step 7: Commit**

```bash
python3 tools/check-line-length.py src/remote.lisp tests/remote-tests.lisp
git add src/tools.lisp tests/remote-tests.lisp
git commit -m "feat(remote): remote-arm and remote-disarm tools

61 tools to 63. Because there is no expiry, armed state has to be loud:
remote-targets marks it, and remote-connect says so on reconnect."
```

---

### Task 5: Terminated is not timed out

**Files:**
- Modify: `src/swank-protocol.lisp`
- Modify: `src/remote.lisp` (pass the tier to the error path)
- Modify: `tests/remote-tests.lisp` (append)

**Interfaces:**
- Consumes: `classify-form` from Task 2.
- Produces: `remote-eval` returns a `:terminated` outcome when a lifecycle
  form is followed by the connection dropping.

- [ ] **Step 1: Write the failing test**

Append to `tests/remote-tests.lisp`:

```lisp
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
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `SESSION-ENDING-FORM-P` is undefined.

- [ ] **Step 3: Implement**

In `src/remote.lisp`, next to `classify-form`:

```lisp
(defparameter *session-ending-operators*
  '("QUIT" "EXIT" "SB-EXT:QUIT" "SB-EXT:EXIT" "SB-EXT:SAVE-LISP-AND-DIE")
  "Lifecycle operators that end the SWANK session. TERMINATE-THREAD and
DELETE-PACKAGE are lifecycle but leave the connection usable.")

(defun session-ending-form-p (form-string)
  (and (%mentions (string-upcase form-string) *session-ending-operators*) t))
```

In `remote.lisp`, in the `handler-case` around the `rex` call inside
`remote-eval`, add a clause **before** the existing generic error clause:

```lisp
      (cl-mcp-server.swank-protocol:swank-error (e)
        (if (session-ending-form-p form)
            (progn
              (close-connection target-name)
              (record target-name tier form :terminated)
              (list :ok t :tier tier
                    :result (format nil "Target ~A terminated, as ~
instructed. The connection is closed." target-name)))
            (progn
              (record target-name tier form :error (princ-to-string e))
              (list :ok nil :tier tier :error (princ-to-string e)))))
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS, `Fail: 0`.

- [ ] **Step 5: Commit**

```bash
python3 tools/check-line-length.py src/remote.lisp tests/remote-tests.lisp
git add src/remote.lisp src/swank-protocol.lisp tests/remote-tests.lisp
git commit -m "fix(remote): a killed target reads as terminated, not timed out

Killing a target surfaced as 'no reply within 30s' -- a timeout that reads
like a hang when it is in fact success. Now that :developer permits
lifecycle forms, that message would be actively misleading.

Only quit, exit and save-lisp-and-die end the session; terminate-thread and
delete-package leave the connection usable and keep the old handling."
```

---

### Task 6: Live verification and docs

**Files:**
- Modify: `docs/reference/remote-swank.md`
- Modify: `README.md`, `CLAUDE.md`,
  `.claude/skills/integration/SKILL.md`,
  `.claude/skills/integration/references/tools-reference.md`,
  `.claude/skills/dev/SKILL.md`, `src/tools.lisp` (usage guide)

**Interfaces:**
- Consumes: everything above.
- Produces: no code interfaces.

- [ ] **Step 1: Start a throwaway target**

```bash
cd ~/work/graph-utils
SWANK_PORT=4010 sbcl --load ~/bin/boot-graph-utils.lisp < /dev/null &
sleep 25 && lsof -nP -iTCP:4010 -sTCP:LISTEN
```

Expected: one LISTEN line.

- [ ] **Step 2: Verify the gate holds and then opens**

Run the MCP server with `CL_MCP_ARMABLE_TARGETS=scratch` and, over stdio:
connect `scratch` to port 4010; call `remote-eval` with
`(defun probe-fn () :before)` and expect a **refusal**; call `remote-arm`;
call the same `remote-eval` and expect success; then confirm from the
service that the definition took, by evaluating `(probe-fn)` and expecting
`:BEFORE`.

Asserting on the arm tool's success message proves nothing — the service's
own answer is the evidence.

- [ ] **Step 3: Verify disarm closes the gate**

Call `remote-disarm`, then `remote-eval` with `(defun probe-fn () :after)`
and expect a refusal. Confirm `remote-targets` no longer shows `[ARMED]`.

- [ ] **Step 4: Verify the terminated message, last**

Re-arm, then `remote-eval` `(sb-ext:quit)`. Expect a result containing
`terminated, as instructed` and **not** `no reply within`. Confirm port
4010 has no listener afterwards.

This is destructive and therefore last; it is what a throwaway target is
for.

- [ ] **Step 5: Mutation-test the gate**

Temporarily change `*mode-permissions*` to grant `:redefine` to `:read`,
run the suite, and confirm `REDEFINE-IS-REFUSED-IN-READ-MODE` fails.
Restore. Then make `armable-target-p` always return T, run the suite, and
confirm `ARMING-IS-REFUSED-WHEN-NOT-ALLOWLISTED` fails. Restore and
confirm `git diff` is empty for those files.

A gate that no test defends is not a gate.

- [ ] **Step 6: Update the docs**

In `docs/reference/remote-swank.md`: add `remote-arm` and `remote-disarm` to
the tool table; add a section covering the mode table, the
`:redefine`/`:state` split, the allowlist with both layers, and the absence
of expiry; replace the "No mutate mode" limitation with the honest
remaining ones (the classifier still cannot see through macros; redefinition
is not atomic under live traffic; a well-formed mistake is undetectable).

In `README.md`, `CLAUDE.md`, both skill files and the in-image usage guide:
add the two tools and update the tool count from 61 to 63.

- [ ] **Step 7: Verify the docs match reality**

```
grep -rn "61 tools" README.md .claude docs || echo "no stale counts"
```

Expected: `no stale counts`. Then confirm `tools/list` over MCP returns 63.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "docs: mutate mode, the allowlist and the arming gate

Verified against a live target: the gate refuses a defun, arming opens it,
the SERVICE confirms the new definition, disarm closes it again, and a
killed target reports terminated rather than timed out.

Replaces the 'No mutate mode' limitation with the ones that remain: the
classifier still cannot see through a macro, redefinition is not atomic
under live traffic, and a well-formed mistake is undetectable."
```

---

## Self-Review

**Spec coverage.** §1 modes-as-table → Task 2. §2 tier split → Task 2. §3
arm/disarm, no clock, disconnect does not disarm, idempotent arm → Task 3.
§4 allowlist, file and env, `*read-eval*` nil, malformed is an error → Task
1. §5 visibility → Task 4. §6 lifecycle UX → Task 5. Testing section →
Tasks 1–5 plus Task 6 steps 2–5. Every spec section maps to a task.

**Placeholders.** None: every step carries the code or the exact command.

**Type consistency.** `armable-target-p` is used in Task 3 exactly as
Task 1 defines it. `target-armed-p` is defined in Task 3 and consumed in
Task 4. `session-ending-form-p` is defined and consumed in Task 5.
`classify-form` returns `:redefine`/`:state` from Task 2 onward, and
`*mode-permissions*` uses those same keywords.

**One gap found and closed:** the spec says disconnect does not disarm, but
no task tested it. Task 3 covers arm/disarm state transitions;
`close-connection` never touches `pre-arm-mode`, so the property holds by
construction. Noted rather than adding a test that asserts an absence.

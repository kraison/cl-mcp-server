# cl-mcp Extraction — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extract MCP protocol infrastructure from cl-mcp-server into a standalone cl-mcp library at `../cl-mcp`.

**Architecture:** Configurable server object with per-instance tool registry. Handlers take `(args)` only, closing over consumer state. Server normalizes handler results (string or content-block list) to MCP wire format.

**Tech Stack:** Common Lisp, SBCL, ASDF, yason, opsis/conditions, FiveAM (tests)

**Design Doc:** `docs/plans/2026-02-25-cl-mcp-extraction.md`

---

## Phase 1: Create cl-mcp

### Task 1: Project skeleton

**Files:**
- Create: `../cl-mcp/cl-mcp.asd`
- Create: `../cl-mcp/src/packages.lisp`

**Step 1: Create directory structure**

```bash
mkdir -p ../cl-mcp/src ../cl-mcp/tests
```

**Step 2: Write the ASDF system definition**

Create `../cl-mcp/cl-mcp.asd`:

```lisp
;;; cl-mcp.asd
;;; ABOUTME: ASDF system definition for cl-mcp

(asdf:defsystem #:cl-mcp
  :description "Model Context Protocol server framework for Common Lisp"
  :author "Abhijit Rao <quasi@quasilabs.com>"
  :license "MIT"
  :version "0.1.0"
  :serial t
  :depends-on (#:yason
               #:opsis/conditions)
  :components ((:module "src"
                :components
                ((:file "packages")
                 (:file "conditions")
                 (:file "json-rpc")
                 (:file "transport")
                 (:file "tools")
                 (:file "server"))))
  :in-order-to ((asdf:test-op (asdf:test-op #:cl-mcp/tests))))

(asdf:defsystem #:cl-mcp/tests
  :description "Tests for cl-mcp"
  :depends-on (#:cl-mcp
               #:fiveam)
  :components ((:module "tests"
                :components
                ((:file "packages")
                 (:file "conditions-tests")
                 (:file "json-rpc-tests")
                 (:file "encoding-tests")
                 (:file "transport-tests")
                 (:file "tools-tests")
                 (:file "server-tests"))))
  :perform (asdf:test-op (o c)
             (uiop:symbol-call :fiveam :run! :cl-mcp-tests)))
```

**Step 3: Write packages.lisp**

Create `../cl-mcp/src/packages.lisp`:

```lisp
;;; src/packages.lisp
;;; ABOUTME: Package definitions for cl-mcp

(defpackage #:cl-mcp.conditions
  (:use #:cl)
  (:shadow #:parse-error)
  (:export
   ;; Condition types
   #:mcp-error
   #:json-rpc-error
   #:parse-error
   #:invalid-request
   #:method-not-found
   #:invalid-params
   #:internal-error
   ;; Condition accessors
   #:error-code
   #:error-message
   #:error-data))

(defpackage #:cl-mcp.json-rpc
  (:use #:cl #:cl-mcp.conditions)
  (:shadowing-import-from #:cl-mcp.conditions #:parse-error)
  (:export
   ;; Message types
   #:json-rpc-request
   #:json-rpc-response
   ;; Accessors
   #:request-id
   #:request-method
   #:request-params
   #:response-id
   #:response-result
   #:response-error
   ;; Constructors
   #:make-request
   #:make-notification
   #:notification-p
   #:make-success-response
   #:make-error-response
   ;; Functions
   #:parse-message
   #:encode-response
   #:encode-error
   ;; Utilities
   #:convert-for-json
   #:json-object-p))

(defpackage #:cl-mcp.transport
  (:use #:cl #:cl-mcp.json-rpc)
  (:export
   #:read-message
   #:write-message
   #:with-stdio-transport))

(defpackage #:cl-mcp.tools
  (:use #:cl #:cl-mcp.conditions)
  (:shadowing-import-from #:cl-mcp.conditions #:parse-error)
  (:export
   ;; Tool definition
   #:tool-definition
   #:tool-name
   #:tool-description
   #:tool-input-schema
   #:tool-handler
   #:make-tool-definition
   ;; Registry functions (all take registry as first arg)
   #:register-tool
   #:get-tool
   #:list-tools
   #:tools-for-mcp
   #:call-tool
   #:validate-tool-args))

(defpackage #:cl-mcp
  (:use #:cl
        #:cl-mcp.conditions
        #:cl-mcp.json-rpc
        #:cl-mcp.transport)
  (:shadowing-import-from #:cl-mcp.conditions #:parse-error)
  (:export
   ;; Server
   #:mcp-server
   #:make-server
   #:mcp-server-name
   #:mcp-server-version
   #:mcp-server-protocol-version
   ;; Public API
   #:register-tool
   #:run-server
   ;; Re-export conditions for consumer convenience
   #:mcp-error
   #:json-rpc-error
   #:parse-error
   #:invalid-request
   #:method-not-found
   #:invalid-params
   #:internal-error
   #:error-code
   #:error-message
   #:error-data))
```

**Step 4: Verify it loads (will fail — source files missing, but packages should define)**

```bash
sbcl --load ../cl-mcp/cl-mcp.asd --eval "(asdf:load-system :cl-mcp)" --quit
```

Expected: Fails because source files don't exist yet. But confirms .asd is parseable.

**Step 5: Commit**

```bash
cd ../cl-mcp && git init && git add cl-mcp.asd src/packages.lisp
git commit -m "feat: project skeleton with ASDF system and packages"
```

---

### Task 2: Conditions

**Files:**
- Create: `../cl-mcp/src/conditions.lisp`
- Create: `../cl-mcp/tests/packages.lisp`
- Create: `../cl-mcp/tests/conditions-tests.lisp`

**Step 1: Write conditions.lisp**

Copy from `cl-mcp-server/src/conditions.lisp`, change package to `cl-mcp.conditions`, and remove `evaluation-timeout` (REPL-specific — stays in cl-mcp-server).

```lisp
;;; src/conditions.lisp
;;; ABOUTME: JSON-RPC 2.0 condition definitions

(in-package #:cl-mcp.conditions)

;;; Base condition

(define-condition mcp-error (error)
  ((message :initarg :message :reader error-message :initform ""))
  (:report (lambda (c s)
             (format s "MCP error: ~A" (error-message c))))
  (:documentation "Base condition for MCP errors"))

;;; JSON-RPC 2.0 standard error conditions

(define-condition json-rpc-error (mcp-error)
  ((code :reader error-code :initform 0 :allocation :class)
   (data :initarg :data :reader error-data :initform nil))
  (:report (lambda (c s)
             (format s "JSON-RPC error ~D: ~A" (error-code c) (error-message c))))
  (:documentation "Base condition for JSON-RPC errors"))

(define-condition parse-error (json-rpc-error)
  ((code :initform -32700 :allocation :class))
  (:report (lambda (c s)
             (format s "Parse error: ~a" (error-message c))))
  (:documentation "Invalid JSON was received"))

(define-condition invalid-request (json-rpc-error)
  ((code :initform -32600 :allocation :class))
  (:report (lambda (c s)
             (format s "Invalid Request: ~a" (error-message c))))
  (:documentation "The JSON sent is not a valid Request object"))

(define-condition method-not-found (json-rpc-error)
  ((code :initform -32601 :allocation :class))
  (:report (lambda (c s)
             (format s "Method not found: ~a" (error-message c))))
  (:documentation "The method does not exist / is not available"))

(define-condition invalid-params (json-rpc-error)
  ((code :initform -32602 :allocation :class))
  (:report (lambda (c s)
             (format s "Invalid params: ~a" (error-message c))))
  (:documentation "Invalid method parameter(s)"))

(define-condition internal-error (json-rpc-error)
  ((code :initform -32603 :allocation :class))
  (:report (lambda (c s)
             (format s "Internal error: ~a" (error-message c))))
  (:documentation "Internal JSON-RPC error"))
```

**Step 2: Write test packages**

Create `../cl-mcp/tests/packages.lisp`:

```lisp
;;; tests/packages.lisp
;;; ABOUTME: Test package definitions for cl-mcp

(defpackage #:cl-mcp-tests
  (:use #:cl #:fiveam)
  (:export #:run-tests))

(in-package #:cl-mcp-tests)

(def-suite cl-mcp-tests
  :description "All tests for cl-mcp")

(defun run-tests ()
  "Run all cl-mcp tests."
  (run! 'cl-mcp-tests))
```

**Step 3: Write conditions tests**

Create `../cl-mcp/tests/conditions-tests.lisp`. Adapted from `cl-mcp-server/tests/conditions-tests.lisp` with package references updated:

```lisp
;;; tests/conditions-tests.lisp
;;; ABOUTME: Tests for JSON-RPC condition types

(in-package #:cl-mcp-tests)

(def-suite conditions-tests
  :description "Condition type tests"
  :in cl-mcp-tests)

(in-suite conditions-tests)

(test json-rpc-error-codes
  "JSON-RPC error conditions have correct codes"
  (is (= -32700 (cl-mcp.conditions:error-code
                  (make-condition 'cl-mcp.conditions:parse-error))))
  (is (= -32600 (cl-mcp.conditions:error-code
                  (make-condition 'cl-mcp.conditions:invalid-request))))
  (is (= -32601 (cl-mcp.conditions:error-code
                  (make-condition 'cl-mcp.conditions:method-not-found))))
  (is (= -32602 (cl-mcp.conditions:error-code
                  (make-condition 'cl-mcp.conditions:invalid-params))))
  (is (= -32603 (cl-mcp.conditions:error-code
                  (make-condition 'cl-mcp.conditions:internal-error)))))

(test json-rpc-error-messages
  "JSON-RPC error conditions have messages"
  (let ((err (make-condition 'cl-mcp.conditions:method-not-found
                             :message "Method foo not found")))
    (is (string= "Method foo not found"
                 (cl-mcp.conditions:error-message err)))))

(test condition-hierarchy
  "Conditions have correct inheritance"
  (is (typep (make-condition 'cl-mcp.conditions:parse-error)
             'cl-mcp.conditions:json-rpc-error))
  (is (typep (make-condition 'cl-mcp.conditions:json-rpc-error)
             'cl-mcp.conditions:mcp-error))
  (is (typep (make-condition 'cl-mcp.conditions:mcp-error)
             'error)))
```

**Step 4: Run tests**

```bash
sbcl --load ../cl-mcp/cl-mcp.asd \
     --eval "(ql:quickload :cl-mcp/tests)" \
     --eval "(fiveam:run! :cl-mcp-tests)" \
     --quit
```

Expected: All conditions tests PASS.

**Step 5: Commit**

```bash
cd ../cl-mcp && git add src/conditions.lisp tests/packages.lisp tests/conditions-tests.lisp
git commit -m "feat: JSON-RPC condition types with tests"
```

---

### Task 3: JSON-RPC

**Files:**
- Create: `../cl-mcp/src/json-rpc.lisp`
- Create: `../cl-mcp/tests/json-rpc-tests.lisp`
- Create: `../cl-mcp/tests/encoding-tests.lisp`

**Step 1: Write json-rpc.lisp**

Copy from `cl-mcp-server/src/json-rpc.lisp`, change package to `cl-mcp.json-rpc`. Code is identical except the `(in-package)` line.

```lisp
;;; src/json-rpc.lisp
;;; ABOUTME: JSON-RPC 2.0 message parsing and encoding

(in-package #:cl-mcp.json-rpc)
```

Then the rest of the file is identical to `cl-mcp-server/src/json-rpc.lisp` lines 7-148.

**Step 2: Write json-rpc tests**

Adapt `cl-mcp-server/tests/json-rpc-tests.lisp`: change package references from `cl-mcp-server.json-rpc` to `cl-mcp.json-rpc`, from `cl-mcp-server.conditions` to `cl-mcp.conditions`, suite parent to `cl-mcp-tests`.

**Step 3: Write encoding tests**

Adapt `cl-mcp-server/tests/encoding-tests.lisp`: same package reference changes.

**Step 4: Run tests**

```bash
sbcl --load ../cl-mcp/cl-mcp.asd \
     --eval "(ql:quickload :cl-mcp/tests)" \
     --eval "(fiveam:run! :cl-mcp-tests)" \
     --quit
```

Expected: All conditions + json-rpc + encoding tests PASS.

**Step 5: Commit**

```bash
cd ../cl-mcp && git add src/json-rpc.lisp tests/json-rpc-tests.lisp tests/encoding-tests.lisp
git commit -m "feat: JSON-RPC 2.0 parsing and encoding with tests"
```

---

### Task 4: Transport

**Files:**
- Create: `../cl-mcp/src/transport.lisp`
- Create: `../cl-mcp/tests/transport-tests.lisp`

**Step 1: Write transport.lisp**

Copy from `cl-mcp-server/src/transport.lisp`, change package to `cl-mcp.transport`, update internal references from `cl-mcp-server.json-rpc` to `cl-mcp.json-rpc`.

```lisp
;;; src/transport.lisp
;;; ABOUTME: Stdio transport for MCP communication

(in-package #:cl-mcp.transport)

(defun read-message (&optional (stream *standard-input*))
  "Read a single JSON-RPC message from stream.
   Messages are newline-delimited JSON (NDJSON).
   Returns nil on EOF, json-rpc-request on success.
   Signals parse-error or invalid-request on bad input.
   Skips empty lines while waiting for content."
  (loop
    (let ((line (read-line stream nil nil)))
      (unless line
        (return nil))
      (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
        (unless (zerop (length trimmed))
          (return (cl-mcp.json-rpc:parse-message trimmed)))))))

(defun write-message (response &optional (stream *standard-output*))
  "Write a JSON-RPC response to stream with newline delimiter."
  (write-string (cl-mcp.json-rpc:encode-response response) stream)
  (write-char #\Newline stream)
  (force-output stream))

(defmacro with-stdio-transport ((&key (input '*standard-input*)
                                      (output '*standard-output*))
                                &body body)
  "Execute body with stdio transport bindings."
  `(let ((*standard-input* ,input)
         (*standard-output* ,output))
     ,@body))
```

**Step 2: Write transport tests**

Adapt `cl-mcp-server/tests/transport-tests.lisp`: change `cl-mcp-server.transport` to `cl-mcp.transport`, `cl-mcp-server.json-rpc` to `cl-mcp.json-rpc`, suite parent to `cl-mcp-tests`.

**Step 3: Run tests, commit**

```bash
sbcl --load ../cl-mcp/cl-mcp.asd \
     --eval "(ql:quickload :cl-mcp/tests)" \
     --eval "(fiveam:run! :cl-mcp-tests)" \
     --quit
```

```bash
cd ../cl-mcp && git add src/transport.lisp tests/transport-tests.lisp
git commit -m "feat: stdio transport with tests"
```

---

### Task 5: Tool registry

**Files:**
- Create: `../cl-mcp/src/tools.lisp`
- Create: `../cl-mcp/tests/tools-tests.lisp`

**Step 1: Write tools.lisp**

This is the registry mechanism only. Key differences from cl-mcp-server's tools.lisp:
- No global `*tools*` — all functions take a `registry` hash table as first arg
- `call-tool` handler signature is `(args)` not `(args session)`
- No `define-builtin-tools`, no tool implementations
- Result normalization: string or content-block list

```lisp
;;; src/tools.lisp
;;; ABOUTME: MCP tool registry and dispatch

(in-package #:cl-mcp.tools)

;;; Tool Definition Structure

(defstruct (tool-definition (:conc-name tool-))
  "Definition of an MCP tool"
  (name "" :type string)
  (description "" :type string)
  (input-schema nil :type list)
  (handler nil :type (or function null)))

;;; Registry Functions
;;; All take a registry (hash-table) as first argument.
;;; No global state.

(defun register-tool (registry name description input-schema handler)
  "Register a tool in REGISTRY.
HANDLER is a function of (arguments) returning a string or content-block list."
  (setf (gethash name registry)
        (make-tool-definition
         :name name
         :description description
         :input-schema input-schema
         :handler handler)))

(defun get-tool (registry name)
  "Get a tool definition by NAME from REGISTRY. Returns nil if not found."
  (gethash name registry))

(defun list-tools (registry)
  "Return a list of all tool definitions in REGISTRY."
  (loop for tool being the hash-values of registry
        collect tool))

(defun tools-for-mcp (registry)
  "Format all tools in REGISTRY for MCP tools/list response."
  (loop for tool being the hash-values of registry
        collect `(("name" . ,(tool-name tool))
                  ("description" . ,(tool-description tool))
                  ("inputSchema" . ,(tool-input-schema tool)))))

;;; Argument Validation

(defun validate-tool-args (args schema)
  "Validate ARGS against the tool's input SCHEMA.
Signals INVALID-PARAMS if required arguments are missing."
  (let ((required (cdr (assoc "required" schema :test #'string=))))
    (dolist (req-name required)
      (unless (assoc req-name args :test #'string=)
        (error 'invalid-params
               :message (format nil "Missing required argument: ~a" req-name)))))
  t)

;;; Result Normalization

(defun content-block-list-p (result)
  "Return T if RESULT looks like a list of MCP content blocks.
A content block is an alist with at least a \"type\" key."
  (and (listp result)
       (consp (first result))
       (listp (first result))
       (assoc "type" (first result) :test #'string=)))

(defun normalize-tool-result (result)
  "Normalize a handler result to MCP content format.
If RESULT is a string, wrap in a single text content block.
If RESULT is a list of content blocks, use as-is."
  (if (stringp result)
      `((("type" . "text") ("text" . ,result)))
      (if (content-block-list-p result)
          result
          ;; Fallback: coerce to string
          `((("type" . "text") ("text" . ,(princ-to-string result)))))))

;;; Tool Calling

(defun call-tool (registry name args)
  "Call tool NAME with ARGS from REGISTRY.
Signals METHOD-NOT-FOUND if the tool doesn't exist.
Signals INVALID-PARAMS if required arguments are missing.
Returns normalized content blocks."
  (let ((tool (get-tool registry name)))
    (unless tool
      (error 'method-not-found
             :message (format nil "Tool not found: ~a" name)))
    (validate-tool-args args (tool-input-schema tool))
    (let ((result (funcall (tool-handler tool) args)))
      (normalize-tool-result result))))
```

**Step 2: Write tools tests**

```lisp
;;; tests/tools-tests.lisp
;;; ABOUTME: Tests for tool registry and dispatch

(in-package #:cl-mcp-tests)

(def-suite tools-tests
  :description "Tool registry tests"
  :in cl-mcp-tests)

(in-suite tools-tests)

;;; Registry tests

(test register-and-get-tool
  "Register a tool and retrieve it"
  (let ((registry (make-hash-table :test #'equal)))
    (cl-mcp.tools:register-tool registry "echo" "Echo input"
                                 '(("type" . "object")
                                   ("required" . ("text"))
                                   ("properties" . (("text" . (("type" . "string"))))))
                                 (lambda (args)
                                   (cdr (assoc "text" args :test #'string=))))
    (let ((tool (cl-mcp.tools:get-tool registry "echo")))
      (is (not (null tool)))
      (is (string= "echo" (cl-mcp.tools:tool-name tool)))
      (is (string= "Echo input" (cl-mcp.tools:tool-description tool))))))

(test get-tool-unknown-returns-nil
  "Unknown tool returns nil"
  (let ((registry (make-hash-table :test #'equal)))
    (is (null (cl-mcp.tools:get-tool registry "nonexistent")))))

(test list-tools-returns-all
  "List all registered tools"
  (let ((registry (make-hash-table :test #'equal)))
    (cl-mcp.tools:register-tool registry "a" "Tool A" nil (lambda (args) (declare (ignore args)) "a"))
    (cl-mcp.tools:register-tool registry "b" "Tool B" nil (lambda (args) (declare (ignore args)) "b"))
    (is (= 2 (length (cl-mcp.tools:list-tools registry))))))

(test tools-for-mcp-format
  "tools-for-mcp returns correct alist format"
  (let ((registry (make-hash-table :test #'equal)))
    (cl-mcp.tools:register-tool registry "echo" "Echo" '(("type" . "object")) (lambda (args) (declare (ignore args)) ""))
    (let ((mcp-tools (cl-mcp.tools:tools-for-mcp registry)))
      (is (= 1 (length mcp-tools)))
      (let ((tool (first mcp-tools)))
        (is (string= "echo" (cdr (assoc "name" tool :test #'string=))))
        (is (string= "Echo" (cdr (assoc "description" tool :test #'string=))))
        (is (assoc "inputSchema" tool :test #'string=))))))

;;; Validation tests

(test validate-args-passes-when-present
  "Validation passes when required args are present"
  (is (cl-mcp.tools:validate-tool-args
       '(("code" . "(+ 1 2)"))
       '(("type" . "object") ("required" . ("code"))))))

(test validate-args-signals-on-missing
  "Validation signals invalid-params for missing required args"
  (signals cl-mcp.conditions:invalid-params
    (cl-mcp.tools:validate-tool-args
     '()
     '(("type" . "object") ("required" . ("code"))))))

;;; Call tests

(test call-tool-dispatches-to-handler
  "call-tool dispatches to registered handler"
  (let ((registry (make-hash-table :test #'equal)))
    (cl-mcp.tools:register-tool registry "echo" "Echo"
                                 '(("type" . "object")
                                   ("required" . ("text"))
                                   ("properties" . (("text" . (("type" . "string"))))))
                                 (lambda (args)
                                   (cdr (assoc "text" args :test #'string=))))
    (let ((result (cl-mcp.tools:call-tool registry "echo" '(("text" . "hello")))))
      ;; String result gets normalized to content blocks
      (is (listp result))
      (is (string= "text" (cdr (assoc "type" (first result) :test #'string=))))
      (is (string= "hello" (cdr (assoc "text" (first result) :test #'string=)))))))

(test call-tool-unknown-signals-error
  "call-tool signals method-not-found for unknown tool"
  (let ((registry (make-hash-table :test #'equal)))
    (signals cl-mcp.conditions:method-not-found
      (cl-mcp.tools:call-tool registry "nonexistent" nil))))

(test call-tool-missing-args-signals-error
  "call-tool signals invalid-params for missing required args"
  (let ((registry (make-hash-table :test #'equal)))
    (cl-mcp.tools:register-tool registry "echo" "Echo"
                                 '(("type" . "object") ("required" . ("text")))
                                 (lambda (args) (declare (ignore args)) ""))
    (signals cl-mcp.conditions:invalid-params
      (cl-mcp.tools:call-tool registry "echo" nil))))

;;; Result normalization tests

(test result-string-normalized-to-content-block
  "String result becomes a text content block"
  (let ((registry (make-hash-table :test #'equal)))
    (cl-mcp.tools:register-tool registry "test" "Test" nil
                                 (lambda (args) (declare (ignore args)) "hello world"))
    (let ((result (cl-mcp.tools:call-tool registry "test" nil)))
      (is (= 1 (length result)))
      (is (string= "text" (cdr (assoc "type" (first result) :test #'string=))))
      (is (string= "hello world" (cdr (assoc "text" (first result) :test #'string=)))))))

(test result-content-blocks-passed-through
  "Content block list is passed through directly"
  (let ((registry (make-hash-table :test #'equal)))
    (cl-mcp.tools:register-tool registry "test" "Test" nil
                                 (lambda (args)
                                   (declare (ignore args))
                                   '((("type" . "text") ("text" . "first"))
                                     (("type" . "text") ("text" . "second")))))
    (let ((result (cl-mcp.tools:call-tool registry "test" nil)))
      (is (= 2 (length result)))
      (is (string= "first" (cdr (assoc "text" (first result) :test #'string=))))
      (is (string= "second" (cdr (assoc "text" (second result) :test #'string=)))))))

;;; Per-server isolation test

(test registries-are-independent
  "Tools registered in one registry don't appear in another"
  (let ((reg-a (make-hash-table :test #'equal))
        (reg-b (make-hash-table :test #'equal)))
    (cl-mcp.tools:register-tool reg-a "only-in-a" "A" nil (lambda (args) (declare (ignore args)) ""))
    (is (not (null (cl-mcp.tools:get-tool reg-a "only-in-a"))))
    (is (null (cl-mcp.tools:get-tool reg-b "only-in-a")))))
```

**Step 3: Run tests, commit**

```bash
sbcl --load ../cl-mcp/cl-mcp.asd \
     --eval "(ql:quickload :cl-mcp/tests)" \
     --eval "(fiveam:run! :cl-mcp-tests)" \
     --quit
```

```bash
cd ../cl-mcp && git add src/tools.lisp tests/tools-tests.lisp
git commit -m "feat: per-server tool registry with result normalization"
```

---

### Task 6: Server

**Files:**
- Create: `../cl-mcp/src/server.lisp`
- Create: `../cl-mcp/tests/server-tests.lisp`

**Step 1: Write server.lisp**

```lisp
;;; src/server.lisp
;;; ABOUTME: MCP server — configurable object with protocol dispatch

(in-package #:cl-mcp)

;;; Server Structure

(defstruct (mcp-server (:conc-name mcp-server-))
  "An MCP server instance with its own tool registry."
  (name "mcp-server" :type string)
  (version "0.1.0" :type string)
  (protocol-version "2025-06-18" :type string)
  (tools (make-hash-table :test #'equal)))

(defun make-server (&key (name "mcp-server") (version "0.1.0"))
  "Create an MCP server instance with its own tool registry."
  (make-mcp-server :name name :version version))

;;; Public API

(defun register-tool (server name &key description schema handler)
  "Register a tool on SERVER's registry.
HANDLER is (lambda (arguments) ...) returning a string or content-block list."
  (cl-mcp.tools:register-tool
   (mcp-server-tools server) name
   (or description "") (or schema '(("type" . "object"))) handler))

;;; Internal MCP Handlers

(defun %handle-initialize (server id)
  "Handle the initialize request."
  (let ((empty-obj (make-hash-table :test #'equal)))
    (make-success-response
     :id id
     :result `(("protocolVersion" . ,(mcp-server-protocol-version server))
               ("serverInfo" . (("name" . ,(mcp-server-name server))
                                ("version" . ,(mcp-server-version server))))
               ("capabilities" . (("tools" . ,empty-obj)))))))

(defun %handle-tools-list (server id)
  "Handle the tools/list request."
  (make-success-response
   :id id
   :result `(("tools" . ,(cl-mcp.tools:tools-for-mcp
                           (mcp-server-tools server))))))

(defun %handle-tools-call (server id params)
  "Handle the tools/call request."
  (let ((name (cdr (assoc "name" params :test #'string=)))
        (arguments (cdr (assoc "arguments" params :test #'string=))))
    (handler-case
        (let ((content (cl-mcp.tools:call-tool
                        (mcp-server-tools server) name arguments)))
          (make-success-response
           :id id
           :result `(("content" . ,content))))
      (method-not-found (c)
        (make-error-response
         :id id
         :code (error-code c)
         :message (error-message c)))
      (invalid-params (c)
        (make-error-response
         :id id
         :code (error-code c)
         :message (error-message c))))))

;;; Request Dispatcher

(defun %handle-request (server request)
  "Dispatch a JSON-RPC request. Returns nil for notifications."
  (when (notification-p request)
    (return-from %handle-request nil))
  (let ((id (request-id request))
        (method (request-method request))
        (params (request-params request))
        (source (mcp-server-name server)))
    (handler-case
        (cond
          ((string= method "initialize")
           (%handle-initialize server id))
          ((string= method "tools/list")
           (%handle-tools-list server id))
          ((string= method "tools/call")
           (%handle-tools-call server id params))
          (t
           (error 'method-not-found
                  :message (format nil "Method not found: ~a" method))))
      (method-not-found (c)
        (make-error-response
         :id id
         :code (error-code c)
         :message (error-message c)))
      (invalid-params (c)
        (make-error-response
         :id id
         :code (error-code c)
         :message (error-message c)))
      (error (c)
        (opsis/c:emit :request-failed :source source :level :error
                      :message (princ-to-string c)
                      :data (list :method method))
        (make-error-response
         :id id
         :code -32603
         :message (format nil "Internal error: ~a" c))))))

;;; Server Main Loop

(defun run-server (server &key (input *standard-input*) (output *standard-output*))
  "Run the MCP server loop. Blocks until EOF on INPUT.
Handles MCP handshake, tool dispatch, and error recovery.
Emits opsis events at protocol lifecycle points."
  (let ((source (mcp-server-name server)))
    (opsis/c:emit :server-started :source source :level :info
                  :message "MCP server ready")
    (loop
      (handler-case
          (let ((request (read-message input)))
            (unless request
              (opsis/c:emit :server-stopped :source source :level :info
                            :message "EOF received")
              (return))
            (opsis/c:emit :request-received :source source
                          :data (list :method (request-method request)))
            (let ((response (%handle-request server request)))
              (when response
                (write-message response output))))
        (json-rpc-error (c)
          (opsis/c:emit :request-failed :source source :level :error
                        :message (princ-to-string c))
          (write-message
           (make-error-response
            :id nil
            :code (error-code c)
            :message (error-message c))
           output))
        (error (c)
          (opsis/c:emit :request-failed :source source :level :error
                        :message (princ-to-string c))
          (write-message
           (make-error-response
            :id nil
            :code -32603
            :message (format nil "Internal error: ~a" c))
           output))))))
```

**Step 2: Write server tests**

```lisp
;;; tests/server-tests.lisp
;;; ABOUTME: Tests for MCP server protocol dispatch

(in-package #:cl-mcp-tests)

(def-suite server-tests
  :description "MCP server tests"
  :in cl-mcp-tests)

(in-suite server-tests)

;;; Helpers

(defun make-test-server ()
  "Create a server with a simple echo tool for testing."
  (let ((server (cl-mcp:make-server :name "test-server" :version "0.1.0")))
    (cl-mcp:register-tool server "echo"
      :description "Echo the input text"
      :schema '(("type" . "object")
                ("required" . ("text"))
                ("properties" . (("text" . (("type" . "string")
                                            ("description" . "Text to echo"))))))
      :handler (lambda (args)
                 (cdr (assoc "text" args :test #'string=))))
    server))

(defun send-json (server json-string)
  "Send a JSON string to server and return the response JSON string."
  (let ((input (make-string-input-stream (format nil "~a~%" json-string)))
        (output (make-string-output-stream)))
    (cl-mcp:run-server server :input input :output output)
    (string-trim '(#\Newline #\Space) (get-output-stream-string output))))

(defun parse-response (json-string)
  "Parse a JSON response string to an alist."
  (yason:parse json-string :object-as :alist))

;;; Initialize tests

(test server-initialize
  "Server responds to initialize with server info"
  (let* ((server (make-test-server))
         (response-json (send-json server
                          "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"))
         (response (parse-response response-json)))
    (is (string= "2.0" (cdr (assoc "jsonrpc" response :test #'string=))))
    (is (= 1 (cdr (assoc "id" response :test #'string=))))
    (let ((result (cdr (assoc "result" response :test #'string=))))
      (is (assoc "serverInfo" result :test #'string=))
      (is (assoc "capabilities" result :test #'string=))
      (is (assoc "protocolVersion" result :test #'string=))
      (let ((info (cdr (assoc "serverInfo" result :test #'string=))))
        (is (string= "test-server" (cdr (assoc "name" info :test #'string=))))
        (is (string= "0.1.0" (cdr (assoc "version" info :test #'string=))))))))

;;; Tools/list tests

(test server-tools-list
  "Server responds to tools/list with registered tools"
  (let* ((server (make-test-server))
         (response-json (send-json server
                          "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}"))
         (response (parse-response response-json)))
    (let* ((result (cdr (assoc "result" response :test #'string=)))
           (tools (cdr (assoc "tools" result :test #'string=))))
      (is (= 1 (length tools)))
      (let ((tool (first tools)))
        (is (string= "echo" (cdr (assoc "name" tool :test #'string=))))))))

;;; Tools/call tests

(test server-tools-call
  "Server dispatches tools/call to handler"
  (let* ((server (make-test-server))
         (response-json (send-json server
                          "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hello\"}}}"))
         (response (parse-response response-json)))
    (is (null (assoc "error" response :test #'string=)))
    (let* ((result (cdr (assoc "result" response :test #'string=)))
           (content (cdr (assoc "content" result :test #'string=)))
           (block (first content)))
      (is (string= "text" (cdr (assoc "type" block :test #'string=))))
      (is (string= "hello" (cdr (assoc "text" block :test #'string=)))))))

(test server-tools-call-unknown
  "Server returns error for unknown tool"
  (let* ((server (make-test-server))
         (response-json (send-json server
                          "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"nonexistent\",\"arguments\":{}}}"))
         (response (parse-response response-json)))
    (let ((err (cdr (assoc "error" response :test #'string=))))
      (is (not (null err)))
      (is (= -32601 (cdr (assoc "code" err :test #'string=)))))))

(test server-tools-call-missing-args
  "Server returns error for missing required args"
  (let* ((server (make-test-server))
         (response-json (send-json server
                          "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{}}}"))
         (response (parse-response response-json)))
    (let ((err (cdr (assoc "error" response :test #'string=))))
      (is (not (null err)))
      (is (= -32602 (cdr (assoc "code" err :test #'string=)))))))

;;; Unknown method test

(test server-unknown-method
  "Server returns error for unknown method"
  (let* ((server (make-test-server))
         (response-json (send-json server
                          "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"unknown/method\",\"params\":{}}"))
         (response (parse-response response-json)))
    (let ((err (cdr (assoc "error" response :test #'string=))))
      (is (not (null err)))
      (is (= -32601 (cdr (assoc "code" err :test #'string=)))))))

;;; Notification test

(test server-notification-no-response
  "Notifications produce no response"
  (let* ((server (make-test-server))
         ;; Send notification then a normal request (to get one response line)
         (input (make-string-input-stream
                 (format nil "~a~%~a~%"
                         "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
                         "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}")))
         (output (make-string-output-stream)))
    (cl-mcp:run-server server :input input :output output)
    (let* ((output-str (get-output-stream-string output))
           (lines (remove "" (uiop:split-string output-str :separator '(#\Newline))
                          :test #'string=)))
      ;; Only 1 response (for initialize), not 2
      (is (= 1 (length lines))))))

;;; Error recovery test

(test server-survives-handler-error
  "Server continues after handler error"
  (let ((server (cl-mcp:make-server :name "test" :version "0.1.0")))
    (cl-mcp:register-tool server "boom"
      :description "Always errors"
      :schema '(("type" . "object"))
      :handler (lambda (args) (declare (ignore args)) (error "kaboom")))
    (cl-mcp:register-tool server "ok"
      :description "Always works"
      :schema '(("type" . "object"))
      :handler (lambda (args) (declare (ignore args)) "fine"))
    (let ((input (make-string-input-stream
                  (format nil "~a~%~a~%"
                          "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"boom\",\"arguments\":{}}}"
                          "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"ok\",\"arguments\":{}}}")))
          (output (make-string-output-stream)))
      (cl-mcp:run-server server :input input :output output)
      (let* ((output-str (get-output-stream-string output))
             (lines (remove "" (uiop:split-string output-str :separator '(#\Newline))
                            :test #'string=)))
        ;; Both requests get responses
        (is (= 2 (length lines)))
        ;; First is error, second is success
        (let ((resp1 (yason:parse (first lines) :object-as :alist))
              (resp2 (yason:parse (second lines) :object-as :alist)))
          (is (not (null (assoc "error" resp1 :test #'string=))))
          (is (null (assoc "error" resp2 :test #'string=))))))))

;;; Full session test

(test server-full-session
  "Full MCP session: initialize → notification → tools/list → tools/call"
  (let ((server (make-test-server)))
    (let ((input (make-string-input-stream
                  (format nil "~{~a~%~}"
                          '("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
                            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
                            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}"
                            "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hello\"}}}"))))
          (output (make-string-output-stream)))
      (cl-mcp:run-server server :input input :output output)
      (let* ((output-str (get-output-stream-string output))
             (lines (remove "" (uiop:split-string output-str :separator '(#\Newline))
                            :test #'string=)))
        ;; 3 responses: initialize, tools/list, tools/call
        ;; Notification produces no response
        (is (= 3 (length lines)))))))
```

**Step 3: Run tests, commit**

```bash
sbcl --load ../cl-mcp/cl-mcp.asd \
     --eval "(ql:quickload :cl-mcp/tests)" \
     --eval "(fiveam:run! :cl-mcp-tests)" \
     --quit
```

Expected: All tests PASS.

```bash
cd ../cl-mcp && git add src/server.lisp tests/server-tests.lisp
git commit -m "feat: MCP server with protocol dispatch and opsis observability"
```

---

### Task 7: Documentation

**Files:**
- Create: `../cl-mcp/CLAUDE.md`
- Create: `../cl-mcp/AGENT.md`

**Step 1: Write CLAUDE.md**

Minimal pointer to AGENT.md with quick reference commands.

**Step 2: Write AGENT.md**

Cover: what the project does, build/test commands, code conventions (same as cl-mcp-server — ABOUTME comments, naming conventions), API reference, architecture rules (request-response guarantee, server stability), testing strategy.

**Step 3: Commit**

```bash
cd ../cl-mcp && git add CLAUDE.md AGENT.md
git commit -m "docs: add CLAUDE.md and AGENT.md"
```

---

## Phase 2: Update cl-mcp-server

### Task 8: Update cl-mcp-server dependencies

**Files:**
- Modify: `cl-mcp-server.asd`

**Step 1: Update .asd**

Replace `yason` and `opsis/conditions` with `cl-mcp`. Remove the three moved source files from components. Keep `conditions` entry but rename to a new file for `evaluation-timeout` only.

The `.asd` `:depends-on` becomes:

```lisp
:depends-on (#:cl-mcp            ; MCP protocol framework
             #:alexandria        ; Utilities
             #:bordeaux-threads  ; Threading (future)
             #:trivial-backtrace) ; Portable backtraces
```

Components remove: `conditions`, `json-rpc`, `transport`. Keep a new `conditions` file for `evaluation-timeout`.

**Step 2: Commit**

```bash
git add cl-mcp-server.asd
git commit -m "refactor: depend on cl-mcp instead of raw protocol deps"
```

---

### Task 9: Update cl-mcp-server packages

**Files:**
- Modify: `src/packages.lisp`

**Step 1: Update packages**

- Remove `cl-mcp-server.conditions` package definition entirely
- Remove `cl-mcp-server.json-rpc` package definition entirely
- Remove `cl-mcp-server.transport` package definition entirely
- Add a new small package `cl-mcp-server.conditions` that only defines `evaluation-timeout` and `:use`s `cl-mcp.conditions` for the base types
- Update all other packages: replace `:use #:cl-mcp-server.conditions` with `:use #:cl-mcp.conditions`, replace `:use #:cl-mcp-server.json-rpc` with `:use #:cl-mcp.json-rpc`, etc.
- The `cl-mcp-server.tools` package no longer needs to export registry functions (they live in cl-mcp now)
- The `cl-mcp-server` main package `:use`s `cl-mcp` instead of the old sub-packages

**Step 2: Commit**

```bash
git add src/packages.lisp
git commit -m "refactor: update packages to use cl-mcp"
```

---

### Task 10: Remove moved source files and update conditions

**Files:**
- Delete: `src/conditions.lisp` (replaced by cl-mcp.conditions + slim evaluation-timeout file)
- Delete: `src/json-rpc.lisp`
- Delete: `src/transport.lisp`
- Create: `src/conditions.lisp` (new, slim — only `evaluation-timeout`)

**Step 1: Rewrite conditions.lisp**

Only `evaluation-timeout` remains — it's REPL-specific:

```lisp
;;; src/conditions.lisp
;;; ABOUTME: REPL-specific condition definitions (extends cl-mcp.conditions)

(in-package #:cl-mcp-server.conditions)

(define-condition evaluation-timeout (cl-mcp.conditions:mcp-error)
  ((timeout-seconds
    :initarg :timeout-seconds
    :reader timeout-seconds
    :documentation "The timeout duration that was exceeded")
   (backtrace
    :initarg :backtrace
    :reader timeout-backtrace
    :initform nil
    :documentation "Stack trace captured at timeout"))
  (:report (lambda (c s)
             (format s "Evaluation exceeded ~A second timeout~@[~%~%Backtrace:~%~A~]"
                     (timeout-seconds c)
                     (timeout-backtrace c))))
  (:documentation "Signaled when code evaluation exceeds the configured timeout"))
```

**Step 2: Delete moved files**

```bash
git rm src/json-rpc.lisp src/transport.lisp
git add src/conditions.lisp
git commit -m "refactor: remove protocol files moved to cl-mcp, slim down conditions"
```

---

### Task 11: Refactor tools.lisp

**Files:**
- Modify: `src/tools.lisp`

**Step 1: Remove registry mechanism**

Remove from `src/tools.lisp`:
- `tool-definition` struct
- `*tools*` global variable
- `register-tool`, `get-tool`, `list-tools`, `tools-for-mcp` functions
- `validate-tool-args`, `call-tool` functions

Keep:
- `define-builtin-tools` — but refactor to take `(server session)` and use `cl-mcp:register-tool`
- All individual tool registrations — but change handler signatures from `(args session)` to `(args)`, closing over `session`
- Helper functions like `get-usage-guide-content`

**Step 2: Update handler signatures**

Every `(lambda (args session) ...)` becomes `(lambda (args) ...)`, with `session` captured from the outer `define-builtin-tools` argument.

Example — evaluate-lisp before:
```lisp
(lambda (args session)
  (let* ((code (cdr (assoc "code" args :test #'string=)))
         ...)
    (when (and session (result-definitions result)) ...)
    (format-result result)))
```

After:
```lisp
(lambda (args)
  (let* ((code (cdr (assoc "code" args :test #'string=)))
         ...)
    (when (result-definitions result)
      (setf (session-definitions session) ...))
    (format-result result)))
```

Every `(register-tool "name" "desc" schema handler)` becomes `(cl-mcp:register-tool server "name" :description "desc" :schema schema :handler handler)`.

**Step 3: Remove `(define-builtin-tools)` call at file end**

The call moves to `server.lisp` / `start` function.

**Step 4: Run tests to check compilation**

```bash
sbcl --load cl-mcp-server.asd \
     --eval "(ql:quickload :cl-mcp-server)" \
     --quit
```

**Step 5: Commit**

```bash
git add src/tools.lisp
git commit -m "refactor: tools.lisp uses cl-mcp registry, closures over session"
```

---

### Task 12: Refactor server.lisp

**Files:**
- Modify: `src/server.lisp`

**Step 1: Rewrite server.lisp**

The entire protocol dispatch moves to cl-mcp. This file becomes thin glue:

```lisp
;;; src/server.lisp
;;; ABOUTME: CL-MCP-Server entry point — REPL tools over MCP

(in-package #:cl-mcp-server)

(defun start ()
  "Start the CL REPL MCP server. Reads from stdin, writes to stdout."
  (let ((server (cl-mcp:make-server :name "cl-mcp-server" :version "0.3.0"))
        (session (make-session)))
    (with-session (session)
      (define-builtin-tools server session)
      (cl-mcp:run-server server))))
```

Remove: `*server-info*`, `*protocol-version*`, `*server-session*`, `handle-initialize`, `handle-tools-list`, `handle-tools-call`, `handle-request`, `run-server`.

**Note:** The `cl-mcp-server` package still exports `start` and `run-server`. If `run-server` is used externally (e.g., in tests), provide a thin wrapper or update call sites. Check `run-server.lisp` and integration tests.

**Step 2: Update run-server.lisp if needed**

`run-server.lisp` calls `(funcall (find-symbol "START" "CL-MCP-SERVER"))` — this still works since `start` is still exported.

**Step 3: Commit**

```bash
git add src/server.lisp
git commit -m "refactor: server.lisp is now thin glue over cl-mcp"
```

---

### Task 13: Update remaining source references

**Files:**
- Modify: `src/introspection.lisp` — change `cl-mcp-server.conditions:invalid-params` to `cl-mcp.conditions:invalid-params`
- Modify: `src/profiling-tools.lisp` — same change
- Modify: `src/error-format.lisp` — verify no broken references
- Modify: any other file referencing old package names

**Step 1: Find and replace all old package references**

In all `src/*.lisp` files:
- `cl-mcp-server.conditions:` → `cl-mcp.conditions:` (except for `evaluation-timeout` and `timeout-seconds`, `timeout-backtrace` which stay in `cl-mcp-server.conditions`)
- `cl-mcp-server.json-rpc:` → `cl-mcp.json-rpc:`
- `cl-mcp-server.transport:` → `cl-mcp.transport:`

**Step 2: Verify compilation**

```bash
sbcl --load cl-mcp-server.asd \
     --eval "(ql:quickload :cl-mcp-server)" \
     --quit
```

**Step 3: Commit**

```bash
git add src/introspection.lisp src/profiling-tools.lisp
git commit -m "refactor: update condition references to cl-mcp.conditions"
```

---

### Task 14: Update tests

**Files:**
- Delete: `tests/conditions-tests.lisp` (moved to cl-mcp)
- Delete: `tests/json-rpc-tests.lisp` (moved to cl-mcp)
- Delete: `tests/encoding-tests.lisp` (moved to cl-mcp)
- Delete: `tests/transport-tests.lisp` (moved to cl-mcp)
- Modify: `tests/packages.lisp` — remove suite references if needed
- Modify: `tests/tools-tests.lisp` — remove registry tests (now in cl-mcp), keep REPL tool tests, update package refs
- Modify: `tests/integration-tests.lisp` — update to use `cl-mcp` server API, update package refs
- Modify: `tests/session-tests.lisp` — update condition references
- Modify: `cl-mcp-server.asd` — remove deleted test files from components

**Step 1: Remove moved test files**

```bash
git rm tests/conditions-tests.lisp tests/json-rpc-tests.lisp tests/encoding-tests.lisp tests/transport-tests.lisp
```

**Step 2: Update remaining test files**

Replace all `cl-mcp-server.conditions:` with `cl-mcp.conditions:` (except `evaluation-timeout`).
Replace all `cl-mcp-server.json-rpc:` with `cl-mcp.json-rpc:`.
Replace all `cl-mcp-server.transport:` with `cl-mcp.transport:`.
Replace all `cl-mcp-server.tools:tool-name` etc. with `cl-mcp.tools:tool-name` for registry accessors.

Update integration tests to work with the new server API — the `cl-mcp-server::handle-initialize` etc. internal functions no longer exist. These tests should either:
- Test through `cl-mcp:run-server` (full stack), or
- Test the REPL tool registrations directly

**Step 3: Update .asd test components**

Remove the four deleted test files from the components list.

**Step 4: Run full test suite**

```bash
sbcl --load cl-mcp-server.asd \
     --eval "(ql:quickload :cl-mcp-server/tests)" \
     --eval "(asdf:test-system :cl-mcp-server)" \
     --quit
```

Expected: All remaining tests PASS.

**Step 5: Commit**

```bash
git add tests/ cl-mcp-server.asd
git commit -m "refactor: update tests for cl-mcp extraction"
```

---

### Task 15: Final verification

**Step 1: Run cl-mcp tests**

```bash
cd ../cl-mcp
sbcl --load cl-mcp.asd \
     --eval "(ql:quickload :cl-mcp/tests)" \
     --eval "(asdf:test-system :cl-mcp)" \
     --quit
```

**Step 2: Run cl-mcp-server tests**

```bash
cd ../cl-mcp-server
sbcl --load cl-mcp-server.asd \
     --eval "(ql:quickload :cl-mcp-server/tests)" \
     --eval "(asdf:test-system :cl-mcp-server)" \
     --quit
```

**Step 3: Verify run-server.lisp still works**

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | sbcl --script run-server.lisp
```

Expected: JSON response with server info.

**Step 4: Create beads issues for deferred work**

```bash
bd create --title="cl-mcp: enforce MCP protocol state machine" --type=feature --priority=3
bd create --title="cl-mcp: transport abstraction for non-stdio consumers" --type=feature --priority=4
```

---

## Notes for Implementer

- **Package shadowing:** Both `cl-mcp.conditions` and `cl-mcp-server.conditions` shadow `cl:parse-error`. Packages that `:use` both will need `(:shadowing-import-from ...)` to resolve the conflict. In practice, `cl-mcp-server.conditions` should `:use #:cl-mcp.conditions` and inherit the shadow.

- **ASDF finding cl-mcp:** The implementing agent must ensure `../cl-mcp/` is findable by ASDF. Either add to `asdf:*central-registry*` or symlink into Quicklisp local-projects.

- **Opsis availability:** `cl-mcp` depends on `opsis/conditions`. Ensure `../opsis/` is loadable via ASDF/Quicklisp before testing cl-mcp.

- **The `cl-mcp-server:run-server` export:** The old `run-server` was exported. After extraction, `start` is the entry point. If anything depends on `cl-mcp-server:run-server`, provide a wrapper or update call sites. Check `run-server.lisp` — it uses `START`, not `run-server`.

- **Integration test rewrite:** Task 14 is the hardest task. The integration tests reference internal functions (`cl-mcp-server::handle-initialize` etc.) that no longer exist. These tests need significant rework to test through the public API. The `server-full-session` test pattern (string streams in/out) is the right model — it's already in cl-mcp's server tests.

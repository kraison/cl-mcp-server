---
title: "cl-mcp: MCP Protocol Framework Extraction"
type: design
permalink: docs/plans/2026-02-25-cl-mcp-extraction
tags:
  - common-lisp
  - mcp
  - architecture
  - extraction
---

# cl-mcp: MCP Protocol Framework Extraction

Extract the reusable MCP protocol layer from cl-mcp-server into a standalone library. Multiple projects (cl-mcp-server, chatterbox, ghost) need MCP server capabilities — the protocol plumbing should exist once.

## Problem

cl-mcp-server mixes two concerns: MCP protocol handling (JSON-RPC, stdio transport, tool dispatch) and CL REPL tools (session, evaluator, introspection). Chatterbox is already a second consumer that needs MCP server support. Ghost is next. Each would have to reimplement JSON-RPC framing, transport, and MCP handshake.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Repo | Separate repo at `../cl-mcp` | Multiple consumers across projects; shared dep, not embedded code |
| Server model | Configurable object, not subclassable | Consumer state belongs in tool handler closures, not in a class hierarchy |
| Handler signature | `(lambda (arguments) ...)` | Consumer closes over its own state (session, connections). Server doesn't know or care. |
| Handler return | String or content-block list | String is convenience (auto-wrapped). List of content blocks for full MCP control. |
| Tool registry | Per-server instance, no global state | Each `mcp-server` has its own tools hash table. No `*tools*` global. Prevents cross-instance contamination. |
| Dependencies | `yason`, `opsis/conditions` | Minimal. No telos — this is protocol plumbing, not domain logic. |
| Package prefix | `cl-mcp.*` | Consistent with `cl-mcp-server.*` naming |

## Architecture

```
┌────────────────────────────────────────────────────────┐
│              Consumer Applications                      │
│                                                         │
│  cl-mcp-server │ chatterbox │ ghost │ future projects   │
│                                                         │
│  Create server, register tools, call run-server         │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌────────────────────────────────────────────────────────┐
│                     cl-mcp                              │
│                                                         │
│  ┌──────────────┐  ┌─────────────┐  ┌──────────────┐  │
│  │ json-rpc     │  │ transport   │  │ tools        │  │
│  │              │  │             │  │              │  │
│  │ Parse/encode │  │ Stdio       │  │ Registry,    │  │
│  │ JSON-RPC 2.0 │  │ NDJSON      │  │ validate,    │  │
│  │ messages     │  │ read/write  │  │ dispatch     │  │
│  └──────────────┘  └─────────────┘  └──────────────┘  │
│                                                         │
│  ┌──────────────┐  ┌─────────────┐                     │
│  │ conditions   │  │ server      │                     │
│  │              │  │             │                     │
│  │ JSON-RPC     │  │ mcp-server  │                     │
│  │ error types  │  │ struct,     │                     │
│  │              │  │ MCP dispatch│                     │
│  │              │  │ opsis emits │                     │
│  └──────────────┘  └─────────────┘                     │
└────────────────────────────────────────────────────────┘
```

## Scope: What Goes Where

### cl-mcp owns

- **conditions.lisp** — `mcp-error`, `json-rpc-error`, `parse-error`, `invalid-request`, `method-not-found`, `invalid-params`, `internal-error`. All JSON-RPC 2.0 standard error conditions.
- **json-rpc.lisp** — `json-rpc-request` and `json-rpc-response` structs. `parse-message`, `encode-response`, `encode-error`. JSON conversion utilities (`convert-for-json`, `json-object-p`).
- **transport.lisp** — `read-message`, `write-message`, `with-stdio-transport`. NDJSON over stdio.
- **tools.lisp** — `tool-definition` struct, per-server registry functions (`register-tool`, `get-tool`, `list-tools`, `tools-for-mcp`, `validate-tool-args`, `call-tool`). All functions take a registry (hash table) as first argument. No global `*tools*` variable. Registry mechanism only — no tool implementations.
- **server.lisp** — `mcp-server` struct, `make-server`, `run-server`. MCP protocol dispatch (`initialize`, `notifications/initialized`, `tools/list`, `tools/call`). Error recovery. Opsis emits at protocol lifecycle points.

### cl-mcp does NOT own

- Tool implementations (consumers register handlers)
- Application state (sessions, connections — lives in handler closures)
- Error formatting / backtrace capture (REPL-specific, stays in cl-mcp-server)
- `evaluation-timeout` condition (REPL-specific)

## Server API

```lisp
(defstruct mcp-server
  (name "mcp-server" :type string)
  (version "0.1.0" :type string)
  (protocol-version "2025-06-18" :type string :read-only t)
  (tools (make-hash-table :test #'equal)))

(defun make-server (&key name version)
  "Create an MCP server instance with its own tool registry.")

(defun register-tool (server name &key description schema handler)
  "Register a tool on SERVER's registry.
HANDLER is (lambda (arguments) ...) returning a tool result.
Each server has its own independent tool registry.")

(defun run-server (server &key (input *standard-input*) (output *standard-output*))
  "Run the MCP server loop. Blocks until EOF on INPUT.
Handles MCP handshake, tool dispatch, and error recovery.
Emits opsis events at protocol lifecycle points.")
```

### Tool Registry: Per-Server, No Global State

Each `mcp-server` instance has its own `tools` hash table. The `cl-mcp.tools` package provides functions that take a registry (hash table) as first argument. There is no global `*tools*` variable. This prevents cross-instance state leakage in multi-server or testing scenarios.

### Handler Contract

Current cl-mcp-server handlers take `(args session)`. In cl-mcp, handlers take `(args)` only. Consumer state belongs in closures.

**Return value:** A handler returns either:
- **A string** — convenience form. Wrapped into a single text content block: `(("content" . ((("type" . "text") ("text" . ,result)))))`.
- **A list of content blocks** — full MCP control. Each block is an alist with at least `"type"` and `"text"` keys. Passed through directly. Allows multiple blocks, structured payloads, and `isError` signaling.

The server detects which form was returned (string vs list-of-alists) and normalizes to MCP wire format.

```lisp
;; cl-mcp-server consumer code
(defun start ()
  (let ((server (cl-mcp:make-server :name "cl-mcp-server" :version "0.3.0"))
        (session (make-session)))
    (with-session (session)
      (register-repl-tools server session)
      (cl-mcp:run-server server))))

(defun register-repl-tools (server session)
  ;; Simple handler — returns a string
  (cl-mcp:register-tool server "evaluate-lisp"
    :description "Evaluate Common Lisp code in the current session."
    :schema '(("type" . "object")
              ("required" . ("code"))
              ("properties" . (("code" . (("type" . "string"))))))
    :handler (lambda (args)
               (let ((code (cdr (assoc "code" args :test #'string=))))
                 (format-result (evaluate-code code session))))))
```

### Opsis Integration

`run-server` emits at protocol lifecycle points:

```lisp
;; Before entering loop
(opsis/c:emit :server-started :source source :level :info
              :message "MCP server ready")

;; After receiving each request
(opsis/c:emit :request-received :source source
              :data (list :method (request-method request)))

;; On internal errors (handler or protocol)
(opsis/c:emit :request-failed :source source :level :error
              :message (princ-to-string condition)
              :data (list :method method))
```

The `:source` is derived from `(mcp-server-name server)`. Every consumer gets observability for free.

## File Structure

```
cl-mcp/
├── cl-mcp.asd
├── src/
│   ├── packages.lisp
│   ├── conditions.lisp
│   ├── json-rpc.lisp
│   ├── transport.lisp
│   ├── tools.lisp
│   └── server.lisp
├── tests/
│   ├── packages.lisp
│   ├── conditions-tests.lisp
│   ├── json-rpc-tests.lisp
│   ├── transport-tests.lisp
│   └── tools-tests.lisp
├── CLAUDE.md
└── AGENT.md
```

## Changes to cl-mcp-server

### Files removed (moved to cl-mcp)

- `src/conditions.lisp`
- `src/json-rpc.lisp`
- `src/transport.lisp`

### Files heavily modified

- **`cl-mcp-server.asd`** — depends on `cl-mcp` instead of `yason`, `opsis/conditions`. Keeps `alexandria`, `trivial-backtrace`, `bordeaux-threads`. Removes the three moved source files.

- **`src/packages.lisp`** — drops `cl-mcp-server.conditions`, `cl-mcp-server.json-rpc`, `cl-mcp-server.transport` packages. Remaining packages use `cl-mcp.*` equivalents.

- **`src/tools.lisp`** — keeps only tool registration code (`define-builtin-tools` and individual registrations). `tool-definition` struct, registry functions, `validate-tool-args`, `call-tool` move to cl-mcp. Handler signatures change from `(args session)` to `(args)` with closures.

- **`src/server.lisp`** — becomes thin glue: creates server, registers tools, calls `cl-mcp:run-server`. Protocol dispatch functions (`handle-initialize`, `handle-tools-list`, `handle-tools-call`, `handle-request`) disappear.

### Files unchanged

- `src/session.lisp`
- `src/evaluator.lisp`
- `src/error-format.lisp`
- `src/introspection.lisp`
- `src/asdf-tools.lisp`
- `src/profiling-tools.lisp`
- `src/telos-tools.lisp`
- `run-server.lisp`

### Tests

- `tests/conditions-tests.lisp`, `tests/json-rpc-tests.lisp`, `tests/transport-tests.lisp` move to cl-mcp (repackaged under `cl-mcp-tests`).
- `tests/tools-tests.lisp` splits: registry tests move to cl-mcp, REPL tool tests stay.
- Remaining tests stay, updated to reference `cl-mcp.*` packages.

## Testing Strategy

### cl-mcp tests

| Suite | Covers |
|-------|--------|
| conditions | Error codes, condition hierarchy, report strings |
| json-rpc | Parse valid/invalid messages, encode responses, convert-for-json |
| transport | Read/write messages, EOF handling, empty line skipping |
| tools | Register, get, list, validate-args, call, method-not-found |
| server | Full request-response cycles: initialize, tools/list, tools/call, error recovery |

Server tests are new — create a server, register a trivial tool, send JSON through string streams, verify responses.

### cl-mcp-server tests

Remain as they are minus the three moved test files. Integration tests still exercise the full stack through cl-mcp.

## Dependencies

**cl-mcp:**
- `yason` — JSON parsing/encoding
- `opsis/conditions` — structured observability signaling (zero external deps)

**cl-mcp-server (after extraction):**
- `cl-mcp` — MCP protocol framework
- `alexandria` — utilities
- `trivial-backtrace` — portable backtraces
- `bordeaux-threads` — threading

## Deferred (Post-V1)

| Item | Rationale |
|------|-----------|
| Protocol state machine (reject tools/call before initialize) | Correct but not blocking — current server doesn't enforce it either. Track as follow-up. |
| Transport abstraction (reader/writer protocol beyond stdio) | All three consumers use stdio. Extract when first non-stdio consumer appears. |

## Implementation Order

1. Create `cl-mcp` repo with extracted protocol code
2. Write cl-mcp tests (adapted from moved test files + new server tests)
3. Verify cl-mcp loads and passes tests independently
4. Update cl-mcp-server to depend on cl-mcp
5. Refactor cl-mcp-server: remove moved files, update packages, change handler signatures
6. Verify cl-mcp-server tests pass against cl-mcp

---

**Last Updated**: 2026-02-25

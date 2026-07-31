---
name: cl-mcp-server-integration
description: For Claude agents using the cl-mcp-server REPL tools. Tool mental model, usage patterns, pitfalls.
version: 0.3.1
author: quasi
type: integration
---

# cl-mcp-server — Integration Skill

A running SBCL process with a persistent REPL exposed as 45 MCP tools. Definitions accumulate across calls — `defun` in call 1 is callable in call 2.

## Rule 0: don't guess — ask the image

Before calling any function you have not already called in this session, look
up its signature. Guessing *feels* cheaper than a tool call; it isn't. A wrong
guess costs an error, a re-read and a retry, and a silently wrong guess costs
much more.

| Before you... | Call |
|---------------|------|
| call an unfamiliar function | `describe-symbol` |
| call a generic function with a mode/algorithm/kind argument | `describe-generic-function` |
| rely on a standard CL operator's edge-case behaviour | `hyperspec-lookup` |
| grep for where something is defined | `find-definition-source` |
| write a `.lisp` file | `write-lisp-file` |
| `quickload` something new | `quicklisp-dry-run` |
| guess whether a name exists | `apropos-search` |

## Quick Start

**Always call first**:
```
tool: get-usage-guide
args: {}
```
Returns workflow guide with current best practices.

**Minimal evaluation**:
```
tool: evaluate-lisp
args: {"code": "(+ 1 2)"}
→ "=> 3"
```

## Core Concepts

### Persistent Session

State is global within a server process:
- `defun`, `defvar`, `defclass`, `ql:quickload` → persist for all subsequent calls
- `let`, `let*` bindings → scoped to one evaluation
- `reset-session` clears everything

### Output Format

`evaluate-lisp` returns a text string with labeled sections:

```
[stdout]
Hello

[stderr]
WARNING: something

[Backtrace]
0: ...

=> 42
```

Only non-empty sections appear. Return value is always last.

### Error Behavior

Errors do NOT crash the server. They return a formatted error string:
```
[ERROR] DIVISION-BY-ZERO
arithmetic error DIVISION-BY-ZERO signalled
Operation was (/ 1 0).

[Backtrace]
0: (/ 1 0)
...
```

`isError: false` in the MCP response even on Lisp errors. Check for `[ERROR]` prefix to detect failures.

## Tool Categories

Full reference: `.claude/skills/integration/references/tools-reference.md`

| Category | Tools |
|----------|-------|
| Core evaluation | `evaluate-lisp`, `compile-form`, `time-execution` |
| Syntax | `validate-syntax` |
| Introspection | `describe-symbol`, `apropos-search`, `macroexpand-form`, `who-calls`, `who-references` |
| CLOS | `class-info`, `find-methods` |
| Error intelligence | `describe-last-error`, `get-backtrace` |
| Session | `list-definitions`, `reset-session`, `configure-limits` |
| ASDF | `describe-system`, `system-dependencies`, `list-local-systems`, `find-system-file`, `load-system`, `load-file` |
| Quicklisp | `quickload`, `quicklisp-search` |
| Profiling | `profile-code`, `profile-functions`, `memory-report`, `allocation-profile` |
| Telos | `telos-list-features`, `telos-feature-intent`, `telos-get-intent`, `telos-intent-chain`, `telos-feature-members`, `telos-feature-decisions`, `telos-list-decisions` |
| Workflow | `get-usage-guide` |

## Common Patterns

### PATTERN-001: Validate Before Evaluate

Use `validate-syntax` before saving code to files:
```
tool: validate-syntax
args: {"code": "(defun foo (x)\n  (* x x))"}
→ "Syntax OK"
```
Does not evaluate — safe for untrusted/large code.

### PATTERN-002: Incremental Definition

Define, test, refine without file I/O:
```
# Step 1
tool: evaluate-lisp
args: {"code": "(defun square (x) (* x x))"}
→ "=> SQUARE"

# Step 2
tool: evaluate-lisp
args: {"code": "(square 7)"}
→ "=> 49"

# Step 3: only write to file when working
```

### PATTERN-003: Debug Last Error

When evaluation returns `[ERROR]`:
```
tool: describe-last-error
args: {}
→ detailed error with restarts

tool: get-backtrace
args: {"max-frames": 10}
→ stack trace
```

### PATTERN-004: Load External System

```
# Check if available
tool: quicklisp-search
args: {"pattern": "alexandria"}

# Load it
tool: quickload
args: {"system": "alexandria"}
→ "Successfully loaded: ALEXANDRIA"

# Verify
tool: evaluate-lisp
args: {"code": "(alexandria:flatten '(1 (2 3) (4 (5))))"}
→ "=> (1 2 3 4 5)"
```

### PATTERN-005: Profile Hot Code

```
tool: time-execution
args: {"code": "(loop repeat 1000000 sum 1)"}
→ "Real time: 0.012s, GC time: 0.000s, Bytes: 0"

# For deeper profiling
tool: profile-code
args: {"code": "(loop repeat 1000000 sum 1)", "mode": "cpu"}
```

## Key Tool Signatures

| Tool | Required args | Optional args |
|------|--------------|---------------|
| `evaluate-lisp` | `code: string` | `package: string`, `capture-time: bool` |
| `compile-form` | `code: string` | — |
| `validate-syntax` | `code: string` | — |
| `describe-symbol` | `name: string` | `package: string` |
| `apropos-search` | `pattern: string` | `package: string`, `type: string` |
| `configure-limits` | — | `timeout: integer`, `max-output: integer` |
| `quickload` | `system: string` | — |
| `load-system` | `system: string` | — |
| `load-file` | `path: string` | `compile: bool` |
| `profile-code` | `code: string` | `mode: string` (cpu/wall/alloc) |
| `get-backtrace` | — | `max-frames: integer` |
| `telos-feature-intent` | `feature: string` | — |

## Pitfalls

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| Stale session | Undefined symbols from prior work | `reset-session` |
| No timeout | Server hangs on infinite loop | `configure-limits {"timeout": 30}` |
| Large output | Response truncated | `configure-limits {"max-output": 50000}` |
| Missing package | `No package error` | `evaluate-lisp` with `"package": "cl-user"` |
| `load-system` vs `quickload` | System not found | Use `quickload` for Quicklisp systems; `load-system` for ASDF-registered only |
| Telos tools on unloaded system | `Telos is not loaded in this image` | `quickload` telos, then reload the system whose source has the `deffeature` forms |
| Telos feature name not found | `No feature named X. Telos is loaded and N features are registered` | The name is wrong, not the load — use the suggested matches or `telos-list-features`. Bare and `pkg::name` spellings both work |
| Telos itself broken | `Telos failed while answering this query` | A telos bug or a stale FASL. Deliberately distinct from "not found" — other telos tools may report wrong counts until it is fixed |
| Macro redefinition | Callers use old expansion | After macro change, reload dependent files |

## Detailed Reference

- **All 45 tools with full schemas**: `.claude/skills/integration/references/tools-reference.md`
- **Architecture**: `docs/explanation/architecture.md`
- **Canon specifications**: `canon/features/`

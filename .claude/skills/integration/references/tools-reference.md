# cl-mcp-server Tools Reference

All 36 tools registered by `cl-mcp-server.tools:define-builtin-tools`.

## Workflow

### get-usage-guide

Returns recommended workflow guide. CALL FIRST in a new session.

- Args: none
- Returns: string (workflow guide)

---

## Code Evaluation

### evaluate-lisp

Execute Common Lisp code in the persistent session.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `code` | string | yes | Code to evaluate |
| `package` | string | no | Package context (default: CL-USER) |
| `capture-time` | bool | no | Include timing in result |

Output format:
```
[stdout]           ← only if stdout produced
...

[stderr]           ← only if stderr/warnings produced
...

[ERROR] TYPE       ← only if error occurred
message

[Backtrace]        ← only if error with backtrace
...

=> value1          ← return value(s), always last
=> value2          ← multiple values each on own line
```

### compile-form

Compile code without executing. Catches warnings and errors.

| Param | Type | Required |
|-------|------|----------|
| `code` | string | yes |

Returns: string with compilation warnings, errors, or "Compiled OK".

### time-execution

Execute code with timing statistics.

| Param | Type | Required |
|-------|------|----------|
| `code` | string | yes |

Returns: result + "Real time: Xs, Run time: Xs, GC time: Xs, Bytes allocated: N"

---

## Syntax & Validation

### validate-syntax

Check syntax without evaluating. Safe — no side effects.

| Param | Type | Required |
|-------|------|----------|
| `code` | string | yes |

Returns: "Syntax OK" or error description with position.

---

## Code Introspection

### describe-symbol

Comprehensive symbol information: type, value, docstring, arglist, source location.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Symbol name (e.g., "defun", "cl:car") |
| `package` | string | no | Package to search in |

### apropos-search

Search symbols by pattern.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `pattern` | string | yes | Search pattern |
| `package` | string | no | Limit to package |
| `type` | string | no | Filter: function, variable, class, macro |

### macroexpand-form

Expand a macro form.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `form` | string | yes | Macro form to expand |
| `full` | bool | no | Full expansion (macroexpand-all) vs one step |

### who-calls

Find all callers of a function. Uses SBCL cross-reference database.

| Param | Type | Required |
|-------|------|----------|
| `name` | string | yes |
| `package` | string | no |

### who-references

Find all code that reads a variable or constant.

| Param | Type | Required |
|-------|------|----------|
| `name` | string | yes |
| `package` | string | no |

---

## CLOS Intelligence

### class-info

Slots, superclasses, subclasses, metaclass for any CLOS class.

| Param | Type | Required |
|-------|------|----------|
| `name` | string | yes |
| `package` | string | no |

### find-methods

All methods specialized on a class.

| Param | Type | Required |
|-------|------|----------|
| `name` | string | yes |
| `package` | string | no |

---

## Error Intelligence

### describe-last-error

Detailed info about the most recent error: type, message, restarts, backtrace.

- Args: none

### get-backtrace

Stack trace from most recent error.

| Param | Type | Default |
|-------|------|---------|
| `max-frames` | integer | 20 |

---

## Session Management

### list-definitions

List all definitions (functions, variables, macros) in current session.

| Param | Type | Description |
|-------|------|-------------|
| `type` | string | Filter: function, variable, macro, class |

### reset-session

Clear all session state. Resets `*package*` to CL-USER, clears definitions and loaded-systems list.

- Args: none

### configure-limits

Set evaluation safety limits. Returns current config.

| Param | Type | Description |
|-------|------|-------------|
| `timeout` | integer | Seconds (0 = disabled, default: 30) |
| `max-output` | integer | Max output chars (default: 100000) |

Both args optional — omit to just query current limits.

---

## ASDF System Management

### describe-system

System info: version, description, author, license, components, dependencies.

| Param | Type | Required |
|-------|------|----------|
| `name` | string | yes |

### system-dependencies

Dependency graph for a system.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | |
| `transitive` | bool | no | Include transitive dependencies |

### list-local-systems

All locally available ASDF systems (Quicklisp local-projects + source registry).

- Args: none

### find-system-file

Find the `.asd` file for a system.

| Param | Type | Required |
|-------|------|----------|
| `name` | string | yes |

### load-system

Load an ASDF system by name. System must already be findable by ASDF.

| Param | Type | Required |
|-------|------|----------|
| `name` | string | yes |

### load-file

Load a single Lisp file.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `path` | string | yes | Absolute path to .lisp file |
| `compile` | bool | no | Compile before loading |

---

## Quicklisp Integration

### quickload

Load a system via Quicklisp. Downloads automatically if not installed.

| Param | Type | Required |
|-------|------|----------|
| `system` | string | yes |

### quicklisp-search

Search Quicklisp for systems matching a pattern.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `pattern` | string | yes | |
| `limit` | integer | no | Max results (default: 30) |

---

## Performance Profiling

### profile-code

Statistical sampling profiler.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `code` | string | yes | Code to profile |
| `mode` | string | no | cpu (default), wall, alloc |
| `duration` | integer | no | Sampling duration in seconds |

### profile-functions

Deterministic profiling of specific functions.

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `action` | string | yes | start, report, stop, reset |
| `functions` | array | for start | Function names to profile |

### memory-report

Heap statistics and GC information.

- Args: none

### allocation-profile

Profile memory allocation in code.

| Param | Type | Required |
|-------|------|----------|
| `code` | string | yes |

---

## Telos Integration

Telos tools say explicitly when `telos` is not loaded. Load with `(ql:quickload :telos)` first.

### Feature names

Telos registers features under symbols interned in each feature's own defining
package (`GHOST.ARENA::ARENA-SQUARE-FEATURE`). Any tool taking a `feature`
argument accepts either spelling, case-insensitively:

- **Bare** — `arena-square-feature`. Matched against the registry's own keys by
  name. This is unambiguous in practice; when two packages do register the same
  name, the tool reports the ambiguity and lists both rather than picking one.
- **Package-qualified** — `ghost.arena::arena-square-feature` (single colon
  accepted too). Use this to resolve a reported ambiguity.

### Reading a failure

Five outcomes are reported distinctly. Read which one you got before acting:

| Message begins | Means | Do |
|----------------|-------|-----|
| `Telos is not loaded in this image` | The `TELOS` package does not exist | `quickload` telos, then reload the defining system |
| `Telos failed while answering this query` | Telos is loaded but signalled an error | A telos bug or a stale FASL. Other telos tools may report wrong counts until it is fixed — do not trust them meanwhile |
| `No feature named X. Telos is loaded and N features are registered` | Telos is fine; the name is wrong | Check the suggested matches or run `telos-list-features` |
| `The name X is ambiguous` | Two packages register that name | Re-query with the package-qualified spelling |
| `Feature X is registered but records no decisions` | Found it; it genuinely has none | Nothing is broken — this is the answer |

These five never blur into each other. In particular:

- A "not found" never implies telos failed to load.
- An empty result is never reported as a lookup failure.
- A telos that **breaks** is never reported as a telos that found **nothing** — so
  no message ever asserts a registry count or an absent field that it could not
  actually read.

### telos-list-features

List all telos features in loaded systems.

| Param | Type | Required |
|-------|------|----------|
| `filter` | string | no (substring matched against name and purpose) |

### telos-feature-intent

Full intent for a feature: purpose, goals, constraints, assumptions, failure modes.

| Param | Type | Required |
|-------|------|----------|
| `feature` | string | yes |

### telos-get-intent

Intent attached to a function, class, or condition.

| Param | Type | Required |
|-------|------|----------|
| `name` | string | yes |
| `package` | string | no |

### telos-intent-chain

Trace intent hierarchy from code to root feature.

| Param | Type | Required |
|-------|------|----------|
| `name` | string | yes |
| `package` | string | no |

### telos-feature-members

All functions and classes belonging to a feature.

| Param | Type | Required |
|-------|------|----------|
| `feature` | string | yes |

### telos-feature-decisions

Design decisions for a feature: what was chosen, what was rejected, why.

| Param | Type | Required |
|-------|------|----------|
| `feature` | string | yes |

### telos-list-decisions

All recorded decisions across all telos features.

- Args: none

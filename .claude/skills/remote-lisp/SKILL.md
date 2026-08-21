---
name: remote-lisp
description: Use when a running Common Lisp service needs inspecting, debugging or fixing in place — a production or staging image, a server that is misbehaving, a process whose state you cannot reproduce locally. Attaches to it over SWANK: evaluate read-only forms, inspect live values, and (only for targets allowlisted outside the session) redefine code in the running image. Triggers on "debug the live server", "what is production doing", "attach to the running Lisp", "hot-fix without a restart".
version: 0.4.4
author: quasi
type: integration
---

# Driving a running Lisp service

A live service is not a dev image: a mistake is not undoable, and there is
no test suite between you and the users. Every safety property below is
client-side discipline, because SWANK itself is just `EVAL` — no read-only
mode, no sandbox.

Provided by the `cl-mcp` MCP server. If the `remote-*` tools are not
present, this skill does not apply.

## The shape of a session

```
remote-connect   name + port, once             → register the target
remote-eval      read-only forms                → look
remote-inspect   a value, transcript mode       → look closer
remote-ledger    before you trust the session   → what did I actually do?
remote-disconnect with cleanup: true            → sweep what you left
```

Targets are addressed by **name**, never host/port, so a port cannot be
typo'd into production.

## What is refused, and why

`remote-eval` classifies the form *before* sending it:

| Tier | Examples | Default |
|------|----------|---------|
| observe | arglists, docs, apropos, source location | allowed |
| read | evaluating a form that reads state | allowed |
| redefine | `defun`, `defmethod` | **refused** |
| state | `setf`, `clrhash`, `load`, `defvar`, and destructive CL like `sort`, `nreverse`, `delete` | **refused** |
| lifecycle | `quit`, `kill-thread`, `delete-package` | **refused** |

Opaque operators — `eval`, `funcall`, `apply`, `read-from-string`, `#.` —
are treated as lifecycle, because their effect cannot be read.

A refusal prints the form for a human to run. That is the intended
escalation path: hand it over, do not work around it.

**The classifier is textual.** It cannot see through a macro, or a function
that mutates internally. It stops accidents, not adversaries. The ledger is
the real audit.

## Mutating a service you own

`remote-arm <target>` puts a target into `developer` mode, permitting
redefinition, state changes and lifecycle forms. It is **refused unless the
target is allowlisted outside the session**, in
`~/.config/cl-mcp-server/config.sexp`:

```lisp
(:armable-targets ("staging" "my-dev-box"))
```

or `CL_MCP_ARMABLE_TARGETS` as a comma-separated list, which *replaces* the
file rather than merging. The allowlist lives outside the session on purpose:
it stops the arming tool being talked into arming a target nobody named.

**There is no expiry.** The target stays armed until `remote-disarm`, which
restores the mode it had before. `remote-targets` marks armed targets;
nothing else will remind you. Disarm when the task is done, in the same
breath as finishing it.

## Inspecting values

`remote-inspect` has two modes. **transcript** (default) renders one level
and retains nothing on the service. **registry** retains handles so parts
can be walked — as weak pointers, so the table can never keep a service's
data alive; a collected handle says so rather than resurrecting the object.

Prefer transcript. Reach for registry only to walk into something, and clear
it with `remote-inspect-clear` (or `remote-disconnect` with `cleanup: true`)
when done.

## Print limits are bound in the remote image

Not on our side: `(gethash k *huge-table*)` could flood or stall the service
before a byte reached us. Limits travel with the form.

## Before you believe a session's work

Read `remote-ledger`. It records every form sent, refusals included, with
timestamps. Without it there is no answer to "what did the agent do to
prod?", and the feature should not exist without one.

## Habits worth keeping

- Connect in `read` mode; escalate deliberately, not by default.
- Look before touching: `remote-inspect` a value beats guessing from source.
- One armed target at a time, and disarm as soon as the change is verified.
- Finish with `remote-disconnect` + `cleanup` — an abrupt disconnect is the
  normal case (a timeout, a dropped socket, a killed agent), so anything
  left on the service is our fault.

## Full safety model

[`docs/reference/remote-swank.md`](https://github.com/kraison/cl-mcp-server/blob/main/docs/reference/remote-swank.md)
— tiering, the arming gate, the ledger, and what mutate mode does *not*
protect you from. Read it before pointing these tools at anything that
matters.

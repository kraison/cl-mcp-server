# Mutate Mode — Design

**Date:** 2026-08-07
**Status:** Implemented and merged (76c99d1). One deviation, noted below.
**Affects:** `src/remote.lisp`, `src/tools.lisp`, new `src/remote-config.lisp`

## Problem

Every remote capability shipped so far is read-only. The worst case of any
existing tool is a stale handle table or a wasted call — nothing can leave a
service different from how it was found.

Mutation breaks that property. A `defun` on a live image changes behaviour
for every subsequent request, there is no undo, and the blast radius is not
the form but every caller of what was redefined.

`tier-allowed-p` already understands a `:mutate` tier, but `remote-connect`
clamps every target to `:read`, so no target can reach it. This design opens
that gate for **live development** — attaching to a long-running service you
own and iterating on it the way SLIME does.

Live development is the first target because it is the case that actually
arises. Operational maintenance and hotfix are later, and the design is
shaped so they are new rows in a table rather than edits to the classifier.

## Design

### 1. Modes are roles, not rungs

The current model is a ladder — `observe ⊂ read ⊂ mutate`, each mode a
superset of the last. Roles do not nest:

- `:developer` redefines functions freely
- `:prod-maintenance` clears a cache but must never `defun`
- `:prod-hotfix` redefines one broken function but must not touch state

`:prod-maintenance` is not a subset of `:developer`. A ladder cannot express
that, so `tier-allowed-p` becomes a table:

| mode | observe | read | inspect-registry | redefine | state | lifecycle |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| `:observe` | ● | | | | | |
| `:read` | ● | ● | ● | | | |
| `:developer` | ● | ● | ● | ● | ● | ● |

`:prod-maintenance` and `:prod-hotfix` are **not built**. They are named here
only to show the shape holds; adding one is adding a row.

This also removes an existing wart: `:inspect-registry` is currently
hand-listed in two `case` branches.

### 2. `:mutate` splits into `:redefine` and `:state`

The existing operator list partitions in two:

- **`:redefine`** — `defun`, `defmethod`, `defgeneric`, `defmacro`,
  `add-method`, `remove-method`
- **`:state`** — `setf`, `setq`, `psetf`, `psetq`, `incf`, `decf`, `push`,
  `pop`, `pushnew`, `remhash`, `clrhash`, `set`, `makunbound`, `fmakunbound`,
  `rotatef`, `shiftf`, `change-class`, plus the destructive CL operators that
  read as innocent: `sort`, `delete`, `nconc`, `nreverse`, `replace`, `fill`

`defclass`, `defstruct`, `defvar`, `defparameter`, `defconstant`, `load`,
`compile-file`, `require`, `trace` and `untrace` classify as **`:state`**
despite their syntax. Redefining a class obsoletes live instances and
updates them lazily; `defvar` and friends alter global bindings; `load` can
do anything. None of these is recoverable by re-evaluating the previous
definition, which is the property that distinguishes `:redefine`.

**Why now, given AGENTS.md rejects speculative infrastructure.** No mode
built here distinguishes the two tiers — `:developer` permits both. The
justification is the ledger: `redefine` versus `state` tells you at a glance
whether a session changed code or data, which is the first question asked
after an incident. The benefit to future modes is a bonus, not the reason.

### 3. Arming

Two new tools:

- `remote-arm <target> [reason]` — sets the target's mode to `:developer`
- `remote-disarm <target>` — restores the mode the target had before arming

Both are ledger events. `reason` is free text, recorded verbatim.

**Disarm restores the pre-arm mode, it does not set `:read`.** A target
registered in `:observe` and then armed must return to `:observe`; returning
it to `:read` would leave it more permissive than it started, which is a
privilege escalation disguised as a cleanup. The pre-arm mode is stored on
the target when arming.

**There is no clock.** An armed target stays armed until disarmed. This was
chosen deliberately over expiry: a sliding window never lapses during an
active session, and an absolute one interrupts the redefine-test-redefine
loop that is the entire point of `:developer` mode. The cost is that the
window is bounded only by someone remembering, which is why §5 makes armed
state loud.

**Disconnect does not disarm.** Arming is a property of the target, not of
the socket, and silently downgrading on a dropped connection would surprise
someone mid-loop.

**Arming an already-armed target is idempotent** — it does not stack, and
the stored pre-arm mode is not overwritten by a second arm.

### 4. The allowlist

Arming is refused unless the target is named as armable **outside the
session**. This is the gate: the arming tool cannot be talked into arming a
target that was never intended to be armable.

It is a guardrail, not a sandbox. `evaluate-lisp` runs in this same image
and can set these internals directly, so the allowlist stops the accident
and the "I decided this was fine" case — not an agent writing arbitrary
Lisp. That is the same standard the classifier is held to, and the ledger
remains the audit.

Two layers, file first, environment second.

**Config file.** `~/.config/cl-mcp-server/config.sexp`:

```lisp
(:armable-targets ("scratch" "my-dev-image"))
```

Read with `*read-eval*` bound to `nil`. Without that, `#.` in a config file
is arbitrary code execution at startup.

A missing file is not an error — it means nothing is armable, which is the
correct default. A malformed file **is** an error, reported at first use
rather than swallowed: a config that fails to parse must not silently become
a config that permits nothing, because the two are indistinguishable to the
user at the moment it matters.

**Environment override.** `CL_MCP_ARMABLE_TARGETS="scratch,my-dev-image"`
**replaces** the file's list entirely.

Replace, not merge, because merge has no way to express removal — with merge
semantics there is no value of the variable that turns an entry in the file
*off*, which is exactly what an override is for. An empty string is a valid
override meaning "nothing is armable", which is the escape hatch.

Both are read at startup and cached. Editing the file mid-session has no
effect until restart; this keeps the gate outside the reach of a session
that could otherwise write to it.

**Out of scope:** the file format leaves room for target definitions
(host/port per name), which would stop callers retyping them at connect.
That is a separate change and is not built here.

### 5. Visibility replaces the clock

Because nothing expires on its own, armed state must be impossible to miss:

- `remote-targets` marks armed targets
- `remote-connect` reports armed state when reconnecting to one
- `remote-arm` and `remote-disarm` bracket the window in the ledger

### 6. Lifecycle in `:developer`

`:lifecycle` is permitted in `:developer` mode. Restarting your own
development image is ordinary work.

This needs a UX fix. Today a form that kills the target surfaces as
`no reply within 30s; the remote thread may still be running the form` — a
timeout, which reads like a hang when it is in fact success. In `:developer`
mode, a connection that drops immediately after a lifecycle form is reported
as **"target terminated, as instructed"**.

Only `quit`, `exit` and `save-lisp-and-die` end the session.
`terminate-thread`, `delete-package` and `unintern` leave the connection
usable and must not trigger the message.

## Testing

**Unit.** The mode table; the `:redefine`/`:state` partition; arming refused
when the allowlist is empty; env var overriding the file; malformed config
reported rather than swallowed; empty override meaning nothing armable;
disarm restoring `:observe` rather than `:read` for a target that started in
`:observe`; a second arm not overwriting the stored pre-arm mode.

**Live, against a throwaway target.** Arm, redefine a function, and confirm
from *the service's own answer* that it sees the new definition — asserting
on the tool's success message would prove nothing. Then disarm and confirm
the same form is refused.

**Lifecycle, last.** Kill the target deliberately and confirm the message
says terminated rather than timed out. This runs last because it destroys
the target, which is what a throwaway target is for.

**Mutation testing**, as with the existing tiering: a mode table that grants
`:redefine` to `:read`, and an allowlist check that passes when the list is
empty, must both fail the suite.

## Risks

**The classifier still cannot see through macros.** Unchanged from the
read-only design, but the consequence is now worse: a false negative used to
cost a wasted call, and in `:developer` mode it costs production behaviour.
The ledger remains the real audit.

**Redefinition is not atomic.** `defmethod` on a generic function with calls
in flight means some requests use the old method and some the new. This is
inherent to live redefinition, not something this design introduces, and it
is why `:developer` is for services you own.

**Success is indistinguishable from disaster.** `(setf *rate-limit* 1000)`
returns `1000` whether or not that was the intended value. Nothing in this
design detects a well-formed mistake.

---

## Deviations from this design, as built

**`CL_MCP_CONFIG` was dropped.** This design specified an environment
variable overriding the config file's *path*. It was never implemented:
`CL_MCP_ARMABLE_TARGETS` overrides the allowlist's *contents* directly,
which covers the practical need (CI, a one-off session, disabling arming
with `""`) without a second variable. A path override with no user is
speculative infrastructure.

Implemented behaviour, in `src/remote-config.lisp`:

- The config file path is `~/.config/cl-mcp-server/config.sexp`, fixed.
- `CL_MCP_ARMABLE_TARGETS` replaces the file's list entirely when set.

**Everything else landed as designed.** Four review rounds after the six
implementation tasks; see `docs/reference/remote-swank.md` for the built
behaviour, which is the document to trust when the two disagree.

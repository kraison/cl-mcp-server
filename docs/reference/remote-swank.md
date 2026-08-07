# Remote SWANK Reference

Tools for inspecting **running Lisp services** over SWANK, the protocol
SLIME uses. Where the rest of this server works against a development image,
these work against production.

That difference drives every design decision here, so it is worth stating
plainly:

| development image | live service |
|---|---|
| restart is free | restart is an outage |
| state is reproducible | state is the product |
| an error is interesting | an error may be an incident |
| a mistake is undoable | **a mistake is not undoable** |

SWANK offers no help with this. It is `eval` over a socket: no read-only
mode, no permission model, no sandbox. Every safety property described below
is **client-side discipline added by these tools**, and it is a guardrail
against accidents, not a defence against a determined form.

## Available Tools

| Tool | Purpose | Use When |
|------|---------|----------|
| [remote-connect](#remote-connect) | Register and verify a target | Starting work against a service |
| [remote-eval](#remote-eval) | Evaluate a form remotely | Reading live state |
| [remote-inspect](#remote-inspect) | Inspect a value on the service | Understanding what data holds |
| [remote-inspect-clear](#remote-inspect-clear) | Drop the handle registry | Housekeeping |
| [remote-targets](#remote-targets) | List registered targets | Checking what is reachable |
| [remote-ledger](#remote-ledger) | Audit every call made | Answering "what did the agent do?" |
| [remote-disconnect](#remote-disconnect) | Close a connection | Finishing, or forcing a reconnect |

---

## The four safety properties

### 1. Named targets

Tools take a target **name**, never a host and port. A port cannot be typo'd
into production, and the name appears in every ledger line.

### 2. Tiering by form inspection

Every form is classified **before** it is sent:

| Tier | Contains | In `read` mode |
|------|----------|----------------|
| read | anything not matching the lists below | runs |
| mutate | `setf` `defun` `defvar` `defclass` `load` `trace` ... | **refused** |
| lifecycle | `quit` `kill-thread` `delete-package` `save-lisp-and-die` ... | **refused** |

A refusal prints the form back so a human can run it deliberately:

```
Refused: lifecycle tier (lifecycle operator QUIT), but target scratch is in
read mode.

Run it yourself if you intend it:
  (sb-ext:quit)
```

**Opaque operators are treated as lifecycle**, not waved through:
`eval`, `read`, `read-from-string`, `funcall`, `apply`, `compile`,
`macroexpand`, `intern`, `find-symbol`. Their effect cannot be determined by
reading them, and refusing a safe form is cheaper than allowing a
destructive one. `#.` (read-eval) is likewise refused — it executes at read
time, before any classification could help.

Matching is token-delimited, so `(settle-account 5)` is **not** mistaken for
`setf`.

#### What this does not do

Classification reads text. It **cannot** see through a macro, a computed
symbol, or a function that mutates internally:

```lisp
(update-the-cache)     ; classified read; may write anything
```

This catches accidents — a `setf` typed without thinking, a `quit` pasted
from a REPL transcript. It is not a security boundary. The real protections
are default-deny, the ledger, and a human in the loop.

### 3. Print limits bound in the remote image

Limits are applied inside the form sent to the service:

```lisp
(let ((*print-length* 200) (*print-level* 5) (*print-circle* t) ...)
  <your form>)
```

Enforcing them on our side would be too late — `(gethash k *huge-table*)`
can stall or flood a service before a byte reaches us.

### 4. The ledger

Every form sent is recorded with a timestamp, target, tier, outcome and
detail — **including refusals**, since an attempt is as interesting as a
success. Without an answer to "what did the agent do to my service?", this
feature should not exist.

---

## remote-connect

Register a named target and verify it is reachable.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| name | string | Yes | Short name used everywhere else |
| port | integer | Yes | SWANK port |
| host | string | No | Default `127.0.0.1` |
| mode | string | No | `observe` or `read` (default: `read`) |

```
Target scratch registered: 127.0.0.1:4010, read mode.
Reachable; remote SBCL "2.6.6".

Mutating and lifecycle forms will be refused.
```

Modes: `observe` permits metadata queries only; `read` also permits forms
that read state. **Neither permits mutation** — that is deliberate, and
there is currently no mode that does.

## remote-eval

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| target | string | Yes | Registered target name |
| code | string | Yes | Form to evaluate |
| package | string | No | Remote package (default: `CL-USER`) |

```
=> (:NODES 2 :EDGES 1)
```

Output printed by the form is captured and shown under `[stdout]`. A remote
error is reported with the restarts the remote image offered — informational
only; invoking them is not yet supported (see Limitations).

## remote-inspect

Inspect a **value** on the service — slots, elements, hash entries — the way
`inspect-object` does locally.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| target | string | Yes | Registered target name |
| code | string | No | Expression to evaluate and inspect |
| handle | integer | No | Walk into a handle from an earlier inspection |
| registry | boolean | No | Retain handles for navigation (default: false) |
| package | string | No | Remote package (default: `CL-USER`) |

Supply one of `code` or `handle`.

### Two modes

**transcript** (the default) renders one level and retains **nothing** on the
target. It cannot navigate — there is no object identity to navigate with.

```
CONS
(1 2 3)
The object is a proper list of length 3.
  0                             1
  1                             2
  2                             3

(transcript mode: nothing retained on the target; pass registry to navigate)
```

**registry** (`registry: true`) retains handles so parts can be walked:

```
[1] CONS
(:A (10 20))
The object is a proper list of length 2.
  [2] 0                         :A
  [3] 1                         (10 20)

3 handles retained (weak).
```

Passing `handle: 3` then descends into `(10 20)`.

### Why the registry is safe

Handles are **weak pointers**. The table can never be the reason a service
keeps an object alive, and a handle whose object has been collected says so
rather than resurrecting it:

```
That object has been collected. Handles are weak: the inspector never keeps
a service's data alive. Re-inspect from the top.
```

That is the property that makes retaining handles on a production heap
acceptable at all. Prefer transcript mode regardless: use registry only when
you actually need to walk into something.

### The `inspect-registry` tier

Registry mode genuinely mutates the target — it defines a variable and
maintains a counter. Rather than masquerade as a read, those forms carry
their own `:inspect-registry` tier, which the ledger records under that name
so the exception is visible. It is permitted wherever `read` is, but **not**
in `observe` mode, whose promise is metadata only.

## remote-inspect-clear

| Parameter | Type | Required |
|-----------|------|----------|
| target | string | Yes |

Drops the handle registry. Entries are weak and cannot keep data alive, so
this is housekeeping rather than a leak fix — but it is the polite thing to
do when finished with a service. `remote-disconnect` with `cleanup: true`
does it for you.

## remote-targets

No parameters. Lists registered targets with host, port and mode.

## remote-ledger

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| target | string | No | Limit to one target (default: all) |

```
3 remote calls:

  20:41:01  ok           read       scratch
    (lisp-implementation-version)
  20:41:02  ok           read       scratch
    (graph-utils:node-count g)
  20:41:03  refused      lifecycle  scratch
    (sb-ext:quit)
    lifecycle operator QUIT
```

## remote-disconnect

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| target | string | Yes | Target name |
| cleanup | boolean | No | Sweep remote state first (default: false) |

Closes the connection. The target keeps running; only our socket goes away.

With `cleanup: true`, anything this session left on the service is swept
first — currently the inspector's handle registry:

```
Cleanup on scratch:
  inspector registry: Remote inspector registry cleared.

Disconnected from scratch.
```

Prefer `cleanup: true` when finishing with a live service. Residue on
someone else's production image is our fault, and an abrupt disconnect — a
timeout, a dropped socket, a killed agent — is the normal case rather than
the exception.

Cleanup actions are registered rather than hard-coded, so each new kind of
residue enrols its own sweep. Actions are isolated: one that fails is
reported and the rest still run.

---

## Limitations

These are deliberate omissions, not oversights.

**No mutate mode.** The tier exists in the classifier, but no target can be
configured to allow it. Mutation should not be automatic until the
classifier has been lived with.

**No remote restarts.** `evaluate-with-restarts` is local-only. Remotely it
would suspend one of the service's live threads and hold it; if that thread
owns a lock or a transaction, the service is wedged — and the suspension
timeout would then *abort* a real request.

**Cleanup is best-effort.** `remote-disconnect` with `cleanup: true` sweeps
what we know about, but a connection that drops mid-call never runs it. The
registry is weak, so the worst case is a stale table rather than retained
memory — but a service restarted less often than the agent will accumulate
them.

**The classifier is heuristic.** See "What this does not do" above.

## Operational advice

- Start in `observe` mode against anything you care about.
- Read `remote-ledger` before trusting a session's work, and after any
  incident.
- Prefer narrow forms. `(hash-table-count *cache*)` is a better question
  than `*cache*`.
- Prefer `remote-inspect` over printing a large structure through
  `remote-eval`: it renders one level with limits bound on the service.
- Use transcript mode unless you need to walk into something. Registry mode
  is safe, but "safe" is not "free".
- Finish with `remote-disconnect` and `cleanup: true`.
- Treat a refusal as information: it is telling you the form would have
  changed something.

## See Also

- [evaluate-lisp](evaluate-lisp.md) — the local equivalent
- [Introspection Tools](introspection-tools.md) — local read-only tooling
- [SLIME/SWANK](https://slime.common-lisp.dev/) — the protocol

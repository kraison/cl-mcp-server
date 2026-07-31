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

| Parameter | Type | Required |
|-----------|------|----------|
| target | string | Yes |

Closes the connection. The target keeps running; only our socket goes away.

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

**No remote inspector.** Handles hold strong references, so a remote
registry would prevent GC on a production heap. Planned as an explicit,
opt-in escalation rather than a default.

**No cleanup on abrupt disconnect.** If a connection drops mid-call, the
remote image may keep tracing or hold a half-open connection. Always call
`remote-disconnect` when finished.

**The classifier is heuristic.** See "What this does not do" above.

## Operational advice

- Start in `observe` mode against anything you care about.
- Read `remote-ledger` before trusting a session's work, and after any
  incident.
- Prefer narrow forms. `(hash-table-count *cache*)` is a better question
  than `*cache*`.
- Treat a refusal as information: it is telling you the form would have
  changed something.

## See Also

- [evaluate-lisp](evaluate-lisp.md) — the local equivalent
- [Introspection Tools](introspection-tools.md) — local read-only tooling
- [SLIME/SWANK](https://slime.common-lisp.dev/) — the protocol

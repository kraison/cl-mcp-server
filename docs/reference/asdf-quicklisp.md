# ASDF and Quicklisp Tools Reference

<!-- Generated from: canon/features/asdf-integration/contracts/*.md -->

Tools for loading and managing Common Lisp systems and libraries.

## Overview

ASDF (Another System Definition Facility) and Quicklisp integration allows you to:
- Load Common Lisp libraries and systems
- Automatically download missing dependencies
- Manage project dependencies
- Work with the broader Common Lisp ecosystem

## quickload

Load an ASDF system via Quicklisp with automatic dependency resolution and downloading.

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| system | string | Yes | Name of the system to load (e.g., "alexandria", "hunchentoot") |
| verbose | boolean | No | Show detailed compilation output (default: false) |

### What It Does

1. Checks if the system is already loaded
2. If not found locally, downloads from Quicklisp
3. Resolves and downloads all dependencies
4. Compiles the system (cached for future loads)
5. Makes the system available in your session

### Examples

**Load a popular library:**

```
User: Please quickload "alexandria"

Response:
Loaded system: ALEXANDRIA (version 1.4)
Dependencies loaded: 0
Load time: 0.12 seconds
```

**Load a library with dependencies:**

```
User: Please quickload "hunchentoot"

Response:
Loaded system: HUNCHENTOOT (version 1.3.0)

Dependencies loaded:
  - BORDEAUX-THREADS (0.9.1)
  - CHUNGA (1.1.7)
  - CL-BASE64 (3.3.4)
  - CL-FAD (0.7.6)
  - CL-PPCRE (2.1.1)
  - FLEXI-STREAMS (1.0.19)
  - CL+SSL (latest)
  - MD5 (2.0.4)
  - RFC2388 (latest)
  - TRIVIAL-BACKTRACE (1.1.0)
  - USOCKET (2.8.3)

Load time: 3.45 seconds
Systems compiled: 12
```

**System already loaded:**

```
User: Please quickload "alexandria"

Response:
System ALEXANDRIA is already loaded (version 1.4)

(No compilation needed)
```

**Download required:**

```
User: Please quickload "cl-ppcre"

Response:
System CL-PPCRE not found locally.
Downloading from Quicklisp...

  → Fetching cl-ppcre (2.1.1) from dist/quicklisp/...
  → Installing to ~/quicklisp/dists/quicklisp/software/cl-ppcre-2.1.1/

Downloaded 156 KB
Compiling...
Loaded system: CL-PPCRE (version 2.1.1)
```

**System not in Quicklisp:**

```
User: Please quickload "nonexistent-system"

Response:
System "nonexistent-system" not found in Quicklisp.

Try:
  (ql:system-apropos "search-term")

Or check: https://www.quicklisp.org/beta/
```

### Verbose Mode

Use `verbose: true` to see detailed compilation output:

```json
{"system": "drakma", "verbose": true}
```

Shows:
- Download progress
- Dependency resolution steps
- Compilation messages
- Warnings and notes

### Popular Libraries You Can Load

| Library | Purpose | Example Use |
|---------|---------|-------------|
| alexandria | Utility functions | General Lisp programming |
| cl-ppcre | Regular expressions | String pattern matching |
| dexador | HTTP client | Making HTTP requests |
| jonathan | JSON parsing | API integration |
| local-time | Time handling | Date/time manipulation |
| bordeaux-threads | Threading | Concurrent programming |
| cl-fad | File operations | Portable file manipulation |
| ironclad | Cryptography | Hashing, encryption |
| hunchentoot | Web server | Building web applications |

### How Quicklisp Works

**First Load:**
1. System not found locally → downloads from Quicklisp servers
2. Extracts to `~/quicklisp/dists/quicklisp/software/`
3. Compiles all .lisp files
4. Stores compiled FASLs in `~/.cache/common-lisp/`
5. Loads the system

**Subsequent Loads:**
1. System found locally
2. Uses cached FASLs (much faster)
3. No recompilation needed (unless source changed)

### Troubleshooting

**Quicklisp not installed:**

```
Error: Quicklisp is not installed or not loaded.

To install Quicklisp:
  1. Download: https://beta.quicklisp.org/quicklisp.lisp
  2. Load: (load "quicklisp.lisp")
  3. Install: (quicklisp-quickstart:install)
```

**Network issues:**

If Quicklisp can't download a system, check:
- Internet connection
- Firewall settings
- Proxy configuration (if behind corporate firewall)

**Compilation warnings:**

Systems may emit warnings during compilation. These are usually benign but worth noting. Use `verbose: true` to see them.

### Notes

- Quickload requires internet access for first-time downloads
- Downloaded systems consume disk space in `~/quicklisp/`
- Compiled code cached in `~/.cache/common-lisp/`
- Systems are loaded into the current session (persist until session ends)

### Common Workflows

**Starting a new project:**
```
1. quickload common utilities (alexandria, etc.)
2. quickload project-specific dependencies
3. Begin development
```

**Exploring libraries:**
```
1. Search Quicklisp: https://www.quicklisp.org/beta/
2. quickload to try it out
3. Use describe-symbol and class-info to explore
```

**Dependency management:**
```
1. Note which systems you use
2. Document in your .asd file
3. Users can quickload your system + dependencies
```

---

## Read-only dist introspection

These five tools query the **local** Quicklisp dist index. They never download,
install or update anything, which makes them safe to call speculatively — the
point being that a tool which might fetch 40 MB does not get used to answer a
quick question, and a tool that is not used does not stop you guessing.

### quicklisp-dry-run

Show exactly what `quickload` would download, without downloading it.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| system | string | Yes | System name |

Reports the transitive dependency tree, how much is already installed, what
would be fetched, and the total archive size. Call it before quickloading
anything unfamiliar: `quickload` is an irreversible network action whose blast
radius is otherwise invisible.

```
quickload cl-telegram-bot

  71 systems in the dependency tree
  58 already installed
  13 would be downloaded (12 releases, 841.8 KB)

Would download:
  40ants-asdf-system
  arrows
  ...
```

### quicklisp-system-info

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| system | string | Yes | System name |

Install state, direct dependencies (each marked installed or not), release and
project, archive size and URL, on-disk location, and sibling systems from the
same release.

### quicklisp-search

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| term | string | Yes | Matches names and descriptions |
| limit | integer | No | Max results (default: 40) |

Results are ranked — exact match first, `-test`/`-doc`/subsystems last — and
each is marked `[installed]` or `[available]`.

> **Changed:** the parameter was `pattern` in earlier versions; it is now
> `term`. The previous implementation returned bare names with no install
> state and no ranking.

### quicklisp-who-depends-on

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| system | string | Yes | System name |
| limit | integer | No | Max results (default: 60) |

Systems that directly require the given system. Useful both for "what breaks if
this changes?" and, when judging an unfamiliar library, "is anything actually
using this?"

### quicklisp-dist-status

_No parameters._

Client version, dist version, systems available, releases installed, and
whether a newer dist exists. A stale dist explains many otherwise-confusing
"system not found" failures.

Reporting only — it will not update anything. `update-dist`, `update-client`
and `uninstall` are deliberately not exposed: they are slow, network-bound and
occasionally destructive, and are left for a human to run.

---

## See Also

- [evaluate-lisp](evaluate-lisp.md) - Execute Lisp code with loaded systems
- [How to: Load Quicklisp Systems](../how-to/load-quicklisp-systems.md) - Practical guide
- [Quicklisp Documentation](https://www.quicklisp.org/beta/) - Official Quicklisp docs

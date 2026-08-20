#!/usr/bin/env python3
"""Extract the CLHS symbol->page map from SLIME's hyperspec.el into Lisp.

The mapping is pure data (symbol name -> relative .htm path under Body/), so
we can ship it and resolve lookups with zero network access. Only the URL we
hand back points at the web.
"""
import glob
import os
import re
import sys

# Absolute paths to one developer's Mac made this unrunnable anywhere else.
# Both are overridable; SRC is discovered from the Quicklisp tree by default.
def find_src() -> str:
    if os.environ.get("HYPERSPEC_EL"):
        return os.environ["HYPERSPEC_EL"]
    pattern = os.path.expanduser(
        "~/quicklisp/dists/quicklisp/software/slime-*/lib/hyperspec.el")
    hits = sorted(glob.glob(pattern))
    if not hits:
        sys.exit(f"no hyperspec.el found under {pattern}; "
                 "set HYPERSPEC_EL to its path")
    return hits[-1]

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(HERE, "src", "hyperspec-data.lisp")

PAIR = re.compile(r'\("([^"\\]+)"\s+"([A-Za-z0-9_.~-]+\.htm)"\)')

def main() -> int:
    src = find_src()
    with open(src, encoding="utf-8", errors="replace") as fh:
        text = fh.read()

    seen = {}
    for name, page in PAIR.findall(text):
        # first mapping wins; the file lists the canonical page first
        seen.setdefault(name.lower(), page)

    if len(seen) < 500:
        print(f"refusing: only extracted {len(seen)} entries", file=sys.stderr)
        return 1

    with open(DST, "w", encoding="utf-8") as out:
        out.write(""";;; src/hyperspec-data.lisp
;;; ABOUTME: CLHS symbol -> page table (generated; do not edit by hand)
;;;
;;; Extracted from SLIME's lib/hyperspec.el, which carries the canonical
;;; Common Lisp HyperSpec symbol index. Shipping the table means lookups
;;; need no network: we resolve the page locally and only the returned URL
;;; refers to the web.
;;;
;;; Regenerate with: tools/extract-hyperspec.py

(in-package #:cl-mcp-server.hyperspec)

(defparameter *clhs-page-alist*
  '(
""")
        for name in sorted(seen):
            page = seen[name]
            esc = name.replace("\\", "\\\\").replace('"', '\\"')
            entry = f'    ("{esc}" . "{page}")'
            # A 63-character CLHS name does not fit one line; split the cons.
            if len(entry) > 80:
                entry = f'    ("{esc}"\n     . "{page}")'
            out.write(entry + "\n")
        out.write("""    )
  "CLHS symbol name (downcased) consed to its page. A flat alist rather
than inline SETF calls because a 63-character symbol name does not fit an
80-column line in the latter shape.")

(defparameter *clhs-pages*
  (let ((table (make-hash-table :test #'equal :size 2048)))
    (loop for (name . page) in *clhs-page-alist*
          do (setf (gethash name table) page))
    table)
  "Maps a downcased CL symbol name to its HyperSpec page, e.g.
\\"car\\" -> \\"f_car_c.htm\\".")
""")

    print(f"wrote {DST} with {len(seen)} entries from {src}")
    for probe in ("car", "mapcar", "defun", "loop", "make-hash-table"):
        print(f"  {probe:18s} -> {seen.get(probe)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

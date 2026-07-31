#!/usr/bin/env python3
"""Extract the CLHS symbol->page map from SLIME's hyperspec.el into Lisp.

The mapping is pure data (symbol name -> relative .htm path under Body/), so
we can ship it and resolve lookups with zero network access. Only the URL we
hand back points at the web.
"""
import re
import sys

SRC = ("/Users/kraison/quicklisp/dists/quicklisp/software/"
       "slime-v2.31/lib/hyperspec.el")
DST = "/Users/kraison/work/cl-mcp-server/src/hyperspec-data.lisp"

PAIR = re.compile(r'\("([^"\\]+)"\s+"([A-Za-z0-9_.~-]+\.htm)"\)')

def main() -> int:
    with open(SRC, encoding="utf-8", errors="replace") as fh:
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

(defparameter *clhs-pages*
  (let ((table (make-hash-table :test #'equal)))
""")
        for name in sorted(seen):
            page = seen[name]
            esc = name.replace("\\", "\\\\").replace('"', '\\"')
            out.write(f'    (setf (gethash "{esc}" table) "{page}")\n')
        out.write("""    table)
  "Maps a downcased CL symbol name to its HyperSpec page, e.g.
\\"car\\" -> \\"f_car_c.htm\\".")
""")

    print(f"wrote {DST} with {len(seen)} entries")
    for probe in ("car", "mapcar", "defun", "loop", "make-hash-table"):
        print(f"  {probe:18s} -> {seen.get(probe)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

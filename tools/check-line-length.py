#!/usr/bin/env python3
"""Report Lisp lines over 80 columns, per the project's style rule."""
import sys
import pathlib

limit = 80
bad = 0
for path in sys.argv[1:]:
    p = pathlib.Path(path)
    if not p.exists():
        continue
    for i, line in enumerate(p.read_text().splitlines(), 1):
        if len(line) > limit:
            print(f"{path}:{i} ({len(line)}) {line[:70]}")
            bad += 1
print(f"\n{bad} line(s) over {limit} columns")
sys.exit(1 if bad else 0)

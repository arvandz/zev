#!/usr/bin/env python3
"""
Finds orphaned fragment lines: leftover corruption where a line consists
only of a dangling argument-list continuation like
"allocator, io, &repo);" with no preceding "try X.Y(" on the same line -
this is never valid Zig syntax standalone, so it's always a leftover
artifact sitting right after an already-complete statement. Deletes them.

Usage:
    python3 find_orphan_fragments.py            # report only
    python3 find_orphan_fragments.py --fix       # delete them
"""
import argparse
import re
from pathlib import Path

SRC = Path("src")

FRAGMENT = re.compile(r"^(allocator|io)\s*,.*\);\s*$")
COMPLETE_PREV = re.compile(r"(\);|\}|;)\s*$")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fix", action="store_true")
    args = ap.parse_args()

    total = 0
    for f in sorted(SRC.rglob("*.zig")):
        lines = f.read_text().splitlines(keepends=True)
        out = []
        file_changed = False
        for i, line in enumerate(lines):
            stripped = line.strip()
            if FRAGMENT.match(stripped):
                prev_stripped = lines[i - 1].strip() if i > 0 else ""
                # only safe to treat as orphan if the previous line is
                # ALREADY a complete, terminated statement - otherwise
                # this could be a legitimate multi-line call continuation
                if not COMPLETE_PREV.search(prev_stripped):
                    print(f"{f}:{i+1}  SKIPPED (previous line not complete - "
                          f"might be a legitimate continuation): {line!r}")
                    print(f"    previous line: {lines[i-1]!r}")
                    out.append(line)
                    continue
                print(f"{f}:{i+1}  {line!r}")
                print(f"    (previous line, already complete: {lines[i-1]!r})")
                total += 1
                file_changed = True
                if args.fix:
                    continue  # drop this line
            out.append(line)
        if args.fix and file_changed:
            f.write_text("".join(out))
    print(f"\nTotal orphan fragments: {total}")
    if not args.fix:
        print("(report only - pass --fix to delete them)")


if __name__ == "__main__":
    main()
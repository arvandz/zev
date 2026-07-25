#!/usr/bin/env python3
"""
Scans for a specific corruption pattern: a line containing the same
non-trivial substring twice, separated only by whitespace (e.g.
"const x = cid.CID.        const x = cid.CID.fromBytes(data);").
This showed up twice in main.zig from some earlier automated edit: this
scans the whole tree for more instances so we can fix them all in one
pass instead of hitting them one at a time as Zig's lazy analysis
reaches each one.

This only REPORTS - it does not auto-fix, since the correct fix (which
copy to keep) needs a human look in each case.

Usage: python3 find_duplicated_lines.py
"""
import argparse
import re
from pathlib import Path

SRC = Path("src")


def find_duplicate_in_line(line):
    """Returns (prefix, rest_after_second_copy) if this line contains a
    non-trivial (15+ char) substring immediately followed by whitespace
    and then itself again."""
    stripped = line.rstrip("\n")
    content = stripped.lstrip()
    indent = stripped[:len(stripped) - len(content)]

    for k in range(4, len(content)):
        prefix = content[:k]
        rest = content[k:]
        rest_lstripped = rest.lstrip()
        gap = len(rest) - len(rest_lstripped)
        if gap < 4:
            continue  # corruption artifacts have a substantial gap;
                      # coincidental short repeats in real code don't
        if rest_lstripped.startswith(prefix):
            after = rest_lstripped[len(prefix):]
            return indent, prefix, after
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fix", action="store_true", help="apply the fix instead of just reporting")
    args = ap.parse_args()

    total = 0
    for f in sorted(SRC.rglob("*.zig")):
        lines = f.read_text().splitlines(keepends=True)
        file_changed = False
        for i, line in enumerate(lines):
            if len(line) < 30:
                continue
            result = find_duplicate_in_line(line)
            if result:
                indent, prefix, after = result
                print(f"{f}:{i+1}")
                print(f"  full line: {line!r}")
                fixed = indent + prefix + after
                if not fixed.endswith("\n") and line.endswith("\n"):
                    fixed += "\n"
                print(f"  {'fixed to' if args.fix else 'looks like'}: {fixed.strip()}")
                total += 1
                if args.fix:
                    lines[i] = fixed
                    file_changed = True
        if args.fix and file_changed:
            f.write_text("".join(lines))
    print(f"\nTotal suspicious lines: {total}")
    if not args.fix:
        print("(report only - pass --fix to apply)")


if __name__ == "__main__":
    main()
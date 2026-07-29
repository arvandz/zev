#!/usr/bin/env python3
"""
Fixes Io.Dir.Iterator.next() calls, which now require an `io` argument,
without touching other iterator types (HashMap iterators, split
iterators, etc.) that don't take io.

Finds `var NAME = EXPR.iterate();` declarations, then within the same
function scope, rewrites `NAME.next()` to `NAME.next(io)`.

Usage:
    python3 fix_dir_iterator_next.py --dry-run
    python3 fix_dir_iterator_next.py
"""
import argparse
import re
from pathlib import Path

SRC = Path("src")
FN_HEADER = re.compile(r"^\s*(pub\s+)?fn\s+\w+\s*\(")
ITERATE_DECL = re.compile(r"^\s*var\s+(\w+)\s*=\s*[\w.]+\.iterate\(\)\s*;\s*$")


def get_function_ranges(lines):
    ranges = []
    i, n = 0, len(lines)
    while i < n:
        if FN_HEADER.match(lines[i]):
            start = i
            depth, started, j, done = 0, False, i, False
            while j < n and not done:
                for ch in lines[j]:
                    if ch == "(":
                        depth += 1
                        started = True
                    elif ch == ")":
                        depth -= 1
                        if started and depth == 0:
                            done = True
                            break
                j += 1
            k = max(j - 1, i)
            while k < n and "{" not in lines[k]:
                k += 1
            if k >= n:
                i += 1
                continue
            depth2, started2, end, p, done2 = 0, False, k, k, False
            while p < n and not done2:
                for ch in lines[p]:
                    if ch == "{":
                        depth2 += 1
                        started2 = True
                    elif ch == "}":
                        depth2 -= 1
                        if started2 and depth2 == 0:
                            end = p
                            done2 = True
                            break
                p += 1
            ranges.append((start, end))
            i = end + 1
        else:
            i += 1
    return ranges


def fix_function(lines, start, end):
    changed = 0
    iter_vars = set()
    for i in range(start, end + 1):
        m = ITERATE_DECL.match(lines[i])
        if m:
            iter_vars.add(m.group(1))
    if not iter_vars:
        return changed
    for i in range(start, end + 1):
        for var in iter_vars:
            pattern = re.compile(r"\b" + re.escape(var) + r"\.next\(\)")
            new_line, n = pattern.subn(f"{var}.next(io)", lines[i])
            if n:
                lines[i] = new_line
                changed += n
    return changed


def convert_file(path: Path, dry_run: bool):
    lines = path.read_text().splitlines(keepends=True)
    ranges = get_function_ranges(lines)
    total = 0
    for start, end in ranges:
        total += fix_function(lines, start, end)
    if total and not dry_run:
        path.write_text("".join(lines))
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    total = 0
    for f in sorted(SRC.rglob("*.zig")):
        n = convert_file(f, args.dry_run)
        if n:
            print(f"{'would change' if args.dry_run else 'changed'} {f}: {n} edit(s)")
            total += n
    print(f"\nTotal: {total} edit(s)")
    if args.dry_run:
        print("(dry run - no files written)")


if __name__ == "__main__":
    main()
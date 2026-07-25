#!/usr/bin/env python3
"""
Strips spuriously-injected `io` arguments from confirmed-pure stdlib
calls that got wrongly touched by propagate_io.py's ambiguous bare-name
call-site matching (it matched `.init(` globally with no awareness of
which type the call belonged to).

Confirmed by direct inspection - none of these ever take `io`:
  - std.StringHashMap(...).init(...)
  - std.AutoHashMap(...).init(...)
  - std.crypto.hash.sha2.Sha256.init(...)

This is a narrow, evidence-based fix - it only touches lines matching
these specific known-pure type names, not a blind global strip of `io`.

Usage:
    python3 fix_spurious_stdlib_io.py --dry-run
    python3 fix_spurious_stdlib_io.py
"""
import argparse
import re
from pathlib import Path

SRC = Path("src")

# Matches the corrupted arg list following one of these type's .init(
# call - captures everything up to the matching close paren is overkill
# here since these are all single-line; instead just strip any
# occurrence of ", io" (with optional trailing comma/space) that
# appears after `.init(` for one of these specific receivers.
PATTERNS = [
    re.compile(r"(std\.StringHashMap\([^)]*\)\.init\([^)]*?)((?:,\s*io\s*)+,?\s*)\)"),
    re.compile(r"(std\.AutoHashMap\([^)]*\)\.init\([^)]*?)((?:,\s*io\s*)+,?\s*)\)"),
    re.compile(r"(std\.crypto\.hash\.sha2\.Sha256\.init\()(?:io,\s*)+"),
]


def fix_line(line):
    changed = False
    new_line = line
    # StringHashMap / AutoHashMap: strip trailing ", io, io, io," etc.
    for pat in PATTERNS[:2]:
        def repl(m):
            nonlocal changed
            changed = True
            return m.group(1) + ")"
        new_line2 = pat.sub(repl, new_line)
        new_line = new_line2
    # Sha256.init(io, ...) -> Sha256.init(...)
    def repl_sha(m):
        nonlocal changed
        changed = True
        return m.group(1)
    new_line = PATTERNS[2].sub(repl_sha, new_line)
    return new_line, changed


def convert_file(path: Path, dry_run: bool):
    lines = path.read_text().splitlines(keepends=True)
    changed_count = 0
    out = []
    for line in lines:
        new_line, changed = fix_line(line)
        if changed:
            changed_count += 1
        out.append(new_line)
    if changed_count and not dry_run:
        path.write_text("".join(out))
    return changed_count


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    total = 0
    for f in sorted(SRC.rglob("*.zig")):
        n = convert_file(f, args.dry_run)
        if n:
            print(f"{'would change' if args.dry_run else 'changed'} {f}: {n} line(s)")
            total += n
    print(f"\nTotal: {total} line(s)")
    if args.dry_run:
        print("(dry run - no files written)")


if __name__ == "__main__":
    main()
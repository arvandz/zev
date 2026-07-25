#!/usr/bin/env python3
"""
Converts old std.time.Instant-based wall-clock timestamp reads to the new
std.Io.Timestamp.now(io, .real) API.

Two shapes handled:
  1. Inline:  (std.time.Instant.now() catch unreachable).timestamp.sec
       ->     @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s)
  2. Two-step:
       const NAME = std.time.Instant.now() catch unreachable;
       ... NAME.timestamp.sec ...
       ->
       const NAME = std.Io.Timestamp.now(io, .real);
       ... @divTrunc(NAME.nanoseconds, std.time.ns_per_s) ...

Deliberately SKIPS any line containing 'start_inst' or '.since(' - those are
monotonic elapsed-time measurements (should use Clock.awake, not .real) and
need a different, hand-reviewed fix rather than this wall-clock conversion.

Usage:
    python3 convert_time.py --dry-run [files...]
    python3 convert_time.py [files...]
"""
import argparse
import re
from pathlib import Path

SRC = Path("src")

INLINE = "(std.time.Instant.now() catch unreachable).timestamp.sec"
INLINE_NEW = "@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s)"

ASSIGN_RE = re.compile(
    r"^(?P<indent>\s*)(?P<decl>const|var)\s+(?P<name>\w+)\s*=\s*std\.time\.Instant\.now\(\)\s*catch\s+unreachable\s*;\s*$"
)
FIELD_ACCESS_RE = re.compile(r"\b(\w+)\.timestamp\.sec\b")


def convert_file(path: Path, dry_run: bool):
    lines = path.read_text().splitlines(keepends=True)
    changed = 0
    out = []
    skip_names = set()  # variable names assigned via a skipped (monotonic) line

    for line in lines:
        if "start_inst" in line or ".since(" in line:
            out.append(line)
            continue

        if INLINE in line:
            new_line = line.replace(INLINE, INLINE_NEW)
            if new_line != line:
                changed += 1
            out.append(new_line)
            continue

        am = ASSIGN_RE.match(line)
        if am:
            indent, decl, name = am.group("indent"), am.group("decl"), am.group("name")
            out.append(f"{indent}{decl} {name} = std.Io.Timestamp.now(io, .real);\n")
            changed += 1
            continue

        if FIELD_ACCESS_RE.search(line):
            new_line = FIELD_ACCESS_RE.sub(
                lambda m: f"@divTrunc({m.group(1)}.nanoseconds, std.time.ns_per_s)", line
            )
            if new_line != line:
                changed += 1
            out.append(new_line)
            continue

        out.append(line)

    if changed and not dry_run:
        path.write_text("".join(out))
    return changed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("files", nargs="*")
    args = ap.parse_args()
    targets = [Path(f) for f in args.files] if args.files else sorted(SRC.rglob("*.zig"))
    total = 0
    for f in targets:
        n = convert_file(f, args.dry_run)
        if n:
            print(f"{'would change' if args.dry_run else 'changed'} {f}: {n} edit(s)")
            total += n
    print(f"\nTotal: {total} edit(s)")
    if args.dry_run:
        print("(dry run - no files written)")


if __name__ == "__main__":
    main()
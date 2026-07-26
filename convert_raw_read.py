#!/usr/bin/env python3
"""
Converts remaining raw `NAME.read(&buf)` calls on an Io.File to the
buffered-reader pattern established throughout this codebase:
    var NAME_scratch: [N]u8 = undefined;
    var NAME_reader = NAME.reader(io, &NAME_scratch);
    ... NAME_reader.interface.readSliceShort(&buf) ...

Skips `child.stdout.?.read(` / `child.stderr.?.read(` since those are
process-output reads handled by convert_child.py already.

Function-scope aware (same brace-matching as convert_writeall.py /
convert_child.py) so the scratch/reader declaration is only added once
per variable per function, and inserted right before first use.

Usage:
    python3 convert_raw_read.py --dry-run [files...]
    python3 convert_raw_read.py [files...]
"""
import argparse
import re
from pathlib import Path

SRC = Path("src")
FN_HEADER = re.compile(r"^\s*(pub\s+)?fn\s+\w+\s*\(")

# NAME.read(&buf) - but not child.stdout.?.read( / child.stderr.?.read(
READ_CALL = re.compile(
    r"(?P<prefix>(?:const|var)\s+\w+\s*=\s*)?(?P<try>try\s+)?"
    r"(?P<recv>\w+)\.read\((?P<arg>&\w+(?:\[[^\]]*\])?)\)(?P<catch>\s*catch\s+.*)?;\s*$"
)


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


def convert_function(lines, start, end):
    out = []
    i = start
    changed = 0
    scratch_declared = set()

    while i <= end:
        line = lines[i]
        m = READ_CALL.match(line.strip())
        if m and "stdout" not in line and "stderr" not in line:
            recv = m.group("recv")
            indent = re.match(r"^(\s*)", line).group(1)
            if recv not in scratch_declared:
                out.append(f"{indent}var {recv}_scratch: [4096]u8 = undefined;\n")
                out.append(f"{indent}var {recv}_reader = {recv}.reader(io, &{recv}_scratch);\n")
                scratch_declared.add(recv)
                changed += 1
            prefix = m.group("prefix") or ""
            try_kw = m.group("try") or ""
            arg = m.group("arg")
            catch = m.group("catch") or ""
            out.append(f"{indent}{prefix}{try_kw}{recv}_reader.interface.readSliceShort({arg}){catch};\n")
            changed += 1
            i += 1
            continue
        out.append(line)
        i += 1

    return out, changed


def convert_file(path: Path, dry_run: bool):
    lines = path.read_text().splitlines(keepends=True)
    ranges = get_function_ranges(lines)
    result = []
    cursor = 0
    total = 0
    for start, end in ranges:
        result.extend(lines[cursor:start])
        block, changed = convert_function(lines, start, end)
        result.extend(block)
        total += changed
        cursor = end + 1
    result.extend(lines[cursor:])
    if total and not dry_run:
        path.write_text("".join(result))
    return total


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
#!/usr/bin/env python3
"""
Converts `NAME.writeAll(args)` call sites on a std.Io.File value to the
buffered-writer pattern your codebase already established in config.zig:

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [512]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(...);
    try writer.flush();

This script:
  1. Finds `NAME = try ... .createFile(io, ...)` (or openFile) lines.
  2. Inserts a per-variable buffer + writer right after that line (and
     updates an adjacent `defer NAME.close();` to `defer NAME.close(io);`
     if present).
  3. Replaces `NAME.writeAll(args)` with `NAME_writer.interface.writeAll(args)`,
     preserving whatever `try` / `catch ...` wrapper the original line used.
  4. Inserts a matching `NAME_writer.flush()` (same try/catch wrapper)
     immediately after EVERY write, not just the last one. This is
     deliberately conservative: flushing once at the end can silently skip
     flushing on an early return/continue inside a loop or catch branch,
     which would be a silent data-loss bug rather than a compile error, so
     it's not worth the minor efficiency gain to place it just once.

This only touches functions where `NAME.writeAll(` is found near a
`NAME = try ...createFile(io, ...)` line in the same file - it does not
try to trace complex ownership across function boundaries. Review the
diff after running.

Usage:
    python3 convert_writeall.py --dry-run
    python3 convert_writeall.py
"""
import argparse
import re
import sys
from pathlib import Path

SRC = Path("src")

FN_HEADER = re.compile(r"^\s*(pub\s+)?fn\s+\w+\s*\(")
CREATE_PATTERN = re.compile(
    r"^(?P<indent>\s*)(?:const|var)\s+(?P<name>\w+)\s*=\s*try\s+.*\.(?:createFile|openFile)\(io\b"
)
WRITEALL_PATTERN = re.compile(
    r"^(?P<indent>\s*)(?P<try>try\s+)?(?P<name>\w+)\.writeAll\((?P<args>.*)\)(?P<catch>\s*catch\s+.*)?;\s*$"
)
CLOSE_PATTERN = re.compile(r"^(?P<indent>\s*)defer\s+(?P<name>\w+)\.close\(\)\s*;\s*$")


def get_function_ranges(lines):
    """Returns list of (start_idx, end_idx) inclusive, one per top-level
    `fn` declaration, spanning from the `fn` line to its body's closing
    brace (found via brace counting from the first `{` after the params)."""
    ranges = []
    i = 0
    n = len(lines)
    while i < n:
        if FN_HEADER.match(lines[i]):
            start = i
            # find end of parameter list (paren depth returns to 0)
            depth = 0
            started = False
            j = i
            done = False
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
            # find first `{` at/after j-1 (the line where params closed)
            k = max(j - 1, i)
            while k < n and "{" not in lines[k]:
                k += 1
            if k >= n:
                i += 1
                continue
            # brace-count from k to find matching close
            depth2 = 0
            started2 = False
            end = k
            p = k
            done2 = False
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
    """Converts writeAll calls within lines[start:end+1] in place-ish;
    returns (new_lines_for_range, changed_count)."""
    out = []
    i = start
    changed = 0
    active_writers = {}

    while i <= end:
        line = lines[i]

        m = CREATE_PATTERN.match(line)
        if m:
            name = m.group("name")
            indent = m.group("indent")
            out.append(line)
            i += 1
            if i <= end:
                cm = CLOSE_PATTERN.match(lines[i])
                if cm and cm.group("name") == name:
                    out.append(f"{cm.group('indent')}defer {name}.close(io);\n")
                    i += 1
            # idempotency: already converted?
            already = False
            for peek in lines[i:min(i + 3, end + 1)]:
                if f"{name}_writer = {name}.writer(" in peek:
                    already = True
                    break
            if already:
                continue
            # only insert buffer/writer if writeAll on this name appears
            # later WITHIN THIS FUNCTION's remaining body
            body_ahead = "".join(lines[i:end + 1])
            if re.search(r"\b" + re.escape(name) + r"\.writeAll\(", body_ahead):
                writer_name = f"{name}_writer"
                out.append(f"{indent}var {name}_buffer: [512]u8 = undefined;\n")
                out.append(f"{indent}var {writer_name} = {name}.writer(io, &{name}_buffer);\n")
                active_writers[name] = writer_name
                changed += 1
            continue

        m = WRITEALL_PATTERN.match(line)
        if m and m.group("name") in active_writers:
            indent = m.group("indent")
            writer_name = active_writers[m.group("name")]
            try_kw = m.group("try") or ""
            args = m.group("args")
            catch = m.group("catch") or ""
            out.append(f"{indent}{try_kw}{writer_name}.interface.writeAll({args}){catch};\n")
            out.append(f"{indent}{try_kw}{writer_name}.flush(){catch};\n")
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
    total_changed = 0
    for start, end in ranges:
        # copy anything between functions untouched
        result.extend(lines[cursor:start])
        new_block, changed = convert_function(lines, start, end)
        result.extend(new_block)
        total_changed += changed
        cursor = end + 1
    result.extend(lines[cursor:])

    if total_changed and not dry_run:
        path.write_text("".join(result))
    return total_changed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("files", nargs="*", help="specific files to process; default: whole src/ tree")
    args = ap.parse_args()

    targets = [Path(f) for f in args.files] if args.files else sorted(SRC.rglob("*.zig"))

    total = 0
    for f in targets:
        n = convert_file(f, args.dry_run)
        if n:
            print(f"{'would change' if args.dry_run else 'changed'} {f}: {n} edit(s)")
            total += n
    print(f"\nTotal: {total} edit(s) across the tree")
    if args.dry_run:
        print("(dry run - no files written)")


if __name__ == "__main__":
    main()
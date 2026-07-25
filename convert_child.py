#!/usr/bin/env python3
"""
Converts the old std.process.Child API (Zig 0.16-style) to the new
free-function std.process.spawn(io, options) API (0.17-dev), scoped
per-function using the same brace-matching approach as convert_writeall.py.

Three related transforms, applied together since they occur in the same
functions:

1. Child construction block:
       var NAME = std.process.Child.init(ARGV, allocator);
       NAME.stdout_behavior = .X;      (optional, either order)
       NAME.stderr_behavior = .Y;      (optional)
       try NAME.spawn();
   becomes:
       var NAME = try std.process.spawn(io, .{
           .argv = ARGV,
           .stdout = .x,               (only if present; enum lowercased)
           .stderr = .y,
       });

2. NAME.wait(...) gets `io` inserted as an argument if missing.

3. Term tag literals (.Exited/.Signal/.Stopped/.Unknown) get lowercased,
   matching the new lowercase union fields.

4. One-shot raw reads:
       PREFIX RECV.stdout.?.read(ARG) SUFFIX;
   becomes, with a scratch buffer + reader inserted just before:
       var RECV_scratch: [4096]u8 = undefined;
       var RECV_reader = RECV.stdout.?.reader(io, &RECV_scratch);
       PREFIX RECV_reader.interface.readSliceShort(ARG) SUFFIX;
   (scratch/reader only declared once per RECV per function)

Does NOT add `io` to function signatures - run propagate_io.py afterward
to thread `io` into any function this introduces a use of `io` into that
didn't have it before (that script's cascade handles it).

Usage:
    python3 convert_child.py --dry-run [files...]
    python3 convert_child.py [files...]        # default: whole src/ tree
"""
import argparse
import re
from pathlib import Path

SRC = Path("src")
FN_HEADER = re.compile(r"^\s*(pub\s+)?fn\s+\w+\s*\(")

CHILD_INIT_START = re.compile(
    r"^(?P<indent>\s*)var\s+(?P<name>\w+)\s*=\s*(?:try\s+)?std\.process\.Child\.init\("
)
BEHAVIOR_LINE = re.compile(
    r"^\s*(?P<name>\w+)\.(?P<which>stdout|stderr)_behavior\s*=\s*\.(?P<val>\w+)\s*;\s*$"
)
SPAWN_LINE = re.compile(r"^\s*try\s+(?P<name>\w+)\.spawn\(\)\s*;\s*$")

WAIT_CALL = re.compile(r"\b(?P<name>\w+)\.wait\(\s*\)")
TERM_TAG = re.compile(r"\.(Exited|Signal|Stopped|Unknown)\b")

RAW_READ = re.compile(r"(?P<recv>\w+)\.stdout\.\?\.read\((?P<arg>[^)]*)\)")


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
    scratch_declared = set()  # recv names already given scratch/reader in this fn

    while i <= end:
        line = lines[i]

        m = CHILD_INIT_START.match(line)
        if m:
            indent = m.group("indent")
            name = m.group("name")
            # gather full text of the init(...) call, possibly multi-line
            paren_col = line.index("(", m.end() - 1)
            depth = 0
            call_lines = []
            j = i
            col = paren_col
            started = False
            closed = False
            while j <= end:
                seg = lines[j]
                k = col
                seg_start = k
                while k < len(seg):
                    ch = seg[k]
                    if ch == "(":
                        depth += 1
                        started = True
                    elif ch == ")":
                        depth -= 1
                        if started and depth == 0:
                            closed = True
                            break
                    k += 1
                call_lines.append((j, seg_start, k))
                if closed:
                    break
                j += 1
                col = 0
            if not closed:
                out.append(line)
                i += 1
                continue
            # reconstruct raw arg text (between outer parens) across lines
            raw_chunks = []
            for (li, s, e) in call_lines:
                seg = lines[li]
                if li == call_lines[0][0]:
                    piece = seg[s + 1:e if li == call_lines[-1][0] else None]
                elif li == call_lines[-1][0]:
                    piece = seg[0:e]
                else:
                    piece = seg[0:None]
                raw_chunks.append(piece.strip("\n"))
            raw_args = " ".join(p.strip() for p in raw_chunks if p.strip())
            # strip trailing ", allocator" / ", self.allocator" / ", X.allocator"
            argv_text = re.sub(r",\s*[\w.]*allocator\s*,?\s*$", "", raw_args).strip()

            end_line_idx = call_lines[-1][0]
            after = i2 = end_line_idx + 1

            # look ahead for behavior lines and spawn line
            stdout_val = None
            stderr_val = None
            spawn_idx = None
            scan = after
            limit = min(after + 6, end + 1)
            while scan < limit:
                bl = lines[scan]
                if bl.strip() == "":
                    scan += 1
                    continue
                bm = BEHAVIOR_LINE.match(bl)
                if bm and bm.group("name") == name:
                    if bm.group("which") == "stdout":
                        stdout_val = bm.group("val").lower()
                    else:
                        stderr_val = bm.group("val").lower()
                    scan += 1
                    continue
                sm = SPAWN_LINE.match(bl)
                if sm and sm.group("name") == name:
                    spawn_idx = scan
                    break
                break  # unexpected line, stop looking

            if spawn_idx is None:
                # couldn't confidently find the block end - leave untouched
                out.append(line)
                i += 1
                continue

            out.append(f"{indent}var {name} = try std.process.spawn(io, .{{\n")
            out.append(f"{indent}    .argv = {argv_text},\n")
            if stdout_val:
                out.append(f"{indent}    .stdout = .{stdout_val},\n")
            if stderr_val:
                out.append(f"{indent}    .stderr = .{stderr_val},\n")
            out.append(f"{indent}}});\n")
            changed += 1
            i = spawn_idx + 1
            continue

        # raw one-shot read conversion
        rm = RAW_READ.search(line)
        if rm:
            recv = rm.group("recv")
            indent = re.match(r"^(\s*)", line).group(1)
            if recv not in scratch_declared:
                out.append(f"{indent}var {recv}_scratch: [4096]u8 = undefined;\n")
                out.append(f"{indent}var {recv}_reader = {recv}.stdout.?.reader(io, &{recv}_scratch);\n")
                scratch_declared.add(recv)
                changed += 1
            new_line = RAW_READ.sub(
                lambda mm: f"{mm.group('recv')}_reader.interface.readSliceShort({mm.group('arg')})",
                line,
            )
            out.append(new_line)
            i += 1
            continue

        # wait() -> wait(io)
        if WAIT_CALL.search(line):
            new_line = WAIT_CALL.sub(lambda mm: f"{mm.group('name')}.wait(io)", line)
            if new_line != line:
                changed += 1
            out.append(new_line)
            i += 1
            continue

        # Term tag lowercasing
        if TERM_TAG.search(line):
            new_line = TERM_TAG.sub(lambda mm: f".{mm.group(1).lower()}", line)
            if new_line != line:
                changed += 1
            out.append(new_line)
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
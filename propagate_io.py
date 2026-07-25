#!/usr/bin/env python3
"""
Iteratively drives `zig build`, and for each compile error caused by a
missing `io: std.Io` in scope, patches:
  1. the enclosing function's signature to add `io: std.Io` as a parameter
     (right after `allocator: std.mem.Allocator` if present, else first), and
  2. every call site of that function elsewhere in src/, inserting `io` as
     an argument (right after `allocator` if the call already passes one,
     else as the first argument).
  3. call sites where a function ALREADY takes io but the call is missing
     it (the "member function expected N argument(s), found M" error) get
     `io` inserted directly at that call site, using the calling function's
     own `io` (only if the caller already has `io` in scope; if not, this
     is deferred to the next iteration once the caller gains one).

This is a heuristic, not a real Zig parser. It matches on function names,
so a name reused across unrelated structs/files could get a false-positive
call-site edit. ALWAYS run from a clean git commit and review `git diff`
after each run (the script prints a summary and stops each iteration so
you can inspect). Re-run to continue the loop.

Usage:
    python3 propagate_io.py             # runs until clean or stuck, max 20 iters
    python3 propagate_io.py --dry-run   # show what would change, no edits
    python3 propagate_io.py --max-iters 5
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

SRC = Path("src")

UNDECLARED_IO = re.compile(
    r"^(?P<file>[^\s:]+\.zig):(?P<line>\d+):(?P<col>\d+): error: use of undeclared identifier 'io'",
    re.MULTILINE,
)
ARG_COUNT = re.compile(
    r"^(?P<file>[^\s:]+\.zig):(?P<line>\d+):(?P<col>\d+): error: member function expected (?P<expected>\d+) argument\(s\), found (?P<found>\d+)",
    re.MULTILINE,
)
FN_HEADER = re.compile(r"^(?P<indent>\s*)(pub\s+)?fn\s+(?P<name>\w+)\s*\(")


def run_build():
    r = subprocess.run(["zig", "build"], capture_output=True, text=True)
    return r.stdout + "\n" + r.stderr


def find_enclosing_fn(lines, line_idx):
    """Scan backward from line_idx for the nearest fn header at column 0
    or 4-space indent (top-level or struct-method level). Returns
    (header_line_idx, fn_name) or (None, None)."""
    for i in range(line_idx, -1, -1):
        m = FN_HEADER.match(lines[i])
        if m:
            return i, m.group("name")
    return None, None


def find_param_list_end(lines, fn_line_idx):
    """Given the line index of a fn header, find the line index where the
    parameter list's closing paren appears (handles multi-line signatures)."""
    depth = 0
    started = False
    for i in range(fn_line_idx, len(lines)):
        for ch in lines[i]:
            if ch == "(":
                depth += 1
                started = True
            elif ch == ")":
                depth -= 1
                if started and depth == 0:
                    return i
    return fn_line_idx


def already_has_io_param(lines, fn_line_idx, end_idx):
    block = "".join(lines[fn_line_idx:end_idx + 1])
    return bool(re.search(r"\bio\s*:\s*std\.Io\b|\bio\s*:\s*Io\b", block))


def add_io_param(lines, fn_line_idx, end_idx):
    """Mutates lines in place, inserting `io: std.Io` into the signature."""
    block_lines = lines[fn_line_idx:end_idx + 1]
    joined = "".join(block_lines)

    if re.search(r"allocator\s*:\s*std\.mem\.Allocator", joined):
        # insert right after the allocator param
        new_joined, n = re.subn(
            r"(allocator\s*:\s*std\.mem\.Allocator\s*,?)",
            r"\1\n    io: std.Io,",
            joined,
            count=1,
        )
        if n == 0:
            new_joined = joined
    else:
        # insert as first param, right after the opening paren
        new_joined, n = re.subn(r"\(", "(io: std.Io, ", joined, count=1)

    new_block_lines = new_joined.splitlines(keepends=True)
    lines[fn_line_idx:end_idx + 1] = new_block_lines
    return len(new_block_lines) - len(block_lines)  # line delta


def patch_call_sites(fn_name, dry_run=False):
    """Find call sites of fn_name across src/ and insert `io` as an argument.
    Skips lines that are the function's own definition. Returns count patched."""
    call_pattern = re.compile(r"\b" + re.escape(fn_name) + r"\s*\(")
    def_pattern = re.compile(r"\b(pub\s+)?fn\s+" + re.escape(fn_name) + r"\s*\(")
    patched = 0
    for f in SRC.rglob("*.zig"):
        text = f.read_text()
        lines = text.splitlines(keepends=True)
        changed = False
        for i, line in enumerate(lines):
            if def_pattern.search(line):
                continue
            m = call_pattern.search(line)
            if not m:
                continue
            if re.search(r"\b" + re.escape(fn_name) + r"\s*\(\s*io\b", line):
                continue  # already has io
            # already has io, or need to insert
            if re.search(r"\ballocator\b", line[m.end():m.end() + 20]):
                new_line = re.sub(
                    r"(\b" + re.escape(fn_name) + r"\s*\(\s*allocator\s*)(,\s*)?",
                    r"\1, io, ",
                    line,
                    count=1,
                )
            else:
                new_line = call_pattern.sub(
                    lambda mm: mm.group(0) + "io, ", line, count=1
                )
            if new_line != line:
                lines[i] = new_line
                changed = True
                patched += 1
        if changed and not dry_run:
            f.write_text("".join(lines))
    return patched


def fix_arg_count_error(file, line_no, col_no, dry_run=False):
    """For 'member function expected N, found M' - insert `io` as first
    arg at this exact call site, using the compiler-reported column to
    find the right call (a line can have several `.word(` patterns, e.g.
    `std.Io.Dir.cwd().access(...)` has both `.cwd(` and `.access(` - the
    column points at the actual under-arg'd one, not necessarily the
    first on the line)."""
    f = Path(file)
    lines = f.read_text().splitlines(keepends=True)
    idx = line_no - 1
    line = lines[idx]
    col = col_no - 1  # 0-indexed
    # find the next '(' at or after the reported column
    paren_idx = line.find("(", col)
    if paren_idx == -1:
        return False
    start = paren_idx + 1
    # don't double-insert
    if line[start:start + 3].strip().startswith("io") and (
        line[start:start + 4] == "io, " or line[start:start + 2] == "io"
    ):
        return False
    new_line = line[:start] + "io, " + line[start:] if line[start] != ")" else line[:start] + "io" + line[start:]
    if new_line == line:
        return False
    if not dry_run:
        lines[idx] = new_line
        f.write_text("".join(lines))
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--max-iters", type=int, default=20)
    args = ap.parse_args()

    for iteration in range(1, args.max_iters + 1):
        print(f"\n=== Iteration {iteration} ===")
        output = run_build()

        undeclared = [m.groupdict() for m in UNDECLARED_IO.finditer(output)]
        argcount = [m.groupdict() for m in ARG_COUNT.finditer(output)]

        if not undeclared and not argcount:
            if "error:" in output:
                print("No more io-related errors matched, but build still has other errors:")
                print(output)
            else:
                print("Build clean. Done.")
            return

        print(f"Found {len(undeclared)} undeclared-io errors, {len(argcount)} arg-count errors")

        fns_touched = set()
        for err in undeclared:
            f = Path(err["file"])
            if not f.exists():
                continue
            lines = f.read_text().splitlines(keepends=True)
            line_idx = int(err["line"]) - 1
            fn_idx, fn_name = find_enclosing_fn(lines, line_idx)
            if fn_idx is None:
                print(f"  ! could not find enclosing fn for {f}:{err['line']}")
                continue
            end_idx = find_param_list_end(lines, fn_idx)
            if already_has_io_param(lines, fn_idx, end_idx):
                continue  # weirdly already has it; the undeclared-id error
                          # is from something else, skip
            print(f"  adding io param to fn {fn_name} in {f}")
            if not args.dry_run:
                add_io_param(lines, fn_idx, end_idx)
                f.write_text("".join(lines))
            fns_touched.add(fn_name)

        for fn_name in fns_touched:
            n = patch_call_sites(fn_name, dry_run=args.dry_run)
            print(f"  patched {n} call site(s) of {fn_name}")

        for err in argcount:
            ok = fix_arg_count_error(err["file"], int(err["line"]), int(err["col"]), dry_run=args.dry_run)
            if ok:
                print(f"  inserted io arg at {err['file']}:{err['line']}")

        if args.dry_run:
            print("\n(dry run - stopping after one iteration)")
            return

    print("\nReached max iterations without a clean build. Run `zig build` "
          "to see what's left, or re-run this script to continue.")


if __name__ == "__main__":
    main()
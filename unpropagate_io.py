#!/usr/bin/env python3
"""
Reverses spurious io-threading introduced by the ambiguous bare-name
call-site matching bug in propagate_io.py. Drives `zig build` in a loop:
for every "unused function parameter" error where the parameter is `io`,
that's the compiler telling us this function never actually needed it -
strip `io: std.Io` from its signature, then strip every `io` argument
(however many duplicated - 1, 2, or 3) from every call site of that
function name across src/.

Usage:
    python3 unpropagate_io.py --dry-run
    python3 unpropagate_io.py
"""
import argparse
import re
import subprocess
from pathlib import Path

SRC = Path("src")

UNUSED_PARAM = re.compile(
    r"^(?P<file>[^\s:]+\.zig):(?P<line>\d+):(?P<col>\d+): error: unused function parameter$",
    re.MULTILINE,
)
FN_HEADER = re.compile(r"^(?P<indent>\s*)(pub\s+)?fn\s+(?P<name>\w+)\s*\(")


def is_io_param_at(lines, line_no, col_no):
    """Confirms the unused parameter at this exact location is really
    named `io` (not some other unused param this error type could also
    report), by reading the actual file at that column rather than
    trusting the echoed source snippet in the build output."""
    idx = line_no - 1
    if idx >= len(lines):
        return False
    line = lines[idx]
    col = col_no - 1
    return line[col:col + 2] == "io" and not (
        col + 2 < len(line) and (line[col + 2].isalnum() or line[col + 2] == "_")
    )


def run_build():
    r = subprocess.run(["zig", "build"], capture_output=True, text=True)
    return r.stdout + "\n" + r.stderr


def find_enclosing_fn(lines, line_idx):
    for i in range(line_idx, -1, -1):
        m = FN_HEADER.match(lines[i])
        if m:
            return i, m.group("name")
    return None, None


def find_param_list_end(lines, fn_line_idx):
    depth, started = 0, False
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


def strip_io_param(lines, fn_line_idx, end_idx):
    block = "".join(lines[fn_line_idx:end_idx + 1])
    new_block = re.sub(r"\s*io\s*:\s*std\.Io\s*,?", "", block, count=1)
    new_block = re.sub(r"\(\s*,", "(", new_block)
    new_lines = new_block.splitlines(keepends=True)
    lines[fn_line_idx:end_idx + 1] = new_lines


FN_DEF_ANYWHERE = re.compile(r"^\s*(pub\s+)?fn\s+(\w+)\s*\(", re.MULTILINE)


def count_fn_definitions(fn_name):
    """Counts how many distinct function definitions with this exact name
    exist anywhere in src/. If more than 1, the name is ambiguous and it
    is NOT safe to strip io from its call sites by bare-name matching -
    this is precisely the bug that caused the original corruption."""
    count = 0
    for f in SRC.rglob("*.zig"):
        text = f.read_text()
        for m in FN_DEF_ANYWHERE.finditer(text):
            if m.group(2) == fn_name:
                count += 1
    return count


def strip_call_site_io(fn_name):
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
            if not call_pattern.search(line):
                continue
            if "io" not in line:
                continue

            def strip_args(m):
                nonlocal changed
                start = m.end()
                rest = line[start:]
                new_rest = re.sub(r"^(\s*io\s*,\s*)+", "", rest)
                new_rest = re.sub(r"^\s*io\s*(?=\))", "", new_rest)
                new_rest = re.sub(r",\s*io\s*(?=,|\))", "", new_rest)
                if new_rest != rest:
                    changed = True
                return line[:start] + new_rest

            new_line = call_pattern.sub(strip_args, line, count=1)
            if new_line != line:
                lines[i] = new_line
                patched += 1
        if changed:
            f.write_text("".join(lines))
    return patched


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--max-iters", type=int, default=20)
    args = ap.parse_args()

    for iteration in range(1, args.max_iters + 1):
        print(f"\n=== Iteration {iteration} ===")
        output = run_build()
        matches = list(UNUSED_PARAM.finditer(output))

        if not matches:
            if "error:" in output:
                print("No more unused-io-parameter errors, but build still has other errors:")
                print(output)
            else:
                print("Build clean. Done.")
            return

        print(f"Found {len(matches)} unused-parameter error(s)")
        fns_touched = set()
        for m in matches:
            f = Path(m.group("file"))
            if not f.exists():
                continue
            lines = f.read_text().splitlines(keepends=True)
            line_no = int(m.group("line"))
            col_no = int(m.group("col"))
            if not is_io_param_at(lines, line_no, col_no):
                continue  # some other unused param, not our concern
            line_idx = line_no - 1
            fn_idx, fn_name = find_enclosing_fn(lines, line_idx)
            if fn_idx is None:
                print(f"  ! could not find enclosing fn for {f}:{m.group('line')}")
                continue
            end_idx = find_param_list_end(lines, fn_idx)
            print(f"  stripping io param from fn {fn_name} in {f}")
            if not args.dry_run:
                strip_io_param(lines, fn_idx, end_idx)
                f.write_text("".join(lines))
            fns_touched.add(fn_name)

        for fn_name in fns_touched:
            if args.dry_run:
                continue
            dupe_count = count_fn_definitions(fn_name)
            if dupe_count > 1:
                print(f"  ! SKIPPING call-site strip for '{fn_name}' - {dupe_count} distinct "
                      f"definitions found in src/ (ambiguous name, not safe to auto-strip by "
                      f"bare name). The signature was already stripped above; you'll need to "
                      f"manually fix call sites of the specific '{fn_name}' that no longer "
                      f"takes io, without touching other same-named functions.")
                continue
            n = strip_call_site_io(fn_name)
            print(f"  stripped io from {n} call site(s) of {fn_name}")

        if args.dry_run:
            print("\n(dry run - stopping after one iteration)")
            return

    print("\nReached max iterations. Run `zig build` to see what's left.")


if __name__ == "__main__":
    main()
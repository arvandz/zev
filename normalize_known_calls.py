#!/usr/bin/env python3
"""
Normalizes call sites of specific known functions to their CONFIRMED
correct io-argument count, regardless of how many stray 'io's got
inserted by the ambiguous-name corruption. Handles 0, 1, 2, 3+ duplicated
io args uniformly by stripping all io occurrences from the call's arg
list first, then re-inserting the confirmed-correct count.

This script does NOT guess - it reads each function's ACTUAL current
signature from the source to determine the correct io count, so it
stays correct even as signatures change.

Usage:
    python3 normalize_known_calls.py --dry-run
    python3 normalize_known_calls.py
"""
import argparse
import re
from pathlib import Path

SRC = Path("src")

# (qualified-or-bare call prefix regex, defining-file, defining-fn-name)
# def_file=None means "always 0 io" (known stdlib type)
TARGETS = [
    (r"CID\.fromBytes", "src/core/cid.zig", "fromBytes"),
    (r"\.equals", "src/core/cid.zig", "equals"),
    (r"Commit\.deserialize", "src/core/commit.zig", "deserialize"),
    (r"Commit\.init", "src/core/commit.zig", "init"),
    (r"FileEntry\.deserialize", "src/core/tree.zig", "deserialize"),
    (r"Tree\.init", "src/core/tree.zig", "init"),
    (r"Tree\.deserialize", "src/core/tree.zig", "deserialize"),
    (r"IgnoreList\.init", "src/core/ignore.zig", "init"),
    (r"MetricMap\.init", "src/core/fedmerge.zig", "init"),
    (r"(?:config_mod\.)?Config\.init", "src/core/config.zig", "init"),
    (r"IPFSClient\.init", "src/core/ipfs.zig", "init"),
    (r"Metadata\.init", "src/core/ipfs_repo.zig", "init"),
    (r"index\.Index\.init|Index\.init", "src/core/index.zig", "init"),
    (r"(?:repository\.)?Repository\.init", "src/core/repository.zig", "init"),
    (r"blob\.BlobStore\.init|BlobStore\.init", "src/core/blob.zig", "init"),
    (r"storage_mod\.StorageManager\.init|StorageManager\.init", "src/core/storage.zig", "init"),
    (r"ipld\.BlockStore\.init", "src/core/ipld.zig", "init"),
    (r"std\.StringHashMap\([^)]*\)\.init", None, None),
    (r"std\.AutoHashMap\([^)]*\)\.init", None, None),
    (r"std\.heap\.ArenaAllocator\.init", None, None),
]


def find_real_io_signature(def_file, fn_name):
    """Returns (io_present: bool, io_index: int or None) - io_index is
    the 0-based position of the io param among all params, needed since
    some signatures have io first, others have it after allocator/self."""
    if def_file is None:
        return (False, None)
    p = Path(def_file)
    if not p.exists():
        return (None, None)
    text = p.read_text()
    m = re.search(r"\bfn\s+" + re.escape(fn_name) + r"\s*\(", text)
    if not m:
        return (None, None)
    start = m.end() - 1
    depth = 0
    i = start
    while i < len(text):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                break
        i += 1
    params_str = text[start + 1:i]
    param_names = [p.strip().split(":")[0].strip() for p in params_str.split(",") if p.strip()]
    for idx, name in enumerate(param_names):
        if name == "io":
            return (True, idx)
    return (False, None)


def normalize_call(line, call_regex, io_present, io_index):
    pattern = re.compile(call_regex + r"\(")
    m = pattern.search(line)
    if not m:
        return line, False
    start = m.end()
    depth = 1
    i = start
    while i < len(line) and depth > 0:
        if line[i] == "(":
            depth += 1
        elif line[i] == ")":
            depth -= 1
        i += 1
    if depth != 0:
        return line, False
    args_str = line[start:i - 1]
    parts = [p.strip() for p in args_str.split(",")]
    # detect an existing io-token (bare 'io' or 'std.testing.io') to
    # preserve which flavor was actually being used (test vs real scope)
    io_token = "io"
    for p in parts:
        if p == "std.testing.io":
            io_token = "std.testing.io"
            break
    # strip every io-like token, keep everything else
    parts = [p for p in parts if p != "" and p != "io" and p != "std.testing.io"]
    if io_present:
        insert_at = min(io_index, len(parts))
        parts.insert(insert_at, io_token)
    new_args = ", ".join(parts)
    new_line = line[:start] + new_args + line[i - 1:]
    changed = new_line != line
    return new_line, changed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    resolved = []
    for call_regex, def_file, fn_name in TARGETS:
        io_present, io_index = find_real_io_signature(def_file, fn_name)
        if io_present is None:
            print(f"! could not resolve signature for {call_regex} in {def_file} - skipping")
            continue
        resolved.append((call_regex, io_present, io_index))
        print(f"resolved: {call_regex} -> io_present={io_present} io_index={io_index}")

    total = 0
    for f in sorted(SRC.rglob("*.zig")):
        lines = f.read_text().splitlines(keepends=True)
        file_changed = False
        for i, line in enumerate(lines):
            if re.match(r"^\s*(pub\s+)?fn\s+", line):
                continue
            for call_regex, io_present, io_index in resolved:
                new_line, changed = normalize_call(line, call_regex, io_present, io_index)
                if changed:
                    lines[i] = new_line
                    line = new_line
                    file_changed = True
                    total += 1
        if file_changed and not args.dry_run:
            f.write_text("".join(lines))
            print(f"changed {f}")
        elif file_changed:
            print(f"would change {f}")

    print(f"\nTotal call sites normalized: {total}")
    if args.dry_run:
        print("(dry run - no files written)")


if __name__ == "__main__":
    main()
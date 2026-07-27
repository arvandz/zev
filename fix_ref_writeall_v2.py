#!/usr/bin/env python3
"""Robust fix for repository.zig's last writeAll call - matches by
finding the specific line containing 'try ref_file.writeAll(commit_hash);'
directly, rather than a fragile multi-line exact-string match.
Run from the repo root: python3 fix_ref_writeall_v2.py
"""
path = "src/core/repository.zig"
lines = open(path, encoding="utf-8").readlines()

target = "            try ref_file.writeAll(commit_hash);\n"
matches = [i for i, l in enumerate(lines) if l == target]
assert len(matches) == 1, f"found {len(matches)} exact matches (expected 1)"
idx = matches[0]

replacement = [
    "            var ref_buffer: [512]u8 = undefined;\n",
    "            var ref_writer = ref_file.writer(io, &ref_buffer);\n",
    "            try ref_writer.interface.writeAll(commit_hash);\n",
    "            try ref_writer.flush();\n",
]
lines[idx:idx + 1] = replacement
open(path, "w", encoding="utf-8").writelines(lines)
print(f"fixed line {idx + 1}")
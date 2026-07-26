#!/usr/bin/env python3
"""One-off fix for repository.zig's last remaining writeAll call.
Run from the repo root: python3 fix_ref_writeall.py
"""
path = "src/core/repository.zig"
text = open(path, encoding="utf-8").read()

old = (
    "            const ref_file = try std.Io.Dir.cwd().createFile(io, full_ref_path, .{});\n"
    "            defer ref_file.close(io);\n"
    "            const commit_hash = try commit_cid.toString(self.allocator);\n"
    "            defer self.allocator.free(commit_hash);\n"
    "            try ref_file.writeAll(commit_hash);\n"
)
new = (
    "            const ref_file = try std.Io.Dir.cwd().createFile(io, full_ref_path, .{});\n"
    "            defer ref_file.close(io);\n"
    "            const commit_hash = try commit_cid.toString(self.allocator);\n"
    "            defer self.allocator.free(commit_hash);\n"
    "            var ref_buffer: [512]u8 = undefined;\n"
    "            var ref_writer = ref_file.writer(io, &ref_buffer);\n"
    "            try ref_writer.interface.writeAll(commit_hash);\n"
    "            try ref_writer.flush();\n"
)
n = text.count(old)
assert n == 1, f"matches: {n} (expected 1)"
text = text.replace(old, new)
open(path, "w", encoding="utf-8").write(text)
print("fixed")
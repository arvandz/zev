#!/usr/bin/env python3
"""One-off fix for repository.zig's raw Io.File.read() call.
Run from the repo root: python3 fix_repository_read.py
"""
path = "src/core/repository.zig"
text = open(path, encoding="utf-8").read()

old = (
    "        const head_file = try std.Io.Dir.cwd().openFile(io, head_path, .{});\n"
    "        defer head_file.close();\n"
    "        var buffer: [256]u8 = undefined;\n"
    "        const bytes_read = try head_file.read(&buffer);\n"
)
new = (
    "        const head_file = try std.Io.Dir.cwd().openFile(io, head_path, .{});\n"
    "        defer head_file.close(io);\n"
    "        var buffer: [256]u8 = undefined;\n"
    "        var head_scratch: [256]u8 = undefined;\n"
    "        var head_reader = head_file.reader(io, &head_scratch);\n"
    "        const bytes_read = try head_reader.interface.readSliceShort(&buffer);\n"
)
n = text.count(old)
assert n == 1, f"matches: {n} (expected 1)"
text = text.replace(old, new)
open(path, "w", encoding="utf-8").write(text)
print("fixed")
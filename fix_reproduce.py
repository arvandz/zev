#!/usr/bin/env python3
"""One-off fix for src/core/reproduce.zig's mixed old/new Child.spawn +
monotonic-timestamp block. Run from the repo root: python3 fix_reproduce.py
"""
path = "src/core/reproduce.zig"
text = open(path, encoding="utf-8").read()

old = "    const start_inst = std.time.Instant.now() catch unreachable;"
new = "    const start_inst = std.Io.Timestamp.now(io, .awake);"
n = text.count(old)
assert n == 1, f"start_inst line: {n} matches (expected 1)"
text = text.replace(old, new)

old2 = "    var child = std.process.Child.init(argv.items, allocator);\n"
n = text.count(old2)
assert n == 1, f"child init line: {n} matches (expected 1)"
text = text.replace(old2, "")

EMOJI = "\u274c"

old3 = (
    "    child.cwd = work_dir;\n"
    "    child.stdout_behavior = .Pipe;\n"
    "    child.stderr_behavior = .Pipe;\n"
    "    var exit_code: i32 = -1;\n"
    "    var output_buf: [65536]u8 = undefined;\n"
    "    var output_len: usize = 0;\n"
    "    if (child.spawn()) |_| {\n"
    "        var child_scratch: [4096]u8 = undefined;\n"
    "        var child_reader = child.stdout.?.reader(io, &child_scratch);\n"
    "        output_len = child_reader.interface.readSliceShort(&output_buf) catch 0;\n"
    "        const term = child.wait(io) catch std.process.Child.Term{ .Exited = 1 };\n"
    "        exit_code = switch (term) {\n"
    "            .exited => |c| @intCast(c),\n"
    "            else => -1,\n"
    "        };\n"
    "    } else |err| {\n"
    "        std.debug.print(\"   " + EMOJI + " Failed to run command: {}\\n\", .{err});\n"
    "        exit_code = -1;\n"
    "    }"
)
n = text.count(old3)
assert n == 1, f"spawn block: {n} matches (expected 1)"

new3 = (
    "    var exit_code: i32 = -1;\n"
    "    var output_buf: [65536]u8 = undefined;\n"
    "    var output_len: usize = 0;\n"
    "    if (std.process.spawn(io, .{\n"
    "        .argv = argv.items,\n"
    "        .cwd = .{ .path = work_dir },\n"
    "        .stdout = .pipe,\n"
    "        .stderr = .pipe,\n"
    "    })) |spawned| {\n"
    "        var child = spawned;\n"
    "        var child_scratch: [4096]u8 = undefined;\n"
    "        var child_reader = child.stdout.?.reader(io, &child_scratch);\n"
    "        output_len = child_reader.interface.readSliceShort(&output_buf) catch 0;\n"
    "        const term = child.wait(io) catch std.process.Child.Term{ .exited = 1 };\n"
    "        exit_code = switch (term) {\n"
    "            .exited => |c| @intCast(c),\n"
    "            else => -1,\n"
    "        };\n"
    "    } else |err| {\n"
    "        std.debug.print(\"   " + EMOJI + " Failed to run command: {}\\n\", .{err});\n"
    "        exit_code = -1;\n"
    "    }"
)
text = text.replace(old3, new3)

old4 = "    const elapsed_ms: u64 = (std.time.Instant.now() catch unreachable).since(start_inst) / std.time.ns_per_ms;"
new4 = "    const elapsed_ms: u64 = @intCast(start_inst.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds());"
n = text.count(old4)
assert n == 1, f"elapsed_ms line: {n} matches (expected 1)"
text = text.replace(old4, new4)

open(path, "w", encoding="utf-8").write(text)
print("reproduce.zig patched successfully")
#!/usr/bin/env python3
"""One-off fix for the 5 remaining old-style Child.init blocks.
Run from the repo root: python3 fix_remaining_child_blocks.py
"""


def apply(path, old, new, label):
    text = open(path, encoding="utf-8").read()
    n = text.count(old)
    assert n == 1, f"{label}: {n} matches (expected 1) in {path}"
    text = text.replace(old, new)
    open(path, "w", encoding="utf-8").write(text)
    print(f"fixed: {label}")


# 1. car.zig importToIPFS
apply(
    "src/core/car.zig",
    (
        "    var child = std.process.Child.init(&argv, allocator);\n"
        "    child.stdout_behavior = .Inherit;\n"
        "    child.stderr_behavior = .Inherit;\n"
        "    child.spawn() catch {\n"
        "        std.debug.print(\"\u26a0\ufe0f  ipfs not found. Install go-ipfs and run:\\n\", .{});\n"
        "        std.debug.print(\"   ipfs dag import {s}\\n\\n\", .{car_path});\n"
        "        return;\n"
        "    };\n"
    ),
    (
        "    var child = std.process.spawn(io, .{\n"
        "        .argv = &argv,\n"
        "        .stdout = .inherit,\n"
        "        .stderr = .inherit,\n"
        "    }) catch {\n"
        "        std.debug.print(\"\u26a0\ufe0f  ipfs not found. Install go-ipfs and run:\\n\", .{});\n"
        "        std.debug.print(\"   ipfs dag import {s}\\n\\n\", .{car_path});\n"
        "        return;\n"
        "    };\n"
    ),
    "car.zig importToIPFS",
)

# 2. dag.zig fetch block
apply(
    "src/core/dag.zig",
    (
        "    var child = std.process.Child.init(&.{ \"curl\", \"-s\", \"-X\", \"POST\", url }, allocator);\n"
        "    child.stdout_behavior = .Pipe;\n"
        "    child.stderr_behavior = .Ignore;\n"
        "    child.spawn() catch {\n"
        "        std.debug.print(\"   \u26a0\ufe0f  curl not available \u2014 cannot fetch from IPFS\\n\", .{});\n"
        "        return;\n"
        "    };\n"
    ),
    (
        "    var child = std.process.spawn(io, .{\n"
        "        .argv = &.{ \"curl\", \"-s\", \"-X\", \"POST\", url },\n"
        "        .stdout = .pipe,\n"
        "        .stderr = .ignore,\n"
        "    }) catch {\n"
        "        std.debug.print(\"   \u26a0\ufe0f  curl not available \u2014 cannot fetch from IPFS\\n\", .{});\n"
        "        return;\n"
        "    };\n"
    ),
    "dag.zig fetch block",
)

# 3. reproduce.zig pip_child block
apply(
    "src/core/reproduce.zig",
    (
        "    var pip_child = std.process.Child.init(&.{ \"pip\", \"freeze\" }, allocator);\n"
        "    pip_child.stdout_behavior = .Pipe;\n"
        "    pip_child.stderr_behavior = .Ignore;\n"
        "    if (pip_child.spawn()) |_| {\n"
    ),
    (
        "    if (std.process.spawn(io, .{\n"
        "        .argv = &.{ \"pip\", \"freeze\" },\n"
        "        .stdout = .pipe,\n"
        "        .stderr = .ignore,\n"
        "    })) |spawned_pip_child| {\n"
        "        var pip_child = spawned_pip_child;\n"
    ),
    "reproduce.zig pip_child",
)

# 4. reproduce.zig conda_child block
apply(
    "src/core/reproduce.zig",
    (
        "    var conda_child = std.process.Child.init(&.{ \"conda\", \"env\", \"export\" }, allocator);\n"
        "    conda_child.stdout_behavior = .Pipe;\n"
        "    conda_child.stderr_behavior = .Ignore;\n"
        "    if (conda_child.spawn()) |_| {\n"
    ),
    (
        "    if (std.process.spawn(io, .{\n"
        "        .argv = &.{ \"conda\", \"env\", \"export\" },\n"
        "        .stdout = .pipe,\n"
        "        .stderr = .ignore,\n"
        "    })) |spawned_conda_child| {\n"
        "        var conda_child = spawned_conda_child;\n"
    ),
    "reproduce.zig conda_child",
)

# 5. reproduce.zig main run-command block
apply(
    "src/core/reproduce.zig",
    (
        "    var child = std.process.Child.init(argv.items, allocator);\n"
    ),
    "",
    "reproduce.zig remove stray Child.init (folded into spawn below)",
)
apply(
    "src/core/reproduce.zig",
    (
        "    child.cwd = work_dir;\n"
        "    child.stdout_behavior = .Pipe;\n"
        "    child.stderr_behavior = .Pipe;\n"
        "\n"
        "    var exit_code: i32 = -1;\n"
        "    var output_buf: [65536]u8 = undefined;\n"
        "    var output_len: usize = 0;\n"
        "\n"
        "    if (child.spawn()) |_| {\n"
    ),
    (
        "    var exit_code: i32 = -1;\n"
        "    var output_buf: [65536]u8 = undefined;\n"
        "    var output_len: usize = 0;\n"
        "\n"
        "    if (std.process.spawn(io, .{\n"
        "        .argv = argv.items,\n"
        "        .cwd = .{ .path = work_dir },\n"
        "        .stdout = .pipe,\n"
        "        .stderr = .pipe,\n"
        "    })) |spawned| {\n"
        "        var child = spawned;\n"
    ),
    "reproduce.zig main run-command block",
)

# 6. publish.zig block
apply(
    "src/core/publish.zig",
    (
        "    var child = std.process.Child.init(argv.items, allocator);\n"
        "    child.stdout_behavior = .Pipe;\n"
        "    child.stderr_behavior = .Pipe;\n"
        "    try child.spawn();\n"
        "\n"
        "    var out_buf: [65536]u8 = undefined;\n"
        "    const bytes_read = try child.stdout.?.read(&out_buf);\n"
        "    const stdout = try allocator.dupe(u8, out_buf[0..bytes_read]);\n"
        "    _ = try child.wait();\n"
    ),
    (
        "    var child = try std.process.spawn(io, .{\n"
        "        .argv = argv.items,\n"
        "        .stdout = .pipe,\n"
        "        .stderr = .pipe,\n"
        "    });\n"
        "\n"
        "    var out_buf: [65536]u8 = undefined;\n"
        "    var child_scratch: [4096]u8 = undefined;\n"
        "    var child_reader = child.stdout.?.reader(io, &child_scratch);\n"
        "    const bytes_read = try child_reader.interface.readSliceShort(&out_buf);\n"
        "    const stdout = try allocator.dupe(u8, out_buf[0..bytes_read]);\n"
        "    _ = try child.wait(io);\n"
    ),
    "publish.zig block",
)

print("\nAll 6 fixes applied successfully")
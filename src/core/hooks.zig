const std = @import("std");

pub const HookType = enum {
    pre_commit,
    post_commit,
    pre_push,
    post_merge,
    commit_msg,

    pub fn toString(self: HookType) []const u8 {
        return switch (self) {
            .pre_commit => "pre-commit",
            .post_commit => "post-commit",
            .pre_push => "pre-push",
            .post_merge => "post-merge",
            .commit_msg => "commit-msg",
        };
    }

    pub fn fromString(s: []const u8) ?HookType {
        if (std.mem.eql(u8, s, "pre-commit")) return .pre_commit;
        if (std.mem.eql(u8, s, "post-commit")) return .post_commit;
        if (std.mem.eql(u8, s, "pre-push")) return .pre_push;
        if (std.mem.eql(u8, s, "post-merge")) return .post_merge;
        if (std.mem.eql(u8, s, "commit-msg")) return .commit_msg;
        return null;
    }
};

pub const HookResult = enum {
    success,
    failure,
    not_found,
};

pub fn runHook(allocator: std.mem.Allocator,
    io: std.Io, repo_path: []const u8, hook_type: HookType, args: []const []const u8) !HookResult {
    const hook_path = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "hooks", hook_type.toString() });
    defer allocator.free(hook_path);

    std.Io.Dir.cwd().access(io, hook_path, .{}) catch |err| {
        if (err == error.FileNotFound) return .not_found;
        return .not_found;
    };

    std.debug.print("🔧 Running {s} hook...\n", .{hook_type.toString()});

    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 1 + args.len);
    defer argv.deinit(allocator);
    try argv.append(allocator, hook_path);
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);

    switch (term) {
        .exited => |code| {
            if (code == 0) {
                return .success;
            } else {
                std.debug.print("❌ Hook {s} failed with exit code {}\n", .{ hook_type.toString(), code });
                return .failure;
            }
        },
        else => {
            std.debug.print("❌ Hook {s} terminated abnormally\n", .{hook_type.toString()});
            return .failure;
        },
    }
}

pub fn installHook(allocator: std.mem.Allocator,
    io: std.Io, repo_path: []const u8, hook_type: HookType, script_content: []const u8) !void {
    const hooks_dir = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "hooks" });
    defer allocator.free(hooks_dir);
    try std.Io.Dir.cwd().createDirPath(io, hooks_dir);

    const hook_path = try std.fs.path.join(allocator, &.{ hooks_dir, hook_type.toString() });
    defer allocator.free(hook_path);

    const file = try std.Io.Dir.cwd().createFile(hook_path, .{});
    defer file.close(io);
    try file.writeAll(script_content);

    try file.chmod(0o755);
    std.debug.print("✅ Installed {s} hook\n", .{hook_type.toString()});
}

pub fn listHooks(allocator: std.mem.Allocator,
    io: std.Io, repo_path: []const u8) !void {
    const hooks_dir = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "hooks" });
    defer allocator.free(hooks_dir);

    var dir = std.Io.Dir.cwd().openDir(io, hooks_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("No hooks installed\n", .{});
            return;
        }
        return err;
    };
    defer dir.close(io);

    var found_any = false;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) {
            found_any = true;
            const hook_path = try std.fs.path.join(allocator, &.{ hooks_dir, entry.name });
            defer allocator.free(hook_path);
            const file = try std.Io.Dir.cwd().openFile(io, hook_path, .{});
            defer file.close(io);
            const stat = try file.stat(io);
            const executable = (stat.permissions.toMode() & 0o111) != 0;
            std.debug.print("  {s} {s}\n", .{ entry.name, if (executable) "[executable]" else "[not executable]" });
        }
    }
    if (!found_any) std.debug.print("No hooks installed\n", .{});
}

pub fn removeHook(allocator: std.mem.Allocator,
    io: std.Io, repo_path: []const u8, hook_type: HookType) !void {
    const hook_path = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "hooks", hook_type.toString() });
    defer allocator.free(hook_path);

    std.Io.Dir.cwd().deleteFile(io, hook_path) catch |err| {
        if (err == error.FileNotFound) return error.HookNotFound;
        return err;
    };
}

pub fn initHooks(allocator: std.mem.Allocator,
    io: std.Io, repo_path: []const u8) !void {
    const hooks_dir = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "hooks" });
    defer allocator.free(hooks_dir);
    try std.Io.Dir.cwd().createDirPath(io, hooks_dir);

    const sample_path = try std.fs.path.join(allocator, &.{ hooks_dir, "pre-commit.sample" });
    defer allocator.free(sample_path);

    const sample_file = try std.Io.Dir.cwd().createFile(sample_path, .{});
    defer sample_file.close(io);
    try sample_file.writeAll("#!/bin/sh\n# Sample hook\n");
}

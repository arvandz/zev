const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");
const blob_mod = @import("blob.zig");

pub const StashEntry = struct {
    id: usize,
    message: []const u8,
    timestamp: i64,
    files: []StashFile,
};

pub const StashFile = struct {
    path: []const u8,
    content: []const u8,
    mode: u32,
};

pub fn stashSave(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, message: ?[]const u8) !void {
    if (repo.index.entries.items.len == 0) {
        std.debug.print("No staged changes to stash\n", .{});
        return;
    }

    const stash_dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "stash" });
    defer allocator.free(stash_dir);
    try std.Io.Dir.cwd().makePath(stash_dir);

    const stash_id = try getNextStashId(allocator, stash_dir);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const now = std.time.Instant.now() catch unreachable;
    const ts = now.timestamp.sec;
    const msg = message orelse "WIP stash";

    try buf.print(allocator, "message {s}\n", .{msg});
    try buf.print(allocator, "timestamp {}\n", .{ts});
    try buf.print(allocator, "count {}\n", .{repo.index.entries.items.len});
    try buf.appendSlice(allocator, "---\n");

    for (repo.index.entries.items) |entry| {
        const file_data = try repo.store.get(io, entry.cid);
        defer allocator.free(file_data);

        const cid_str = try entry.cid.toString(allocator);
        defer allocator.free(cid_str);

        try buf.print(allocator, "file {s} {} {}\n", .{ entry.path, entry.size, entry.mode });
        try buf.print(allocator, "cid {s}\n", .{cid_str});
        try buf.appendSlice(allocator, "content-start\n");
        try buf.appendSlice(allocator, file_data);
        try buf.appendSlice(allocator, "\ncontent-end\n");
    }

    const stash_file_path = try std.fmt.allocPrint(allocator, "{s}/stash-{}", .{ stash_dir, stash_id });
    defer allocator.free(stash_file_path);

    const stash_file = try std.Io.Dir.cwd().createFile(io, stash_file_path, .{});
    defer stash_file.close();
    try stash_file.writeAll(try buf.toOwnedSlice(allocator));

    repo.index.clear();
    try repo.index.write(io);

    std.debug.print("✅ Saved stash@{{{}}} : {s}\n", .{ stash_id, msg });
}

pub fn stashList(allocator: std.mem.Allocator, repo: *Repository) !void {
    const stash_dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "stash" });
    defer allocator.free(stash_dir);

    var dir = std.Io.Dir.cwd().openDir(stash_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("No stashes found\n", .{});
            return;
        }
        return err;
    };
    defer dir.close();

    var found_any = false;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "stash-")) continue;
        found_any = true;

        const file_path = try std.fs.path.join(allocator, &.{ stash_dir, entry.name });
        defer allocator.free(file_path);

        const file = try std.Io.Dir.cwd().openFile(file_path, .{});
        defer file.close();

        var buf: [512]u8 = undefined;
        const n = try file.read(&buf);
        const content = buf[0..n];

        var msg: []const u8 = "unknown";
        var lines = std.mem.splitSequence(u8, content, "\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "message ")) {
                msg = line[8..];
                break;
            }
        }

        const id_str = entry.name[6..];
        std.debug.print("  stash@{{{s}}} : {s}\n", .{ id_str, msg });
    }

    if (!found_any) std.debug.print("No stashes found\n", .{});
}

pub fn stashApply(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, stash_id: usize) !void {
    const stash_dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "stash" });
    defer allocator.free(stash_dir);

    const stash_file_path = try std.fmt.allocPrint(allocator, "{s}/stash-{}", .{ stash_dir, stash_id });
    defer allocator.free(stash_file_path);

    const file = std.Io.Dir.cwd().openFile(io, stash_file_path, .{}) catch |err| {
        if (err == error.FileNotFound) return error.StashNotFound;
        return err;
    };
    defer file.close();

    const stat = try file.stat(io, );
    const content = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(content);
    _ = try file.read(content);

    var in_content = false;
    var current_file: ?[]const u8 = null;
    var current_content: std.ArrayList(u8) = .empty;
    defer current_content.deinit(allocator);
    var current_mode: u32 = 0o644;
    var restored: usize = 0;

    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "file ")) {
            current_file = null;
            var parts = std.mem.splitSequence(u8, line[5..], " ");
            current_file = parts.next() orelse continue;
            _ = parts.next(); // size
            if (parts.next()) |mode_str| {
                current_mode = std.fmt.parseInt(u32, mode_str, 10) catch 0o644;
            }
        } else if (std.mem.eql(u8, line, "content-start")) {
            in_content = true;
            current_content.clearRetainingCapacity();
        } else if (std.mem.eql(u8, line, "content-end")) {
            in_content = false;
            if (current_file) |path| {
                const file_content = try current_content.toOwnedSlice(allocator);
                defer allocator.free(file_content);

                const out_file = try std.Io.Dir.cwd().createFile(io, path, .{});
                defer out_file.close();
                try out_file.writeAll(file_content);

                const content_cid = try repo.store.put(io, file_content);
                try repo.index.addEntry(path, content_cid, file_content.len, current_mode);
                restored += 1;
                std.debug.print("  restored: {s}\n", .{path});
            }
        } else if (in_content) {
            try current_content.appendSlice(allocator, line);
            try current_content.append(allocator, '\n');
        }
    }

    try repo.index.write();
    std.debug.print("✅ Applied stash@{{{}}} ({} files restored)\n", .{ stash_id, restored });
}

pub fn stashDrop(allocator: std.mem.Allocator, repo: *Repository, stash_id: usize) !void {
    const stash_dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "stash" });
    defer allocator.free(stash_dir);

    const stash_file_path = try std.fmt.allocPrint(allocator, "{s}/stash-{}", .{ stash_dir, stash_id });
    defer allocator.free(stash_file_path);

    std.Io.Dir.cwd().deleteFile(stash_file_path) catch |err| {
        if (err == error.FileNotFound) return error.StashNotFound;
        return err;
    };
    std.debug.print("✅ Dropped stash@{{{}}}\n", .{stash_id});
}

fn getNextStashId(allocator: std.mem.Allocator, stash_dir: []const u8) !usize {
    var dir = std.Io.Dir.cwd().openDir(stash_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var max_id: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "stash-")) continue;
        const id = std.fmt.parseInt(usize, entry.name[6..], 10) catch continue;
        if (id >= max_id) max_id = id + 1;
    }
    _ = allocator;
    return max_id;
}

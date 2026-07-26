const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");

pub const Tag = struct {
    name: []const u8,
    commit_cid: cid_mod.CID,
    message: ?[]const u8,
    tagger: ?[]const u8,
    timestamp: i64,
};

pub fn createTag(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, tag_name: []const u8) !void {
    if (tag_name.len == 0) return error.InvalidTagName;
    for (tag_name) |c| {
        if (c == ' ' or c == '\t' or c == '\n') return error.InvalidTagName;
    }

    const head_cid = try repo.getHeadCommit();
    const commit_hash = try head_cid.toString(allocator);
    defer allocator.free(commit_hash);

    const tag_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "tags", tag_name });
    defer allocator.free(tag_path);

    if (std.Io.Dir.cwd().access(tag_path, .{}) == error.FileNotFound or true) {
        const tags_dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "tags" });
        defer allocator.free(tags_dir);
        try std.Io.Dir.cwd().makePath(tags_dir);

        const tag_file = try std.Io.Dir.cwd().createFile(tag_path, .{ .exclusive = false });
        defer tag_file.close(io);
        try tag_file.writeAll(commit_hash);
        try tag_file.writeAll("\n");
    }
}

pub fn createAnnotatedTag(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, tag_name: []const u8, message: []const u8, tagger: []const u8) !void {
    if (tag_name.len == 0) return error.InvalidTagName;

    const head_cid = try repo.getHeadCommit();
    const commit_hash = try head_cid.toString(allocator);
    defer allocator.free(commit_hash);

    const tags_dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "tags" });
    defer allocator.free(tags_dir);
    try std.Io.Dir.cwd().makePath(tags_dir);

    const tag_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "tags", tag_name });
    defer allocator.free(tag_path);

    const tag_file = try std.Io.Dir.cwd().createFile(tag_path, .{ .exclusive = false });
    defer tag_file.close(io);

    const timestamp: u64 = 0;
    var buf: [1024]u8 = undefined;
    const content = try std.fmt.bufPrint(&buf, "commit {s}\ntagger {s}\ntime {}\n\n{s}\n", .{ commit_hash, tagger, timestamp, message });
    try tag_file.writeAll(content);
}

pub fn listTags(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository) !void {
    const tags_dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "tags" });
    defer allocator.free(tags_dir);

    var dir = std.Io.Dir.cwd().openDir(tags_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("No tags found\n", .{});
            return;
        }
        return err;
    };
    defer dir.close(io);

    var found_any = false;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file) {
            found_any = true;
            const tag_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "tags", entry.name });
            defer allocator.free(tag_path);

            const tag_file = try std.Io.Dir.cwd().openFile(tag_path, .{});
            defer tag_file.close(io);

            var buf: [512]u8 = undefined;
            var tag_file_scratch: [4096]u8 = undefined;
            var tag_file_reader = tag_file.reader(io, &tag_file_scratch);
            const bytes = try tag_file_reader.interface.readSliceShort(&buf);
            const content = buf[0..bytes];

            if (std.mem.startsWith(u8, content, "commit ")) {
                std.debug.print("  {s} (annotated)\n", .{entry.name});
            } else {
                const commit_hash = std.mem.trim(u8, content, " \n\r\t");
                std.debug.print("  {s} -> {s}\n", .{ entry.name, commit_hash[0..@min(12, commit_hash.len)] });
            }
        }
    }

    if (!found_any) {
        std.debug.print("No tags found\n", .{});
    }
}

pub fn deleteTag(allocator: std.mem.Allocator, repo: *Repository, tag_name: []const u8) !void {
    const tag_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "tags", tag_name });
    defer allocator.free(tag_path);

    std.Io.Dir.cwd().deleteFile(tag_path) catch |err| {
        if (err == error.FileNotFound) return error.TagNotFound;
        return err;
    };
}

pub fn getTagCommit(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, tag_name: []const u8) !cid_mod.CID {
    const tag_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "tags", tag_name });
    defer allocator.free(tag_path);

    const tag_file = std.Io.Dir.cwd().openFile(tag_path, .{}) catch |err| {
        if (err == error.FileNotFound) return error.TagNotFound;
        return err;
    };
    defer tag_file.close(io);

    var buf: [512]u8 = undefined;
    var tag_file_scratch: [4096]u8 = undefined;
    var tag_file_reader = tag_file.reader(io, &tag_file_scratch);
    const bytes = try tag_file_reader.interface.readSliceShort(&buf);
    var content = std.mem.trim(u8, buf[0..bytes], " \n\r\t");

    if (std.mem.startsWith(u8, content, "commit ")) {
        const line_end = std.mem.indexOf(u8, content, "\n") orelse content.len;
        content = content[7..line_end];
    }

    if (content.len != 64) return error.InvalidTag;

    var hash: [32]u8 = undefined;
    for (0..32) |i| {
        const high = try std.fmt.charToDigit(content[i * 2], 16);
        const low = try std.fmt.charToDigit(content[i * 2 + 1], 16);
        hash[i] = (high << 4) | low;
    }

    return cid_mod.CID{ .hash = hash };
}

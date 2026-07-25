const std = @import("std");
const Repository = @import("repository.zig").Repository;
const tree_mod = @import("tree.zig");
const cid_mod = @import("cid.zig");

pub fn checkoutTree(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, tree_cid: cid_mod.CID, path: []const u8) !void {
    const tree_data = try repo.store.get(io, tree_cid);
    defer allocator.free(tree_data);

    var tree = try tree_mod.Tree.deserialize(allocator, io, tree_data);
    defer tree.deinit();

    if (path.len > 0) {
        const dir_path = try std.fs.path.join(allocator, &.{ repo.path, path });
        defer allocator.free(dir_path);
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
    }

    for (tree.entries.items) |entry| {
        const file_path = if (path.len > 0)
            try std.fs.path.join(allocator, &.{ path, entry.name })
        else
            try allocator.dupe(u8, entry.name);
        defer allocator.free(file_path);

        const full_path = try std.fs.path.join(allocator, &.{ repo.path, file_path });
        defer allocator.free(full_path);

        const is_dir = (entry.mode & 0o040000) != 0;

        if (is_dir) {
            try checkoutTree(allocator, io, repo, entry.cid, file_path);
        } else {
            const blob_data = try repo.store.get(io, entry.cid);
            defer allocator.free(blob_data);
            const file = try std.Io.Dir.cwd().createFile(io, full_path, .{});
            defer file.close(io);
            var buffer: [4096]u8 = undefined;
            var writer = file.writer(io, &buffer);
            try writer.interface.writeAll(blob_data);
            try writer.flush();
            if (@hasDecl(std.Io.File, "chmod")) {
                try file.chmod(entry.mode & 0o777);
            }

            std.debug.print("  {s}\n", .{file_path});
        }
    }
}

pub fn checkoutCommit(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, commit_cid: cid_mod.CID) !void {
    const commit_mod = @import("commit.zig");

    const commit_data = try repo.store.get(io, commit_cid);
    defer allocator.free(commit_data);

    const commit = try commit_mod.Commit.deserialize(allocator, io, commit_data);
    defer allocator.free(commit.author);
    defer allocator.free(commit.message);

    std.debug.print("Checking out files...\n", .{});

    try checkoutTree(allocator, io, repo, commit.tree_cid, "");

    std.debug.print("✅ Files checked out successfully\n", .{});
}

pub fn cleanWorkingDirectory(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, tree_cid: cid_mod.CID, path: []const u8) !void {
    const tree_data = try repo.store.get(io, tree_cid);
    defer allocator.free(tree_data);

    var tree = try tree_mod.Tree.deserialize(allocator, io, tree_data);
    defer tree.deinit();

    for (tree.entries.items) |entry| {
        const file_path = if (path.len > 0)
            try std.fs.path.join(allocator, &.{ path, entry.name })
        else
            try allocator.dupe(u8, entry.name);
        defer allocator.free(file_path);

        const full_path = try std.fs.path.join(allocator, &.{ repo.path, file_path });
        defer allocator.free(full_path);

        const is_dir = (entry.mode & 0o040000) != 0;

        if (is_dir) {
            try cleanWorkingDirectory(allocator, io, repo, entry.cid, file_path);
            std.Io.Dir.cwd().deleteDir(io, full_path) catch {};
        } else {
            std.Io.Dir.cwd().deleteFile(io, full_path) catch {};
        }
    }
}

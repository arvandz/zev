const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");
const commit_mod = @import("commit.zig");
const tree_mod = @import("tree.zig");
const blob_mod = @import("blob.zig");

pub const CherryPickResult = enum {
    success,
    conflict,
    already_applied,
};

pub fn cherryPick(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    pick_cid: cid_mod.CID,
) !CherryPickResult {
    const pick_data = repo.store.get(io, pick_cid) catch {
        std.debug.print("Error: Commit not found\n", .{});
        return .conflict;
    };
    defer allocator.free(pick_data);

    const pick_commit = try commit_mod.Commit.deserialize(allocator, pick_data);
    defer allocator.free(pick_commit.author);
    defer allocator.free(pick_commit.message);

    const current_head = repo.getHeadCommit() catch {
        std.debug.print("Error: No commits on current branch\n", .{});
        return .conflict;
    };

    const pick_parent_tree = if (pick_commit.parent_cid) |parent_cid| blk: {
        const parent_data = repo.store.get(io, parent_cid) catch break :blk null;
        defer allocator.free(parent_data);
        const parent_commit = commit_mod.Commit.deserialize(allocator, parent_data) catch break :blk null;
        defer allocator.free(parent_commit.author);
        defer allocator.free(parent_commit.message);
        break :blk parent_commit.tree_cid;
    } else null;

    const pick_tree = try getTree(allocator, repo, pick_commit.tree_cid);
    defer {
        var t = pick_tree;
        t.deinit();
    }

    const current_commit_data = try repo.store.get(io, current_head);
    defer allocator.free(current_commit_data);
    const current_commit = try commit_mod.Commit.deserialize(allocator, current_commit_data);
    defer allocator.free(current_commit.author);
    defer allocator.free(current_commit.message);

    var current_tree = try getTree(allocator, repo, current_commit.tree_cid);
    defer current_tree.deinit();

    var new_tree = tree_mod.Tree.init(allocator);
    defer new_tree.deinit();

    for (current_tree.entries.items) |entry| {
        try new_tree.entries.append(allocator, tree_mod.FileEntry{
            .name = try allocator.dupe(u8, entry.name),
            .cid = entry.cid,
            .size = entry.size,
            .mode = entry.mode,
        });
    }

    var files_changed: usize = 0;
    for (pick_tree.entries.items) |pick_entry| {
        const changed = if (pick_parent_tree) |ppt| blk: {
            const parent_tree = getTree(allocator, repo, ppt) catch break :blk true;
            var pt = parent_tree;
            defer pt.deinit();
            const parent_entry = pt.getEntry(pick_entry.name);
            break :blk if (parent_entry) |pe| !pe.cid.equals(pick_entry.cid) else true;
        } else true;

        if (!changed) continue;

        files_changed += 1;

        const new_content = try repo.store.get(io, pick_entry.cid);
        defer allocator.free(new_content);

        const new_cid = try repo.store.put(io, new_content);

        if (std.fs.path.dirname(pick_entry.name)) |dir| {
            try std.Io.Dir.cwd().createDirPath(io, dir);
        }
        const out_file = try std.Io.Dir.cwd().createFile(pick_entry.name, .{});
        defer out_file.close(io);
        try out_file.writeAll(new_content);

        var found = false;
        for (new_tree.entries.items) |*nt_entry| {
            if (std.mem.eql(u8, nt_entry.name, pick_entry.name)) {
                nt_entry.cid = new_cid;
                nt_entry.size = pick_entry.size;
                found = true;
                break;
            }
        }
        if (!found) {
            try new_tree.entries.append(allocator, tree_mod.FileEntry{
                .name = try allocator.dupe(u8, pick_entry.name),
                .cid = new_cid,
                .size = pick_entry.size,
                .mode = pick_entry.mode,
            });
        }

        std.debug.print("  applied: {s}\n", .{pick_entry.name});
    }

    if (files_changed == 0) {
        std.debug.print("Nothing to apply - commit has no changes\n", .{});
        return .already_applied;
    }

    const new_tree_data = try new_tree.serialize();
    defer allocator.free(new_tree_data);
    const new_tree_cid = try repo.store.put(io, new_tree_data);

    const author = if (repo.config) |*cfg|
        try std.fmt.allocPrint(allocator, "{s} <{s}>", .{ cfg.user_name, cfg.user_email })
    else
        try allocator.dupe(u8, pick_commit.author);
    defer allocator.free(author);

    const pick_hash = try pick_cid.toString(allocator);
    defer allocator.free(pick_hash);
    const msg = std.mem.trim(u8, pick_commit.message, " \n\r\t");
    const new_message = try std.fmt.allocPrint(allocator, "{s}\n\n(cherry picked from commit {s})", .{ msg, pick_hash[0..8] });
    defer allocator.free(new_message);

    const new_commit = commit_mod.Commit{
        .tree_cid = new_tree_cid,
        .parent_cid = current_head,
        .author = author,
        .message = new_message,
        .timestamp = pick_commit.timestamp,
    };

    const new_commit_data = try new_commit.serialize(allocator);
    defer allocator.free(new_commit_data);
    const new_commit_cid = try repo.store.put(io, new_commit_data);

    try updateHead(allocator, io, repo, new_commit_cid);

    const new_hash = try new_commit_cid.toString(allocator);
    defer allocator.free(new_hash);
    std.debug.print("✅ Cherry-picked: [{s}] {s}\n", .{ new_hash[0..8], msg[0..@min(50, msg.len)] });

    return .success;
}

fn getTree(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, tree_cid: cid_mod.CID) !tree_mod.Tree {
    const tree_data = try repo.store.get(io, tree_cid);
    defer allocator.free(tree_data);
    return try tree_mod.Tree.deserialize(allocator, tree_data);
}

fn updateHead(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, new_cid: cid_mod.CID) !void {
    const zev_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev" });
    defer allocator.free(zev_path);

    const head_path = try std.fs.path.join(allocator, &.{ zev_path, "HEAD" });
    defer allocator.free(head_path);

    const head_file = try std.Io.Dir.cwd().openFile(head_path, .{});
    defer head_file.close(io);

    var buf: [256]u8 = undefined;
    var head_file_scratch: [4096]u8 = undefined;
    var head_file_reader = head_file.reader(io, &head_file_scratch);
    const n = try head_file_reader.interface.readSliceShort(&buf);
    const head_content = std.mem.trim(u8, buf[0..n], " \n\r\t");

    if (std.mem.startsWith(u8, head_content, "ref: ")) {
        const ref_rel = head_content[5..];
        const ref_path = try std.fs.path.join(allocator, &.{ zev_path, ref_rel });
        defer allocator.free(ref_path);

        const ref_file = try std.Io.Dir.cwd().createFile(ref_path, .{});
        defer ref_file.close(io);

        const hash = try new_cid.toString(allocator);
        defer allocator.free(hash);
        try ref_file.writeAll(hash);
    }
}

const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");
const commit_mod = @import("commit.zig");
const tree_mod = @import("tree.zig");
const blob_mod = @import("blob.zig");

pub const RebaseResult = enum {
    success,
    conflict,
    nothing_to_rebase,
};

fn collectCommits(
    allocator: std.mem.Allocator,
    store: *blob_mod.BlobStore,
    start: cid_mod.CID,
    base: cid_mod.CID,
) !std.ArrayList(cid_mod.CID) {
    var commits: std.ArrayList(cid_mod.CID) = .empty;
    var current = start;

    while (true) {
        if (current.equals(base)) break;

        const data = store.get(current) catch break;
        defer allocator.free(data);

        const c = commit_mod.Commit.deserialize(allocator, data) catch break;
        defer allocator.free(c.author);
        defer allocator.free(c.message);

        try commits.append(allocator, current);

        if (c.parent_cid) |parent| {
            current = parent;
        } else break;
    }

    std.mem.reverse(cid_mod.CID, commits.items);
    return commits;
}

fn findCommonAncestor(
    allocator: std.mem.Allocator,
    store: *blob_mod.BlobStore,
    a: cid_mod.CID,
    b: cid_mod.CID,
) !?cid_mod.CID {
    var a_ancestors = std.AutoHashMap([32]u8, void).init(allocator);
    defer a_ancestors.deinit();

    var current = a;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try a_ancestors.put(current.hash, {});
        const data = store.get(current) catch break;
        defer allocator.free(data);
        const c = commit_mod.Commit.deserialize(allocator, data) catch break;
        defer allocator.free(c.author);
        defer allocator.free(c.message);
        if (c.parent_cid) |parent| {
            current = parent;
        } else break;
    }

    current = b;
    var j: usize = 0;
    while (j < 1000) : (j += 1) {
        if (a_ancestors.contains(current.hash)) return current;
        const data = store.get(current) catch break;
        defer allocator.free(data);
        const c = commit_mod.Commit.deserialize(allocator, data) catch break;
        defer allocator.free(c.author);
        defer allocator.free(c.message);
        if (c.parent_cid) |parent| {
            current = parent;
        } else break;
    }

    return null;
}

fn replayCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    commit_cid: cid_mod.CID,
    new_parent: cid_mod.CID,
) !cid_mod.CID {
    const data = try repo.store.get(io, commit_cid);
    defer allocator.free(data);

    const c = try commit_mod.Commit.deserialize(allocator, data);
    defer allocator.free(c.author);
    defer allocator.free(c.message);

    const new_commit = commit_mod.Commit{
        .tree_cid = c.tree_cid,
        .parent_cid = new_parent,
        .author = c.author,
        .message = c.message,
        .timestamp = c.timestamp,
    };

    const new_data = try new_commit.serialize(allocator);
    defer allocator.free(new_data);

    try copyTreeObjects(allocator, repo, c.tree_cid);

    return try repo.store.put(io, new_data);
}

fn copyTreeObjects(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    tree_cid: cid_mod.CID,
) !void {
    const tree_data = repo.store.get(io, tree_cid) catch return;
    defer allocator.free(tree_data);

    var t = tree_mod.Tree.deserialize(allocator, tree_data) catch return;
    defer t.deinit();

    for (t.entries.items) |entry| {
        if (try repo.store.has(io, entry.cid)) continue;
        const blob_data = repo.store.get(io, entry.cid) catch continue;
        defer allocator.free(blob_data);
        _ = try repo.store.put(io, blob_data);
    }
}

pub fn rebase(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    onto_branch: []const u8,
) !RebaseResult {
    const current_head = repo.getHeadCommit(io) catch {
        std.debug.print("Error: No commits on current branch\n", .{});
        return .nothing_to_rebase;
    };

    const onto_ref_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "heads", onto_branch });
    defer allocator.free(onto_ref_path);
    const onto_ref_file = std.Io.Dir.cwd().openFile(onto_ref_path, .{}) catch {
        std.debug.print("Error: Branch '{s}' not found\n", .{onto_branch});
        return .nothing_to_rebase;
    };
    defer onto_ref_file.close(io);
    var onto_buf: [128]u8 = undefined;
    var onto_ref_file_scratch: [4096]u8 = undefined;
    var onto_ref_file_reader = onto_ref_file.reader(io, &onto_ref_file_scratch);
    const onto_n = try onto_ref_file_reader.interface.readSliceShort(&onto_buf);
    const onto_hash_str = std.mem.trim(u8, onto_buf[0..onto_n], " \n\r\t");
    var onto_hash: [32]u8 = undefined;
    for (0..32) |idx| {
        const high = try std.fmt.charToDigit(onto_hash_str[idx * 2], 16);
        const low = try std.fmt.charToDigit(onto_hash_str[idx * 2 + 1], 16);
        onto_hash[idx] = (high << 4) | low;
    }
    const onto_head = cid_mod.CID{ .hash = onto_hash };

    if (current_head.equals(onto_head)) {
        std.debug.print("Already up to date.\n", .{});
        return .nothing_to_rebase;
    }

    const ancestor = try     const ancestor = try findCommonAncestor(allocator, &repo.store, current_head, onto_head);
allocator, io, &repo.store, current_head, onto_head);
    if (ancestor == null) {
        std.debug.print("Error: No common ancestor found\n", .{});
        return .nothing_to_rebase;
    }

    std.debug.print("🔀 Rebasing onto {s}...\n", .{onto_branch});

    var commits_to_replay = try collectCommits(allocator, io, &repo.store, current_head, ancestor.?);
    defer commits_to_replay.deinit(allocator);

    if (commits_to_replay.items.len == 0) {
        std.debug.print("Nothing to rebase.\n", .{});
        return .nothing_to_rebase;
    }

    std.debug.print("  Replaying {} commit(s)...\n", .{commits_to_replay.items.len});

    var new_head = onto_head;
    for (commits_to_replay.items) |commit_cid| {
        const cdata = try repo.store.get(io, commit_cid);
        defer allocator.free(cdata);
        const c = try commit_mod.Commit.deserialize(allocator, cdata);
        defer allocator.free(c.author);
        defer allocator.free(c.message);
        const msg = std.mem.trim(u8, c.message, " \n\r\t");
        const short_msg = msg[0..@min(40, msg.len)];

        new_head = try replayCommit(allocator, repo, commit_cid, new_head);
        const new_hash = try new_head.toString(allocator);
        defer allocator.free(new_hash);
        std.debug.print("  ✅ {s} {s}\n", .{ new_hash[0..8], short_msg });
    }

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
        const ref_path_rel = head_content[5..];
        const ref_path = try std.fs.path.join(allocator, &.{ zev_path, ref_path_rel });
        defer allocator.free(ref_path);

        const ref_file = try std.Io.Dir.cwd().createFile(ref_path, .{});
        defer ref_file.close(io);

        const new_hash = try new_head.toString(allocator);
        defer allocator.free(new_hash);
        try ref_file.writeAll(new_hash);
    }

    std.debug.print("✅ Rebase complete. {} commit(s) replayed.\n", .{commits_to_replay.items.len});
    return .success;
}

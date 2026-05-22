const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");
const commit_mod = @import("commit.zig");
const tree_mod = @import("tree.zig");
const blob_mod = @import("blob.zig");
const checkout_mod = @import("checkout.zig");

pub fn shallowCopy(
    allocator: std.mem.Allocator,
    from_repo: *Repository,
    to_repo: *Repository,
    head: cid_mod.CID,
    depth: usize,
) !void {
    var current_cid = head;
    var remaining = depth;

    while (remaining > 0) : (remaining -= 1) {
        const commit_data = try from_repo.store.get(current_cid);
        defer allocator.free(commit_data);
        _ = try to_repo.store.put(commit_data);

        const commit = try commit_mod.Commit.deserialize(allocator, commit_data);
        defer allocator.free(commit.author);
        defer allocator.free(commit.message);

        try copyTree(allocator, from_repo, to_repo, commit.tree_cid);

        if (commit.parent_cid) |parent| {
            current_cid = parent;
        } else break;
    }

    const shallow_path = try std.fs.path.join(allocator, &.{ to_repo.path, ".zev", "shallow" });
    defer allocator.free(shallow_path);

    const cid_str = try current_cid.toString(allocator);
    defer allocator.free(cid_str);

    const shallow_file = try std.fs.cwd().createFile(shallow_path, .{});
    defer shallow_file.close();
    try shallow_file.writeAll(cid_str);
    try shallow_file.writeAll("\n");
}

fn copyTree(
    allocator: std.mem.Allocator,
    from_repo: *Repository,
    to_repo: *Repository,
    tree_cid: cid_mod.CID,
) !void {
    if (try to_repo.store.has(tree_cid)) return;

    const tree_data = try from_repo.store.get(tree_cid);
    defer allocator.free(tree_data);
    _ = try to_repo.store.put(tree_data);

    var tree = try tree_mod.Tree.deserialize(allocator, tree_data);
    defer tree.deinit();

    for (tree.entries.items) |entry| {
        if (try to_repo.store.has(entry.cid)) continue;
        const blob_data = try from_repo.store.get(entry.cid);
        defer allocator.free(blob_data);
        _ = try to_repo.store.put(blob_data);
    }
}

pub fn isShallow(allocator: std.mem.Allocator, repo_path: []const u8) bool {
    const shallow_path = std.fs.path.join(allocator, &.{ repo_path, ".zev", "shallow" }) catch return false;
    defer allocator.free(shallow_path);
    std.fs.cwd().access(shallow_path, .{}) catch return false;
    return true;
}

pub fn getShallowBoundary(allocator: std.mem.Allocator, repo_path: []const u8) !?cid_mod.CID {
    const shallow_path = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "shallow" });
    defer allocator.free(shallow_path);

    const file = std.fs.cwd().openFile(shallow_path, .{}) catch return null;
    defer file.close();

    var buf: [128]u8 = undefined;
    const n = try file.read(&buf);
    const hash_str = std.mem.trim(u8, buf[0..n], " \n\r\t");
    if (hash_str.len != 64) return null;

    var hash: [32]u8 = undefined;
    for (0..32) |i| {
        const high = try std.fmt.charToDigit(hash_str[i * 2], 16);
        const low = try std.fmt.charToDigit(hash_str[i * 2 + 1], 16);
        hash[i] = (high << 4) | low;
    }
    return cid_mod.CID{ .hash = hash };
}

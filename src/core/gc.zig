const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");
const commit_mod = @import("commit.zig");
const tree_mod = @import("tree.zig");
const blob_mod = @import("blob.zig");

fn collectReachable(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *blob_mod.BlobStore,
    start_cid: cid_mod.CID,
    reachable: *std.AutoHashMap([32]u8, void),
) !void {
    if (reachable.contains(start_cid.hash)) return;
    try reachable.put(start_cid.hash, {});

    const data = store.get(start_cid) catch return;
    defer allocator.free(data);

    if (commit_mod.Commit.deserialize(allocator, data)) |commit| {
        defer allocator.free(commit.author);
        defer allocator.free(commit.message);

        try collectReachable(allocator, io, store, commit.tree_cid, reachable);

        if (commit.parent_cid) |parent| {
            try collectReachable(allocator, io, store, parent, reachable);
        }
        return;
    } else |_| {}

    if (tree_mod.Tree.deserialize(allocator, data)) |*tree| {
        var t = tree.*;
        defer t.deinit();
        for (t.entries.items) |entry| {
            try collectReachable(allocator, io, store, entry.cid, reachable);
        }
        return;
    } else |_| {}
}

fn collectAllReachable(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    reachable: *std.AutoHashMap([32]u8, void),
) !void {
    const heads_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "heads" });
    defer allocator.free(heads_path);

    var dir = std.Io.Dir.cwd().openDir(heads_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;

        const ref_path = try std.fs.path.join(allocator, &.{ heads_path, entry.name });
        defer allocator.free(ref_path);

        const file = std.Io.Dir.cwd().openFile(ref_path, .{}) catch continue;
        defer file.close(io);

        var buf: [128]u8 = undefined;
        var file_scratch: [4096]u8 = undefined;
        var file_reader = file.reader(io, &file_scratch);
        const n = try file_reader.interface.readSliceShort(&buf);
        const hash_str = std.mem.trim(u8, buf[0..n], " \n\r\t");
        if (hash_str.len != 64) continue;

        var hash: [32]u8 = undefined;
        for (0..32) |i| {
            const high = std.fmt.charToDigit(hash_str[i * 2], 16) catch continue;
            const low = std.fmt.charToDigit(hash_str[i * 2 + 1], 16) catch continue;
            hash[i] = (high << 4) | low;
        }

        const branch_cid = cid_mod.CID{ .hash = hash };
        try collectReachable(allocator, io, &repo.store, branch_cid, reachable);
    }

    const tags_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "tags" });
    defer allocator.free(tags_path);

    var tags_dir = std.Io.Dir.cwd().openDir(tags_path, .{ .iterate = true }) catch return;
    defer tags_dir.close(io);

    var tags_it = tags_dir.iterate();
    while (try tags_it.next()) |entry| {
        if (entry.kind != .file) continue;

        const tag_path = try std.fs.path.join(allocator, &.{ tags_path, entry.name });
        defer allocator.free(tag_path);

        const file = std.Io.Dir.cwd().openFile(tag_path, .{}) catch continue;
        var file_scratch2: [4096]u8 = undefined;
        var file_reader2 = file.reader(io, &file_scratch2);
        defer file.close(io);

        var buf: [256]u8 = undefined;
        const n = try file_reader2.interface.readSliceShort(&buf);
        var content = std.mem.trim(u8, buf[0..n], " \n\r\t");

        if (std.mem.startsWith(u8, content, "commit ")) {
            const line_end = std.mem.indexOf(u8, content, "\n") orelse content.len;
            content = content[7..line_end];
        }

        if (content.len != 64) continue;

        var hash: [32]u8 = undefined;
        for (0..32) |i| {
            const high = std.fmt.charToDigit(content[i * 2], 16) catch continue;
            const low = std.fmt.charToDigit(content[i * 2 + 1], 16) catch continue;
            hash[i] = (high << 4) | low;
        }

        const tag_cid = cid_mod.CID{ .hash = hash };
        try collectReachable(allocator, io, &repo.store, tag_cid, reachable);
    }
}

pub const GCResult = struct {
    objects_checked: usize,
    objects_removed: usize,
    bytes_freed: usize,
};

pub fn runGC(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, dry_run: bool) !GCResult {
    var result = GCResult{
        .objects_checked = 0,
        .objects_removed = 0,
        .bytes_freed = 0,
    };

    var reachable = std.AutoHashMap([32]u8, void).init(allocator);
    defer reachable.deinit();

    std.debug.print("🔍 Scanning reachable objects...\n", .{});
    try collectAllReachable(allocator, io, repo, &reachable);
    std.debug.print("✅ Found {} reachable objects\n", .{reachable.count(io, )});

    const objects_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "objects" });
    defer allocator.free(objects_path);

    var objects_dir = std.Io.Dir.cwd().openDir(objects_path, .{ .iterate = true }) catch {
        return result;
    };
    defer objects_dir.close(io);

    var obj_it = objects_dir.iterate();
    while (try obj_it.next()) |obj_entry| {
        if (obj_entry.kind != .file) continue;
        if (obj_entry.name.len != 64) continue;
        result.objects_checked += 1;

        var hash: [32]u8 = undefined;
        var valid = true;
        for (0..32) |i| {
            const high = std.fmt.charToDigit(obj_entry.name[i * 2], 16) catch {
                valid = false;
                break;
            };
            const low = std.fmt.charToDigit(obj_entry.name[i * 2 + 1], 16) catch {
                valid = false;
                break;
            };
            hash[i] = (high << 4) | low;
        }
        if (!valid) continue;

        if (!reachable.contains(hash)) {
            const obj_path = try std.fs.path.join(allocator, &.{ objects_path, obj_entry.name });
            defer allocator.free(obj_path);

            const file = std.Io.Dir.cwd().openFile(obj_path, .{}) catch continue;
            const stat = file.stat(io) catch {
                file.close(io);
                continue;
            };
            file.close(io);

            result.bytes_freed += stat.size;
            result.objects_removed += 1;

            if (dry_run) {
                std.debug.print("  [dry-run] would remove: {s}\n", .{obj_entry.name[0..12]});
            } else {
                std.Io.Dir.cwd().deleteFile(obj_path) catch {};
                std.debug.print("  removed: {s}\n", .{obj_entry.name[0..12]});
            }
        }
    }

    return result;
}

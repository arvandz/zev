const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");
const commit_mod = @import("commit.zig");
const checkout_mod = @import("checkout.zig");

pub const Snapshot = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    commit_hash: []const u8,
    branch: []const u8,
    created_at: i64,
    tags: []const u8,
    author: []const u8,
    experiment_ref: []const u8,
    lineage_refs: []const u8,
    metrics_snapshot: []const u8,
    permanent: bool,
};

fn snapshotDir(allocator: std.mem.Allocator, repo: *Repository) ![]u8 {
    const dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "snapshots" });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn snapshotPath(allocator: std.mem.Allocator, repo: *Repository, id: []const u8) ![]u8 {
    const dir = try snapshotDir(allocator, repo);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, id });
}

fn computeSnapshotId(allocator: std.mem.Allocator, name: []const u8, commit_hash: []const u8, created_at: i64) ![]u8 {
    const fingerprint = try std.fmt.allocPrint(allocator, "snapshot:{s}:{s}:{d}", .{ name, commit_hash, created_at });
    defer allocator.free(fingerprint);
    const content_cid = cid_mod.CID.fromBytes(fingerprint);
    return try content_cid.toString(allocator);
}

fn saveSnapshot(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, snap: Snapshot) !void {
    const path = try snapshotPath(allocator, repo, snap.id);
    defer allocator.free(path);

    const file = try std.Io.Dir.cwd().createFile(path, .{});
    defer file.close(io);

    const permanent_str: []const u8 = if (snap.permanent) "true" else "false";
    const content = try std.fmt.allocPrint(allocator, "id={s}\nname={s}\ndescription={s}\ncommit_hash={s}\nbranch={s}\ncreated_at={d}\ntags={s}\nauthor={s}\nexperiment_ref={s}\nlineage_refs={s}\nmetrics_snapshot={s}\npermanent={s}\n", .{ snap.id, snap.name, snap.description, snap.commit_hash, snap.branch, snap.created_at, snap.tags, snap.author, snap.experiment_ref, snap.lineage_refs, snap.metrics_snapshot, permanent_str });
    defer allocator.free(content);
    try file.writeAll(content);

    const index_path = try std.fmt.allocPrint(allocator, "{s}.name", .{path});
    defer allocator.free(index_path);
    const idx = try std.Io.Dir.cwd().createFile(index_path, .{});
    defer idx.close(io);
    try idx.writeAll(snap.id);
}

fn loadSnapshot(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, id: []const u8) !?Snapshot {
    const path = try snapshotPath(allocator, repo, id);
    defer allocator.free(path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(content);

    var snap_id: []u8 = try allocator.dupe(u8, "");
    var name: []u8 = try allocator.dupe(u8, "");
    var description: []u8 = try allocator.dupe(u8, "");
    var commit_hash: []u8 = try allocator.dupe(u8, "");
    var branch: []u8 = try allocator.dupe(u8, "");
    var created_at: i64 = 0;
    var tags: []u8 = try allocator.dupe(u8, "");
    var author: []u8 = try allocator.dupe(u8, "");
    var experiment_ref: []u8 = try allocator.dupe(u8, "");
    var lineage_refs: []u8 = try allocator.dupe(u8, "");
    var metrics_snapshot: []u8 = try allocator.dupe(u8, "");
    var permanent: bool = false;

    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOf(u8, line, "=") orelse continue;
        const k = line[0..eq];
        const v = line[eq + 1 ..];
        if (std.mem.eql(u8, k, "id")) {
            allocator.free(snap_id);
            snap_id = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "name")) {
            allocator.free(name);
            name = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "description")) {
            allocator.free(description);
            description = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "commit_hash")) {
            allocator.free(commit_hash);
            commit_hash = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "branch")) {
            allocator.free(branch);
            branch = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "created_at")) {
            created_at = std.fmt.parseInt(i64, v, 10) catch 0;
        } else if (std.mem.eql(u8, k, "tags")) {
            allocator.free(tags);
            tags = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "author")) {
            allocator.free(author);
            author = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "experiment_ref")) {
            allocator.free(experiment_ref);
            experiment_ref = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "lineage_refs")) {
            allocator.free(lineage_refs);
            lineage_refs = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "metrics_snapshot")) {
            allocator.free(metrics_snapshot);
            metrics_snapshot = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "permanent")) {
            permanent = std.mem.eql(u8, v, "true");
        }
    }

    return Snapshot{
        .id = snap_id,
        .name = name,
        .description = description,
        .commit_hash = commit_hash,
        .branch = branch,
        .created_at = created_at,
        .tags = tags,
        .author = author,
        .experiment_ref = experiment_ref,
        .lineage_refs = lineage_refs,
        .metrics_snapshot = metrics_snapshot,
        .permanent = permanent,
    };
}

fn freeSnapshot(allocator: std.mem.Allocator, snap: Snapshot) void {
    allocator.free(snap.id);
    allocator.free(snap.name);
    allocator.free(snap.description);
    allocator.free(snap.commit_hash);
    allocator.free(snap.branch);
    allocator.free(snap.tags);
    allocator.free(snap.author);
    allocator.free(snap.experiment_ref);
    allocator.free(snap.lineage_refs);
    allocator.free(snap.metrics_snapshot);
}

fn resolveSnapshotId(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, name_or_id: []const u8) !?[]u8 {
    const direct = try loadSnapshot(allocator, repo, name_or_id);
    if (direct != null) {
        freeSnapshot(allocator, direct.?);
        return try allocator.dupe(u8, name_or_id);
    }

    const dir_path = try snapshotDir(allocator, repo);
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".name")) continue;
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(full_path);
        const stored_id = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .limited(128)) catch continue;
        defer allocator.free(stored_id);
        const snap = (try loadSnapshot(allocator, repo, stored_id)) orelse continue;
        defer freeSnapshot(allocator, snap);
        if (std.mem.eql(u8, snap.name, name_or_id)) {
            return try allocator.dupe(u8, stored_id);
        }
    }
    return null;
}

fn captureMetrics(allocator: std.mem.Allocator, io: std.Io, repo: *Repository) ![]u8 {
    const head = repo.getHeadCommit() catch return try allocator.dupe(u8, "");
    const hash_str = head.toString(allocator) catch return try allocator.dupe(u8, "");
    defer allocator.free(hash_str);

    const metrics_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "metrics", hash_str });
    defer allocator.free(metrics_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, metrics_path, allocator, .limited(64 * 1024)) catch
        return try allocator.dupe(u8, "");

    var result: std.ArrayList(u8) = .empty;
    var first = true;
    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOf(u8, line, "\t") orelse line.len;
        const kv = line[0..tab];
        if (kv.len == 0) continue;
        if (!first) try result.append(allocator, ';');
        try result.appendSlice(allocator, kv);
        first = false;
    }
    allocator.free(content);
    return result.toOwnedSlice(allocator);
}

fn getCurrentBranch(allocator: std.mem.Allocator, io: std.Io, repo: *Repository) ![]u8 {
    const head_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "HEAD" });
    defer allocator.free(head_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, head_path, allocator, .limited(256)) catch
        return try allocator.dupe(u8, "main");
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \n\r\t");
    if (std.mem.startsWith(u8, trimmed, "ref: refs/heads/")) {
        return try allocator.dupe(u8, trimmed[16..]);
    }
    return try allocator.dupe(u8, trimmed);
}

pub fn snapshotCreate(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    name: []const u8,
    description: []const u8,
    tags: []const u8,
    experiment_ref: []const u8,
    lineage_refs: []const u8,
    permanent: bool,
) !void {
    const head = repo.getHeadCommit(io) catch {
        std.debug.print("Error: No commits yet. Make a commit before creating a snapshot.\n", .{});
        return;
    };
    const commit_hash = try head.toString(allocator);
    defer allocator.free(commit_hash);

    const branch = try getCurrentBranch(allocator, io, repo);
    defer allocator.free(branch);

    const now = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);
    const snap_id = try computeSnapshotId(allocator, name, commit_hash, now);
    defer allocator.free(snap_id);

    const existing_id = try resolveSnapshotId(allocator, repo, name);
    if (existing_id != null) {
        allocator.free(existing_id.?);
        std.debug.print("Error: Snapshot '{s}' already exists\n", .{name});
        std.debug.print("Use a different name or 'zev snapshot list' to see existing snapshots\n", .{});
        return;
    }

    const metrics = try captureMetrics(allocator, repo);
    defer allocator.free(metrics);

    const config_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "config" });
    defer allocator.free(config_path);
    const config_content = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(4096)) catch
        try allocator.dupe(u8, "");
    defer allocator.free(config_content);

    var author: []u8 = try allocator.dupe(u8, "unknown");
    var cfg_iter = std.mem.splitSequence(u8, config_content, "\n");
    while (cfg_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "user.name=")) {
            allocator.free(author);
            author = try allocator.dupe(u8, line[10..]);
        }
    }
    defer allocator.free(author);

    const snap = Snapshot{
        .id = snap_id,
        .name = name,
        .description = description,
        .commit_hash = commit_hash,
        .branch = branch,
        .created_at = now,
        .tags = tags,
        .author = author,
        .experiment_ref = experiment_ref,
        .lineage_refs = lineage_refs,
        .metrics_snapshot = metrics,
        .permanent = permanent,
    };

    try saveSnapshot(allocator, io, repo, snap);

    const perm_icon: []const u8 = if (permanent) "🔒" else "📸";
    std.debug.print("{s} Snapshot '{s}' created!\n", .{ perm_icon, name });
    std.debug.print("   ID:      {s}\n", .{snap_id[0..16]});
    std.debug.print("   Commit:  {s}\n", .{commit_hash[0..8]});
    std.debug.print("   Branch:  {s}\n", .{branch});
    if (description.len > 0)
        std.debug.print("   Desc:    {s}\n", .{description});
    if (metrics.len > 0)
        std.debug.print("   Metrics: {s}\n", .{metrics});
    if (tags.len > 0)
        std.debug.print("   Tags:    {s}\n", .{tags});
    if (permanent)
        std.debug.print("   🔒 Marked as permanent (immutable checkpoint)\n", .{});
    std.debug.print("   Full ID: {s}\n", .{snap_id});
}

pub fn snapshotList(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository) !void {
    const dir_path = try snapshotDir(allocator, repo);
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        std.debug.print("No snapshots yet.\n", .{});
        std.debug.print("Create one: zev snapshot create <name> [description]\n", .{});
        return;
    };
    defer dir.close(io);

    std.debug.print("📸 Snapshots:\n\n", .{});
    var count: usize = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".name")) continue;

        const snap = (try loadSnapshot(allocator, repo, entry.name)) orelse continue;
        defer freeSnapshot(allocator, snap);
        count += 1;

        const perm: []const u8 = if (snap.permanent) " 🔒" else "";
        std.debug.print("  📸 {s:<25}{s}\n", .{ snap.name, perm });
        std.debug.print("     ID:     {s}\n", .{snap.id[0..16]});
        std.debug.print("     Commit: {s}  Branch: {s}\n", .{ snap.commit_hash[0..8], snap.branch });
        if (snap.description.len > 0)
            std.debug.print("     {s}\n", .{snap.description});
        if (snap.metrics_snapshot.len > 0)
            std.debug.print("     Metrics: {s}\n", .{snap.metrics_snapshot});
        if (snap.tags.len > 0)
            std.debug.print("     Tags: {s}\n", .{snap.tags});
        std.debug.print("\n", .{});
    }

    if (count == 0) {
        std.debug.print("  No snapshots yet.\n", .{});
        std.debug.print("  Create one: zev snapshot create <name> [description]\n", .{});
    } else {
        std.debug.print("  Total: {d} snapshot(s)\n", .{count});
    }
}

pub fn snapshotShow(allocator: std.mem.Allocator, repo: *Repository, name_or_id: []const u8) !void {
    const snap_id = (try resolveSnapshotId(allocator, repo, name_or_id)) orelse {
        std.debug.print("Error: Snapshot '{s}' not found\n", .{name_or_id});
        return;
    };
    defer allocator.free(snap_id);

    const snap = (try loadSnapshot(allocator, repo, snap_id)) orelse {
        std.debug.print("Error: Snapshot '{s}' not found\n", .{name_or_id});
        return;
    };
    defer freeSnapshot(allocator, snap);

    const perm_str: []const u8 = if (snap.permanent) " [PERMANENT 🔒]" else "";
    std.debug.print("\n📸 Snapshot: {s}{s}\n", .{ snap.name, perm_str });
    std.debug.print("   ─────────────────────────────────────────\n", .{});
    std.debug.print("   ID:          {s}\n", .{snap.id});
    std.debug.print("   Commit:      {s}\n", .{snap.commit_hash});
    std.debug.print("   Branch:      {s}\n", .{snap.branch});
    std.debug.print("   Author:      {s}\n", .{snap.author});
    std.debug.print("   Created:     {d}\n", .{snap.created_at});
    if (snap.description.len > 0)
        std.debug.print("   Description: {s}\n", .{snap.description});
    if (snap.tags.len > 0)
        std.debug.print("   Tags:        {s}\n", .{snap.tags});
    if (snap.experiment_ref.len > 0)
        std.debug.print("   Experiment:  {s}\n", .{snap.experiment_ref});
    if (snap.lineage_refs.len > 0)
        std.debug.print("   Lineage:     {s}\n", .{snap.lineage_refs});
    if (snap.metrics_snapshot.len > 0) {
        std.debug.print("\n   Metrics at snapshot:\n", .{});
        var m_iter = std.mem.splitSequence(u8, snap.metrics_snapshot, ";");
        while (m_iter.next()) |kv| {
            if (kv.len == 0) continue;
            const eq = std.mem.indexOf(u8, kv, "=") orelse continue;
            std.debug.print("     {s:<20} {s}\n", .{ kv[0..eq], kv[eq + 1 ..] });
        }
    }
    std.debug.print("\n", .{});
}

pub fn snapshotRestore(allocator: std.mem.Allocator, repo: *Repository, name_or_id: []const u8) !void {
    const snap_id = (try resolveSnapshotId(allocator, repo, name_or_id)) orelse {
        std.debug.print("Error: Snapshot '{s}' not found\n", .{name_or_id});
        return;
    };
    defer allocator.free(snap_id);

    const snap = (try loadSnapshot(allocator, repo, snap_id)) orelse {
        std.debug.print("Error: Snapshot data missing\n", .{});
        return;
    };
    defer freeSnapshot(allocator, snap);

    if (snap.commit_hash.len != 64) {
        std.debug.print("Error: Invalid commit hash in snapshot\n", .{});
        return;
    }

    var hash: [32]u8 = undefined;
    for (0..32) |i| {
        const high = try std.fmt.charToDigit(snap.commit_hash[i * 2], 16);
        const low = try std.fmt.charToDigit(snap.commit_hash[i * 2 + 1], 16);
        hash[i] = (high << 4) | low;
    }
    const commit_cid = cid_mod.CID{ .hash = hash };

    std.debug.print("🔄 Restoring to snapshot '{s}'...\n", .{snap.name});
    std.debug.print("   Commit: {s}\n", .{snap.commit_hash[0..8]});
    std.debug.print("   Branch: {s}\n", .{snap.branch});

    try checkout_mod.checkoutCommit(allocator, repo, commit_cid);

    std.debug.print("✅ Restored to snapshot '{s}'\n", .{snap.name});
    if (snap.metrics_snapshot.len > 0)
        std.debug.print("   Metrics were: {s}\n", .{snap.metrics_snapshot});
}

pub fn snapshotDiff(allocator: std.mem.Allocator, repo: *Repository, name_a: []const u8, name_b: []const u8) !void {
    const id_a = (try resolveSnapshotId(allocator, repo, name_a)) orelse {
        std.debug.print("Error: Snapshot '{s}' not found\n", .{name_a});
        return;
    };
    defer allocator.free(id_a);

    const id_b = (try resolveSnapshotId(allocator, repo, name_b)) orelse {
        std.debug.print("Error: Snapshot '{s}' not found\n", .{name_b});
        return;
    };
    defer allocator.free(id_b);

    const snap_a = (try loadSnapshot(allocator, repo, id_a)) orelse return;
    defer freeSnapshot(allocator, snap_a);
    const snap_b = (try loadSnapshot(allocator, repo, id_b)) orelse return;
    defer freeSnapshot(allocator, snap_b);

    std.debug.print("\n📸 Snapshot diff: {s} → {s}\n\n", .{ name_a, name_b });
    std.debug.print("   Commit:  {s} → {s}\n", .{ snap_a.commit_hash[0..8], snap_b.commit_hash[0..8] });
    std.debug.print("   Branch:  {s} → {s}\n", .{ snap_a.branch, snap_b.branch });

    if (snap_a.metrics_snapshot.len > 0 or snap_b.metrics_snapshot.len > 0) {
        std.debug.print("\n   Metric changes:\n", .{});

        var map_a = std.StringHashMap([]const u8).init(allocator);
        defer map_a.deinit();
        var map_b = std.StringHashMap([]const u8).init(allocator);
        defer map_b.deinit();

        var it_a = std.mem.splitSequence(u8, snap_a.metrics_snapshot, ";");
        while (it_a.next()) |kv| {
            if (kv.len == 0) continue;
            const eq = std.mem.indexOf(u8, kv, "=") orelse continue;
            try map_a.put(kv[0..eq], kv[eq + 1 ..]);
        }
        var it_b = std.mem.splitSequence(u8, snap_b.metrics_snapshot, ";");
        while (it_b.next()) |kv| {
            if (kv.len == 0) continue;
            const eq = std.mem.indexOf(u8, kv, "=") orelse continue;
            try map_b.put(kv[0..eq], kv[eq + 1 ..]);
        }

        var all_keys = std.StringHashMap(bool).init(allocator);
        defer all_keys.deinit();
        var ka = map_a.iterator();
        while (ka.next()) |e| try all_keys.put(e.key_ptr.*, true);
        var kb = map_b.iterator();
        while (kb.next()) |e| try all_keys.put(e.key_ptr.*, true);

        var keys_iter = all_keys.iterator();
        while (keys_iter.next()) |ke| {
            const key = ke.key_ptr.*;
            const va = map_a.get(key) orelse "(none)";
            const vb = map_b.get(key) orelse "(none)";
            if (std.mem.eql(u8, va, vb)) {
                std.debug.print("     {s:<20} {s} (unchanged)\n", .{ key, va });
            } else {
                const fa = std.fmt.parseFloat(f64, va) catch null;
                const fb = std.fmt.parseFloat(f64, vb) catch null;
                if (fa != null and fb != null) {
                    const delta = fb.? - fa.?;
                    const arrow: []const u8 = if (delta > 0) "▲" else "▼";
                    std.debug.print("     {s:<20} {s} → {s}  {s} {d:.4}\n", .{ key, va, vb, arrow, @abs(delta) });
                } else {
                    std.debug.print("     {s:<20} {s} → {s}\n", .{ key, va, vb });
                }
            }
        }
    }
    std.debug.print("\n", .{});
}

const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");
const commit_mod = @import("commit.zig");

fn containsI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            const hl = if (hc >= 'A' and hc <= 'Z') hc + 32 else hc;
            const nl = if (nc >= 'A' and nc <= 'Z') nc + 32 else nc;
            if (hl != nl) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

const CompareOp = enum { gt, lt, gte, lte, eq };

fn parseOp(s: []const u8) ?struct { op: CompareOp, rest: []const u8 } {
    if (std.mem.startsWith(u8, s, ">=")) return .{ .op = .gte, .rest = s[2..] };
    if (std.mem.startsWith(u8, s, "<=")) return .{ .op = .lte, .rest = s[2..] };
    if (std.mem.startsWith(u8, s, ">")) return .{ .op = .gt, .rest = s[1..] };
    if (std.mem.startsWith(u8, s, "<")) return .{ .op = .lt, .rest = s[1..] };
    if (std.mem.startsWith(u8, s, "=")) return .{ .op = .eq, .rest = s[1..] };
    return null;
}

fn compareFloat(a: f64, op: CompareOp, b: f64) bool {
    return switch (op) {
        .gt => a > b,
        .lt => a < b,
        .gte => a >= b,
        .lte => a <= b,
        .eq => @abs(a - b) < 0.0001,
    };
}

fn readMetricsForCommit(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, hash: []const u8) !std.StringHashMap(f64) {
    var map = std.StringHashMap(f64).init(allocator);
    const path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "metrics", hash });
    defer allocator.free(path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch return map;
    defer allocator.free(content);

    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOf(u8, line, "\t") orelse line.len;
        const kv = line[0..tab];
        const eq = std.mem.indexOf(u8, kv, "=") orelse continue;
        const k = kv[0..eq];
        const v = kv[eq + 1 ..];
        const f = std.fmt.parseFloat(f64, v) catch continue;
        const k_owned = try allocator.dupe(u8, k);
        try map.put(k_owned, f);
    }
    return map;
}

fn freeMetricsMap(allocator: std.mem.Allocator, map: *std.StringHashMap(f64)) void {
    var it = map.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    map.deinit();
}

pub fn searchCommits(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, query: []const u8, max: usize) !void {
    const head = repo.getHeadCommit() catch {
        std.debug.print("No commits yet.\n", .{});
        return;
    };

    std.debug.print("🔍 Searching commits for: \"{s}\"\n\n", .{query});
    var found: usize = 0;
    var current_opt: ?cid_mod.CID = head;
    var checked: usize = 0;

    while (current_opt) |current| {
        if (checked > 10000) break;
        checked += 1;

        const data = repo.store.get(io, current) catch break;
        defer allocator.free(data);
        const commit = commit_mod.Commit.deserialize(allocator, data) catch break;
        defer allocator.free(commit.author);
        defer allocator.free(commit.message);

        const hash_str = current.toString(allocator) catch break;
        defer allocator.free(hash_str);

        const msg = std.mem.trim(u8, commit.message, " \n\r\t");
        const matches = query.len == 0 or
            containsI(msg, query) or
            containsI(commit.author, query) or
            std.mem.startsWith(u8, hash_str, query);

        if (matches) {
            found += 1;
            std.debug.print("  📝 {s}  {s}\n", .{ hash_str[0..8], msg[0..@min(60, msg.len)] });
            std.debug.print("     Author: {s}\n", .{commit.author});
            if (found >= max) {
                std.debug.print("  ... (limit {d} reached, use --limit N for more)\n", .{max});
                break;
            }
        }

        current_opt = commit.parent_cid;
    }

    if (found == 0) {
        std.debug.print("  No commits matching \"{s}\"\n", .{query});
    } else {
        std.debug.print("\n  Found {d} commit(s)\n", .{found});
    }
}

pub fn searchExperiments(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, query: []const u8, status_filter: []const u8) !void {
    const exp_dir_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "experiments" });
    defer allocator.free(exp_dir_path);

    var dir = std.Io.Dir.cwd().openDir(io, exp_dir_path, .{ .iterate = true }) catch {
        std.debug.print("No experiments yet.\n", .{});
        return;
    };
    defer dir.close(io);

    std.debug.print("🔍 Searching experiments", .{});
    if (query.len > 0) std.debug.print(" for: \"{s}\"", .{query});
    if (status_filter.len > 0) std.debug.print(" [status={s}]", .{status_filter});
    std.debug.print("\n\n", .{});

    var found: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".results")) continue;

        const path = try std.fs.path.join(allocator, &.{ exp_dir_path, entry.name });
        defer allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(content);

        var name: []u8 = try allocator.dupe(u8, entry.name);
        var description: []u8 = try allocator.dupe(u8, "");
        var status: []u8 = try allocator.dupe(u8, "");
        var tags: []u8 = try allocator.dupe(u8, "");
        var branch: []u8 = try allocator.dupe(u8, "");
        defer allocator.free(name);
        defer allocator.free(description);
        defer allocator.free(status);
        defer allocator.free(tags);
        defer allocator.free(branch);

        var line_iter = std.mem.splitSequence(u8, content, "\n");
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            const eq = std.mem.indexOf(u8, line, "=") orelse continue;
            const k = line[0..eq];
            const v = line[eq + 1 ..];
            if (std.mem.eql(u8, k, "name")) {
                allocator.free(name);
                name = try allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, k, "description")) {
                allocator.free(description);
                description = try allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, k, "status")) {
                allocator.free(status);
                status = try allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, k, "tags")) {
                allocator.free(tags);
                tags = try allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, k, "branch")) {
                allocator.free(branch);
                branch = try allocator.dupe(u8, v);
            }
        }

        if (status_filter.len > 0 and !std.mem.eql(u8, status, status_filter)) continue;

        const matches = query.len == 0 or
            containsI(name, query) or
            containsI(description, query) or
            containsI(tags, query);
        if (!matches) continue;

        found += 1;
        const icon: []const u8 = if (std.mem.eql(u8, status, "running")) "🔄" else if (std.mem.eql(u8, status, "completed")) "✅" else "🗑️ ";
        std.debug.print("  {s} {s}  [{s}]\n", .{ icon, name, branch });
        if (description.len > 0) std.debug.print("     {s}\n", .{description});
        if (tags.len > 0) std.debug.print("     Tags: {s}\n", .{tags});
        std.debug.print("\n", .{});
    }

    if (found == 0) {
        std.debug.print("  No experiments found\n", .{});
    } else {
        std.debug.print("  Found {d} experiment(s)\n", .{found});
    }
}

pub fn searchMetrics(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, filter: []const u8) !void {
    var key_end: usize = 0;
    for (filter, 0..) |c, i| {
        if (c == '>' or c == '<' or c == '=') {
            key_end = i;
            break;
        }
    }
    if (key_end == 0) {
        std.debug.print("Invalid metric filter. Use: key>value, key<value, key>=value, key<=value, key=value\n", .{});
        std.debug.print("Examples: accuracy>0.9   loss<0.3   epochs>=50\n", .{});
        return;
    }

    const key = filter[0..key_end];
    const op_rest = filter[key_end..];
    const parsed = parseOp(op_rest) orelse {
        std.debug.print("Invalid operator in: {s}\n", .{filter});
        return;
    };
    const threshold = std.fmt.parseFloat(f64, parsed.rest) catch {
        std.debug.print("Invalid value in: {s}\n", .{filter});
        return;
    };

    std.debug.print("🔍 Searching metrics: {s}\n\n", .{filter});

    const head = repo.getHeadCommit() catch {
        std.debug.print("No commits yet.\n", .{});
        return;
    };

    var found: usize = 0;
    var current_opt: ?cid_mod.CID = head;

    while (current_opt) |current| {
        const hash_str = current.toString(allocator) catch break;
        defer allocator.free(hash_str);

        var metrics = try readMetricsForCommit(allocator, repo, hash_str);
        defer freeMetricsMap(allocator, &metrics);

        if (metrics.get(key)) |val| {
            if (compareFloat(val, parsed.op, threshold)) {
                found += 1;

                const data = repo.store.get(io, current) catch {
                    current_opt = null;
                    break;
                };
                defer allocator.free(data);
                const commit = commit_mod.Commit.deserialize(allocator, data) catch break;
                defer allocator.free(commit.author);
                defer allocator.free(commit.message);

                const msg = std.mem.trim(u8, commit.message, " \n\r\t");
                std.debug.print("  📊 {s}  {s}\n", .{ hash_str[0..8], msg[0..@min(60, msg.len)] });
                std.debug.print("     {s} = {d:.4}\n", .{ key, val });

                var mit = metrics.iterator();
                while (mit.next()) |entry| {
                    if (!std.mem.eql(u8, entry.key_ptr.*, key)) {
                        std.debug.print("     {s} = {d:.4}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                    }
                }
                std.debug.print("\n", .{});

                current_opt = commit.parent_cid;
                continue;
            }
        }

        const data = repo.store.get(io, current) catch break;
        defer allocator.free(data);
        const commit = commit_mod.Commit.deserialize(allocator, data) catch break;
        defer allocator.free(commit.author);
        defer allocator.free(commit.message);
        current_opt = commit.parent_cid;
    }

    if (found == 0) {
        std.debug.print("  No commits found where {s}\n", .{filter});
    } else {
        std.debug.print("  Found {d} commit(s) matching {s}\n", .{ found, filter });
    }
}

pub fn searchLineage(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, query: []const u8, type_filter: []const u8) !void {
    const dir_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "lineage" });
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        std.debug.print("No lineage nodes yet.\n", .{});
        return;
    };
    defer dir.close(io);

    std.debug.print("🔍 Searching lineage", .{});
    if (query.len > 0) std.debug.print(" for: \"{s}\"", .{query});
    if (type_filter.len > 0) std.debug.print(" [type={s}]", .{type_filter});
    std.debug.print("\n\n", .{});

    var found: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;

        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(content);

        var node_id: []u8 = try allocator.dupe(u8, entry.name);
        var node_type: []u8 = try allocator.dupe(u8, "");
        var description: []u8 = try allocator.dupe(u8, "");
        var tags: []u8 = try allocator.dupe(u8, "");
        var version: []u8 = try allocator.dupe(u8, "");
        var parents: []u8 = try allocator.dupe(u8, "");
        defer allocator.free(node_id);
        defer allocator.free(node_type);
        defer allocator.free(description);
        defer allocator.free(tags);
        defer allocator.free(version);
        defer allocator.free(parents);

        var line_iter = std.mem.splitSequence(u8, content, "\n");
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            const eq = std.mem.indexOf(u8, line, "=") orelse continue;
            const k = line[0..eq];
            const v = line[eq + 1 ..];
            if (std.mem.eql(u8, k, "id")) {
                allocator.free(node_id);
                node_id = try allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, k, "type")) {
                allocator.free(node_type);
                node_type = try allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, k, "description")) {
                allocator.free(description);
                description = try allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, k, "tags")) {
                allocator.free(tags);
                tags = try allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, k, "version")) {
                allocator.free(version);
                version = try allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, k, "parents")) {
                allocator.free(parents);
                parents = try allocator.dupe(u8, v);
            }
        }

        if (type_filter.len > 0 and !std.mem.eql(u8, node_type, type_filter)) continue;

        const matches = query.len == 0 or
            containsI(node_id, query) or
            containsI(description, query) or
            containsI(tags, query);
        if (!matches) continue;

        found += 1;
        const icon: []const u8 =
            if (std.mem.eql(u8, node_type, "dataset")) "📦" else if (std.mem.eql(u8, node_type, "script")) "📜" else if (std.mem.eql(u8, node_type, "model")) "🤖" else if (std.mem.eql(u8, node_type, "experiment")) "🧪" else "📁";

        std.debug.print("  {s} {s} v{s}  [{s}]\n", .{ icon, node_id, version, node_type });
        if (description.len > 0) std.debug.print("     {s}\n", .{description});
        if (tags.len > 0) std.debug.print("     Tags: {s}\n", .{tags});
        if (parents.len > 0) std.debug.print("     Parents: {s}\n", .{parents});
        std.debug.print("\n", .{});
    }

    if (found == 0) std.debug.print("  No lineage nodes found\n", .{}) else std.debug.print("  Found {d} node(s)\n", .{found});
}

pub fn searchSnapshots(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, query: []const u8, permanent_only: bool) !void {
    const dir_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "snapshots" });
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        std.debug.print("No snapshots yet.\n", .{});
        return;
    };
    defer dir.close(io);

    std.debug.print("🔍 Searching snapshots", .{});
    if (query.len > 0) std.debug.print(" for: \"{s}\"", .{query});
    if (permanent_only) std.debug.print(" [permanent only]", .{});
    std.debug.print("\n\n", .{});

    var found: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".name")) continue;

        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(content);

        var name: []u8 = try allocator.dupe(u8, "");
        var description: []u8 = try allocator.dupe(u8, "");
        var tags: []u8 = try allocator.dupe(u8, "");
        var commit_hash: []u8 = try allocator.dupe(u8, "");
        var branch: []u8 = try allocator.dupe(u8, "");
        var metrics_snap: []u8 = try allocator.dupe(u8, "");
        var permanent = false;
        defer allocator.free(name);
        defer allocator.free(description);
        defer allocator.free(tags);
        defer allocator.free(commit_hash);
        defer allocator.free(branch);
        defer allocator.free(metrics_snap);

        var line_iter = std.mem.splitSequence(u8, content, "\n");
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            const eq = std.mem.indexOf(u8, line, "=") orelse continue;
            const k = line[0..eq];
            const v = line[eq + 1 ..];
            if (std.mem.eql(u8, k, "name")) {
                allocator.free(name);
                name = try allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, k, "description")) {
                allocator.free(description);
                description = try allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, k, "tags")) {
                allocator.free(tags);
                tags = try allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, k, "commit_hash")) {
                allocator.free(commit_hash);
                commit_hash = try allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, k, "branch")) {
                allocator.free(branch);
                branch = try allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, k, "metrics_snapshot")) {
                allocator.free(metrics_snap);
                metrics_snap = try allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, k, "permanent")) {
                permanent = std.mem.eql(u8, v, "true");
            }
        }

        if (permanent_only and !permanent) continue;

        const matches = query.len == 0 or
            containsI(name, query) or
            containsI(description, query) or
            containsI(tags, query);
        if (!matches) continue;

        found += 1;
        const perm: []const u8 = if (permanent) " 🔒" else "";
        std.debug.print("  📸 {s}{s}\n", .{ name, perm });
        std.debug.print("     Commit: {s}  Branch: {s}\n", .{ commit_hash[0..@min(8, commit_hash.len)], branch });
        if (description.len > 0) std.debug.print("     {s}\n", .{description});
        if (metrics_snap.len > 0) std.debug.print("     Metrics: {s}\n", .{metrics_snap});
        if (tags.len > 0) std.debug.print("     Tags: {s}\n", .{tags});
        std.debug.print("\n", .{});
    }

    if (found == 0) std.debug.print("  No snapshots found\n", .{}) else std.debug.print("  Found {d} snapshot(s)\n", .{found});
}

pub fn searchAll(allocator: std.mem.Allocator, repo: *Repository, query: []const u8) !void {
    std.debug.print("🔍 Global search: \"{s}\"\n", .{query});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});

    std.debug.print("── Commits ─────────────────────────────\n", .{});
    try searchCommits(allocator, repo, query, 5);

    std.debug.print("\n── Experiments ─────────────────────────\n", .{});
    try searchExperiments(allocator, repo, query, "");

    std.debug.print("\n── Lineage ──────────────────────────────\n", .{});
    try searchLineage(allocator, repo, query, "");

    std.debug.print("\n── Snapshots ────────────────────────────\n", .{});
    try searchSnapshots(allocator, repo, query, false);
}

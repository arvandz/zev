const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");
const commit_mod = @import("commit.zig");
const tree_mod = @import("tree.zig");

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
}

fn readMetricsForHash(allocator: std.mem.Allocator, repo: *Repository, hash: []const u8) !std.StringHashMap([]u8) {
    var map = std.StringHashMap([]u8).init(allocator);
    const path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "metrics", hash });
    defer allocator.free(path);
    const content = (try readFile(allocator, path)) orelse return map;
    defer allocator.free(content);
    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOf(u8, line, "\t") orelse line.len;
        const kv = line[0..tab];
        const eq = std.mem.indexOf(u8, kv, "=") orelse continue;
        const k = try allocator.dupe(u8, kv[0..eq]);
        const v = try allocator.dupe(u8, kv[eq + 1 ..]);
        try map.put(k, v);
    }
    return map;
}

fn freeStrMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]u8)) void {
    var it = map.iterator();
    while (it.next()) |e| {
        allocator.free(e.key_ptr.*);
        allocator.free(e.value_ptr.*);
    }
    map.deinit();
}

fn hashFromStr(hash_str: []const u8) ![32]u8 {
    if (hash_str.len != 64) return error.InvalidHash;
    var hash: [32]u8 = undefined;
    for (0..32) |i| {
        const high = try std.fmt.charToDigit(hash_str[i * 2], 16);
        const low = try std.fmt.charToDigit(hash_str[i * 2 + 1], 16);
        hash[i] = (high << 4) | low;
    }
    return hash;
}

fn printSeparator() void {
    const divider60 = comptime blk: {
        var s: []const u8 = "";
        for (0..60) |_| s = s ++ "─";
        break :blk s;
    };
    std.debug.print("   {s}\n", .{divider60});
}

fn printRow(label: []const u8, val_a: []const u8, val_b: []const u8) void {
    std.debug.print("   {s:<20} {s:<28} {s}\n", .{ label, val_a, val_b });
}

fn printMetricRow(key: []const u8, va: []const u8, vb: []const u8) void {
    const fa = std.fmt.parseFloat(f64, va) catch null;
    const fb = std.fmt.parseFloat(f64, vb) catch null;

    if (fa != null and fb != null) {
        const delta = fb.? - fa.?;
        if (@abs(delta) < 0.0001) {
            std.debug.print("   {s:<20} {s:<28} {s}  (=)\n", .{ key, va, vb });
        } else {
            const arrow: []const u8 = if (delta > 0) "▲" else "▼";
            var buf: [32]u8 = undefined;
            const delta_str = std.fmt.bufPrint(&buf, "{s}{d:.4}", .{ arrow, @abs(delta) }) catch "?";
            std.debug.print("   {s:<20} {s:<28} {s}  {s}\n", .{ key, va, vb, delta_str });
        }
    } else {
        const changed = if (std.mem.eql(u8, va, vb)) "(=)" else "(changed)";
        std.debug.print("   {s:<20} {s:<28} {s}  {s}\n", .{ key, va, vb, changed });
    }
}

fn collectTreeFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    tree_cid: cid_mod.CID,
    prefix: []const u8,
    out: *std.StringHashMap(cid_mod.CID),
) !void {
    const data = try repo.store.get(io, tree_cid);
    defer allocator.free(data);
    var tree = try tree_mod.Tree.deserialize(allocator, data);
    defer tree.deinit();

    for (tree.entries.items) |entry| {
        const full = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        const is_dir = (entry.mode & 0o040000) != 0;
        if (is_dir) {
            try collectTreeFiles(allocator, repo, entry.cid, full, out);
            allocator.free(full);
        } else {
            try out.put(full, entry.cid);
        }
    }
}

fn freeTreeMap(allocator: std.mem.Allocator, map: *std.StringHashMap(cid_mod.CID)) void {
    var it = map.iterator();
    while (it.next()) |e| allocator.free(e.key_ptr.*);
    map.deinit();
}

pub fn compareCommits(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, hash_a: []const u8, hash_b: []const u8) !void {
    const cid_a = cid_mod.CID{ .hash = try hashFromStr(hash_a) };
    const cid_b = cid_mod.CID{ .hash = try hashFromStr(hash_b) };

    const data_a = repo.store.get(io, cid_a) catch {
        std.debug.print("Error: Commit {s} not found\n", .{hash_a[0..8]});
        return;
    };
    defer allocator.free(data_a);
    const data_b = repo.store.get(io, cid_b) catch {
        std.debug.print("Error: Commit {s} not found\n", .{hash_b[0..8]});
        return;
    };
    defer allocator.free(data_b);

    const ca = try commit_mod.Commit.deserialize(allocator, data_a);
    defer allocator.free(ca.author);
    defer allocator.free(ca.message);
    const cb = try commit_mod.Commit.deserialize(allocator, data_b);
    defer allocator.free(cb.author);
    defer allocator.free(cb.message);

    const msg_a = std.mem.trim(u8, ca.message, " \n\r\t");
    const msg_b = std.mem.trim(u8, cb.message, " \n\r\t");

    std.debug.print("\n⚡ Commit comparison\n", .{});
    printSeparator();
    std.debug.print("   {s:<20} {s:<28} {s}\n", .{ "", hash_a[0..8], hash_b[0..8] });
    printSeparator();
    printRow("Message", msg_a[0..@min(26, msg_a.len)], msg_b[0..@min(26, msg_b.len)]);
    printRow("Author", ca.author[0..@min(26, ca.author.len)], cb.author[0..@min(26, cb.author.len)]);

    var files_a = std.StringHashMap(cid_mod.CID).init(allocator);
    defer freeTreeMap(allocator, &files_a);
    var files_b = std.StringHashMap(cid_mod.CID).init(allocator);
    defer freeTreeMap(allocator, &files_b);

    try collectTreeFiles(allocator, repo, ca.tree_cid, "", &files_a);
    try collectTreeFiles(allocator, repo, cb.tree_cid, "", &files_b);

    var added: usize = 0;
    var removed: usize = 0;
    var modified: usize = 0;

    var it_b = files_b.iterator();
    while (it_b.next()) |eb| {
        if (files_a.get(eb.key_ptr.*)) |cid_in_a| {
            if (!cid_in_a.equals(eb.value_ptr.*)) modified += 1;
        } else {
            added += 1;
        }
    }
    var it_a = files_a.iterator();
    while (it_a.next()) |ea| {
        if (!files_b.contains(ea.key_ptr.*)) removed += 1;
    }

    var change_buf: [64]u8 = undefined;
    const change_a = std.fmt.bufPrint(&change_buf, "{d} file(s)", .{files_a.count(io, )}) catch "?";
    var change_buf2: [64]u8 = undefined;
    const change_b = std.fmt.bufPrint(&change_buf2, "{d} file(s)", .{files_b.count(io, )}) catch "?";
    printRow("Files", change_a, change_b);

    if (added > 0 or removed > 0 or modified > 0) {
        std.debug.print("\n   File changes (A→B):\n", .{});
        var it2 = files_b.iterator();
        while (it2.next()) |eb| {
            if (!files_a.contains(eb.key_ptr.*)) {
                std.debug.print("   + {s}\n", .{eb.key_ptr.*});
            }
        }
        var it3 = files_a.iterator();
        while (it3.next()) |ea| {
            if (!files_b.contains(ea.key_ptr.*)) {
                std.debug.print("   - {s}\n", .{ea.key_ptr.*});
            }
        }
        var it4 = files_b.iterator();
        while (it4.next()) |eb| {
            if (files_a.get(eb.key_ptr.*)) |cid_in_a| {
                if (!cid_in_a.equals(eb.value_ptr.*)) {
                    std.debug.print("   ~ {s}\n", .{eb.key_ptr.*});
                }
            }
        }
    } else {
        std.debug.print("   (identical file trees)\n", .{});
    }

    var metrics_a = try readMetricsForHash(allocator, repo, hash_a);
    defer freeStrMap(allocator, &metrics_a);
    var metrics_b = try readMetricsForHash(allocator, repo, hash_b);
    defer freeStrMap(allocator, &metrics_b);

    if (metrics_a.count(io, ) > 0 or metrics_b.count() > 0) {
        std.debug.print("\n   Metrics:\n", .{});
        std.debug.print("   {s:<20} {s:<28} {s}\n", .{ "Key", hash_a[0..8], hash_b[0..8] });
        printSeparator();

        var all_keys = std.StringHashMap(bool).init(allocator);
        defer all_keys.deinit();
        var ka = metrics_a.iterator();
        while (ka.next()) |e| try all_keys.put(e.key_ptr.*, true);
        var kb = metrics_b.iterator();
        while (kb.next()) |e| try all_keys.put(e.key_ptr.*, true);

        var kit = all_keys.iterator();
        while (kit.next()) |ke| {
            const key = ke.key_ptr.*;
            const va = metrics_a.get(key) orelse "(none)";
            const vb = metrics_b.get(key) orelse "(none)";
            printMetricRow(key, va, vb);
        }
    }
    std.debug.print("\n", .{});
}

fn loadExpFields(allocator: std.mem.Allocator, repo: *Repository, name: []const u8) !?std.StringHashMap([]u8) {
    const path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "experiments", name });
    defer allocator.free(path);
    const content = (try readFile(allocator, path)) orelse return null;
    defer allocator.free(content);

    var map = std.StringHashMap([]u8).init(allocator);
    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOf(u8, line, "=") orelse continue;
        const k = try allocator.dupe(u8, line[0..eq]);
        const v = try allocator.dupe(u8, line[eq + 1 ..]);
        try map.put(k, v);
    }
    return map;
}

pub fn compareExperiments(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, name_a: []const u8, name_b: []const u8) !void {
    var exp_a = (try loadExpFields(allocator, repo, name_a)) orelse {
        std.debug.print("Error: Experiment '{s}' not found\n", .{name_a});
        return;
    };
    defer freeStrMap(allocator, &exp_a);

    var exp_b = (try loadExpFields(allocator, repo, name_b)) orelse {
        std.debug.print("Error: Experiment '{s}' not found\n", .{name_b});
        return;
    };
    defer freeStrMap(allocator, &exp_b);

    std.debug.print("\n🧪 Experiment comparison\n", .{});
    printSeparator();
    std.debug.print("   {s:<20} {s:<28} {s}\n", .{ "", name_a, name_b });
    printSeparator();

    const fields = [_][]const u8{ "status", "branch", "description", "hypothesis", "tags" };
    for (fields) |field| {
        const va = exp_a.get(field) orelse "";
        const vb = exp_b.get(field) orelse "";
        const va_short = va[0..@min(26, va.len)];
        const vb_short = vb[0..@min(26, vb.len)];
        const marker: []const u8 = if (std.mem.eql(u8, va, vb)) "" else " ◀";
        std.debug.print("   {s:<20} {s:<28} {s}{s}\n", .{ field, va_short, vb_short, marker });
    }

    const refs_base = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "heads" });
    defer allocator.free(refs_base);

    const branch_a = exp_a.get("branch") orelse "";
    const branch_b = exp_b.get("branch") orelse "";

    if (branch_a.len > 0 and branch_b.len > 0) {
        const ref_path_a = try std.fs.path.join(allocator, &.{ refs_base, branch_a });
        defer allocator.free(ref_path_a);
        const ref_path_b = try std.fs.path.join(allocator, &.{ refs_base, branch_b });
        defer allocator.free(ref_path_b);

        const hash_a_raw = (try readFile(allocator, ref_path_a)) orelse try allocator.dupe(u8, "");
        defer allocator.free(hash_a_raw);
        const hash_b_raw = (try readFile(allocator, ref_path_b)) orelse try allocator.dupe(u8, "");
        defer allocator.free(hash_b_raw);

        const hash_a = std.mem.trim(u8, hash_a_raw, " \n\r\t");
        const hash_b = std.mem.trim(u8, hash_b_raw, " \n\r\t");

        var metrics_a = try readMetricsForHash(allocator, repo, hash_a);
        defer freeStrMap(allocator, &metrics_a);
        var metrics_b = try readMetricsForHash(allocator, repo, hash_b);
        defer freeStrMap(allocator, &metrics_b);

        if (metrics_a.count(io, ) > 0 or metrics_b.count() > 0) {
            std.debug.print("\n   Metrics:\n", .{});
            std.debug.print("   {s:<20} {s:<28} {s}\n", .{ "Key", name_a, name_b });
            printSeparator();

            var all_keys = std.StringHashMap(bool).init(allocator);
            defer all_keys.deinit();
            var ka = metrics_a.iterator();
            while (ka.next()) |e| try all_keys.put(e.key_ptr.*, true);
            var kb = metrics_b.iterator();
            while (kb.next()) |e| try all_keys.put(e.key_ptr.*, true);

            var kit = all_keys.iterator();
            while (kit.next()) |ke| {
                const va = metrics_a.get(ke.key_ptr.*) orelse "(none)";
                const vb = metrics_b.get(ke.key_ptr.*) orelse "(none)";
                printMetricRow(ke.key_ptr.*, va, vb);
            }
        }
    }
    std.debug.print("\n", .{});
}

fn findSnapshotById(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, name: []const u8) !?std.StringHashMap([]u8) {
    const dir_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "snapshots" });
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".name")) continue;
        const full = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(full);
        const stored_id = (try readFile(allocator, full)) orelse continue;
        defer allocator.free(stored_id);
        const snap_path = try std.fs.path.join(allocator, &.{ dir_path, stored_id });
        defer allocator.free(snap_path);
        const content = (try readFile(allocator, snap_path)) orelse continue;
        defer allocator.free(content);

        var found_name = false;
        var snap_iter = std.mem.splitSequence(u8, content, "\n");
        while (snap_iter.next()) |line| {
            if (std.mem.startsWith(u8, line, "name=") and std.mem.eql(u8, line[5..], name)) {
                found_name = true;
                break;
            }
        }
        if (!found_name) continue;

        var map = std.StringHashMap([]u8).init(allocator);
        var iter2 = std.mem.splitSequence(u8, content, "\n");
        while (iter2.next()) |line| {
            if (line.len == 0) continue;
            const eq = std.mem.indexOf(u8, line, "=") orelse continue;
            const k = try allocator.dupe(u8, line[0..eq]);
            const v = try allocator.dupe(u8, line[eq + 1 ..]);
            try map.put(k, v);
        }
        return map;
    }
    return null;
}

pub fn compareSnapshots(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, name_a: []const u8, name_b: []const u8) !void {
    var snap_a = (try findSnapshotById(allocator, io, repo, name_a)) orelse {
        std.debug.print("Error: Snapshot '{s}' not found\n", .{name_a});
        return;
    };
    defer freeStrMap(allocator, &snap_a);

    var snap_b = (try findSnapshotById(allocator, io, repo, name_b)) orelse {
        std.debug.print("Error: Snapshot '{s}' not found\n", .{name_b});
        return;
    };
    defer freeStrMap(allocator, &snap_b);

    std.debug.print("\n📸 Snapshot comparison\n", .{});
    printSeparator();
    std.debug.print("   {s:<20} {s:<28} {s}\n", .{ "", name_a, name_b });
    printSeparator();

    const fields = [_][]const u8{ "branch", "author", "permanent", "tags" };
    for (fields) |field| {
        const va = snap_a.get(field) orelse "";
        const vb = snap_b.get(field) orelse "";
        const marker: []const u8 = if (std.mem.eql(u8, va, vb)) "" else " ◀";
        std.debug.print("   {s:<20} {s:<28} {s}{s}\n", .{ field, va[0..@min(26, va.len)], vb[0..@min(26, vb.len)], marker });
    }

    const hash_a = snap_a.get("commit_hash") orelse "";
    const hash_b = snap_b.get("commit_hash") orelse "";
    const ha_short = hash_a[0..@min(8, hash_a.len)];
    const hb_short = hash_b[0..@min(8, hash_b.len)];
    const same_commit = std.mem.eql(u8, hash_a, hash_b);
    std.debug.print("   {s:<20} {s:<28} {s}{s}\n", .{ "commit", ha_short, hb_short, if (same_commit) "" else " ◀" });

    const metrics_raw_a = snap_a.get("metrics_snapshot") orelse "";
    const metrics_raw_b = snap_b.get("metrics_snapshot") orelse "";

    if (metrics_raw_a.len > 0 or metrics_raw_b.len > 0) {
        std.debug.print("\n   Metrics:\n", .{});
        std.debug.print("   {s:<20} {s:<28} {s}\n", .{ "Key", name_a, name_b });
        printSeparator();

        var map_a = std.StringHashMap([]const u8).init(allocator);
        defer map_a.deinit();
        var map_b = std.StringHashMap([]const u8).init(allocator);
        defer map_b.deinit();

        var it_a = std.mem.splitSequence(u8, metrics_raw_a, ";");
        while (it_a.next()) |kv| {
            const eq = std.mem.indexOf(u8, kv, "=") orelse continue;
            try map_a.put(kv[0..eq], kv[eq + 1 ..]);
        }
        var it_b = std.mem.splitSequence(u8, metrics_raw_b, ";");
        while (it_b.next()) |kv| {
            const eq = std.mem.indexOf(u8, kv, "=") orelse continue;
            try map_b.put(kv[0..eq], kv[eq + 1 ..]);
        }

        var all_keys = std.StringHashMap(bool).init(allocator);
        defer all_keys.deinit();
        var ka = map_a.iterator();
        while (ka.next()) |e| try all_keys.put(e.key_ptr.*, true);
        var kb = map_b.iterator();
        while (kb.next()) |e| try all_keys.put(e.key_ptr.*, true);

        var kit = all_keys.iterator();
        while (kit.next()) |ke| {
            const va = map_a.get(ke.key_ptr.*) orelse "(none)";
            const vb = map_b.get(ke.key_ptr.*) orelse "(none)";
            printMetricRow(ke.key_ptr.*, va, vb);
        }
    }
    std.debug.print("\n", .{});
}

pub fn compareBranches(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, branch_a: []const u8, branch_b: []const u8) !void {
    const refs_base = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "heads" });
    defer allocator.free(refs_base);

    const path_a = try std.fs.path.join(allocator, &.{ refs_base, branch_a });
    defer allocator.free(path_a);
    const path_b = try std.fs.path.join(allocator, &.{ refs_base, branch_b });
    defer allocator.free(path_b);

    const raw_a = (try readFile(allocator, path_a)) orelse {
        std.debug.print("Error: Branch '{s}' not found\n", .{branch_a});
        return;
    };
    defer allocator.free(raw_a);
    const raw_b = (try readFile(allocator, path_b)) orelse {
        std.debug.print("Error: Branch '{s}' not found\n", .{branch_b});
        return;
    };
    defer allocator.free(raw_b);

    const hash_a = std.mem.trim(u8, raw_a, " \n\r\t");
    const hash_b = std.mem.trim(u8, raw_b, " \n\r\t");

    std.debug.print("\n🌿 Branch comparison: {s} vs {s}\n", .{ branch_a, branch_b });
    printSeparator();
    std.debug.print("   {s:<20} {s:<28} {s}\n", .{ "", branch_a, branch_b });
    printSeparator();
    std.debug.print("   {s:<20} {s:<28} {s}\n", .{ "HEAD commit", hash_a[0..@min(8, hash_a.len)], hash_b[0..@min(8, hash_b.len)] });

    var ancestors_a = std.StringHashMap(usize).init(allocator);
    defer ancestors_a.deinit();
    var ancestors_b = std.StringHashMap(usize).init(allocator);
    defer ancestors_b.deinit();

    {
        var depth: usize = 0;
        var current_opt: ?cid_mod.CID = if (hash_a.len == 64)
            cid_mod.CID{ .hash = hashFromStr(hash_a) catch return }
        else
            null;
        while (current_opt) |cur| {
            const hs = try cur.toString(allocator);
            defer allocator.free(hs);
            try ancestors_a.put(try allocator.dupe(u8, hs), depth);
            depth += 1;
            if (depth > 1000) break;
            const data = repo.store.get(io, cur) catch break;
            defer allocator.free(data);
            const c = commit_mod.Commit.deserialize(allocator, data) catch break;
            defer allocator.free(c.author);
            defer allocator.free(c.message);
            current_opt = c.parent_cid;
        }
    }

    var diverge_hash: ?[]u8 = null;
    var commits_only_b: usize = 0;
    {
        var depth: usize = 0;
        var current_opt: ?cid_mod.CID = if (hash_b.len == 64)
            cid_mod.CID{ .hash = hashFromStr(hash_b) catch return }
        else
            null;
        while (current_opt) |cur| {
            const hs = try cur.toString(allocator);
            defer allocator.free(hs);
            if (ancestors_a.contains(hs)) {
                diverge_hash = try allocator.dupe(u8, hs);
                break;
            }
            commits_only_b += 1;
            depth += 1;
            if (depth > 1000) break;
            const data = repo.store.get(io, cur) catch break;
            defer allocator.free(data);
            const c = commit_mod.Commit.deserialize(allocator, data) catch break;
            defer allocator.free(c.author);
            defer allocator.free(c.message);
            current_opt = c.parent_cid;
        }
    }
    defer if (diverge_hash) |dh| allocator.free(dh);

    var commits_only_a: usize = 0;
    if (diverge_hash) |dh| {
        if (ancestors_a.get(dh)) |depth_at_diverge| {
            commits_only_a = depth_at_diverge;
        }
    }

    var ait = ancestors_a.iterator();
    while (ait.next()) |e| allocator.free(e.key_ptr.*);

    var buf_a: [32]u8 = undefined;
    var buf_b: [32]u8 = undefined;
    const ca_str = std.fmt.bufPrint(&buf_a, "{d} ahead", .{commits_only_a}) catch "?";
    const cb_str = std.fmt.bufPrint(&buf_b, "{d} ahead", .{commits_only_b}) catch "?";
    std.debug.print("   {s:<20} {s:<28} {s}\n", .{ "Divergence", ca_str, cb_str });

    if (diverge_hash) |dh| {
        std.debug.print("   {s:<20} {s}\n", .{ "Common ancestor", dh[0..@min(8, dh.len)] });
    } else {
        std.debug.print("   (No common ancestor found)\n", .{});
    }

    std.debug.print("\n   Recent commits on {s}:\n", .{branch_b});
    var count: usize = 0;
    var cur_opt: ?cid_mod.CID = if (hash_b.len == 64)
        cid_mod.CID{ .hash = hashFromStr(hash_b) catch return }
    else
        null;
    while (cur_opt) |cur| {
        if (count >= 3) break;
        const hs = try cur.toString(allocator);
        defer allocator.free(hs);
        const data = repo.store.get(io, cur) catch break;
        defer allocator.free(data);
        const c = commit_mod.Commit.deserialize(allocator, data) catch break;
        defer allocator.free(c.author);
        defer allocator.free(c.message);
        const msg = std.mem.trim(u8, c.message, " \n\r\t");
        std.debug.print("     {s}  {s}\n", .{ hs[0..8], msg[0..@min(50, msg.len)] });
        count += 1;
        cur_opt = c.parent_cid;
    }
    std.debug.print("\n", .{});
}

const std = @import("std");
const ipld = @import("ipld.zig");
const car_mod = @import("car.zig");
const crypto = @import("crypto.zig");
const ipld_commit = @import("ipld_commit.zig");
const Repository = @import("repository.zig").Repository;

pub const MergeNode = struct {
    parent_a: ipld.CID,
    parent_b: ipld.CID,
    strategy: []const u8,
    resolved: []ResolvedConflict,
    merged_at: i64,
    merged_by: []const u8,

    pub const ResolvedConflict = struct {
        key: []const u8,
        val_a: f64,
        val_b: f64,
        winner: f64,
        source: []const u8,
    };

    pub fn toValue(self: MergeNode, allocator: std.mem.Allocator) !ipld.Value {
        var entries = std.ArrayList(ipld.Value.MapEntry){};

        try entries.append(allocator, .{ .key = try allocator.dupe(u8, "zev"), .value = .{ .string = try allocator.dupe(u8, "merge") } });
        try entries.append(allocator, .{ .key = try allocator.dupe(u8, "parent_a"), .value = .{ .link = self.parent_a } });
        try entries.append(allocator, .{ .key = try allocator.dupe(u8, "parent_b"), .value = .{ .link = self.parent_b } });
        try entries.append(allocator, .{ .key = try allocator.dupe(u8, "strategy"), .value = .{ .string = try allocator.dupe(u8, self.strategy) } });
        try entries.append(allocator, .{ .key = try allocator.dupe(u8, "merged_at"), .value = .{ .int = self.merged_at } });
        try entries.append(allocator, .{ .key = try allocator.dupe(u8, "merged_by"), .value = .{ .string = try allocator.dupe(u8, self.merged_by) } });

        var resolved_list = try allocator.alloc(ipld.Value, self.resolved.len);
        for (self.resolved, 0..) |rc, i| {
            var rc_entries = try allocator.alloc(ipld.Value.MapEntry, 5);
            rc_entries[0] = .{ .key = try allocator.dupe(u8, "key"), .value = .{ .string = try allocator.dupe(u8, rc.key) } };
            rc_entries[1] = .{ .key = try allocator.dupe(u8, "val_a"), .value = .{ .float = rc.val_a } };
            rc_entries[2] = .{ .key = try allocator.dupe(u8, "val_b"), .value = .{ .float = rc.val_b } };
            rc_entries[3] = .{ .key = try allocator.dupe(u8, "winner"), .value = .{ .float = rc.winner } };
            rc_entries[4] = .{ .key = try allocator.dupe(u8, "source"), .value = .{ .string = try allocator.dupe(u8, rc.source) } };
            resolved_list[i] = .{ .map = rc_entries };
        }
        try entries.append(allocator, .{ .key = try allocator.dupe(u8, "resolved"), .value = .{ .list = resolved_list } });

        return ipld.Value{ .map = try entries.toOwnedSlice(allocator) };
    }
};

const MetricMap = struct {
    entries: std.StringHashMap(f64),

    pub fn init(allocator: std.mem.Allocator) MetricMap {
        return .{ .entries = std.StringHashMap(f64).init(allocator) };
    }

    pub fn deinit(self: *MetricMap) void {
        self.entries.deinit();
    }

    pub fn put(self: *MetricMap, key: []const u8, value: f64) !void {
        try self.entries.put(key, value);
    }

    pub fn get(self: MetricMap, key: []const u8) ?f64 {
        return self.entries.get(key);
    }
};

fn collectMetrics(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *ipld.BlockStore,
    root_cid: ipld.CID,
    out: *MetricMap,
) !void {
    const root_short = try root_cid.toShort(allocator);
    defer allocator.free(root_short);

    var root_dir = std.Io.Dir.cwd().openDir(store.base_path, .{ .iterate = true }) catch return;
    defer root_dir.close();
    var rit = root_dir.iterate();
    while (try rit.next()) |shard| {
        if (shard.kind != .directory) continue;
        const sp = try std.fs.path.join(allocator, &.{ store.base_path, shard.name });
        defer allocator.free(sp);
        var sd = std.Io.Dir.cwd().openDir(sp, .{ .iterate = true }) catch continue;
        defer sd.close();
        var si = sd.iterate();
        while (try si.next()) |block| {
            if (block.kind != .file) continue;
            const c = ipld.CID.fromHex(block.name) catch continue;
            const v = store.getNode(allocator, c) catch continue;
            defer v.deinit(allocator);
            if (v != .map) continue;
            const t = v.getString("zev") orelse continue;
            if (!std.mem.eql(u8, t, "metrics")) continue;
            if (v.getLink("commit")) |cc| {
                const cs = try cc.toShort(allocator);
                defer allocator.free(cs);
                if (!std.mem.startsWith(u8, root_short, cs[0..@min(cs.len, 8)]) and
                    !std.mem.startsWith(u8, cs, root_short[0..@min(root_short.len, 8)])) continue;
            }
            if (v.getField("metrics")) |mmap| {
                if (mmap == .map) {
                    for (mmap.map) |entry| {
                        const val: f64 = switch (entry.value) {
                            .float => |f| f,
                            .int => |i| @floatFromInt(i),
                            else => continue,
                        };
                        try out.put(entry.key, val);
                    }
                }
            }
        }
    }
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var it = visited.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        visited.deinit();
    }
    try collectMetricsInner(allocator, store, root_cid, out, &visited, 3);
}

fn collectMetricsInner(
    allocator: std.mem.Allocator,
    store: *ipld.BlockStore,
    c: ipld.CID,
    out: *MetricMap,
    visited: *std.StringHashMap(void),
    depth: usize,
) anyerror!void {
    if (depth == 0) return;

    const short = try c.toShort(allocator);
    if (visited.contains(short)) {
        allocator.free(short);
        return;
    }
    try visited.put(short, {});

    const node = store.getNode(allocator, c) catch return;
    defer node.deinit(allocator);
    if (node != .map) return;

    const ntype = node.getString("zev") orelse "";

    if (std.mem.eql(u8, ntype, "metrics")) {
        if (node.getField("metrics")) |mmap| {
            if (mmap == .map) {
                for (mmap.map) |entry| {
                    const v: f64 = switch (entry.value) {
                        .float => |f| f,
                        .int => |i| @floatFromInt(i),
                        else => continue,
                    };
                    try out.put(entry.key, v);
                }
            }
        }
        for (node.map) |entry| {
            if (std.mem.eql(u8, entry.key, "zev")) continue;
            if (std.mem.eql(u8, entry.key, "commit")) continue;
            if (std.mem.eql(u8, entry.key, "timestamp")) continue;
            if (std.mem.eql(u8, entry.key, "metrics")) continue;
            const v: f64 = switch (entry.value) {
                .float => |f| f,
                .int => |i| @floatFromInt(i),
                else => continue,
            };
            try out.put(entry.key, v);
        }
    }

    for (node.map) |entry| {
        if (entry.value == .link) {
            try collectMetricsInner(allocator, store, entry.value.link, out, visited, depth - 1);
        }
    }
}

fn findHeadCommit(
    allocator: std.mem.Allocator,
    store: *ipld.BlockStore,
) !?ipld.CID {
    var best: ?ipld.CID = null;
    var best_ts: i64 = -1;

    var root_dir = std.Io.Dir.cwd().openDir(store.base_path, .{ .iterate = true }) catch return null;
    defer root_dir.close();
    var rit = root_dir.iterate();
    while (try rit.next()) |shard| {
        if (shard.kind != .directory) continue;
        const sp = try std.fs.path.join(allocator, &.{ store.base_path, shard.name });
        defer allocator.free(sp);
        var sd = std.Io.Dir.cwd().openDir(sp, .{ .iterate = true }) catch continue;
        defer sd.close();
        var si = sd.iterate();
        while (try si.next()) |block| {
            if (block.kind != .file) continue;
            const c = ipld.CID.fromHex(block.name) catch continue;
            const v = store.getNode(allocator, c) catch continue;
            defer v.deinit(allocator);
            if (v != .map) continue;
            const t = v.getString("zev") orelse continue;
            if (!std.mem.eql(u8, t, "commit")) continue;
            const ts = v.getInt("timestamp") orelse 0;
            const has_parent = v.getLink("parent") != null;
            if (has_parent and ts >= best_ts) {
                best = c;
                best_ts = ts;
            } else if (best == null) {
                best = c;
                best_ts = ts;
            }
        }
    }
    return best;
}

pub const MergeStrategy = enum {
    metrics_max,
    metrics_min,
    metrics_avg,
    commit_union,
    dataset_union,
    manual,

    pub fn fromStr(s: []const u8) MergeStrategy {
        if (std.mem.eql(u8, s, "metrics-max")) return .metrics_max;
        if (std.mem.eql(u8, s, "metrics-min")) return .metrics_min;
        if (std.mem.eql(u8, s, "metrics-avg")) return .metrics_avg;
        if (std.mem.eql(u8, s, "commit-union")) return .commit_union;
        if (std.mem.eql(u8, s, "dataset-union")) return .dataset_union;
        return .metrics_max; // default
    }

    pub fn toStr(self: MergeStrategy) []const u8 {
        return switch (self) {
            .metrics_max => "metrics-max",
            .metrics_min => "metrics-min",
            .metrics_avg => "metrics-avg",
            .commit_union => "commit-union",
            .dataset_union => "dataset-union",
            .manual => "manual",
        };
    }
};

pub const MergeResult = struct {
    merge_cid: ipld.CID,
    head_a: ipld.CID,
    head_b: ipld.CID,
    resolved: []MergeNode.ResolvedConflict,
    imported: usize,
    conflicts: usize,
};

pub fn mergeFromCar(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    car_path: []const u8,
    strategy: MergeStrategy,
    dry_run: bool,
    sign_result: bool,
) !void {
    var store = try ipld.BlockStore.init(allocator, io, io, io, repo.path);
    defer store.deinit();

    std.debug.print("🔀 Federated Merge\n\n", .{});
    std.debug.print("   Source:   {s}\n", .{car_path});
    std.debug.print("   Strategy: {s}\n", .{strategy.toStr()});
    if (dry_run) std.debug.print("   Mode:     DRY RUN\n", .{});
    std.debug.print("\n", .{});

    const head_a = blk: {
        const hp = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "ipld_head" });
        defer allocator.free(hp);
        if (std.Io.Dir.cwd().readFileAlloc(io, hp, allocator, .limited(64))) |content| {
            defer allocator.free(content);
            const trimmed = std.mem.trim(u8, content, "\n\r ");
            if (ipld.CID.fromHex(trimmed)) |c| break :blk c else |_| {}
        } else |_| {}
        break :blk try findHeadCommit(allocator, &store) orelse {
            std.debug.print("❌ No IPLD commits in this repo. Run: zev ipld migrate\n\n", .{});
            return;
        };
    };

    std.debug.print("📥 Importing foreign blocks...\n", .{});
    var imported_count: usize = 0;
    {
        const car_data = try std.Io.Dir.cwd().readFileAlloc(io, car_path, allocator, .limited(512 * 1024 * 1024));
        defer allocator.free(car_data);

        var pos: usize = 0;
        const header_len = try readVarint(car_data, &pos);
        pos += header_len;

        while (pos < car_data.len) {
            const block_len = readVarint(car_data, &pos) catch break;
            if (block_len == 0 or pos + block_len > car_data.len) break;
            const block_end = pos + block_len;
            const c = parseCIDBytes(car_data[pos..block_end]) catch {
                pos = block_end;
                continue;
            };
            const cid_len = try cidByteLen(c, allocator);
            pos += cid_len;
            const data = car_data[pos..block_end];
            pos = block_end;

            if (!store.has(c)) {
                if (!dry_run) try store.put(c, data);
                imported_count += 1;
            }
        }
    }
    std.debug.print("   Imported: {d} new blocks\n\n", .{imported_count});

    const head_b = try findHeadInCar(allocator, &store, car_path) orelse
        try findHeadCommit(allocator, &store) orelse {
        std.debug.print("❌ No commit nodes found in foreign CAR.\n\n", .{});
        return;
    };

    const short_a = try head_a.toShort(allocator);
    defer allocator.free(short_a);
    const short_b = try head_b.toShort(allocator);
    defer allocator.free(short_b);

    if (std.mem.eql(u8, short_a, short_b)) {
        std.debug.print("✅ Already up to date — same HEAD.\n\n", .{});
        return;
    }

    std.debug.print("   HEAD A (ours):   {s}\n", .{short_a});
    std.debug.print("   HEAD B (theirs): {s}\n\n", .{short_b});

    var metrics_a = MetricMap.init(allocator, io, io, io, );
    defer metrics_a.deinit();
    var metrics_b = MetricMap.init(allocator, io, io, io, );
    defer metrics_b.deinit();

    try collectMetrics(allocator, io, &store, head_a, &metrics_a);
    try collectMetrics(allocator, io, &store, head_b, &metrics_b);

    std.debug.print("📊 Metrics comparison:\n\n", .{});
    var all_keys = std.StringHashMap(void).init(allocator);
    defer all_keys.deinit();
    var it_a = metrics_a.entries.keyIterator();
    while (it_a.next()) |k| try all_keys.put(k.*, {});
    var it_b = metrics_b.entries.keyIterator();
    while (it_b.next()) |k| try all_keys.put(k.*, {});

    var resolved = std.ArrayList(MergeNode.ResolvedConflict){};
    defer resolved.deinit(allocator);

    var key_it = all_keys.keyIterator();
    while (key_it.next()) |key| {
        const va = metrics_a.get(key.*);
        const vb = metrics_b.get(key.*);

        std.debug.print("   {s}:\n", .{key.*});
        if (va) |v| std.debug.print("     A: {d:.4}\n", .{v}) else std.debug.print("     A: (none)\n", .{});
        if (vb) |v| std.debug.print("     B: {d:.4}\n", .{v}) else std.debug.print("     B: (none)\n", .{});

        if (va == null or vb == null) {
            const winner = va orelse vb.?;
            const source: []const u8 = if (va != null) "a" else "b";
            std.debug.print("     → {s} (only on side {s})\n\n", .{ source, source });
            try resolved.append(allocator, .{
                .key = key.*,
                .val_a = va orelse 0,
                .val_b = vb orelse 0,
                .winner = winner,
                .source = source,
            });
            continue;
        }

        const winner: f64 = switch (strategy) {
            .metrics_max, .commit_union, .dataset_union => if (va.? >= vb.?) va.? else vb.?,
            .metrics_min => if (va.? <= vb.?) va.? else vb.?,
            .metrics_avg => (va.? + vb.?) / 2.0,
            .manual => blk: {
                std.debug.print("     ⚠️  CONFLICT — use --resolve {s}=<value>\n\n", .{key.*});
                break :blk va.?;
            },
        };

        const source: []const u8 = switch (strategy) {
            .metrics_max, .commit_union, .dataset_union => if (va.? >= vb.?) "a" else "b",
            .metrics_min => if (va.? <= vb.?) "a" else "b",
            .metrics_avg => "avg",
            .manual => "a",
        };

        std.debug.print("     → {d:.4} (from {s})\n\n", .{ winner, source });

        try resolved.append(allocator, .{
            .key = key.*,
            .val_a = va.?,
            .val_b = vb.?,
            .winner = winner,
            .source = source,
        });
    }

    if (dry_run) {
        std.debug.print("🔍 Dry run complete — no changes made.\n\n", .{});
        std.debug.print("   Run without --dry-run to apply merge.\n\n", .{});
        return;
    }

    const now = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);
    const identity = try crypto.Identity.loadOrCreate(allocator, repo.path);
    const pk_str = identity.publicKeyB64();

    const mn = MergeNode{
        .parent_a = head_a,
        .parent_b = head_b,
        .strategy = strategy.toStr(),
        .resolved = resolved.items,
        .merged_at = now,
        .merged_by = &pk_str,
    };

    var arena = std.heap.ArenaAllocator.init(allocator, io, io, io, );
    defer arena.deinit();
    const aa = arena.allocator();

    const mn_val = try mn.toValue(aa);
    var merge_cid = try store.putNode(aa, mn_val);

    if (sign_result) {
        merge_cid = try crypto.signCommitNode(allocator, io, &store, repo, merge_cid);
    }

    const head_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "ipld_head" });
    defer allocator.free(head_path);
    const merge_short = try merge_cid.toShort(allocator);
    defer allocator.free(merge_short);
    {
        const f = try std.Io.Dir.cwd().createFile(head_path, .{});
        defer f.close();
        try f.writeAll(merge_short);
    }

    if (resolved.items.len > 0) {
        var metric_entries = try allocator.alloc(ipld.MetricsNode.MetricEntry, resolved.items.len);
        defer allocator.free(metric_entries);
        for (resolved.items, 0..) |rc, i| {
            metric_entries[i] = .{ .key = rc.key, .value = rc.winner };
        }
        const merged_mn = ipld.MetricsNode{
            .commit = merge_cid,
            .entries = metric_entries,
            .timestamp = now,
        };
        const mmv = try merged_mn.toValue(aa);
        _ = try store.putNode(aa, mmv);
    }

    std.debug.print("✅ Merge complete\n\n", .{});
    std.debug.print("   Merge node: {s}\n", .{merge_short});
    std.debug.print("   Parents:    {s} ↔ {s}\n", .{ short_a, short_b });
    std.debug.print("   Conflicts:  {d} resolved\n", .{resolved.items.len});
    if (sign_result) std.debug.print("   Signed:     yes\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("   Inspect: zev dag show {s}\n", .{merge_short});
    std.debug.print("   Log:     zev ipld log\n", .{});
    std.debug.print("   Query:   zev dag query all:merge\n\n", .{});
}

fn findHeadInCar(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *ipld.BlockStore,
    car_path: []const u8,
) !?ipld.CID {
    const car_data = std.Io.Dir.cwd().readFileAlloc(io, car_path, allocator, .limited(512 * 1024 * 1024)) catch return null;
    defer allocator.free(car_data);

    var pos: usize = 0;
    const header_len = readVarint(car_data, &pos) catch return null;
    pos += header_len;

    var best: ?ipld.CID = null;
    var best_ts: i64 = -1;

    while (pos < car_data.len) {
        const block_len = readVarint(car_data, &pos) catch break;
        if (block_len == 0 or pos + block_len > car_data.len) break;
        const block_end = pos + block_len;
        const c = parseCIDBytes(car_data[pos..block_end]) catch {
            pos = block_end;
            continue;
        };
        const cid_len = cidByteLen(c, allocator) catch {
            pos = block_end;
            continue;
        };
        pos += cid_len;
        const data = car_data[pos..block_end];
        pos = block_end;

        const v = ipld.decode(allocator, data) catch continue;
        defer v.deinit(allocator);
        if (v != .map) continue;
        const t = v.getString("zev") orelse continue;
        if (!std.mem.eql(u8, t, "commit")) continue;
        const ts = v.getInt("timestamp") orelse 0;
        const has_parent = v.getLink("parent") != null;
        if (has_parent and ts >= best_ts) {
            best = c;
            best_ts = ts;
        } else if (best == null) {
            best = c;
            best_ts = ts;
        }
        _ = store;
    }
    return best;
}

fn readVarint(data: []const u8, pos: *usize) !usize {
    var result: usize = 0;
    var shift: u6 = 0;
    while (pos.* < data.len) {
        const b = data[pos.*];
        pos.* += 1;
        result |= @as(usize, b & 0x7f) << shift;
        if (b & 0x80 == 0) return result;
        shift += 7;
        if (shift >= 64) return error.VarintOverflow;
    }
    return error.UnexpectedEnd;
}

fn parseCIDBytes(data: []const u8) !ipld.CID {
    if (data.len < 4) return error.TooShort;
    var pos: usize = 0;
    const version = try readVarintU64(data, &pos);
    if (version != 1) return error.UnsupportedVersion;
    const codec = try readVarintU64(data, &pos);
    const mh_code = try readVarintU64(data, &pos);
    const mh_size: u8 = @truncate(try readVarintU64(data, &pos));
    if (pos + mh_size > data.len) return error.TruncatedCID;
    var digest: [32]u8 = std.mem.zeroes([32]u8);
    const copy_len = @min(@as(usize, mh_size), 32);
    @memcpy(digest[0..copy_len], data[pos .. pos + copy_len]);
    return ipld.CID{ .version = 1, .codec = codec, .hash = .{ .code = mh_code, .size = mh_size, .digest = digest } };
}

fn readVarintU64(data: []const u8, pos: *usize) !u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (pos.* < data.len) {
        const b = data[pos.*];
        pos.* += 1;
        result |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return result;
        shift += 7;
        if (shift >= 64) return error.VarintOverflow;
    }
    return error.UnexpectedEnd;
}

fn cidByteLen(c: ipld.CID, allocator: std.mem.Allocator) !usize {
    const bytes = try c.encode(allocator);
    defer allocator.free(bytes);
    return bytes.len;
}

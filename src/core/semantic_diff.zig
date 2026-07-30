const std = @import("std");
const file_diff = @import("file_diff.zig");
const ipld = @import("ipld.zig");
const Repository = @import("repository.zig").Repository;

pub const MetricDelta = struct {
    key: []const u8,
    val_a: ?f64,
    val_b: ?f64,
    delta: f64,
    pct: f64,
    direction: Direction,
    status: Status,

    pub const Direction = enum { improved, degraded, unchanged, only_a, only_b };
    pub const Status = enum { large, moderate, small, negligible };

    pub fn compute(key: []const u8, a: ?f64, b: ?f64) MetricDelta {
        if (a == null and b != null) return .{
            .key = key,
            .val_a = null,
            .val_b = b,
            .delta = b.?,
            .pct = 0,
            .direction = .only_b,
            .status = .large,
        };
        if (a != null and b == null) return .{
            .key = key,
            .val_a = a,
            .val_b = null,
            .delta = 0,
            .pct = 0,
            .direction = .only_a,
            .status = .large,
        };
        if (a == null and b == null) return .{
            .key = key,
            .val_a = null,
            .val_b = null,
            .delta = 0,
            .pct = 0,
            .direction = .unchanged,
            .status = .negligible,
        };

        const av = a.?;
        const bv = b.?;
        const delta = bv - av;
        const pct = if (@abs(av) > 0.0001) (delta / @abs(av)) * 100.0 else 0.0;

        const higher_is_better = isHigherBetter(key);

        const direction: Direction = if (@abs(delta) < 0.0001) .unchanged else if (higher_is_better and delta > 0) .improved else if (higher_is_better and delta < 0) .degraded else if (!higher_is_better and delta < 0) .improved else .degraded;

        const abs_pct = @abs(pct);
        const status: Status = if (abs_pct > 10.0) .large else if (abs_pct > 3.0) .moderate else if (abs_pct > 0.5) .small else .negligible;

        return .{
            .key = key,
            .val_a = av,
            .val_b = bv,
            .delta = delta,
            .pct = pct,
            .direction = direction,
            .status = status,
        };
    }

    fn isHigherBetter(key: []const u8) bool {
        const lower_better = [_][]const u8{
            "loss",    "error",  "mse",    "mae",   "rmse",                "perplexity",
            "latency", "memory", "params", "flops", "false_positive_rate",
        };
        for (lower_better) |lb| {
            if (std.mem.indexOf(u8, key, lb) != null) return false;
        }
        return true;
    }
};

pub const FileDelta = struct {
    path: []const u8,
    cid_a: ?ipld.CID,
    cid_b: ?ipld.CID,
    change: Change,

    pub const Change = enum { added, removed, modified, unchanged };
};

pub const SemanticDiff = struct {
    cid_a: ipld.CID,
    cid_b: ipld.CID,
    metrics: []MetricDelta,
    file_diffs: []file_diff.FileDiff,
    same_dataset: bool,
    dataset_note: []const u8,
    summary: Summary,

    pub const Summary = struct {
        metrics_improved: usize,
        metrics_degraded: usize,
        metrics_unchanged: usize,
        files_changed: usize,
        files_added: usize,
        files_removed: usize,
        overall: Overall,

        pub const Overall = enum { improved, degraded, mixed, unchanged };
    };
};

const MetricMap = std.StringHashMap(f64);

fn collectMetricsForCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *ipld.BlockStore,
    commit_cid: ipld.CID,
) !MetricMap {
    var map = MetricMap.init(allocator);

    const commit_short = try commit_cid.toShort(allocator);
    defer allocator.free(commit_short);

    var text_hash_opt: ?[]u8 = null;
    defer if (text_hash_opt) |th| allocator.free(th);
    {
        const bp = store.base_path;
        const suffix = "/.zev/ipld";
        const repo_path = if (std.mem.endsWith(u8, bp, suffix)) bp[0 .. bp.len - suffix.len] else bp;
        const cd_path = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "ipld_commits" });
        defer allocator.free(cd_path);
        if (std.Io.Dir.cwd().openDir(io, cd_path, .{ .iterate = true })) |*dir| {
            var cdir = dir.*;
            defer cdir.close(io);
            var cit = cdir.iterate();
            while (cit.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                const ep = try std.fs.path.join(allocator, &.{ cd_path, entry.name });
                defer allocator.free(ep);
                const stored = std.Io.Dir.cwd().readFileAlloc(io, ep, allocator, .limited(64)) catch continue;
                defer allocator.free(stored);
                const trimmed = std.mem.trim(u8, stored, "\n\r ");
                const mlen = @min(trimmed.len, commit_short.len);
                if (std.mem.eql(u8, trimmed[0..mlen], commit_short[0..mlen])) {
                    text_hash_opt = try allocator.dupe(u8, entry.name);
                    break;
                }
            }
        } else |_| {}
    }

    var root_dir = std.Io.Dir.cwd().openDir(io, store.base_path, .{ .iterate = true }) catch return map;
    defer root_dir.close(io);

    var rit = root_dir.iterate();
    while (try rit.next(io)) |shard| {
        if (shard.kind != .directory) continue;
        const sp = try std.fs.path.join(allocator, &.{ store.base_path, shard.name });
        defer allocator.free(sp);
        var sd = std.Io.Dir.cwd().openDir(io, sp, .{ .iterate = true }) catch continue;
        defer sd.close(io);
        var si = sd.iterate();
        while (try si.next(io)) |block| {
            if (block.kind != .file) continue;
            const c = ipld.CID.fromHex(block.name) catch continue;
            const v = store.getNode(allocator, io, c) catch continue;
            defer v.deinit(allocator);
            if (v != .map) continue;
            const t = v.getString("zev") orelse continue;
            if (!std.mem.eql(u8, t, "metrics")) continue;

            var belongs = false;
            if (v.getLink("commit")) |cc| {
                const cs = try cc.toShort(allocator);
                defer allocator.free(cs);
                const len = @min(8, @min(commit_short.len, cs.len));
                belongs = std.mem.eql(u8, commit_short[0..len], cs[0..len]);
                if (!belongs) {
                    if (text_hash_opt) |th| {
                        const tlen = @min(8, @min(th.len, cs.len));
                        belongs = std.mem.eql(u8, th[0..tlen], cs[0..tlen]);
                    }
                }
            }

            if (!belongs) {
                if (v.getLink("commit")) |cc| {
                    var buf_a: [16]u8 = undefined;
                    var buf_c: [16]u8 = undefined;
                    const sa = try std.fmt.bufPrint(&buf_a, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ commit_cid.hash.digest[0], commit_cid.hash.digest[1], commit_cid.hash.digest[2], commit_cid.hash.digest[3] });
                    const sc2 = try std.fmt.bufPrint(&buf_c, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ cc.hash.digest[0], cc.hash.digest[1], cc.hash.digest[2], cc.hash.digest[3] });
                    belongs = std.mem.eql(u8, sa, sc2);
                }
            }

            if (!belongs) continue;

            if (v.getField("metrics")) |mmap| {
                if (mmap == .map) {
                    for (mmap.map) |entry| {
                        const val: f64 = switch (entry.value) {
                            .float => |f| f,
                            .int => |i| @floatFromInt(i),
                            else => continue,
                        };
                        const k = try allocator.dupe(u8, entry.key);
                        try map.put(k, val);
                    }
                }
            }
            for (v.map) |entry| {
                if (std.mem.eql(u8, entry.key, "zev")) continue;
                if (std.mem.eql(u8, entry.key, "commit")) continue;
                if (std.mem.eql(u8, entry.key, "timestamp")) continue;
                if (std.mem.eql(u8, entry.key, "metrics")) continue;
                const val: f64 = switch (entry.value) {
                    .float => |f| f,
                    .int => |i| @floatFromInt(i),
                    else => continue,
                };
                const k2 = try allocator.dupe(u8, entry.key);
                try map.put(k2, val);
            }
        }
    }

    return map;
}

fn diffTrees(
    allocator: std.mem.Allocator,
    store: *ipld.BlockStore,
    tree_a: ?ipld.CID,
    tree_b: ?ipld.CID,
    out: *std.ArrayList(FileDelta),
) !void {
    if (tree_a == null and tree_b == null) return;

    if (tree_a == null) {
        try out.append(allocator, .{
            .path = "(all files)",
            .cid_a = null,
            .cid_b = tree_b,
            .change = .added,
        });
        return;
    }
    if (tree_b == null) {
        try out.append(allocator, .{
            .path = "(all files)",
            .cid_a = tree_a,
            .cid_b = null,
            .change = .removed,
        });
        return;
    }

    const short_a = try tree_a.?.toShort(allocator);
    defer allocator.free(short_a);
    const short_b = try tree_b.?.toShort(allocator);
    defer allocator.free(short_b);

    if (std.mem.eql(u8, short_a, short_b)) {
        try out.append(allocator, .{
            .path = "(working tree)",
            .cid_a = tree_a,
            .cid_b = tree_b,
            .change = .unchanged,
        });
        return;
    }

    _ = store;
    try out.append(allocator, .{
        .path = "(working tree)",
        .cid_a = tree_a,
        .cid_b = tree_b,
        .change = .modified,
    });
}

pub fn computeSemanticDiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *ipld.BlockStore,
    cid_a: ipld.CID,
    cid_b: ipld.CID,
) !SemanticDiff {
    const node_a = try store.getNode(allocator, io, cid_a);
    defer node_a.deinit(allocator);
    const node_b = try store.getNode(allocator, io, cid_b);
    defer node_b.deinit(allocator);

    var metrics_a = try collectMetricsForCommit(allocator, io, store, cid_a);
    defer {
        var kit = metrics_a.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        metrics_a.deinit();
    }
    var metrics_b = try collectMetricsForCommit(allocator, io, store, cid_b);
    defer {
        var kit = metrics_b.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        metrics_b.deinit();
    }

    var all_keys = std.StringHashMap(void).init(allocator);
    defer {
        var kit = all_keys.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        all_keys.deinit();
    }
    var it_a = metrics_a.keyIterator();
    while (it_a.next()) |k| try all_keys.put(try allocator.dupe(u8, k.*), {});
    var it_b = metrics_b.keyIterator();
    while (it_b.next()) |k| {
        if (!all_keys.contains(k.*))
            try all_keys.put(try allocator.dupe(u8, k.*), {});
    }

    var deltas = std.ArrayList(MetricDelta).empty;
    var key_it = all_keys.keyIterator();
    while (key_it.next()) |key| {
        const va = metrics_a.get(key.*);
        const vb = metrics_b.get(key.*);
        const key_owned = try allocator.dupe(u8, key.*);
        const delta = MetricDelta.compute(key_owned, va, vb);
        try deltas.append(allocator, delta);
    }

    const items = deltas.items;
    for (0..items.len) |i| {
        for (0..items.len - i - 1) |j| {
            const priority_a = @intFromEnum(items[j].status);
            const priority_b = @intFromEnum(items[j + 1].status);
            if (priority_a < priority_b) {
                const tmp = items[j];
                items[j] = items[j + 1];
                items[j + 1] = tmp;
            }
        }
    }

    const tree_a = if (node_a == .map) node_a.getLink("tree") else null;
    const tree_b = if (node_b == .map) node_b.getLink("tree") else null;

    const bp = store.base_path;
    const suffix = "/.zev/ipld";
    const repo_path = if (std.mem.endsWith(u8, bp, suffix))
        bp[0 .. bp.len - suffix.len]
    else
        bp;

    var file_diffs: []file_diff.FileDiff = &.{};
    if (tree_a != null and tree_b != null) {
        const short_ta = try tree_a.?.toShort(allocator);
        defer allocator.free(short_ta);
        const short_tb = try tree_b.?.toShort(allocator);
        defer allocator.free(short_tb);
        file_diffs = file_diff.diffTrees(allocator, io, repo_path, short_ta, short_tb) catch &.{};
    }

    const ds_a = if (node_a == .map) node_a.getLink("dataset") else null;
    const ds_b = if (node_b == .map) node_b.getLink("dataset") else null;
    var same_dataset = false;
    var dataset_note: []const u8 = "no dataset tracked";
    if (ds_a != null and ds_b != null) {
        const sa = try ds_a.?.toShort(allocator);
        defer allocator.free(sa);
        const sb = try ds_b.?.toShort(allocator);
        defer allocator.free(sb);
        same_dataset = std.mem.eql(u8, sa, sb);
        dataset_note = if (same_dataset) "identical (same CID)" else "changed";
    } else if (ds_a == null and ds_b == null) {
        dataset_note = "not tracked in either commit";
    }

    var n_improved: usize = 0;
    var n_degraded: usize = 0;
    var n_unchanged: usize = 0;
    var n_changed: usize = 0;
    var n_added: usize = 0;
    var n_removed: usize = 0;

    for (deltas.items) |d| {
        switch (d.direction) {
            .improved => n_improved += 1,
            .degraded => n_degraded += 1,
            .unchanged => n_unchanged += 1,
            .only_a => n_removed += 1,
            .only_b => n_added += 1,
        }
    }
    for (file_diffs) |f| {
        switch (f.change) {
            .modified => n_changed += 1,
            .added => n_added += 1,
            .removed => n_removed += 1,
            .unchanged => {},
        }
    }

    const overall: SemanticDiff.Summary.Overall =
        if (n_improved > 0 and n_degraded == 0) .improved else if (n_degraded > 0 and n_improved == 0) .degraded else if (n_improved > 0 and n_degraded > 0) .mixed else .unchanged;

    return SemanticDiff{
        .cid_a = cid_a,
        .cid_b = cid_b,
        .metrics = try deltas.toOwnedSlice(allocator),
        .file_diffs = file_diffs,
        .same_dataset = same_dataset,
        .dataset_note = dataset_note,
        .summary = .{
            .metrics_improved = n_improved,
            .metrics_degraded = n_degraded,
            .metrics_unchanged = n_unchanged,
            .files_changed = n_changed,
            .files_added = n_added,
            .files_removed = n_removed,
            .overall = overall,
        },
    };
}

pub fn resolveRef(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *ipld.BlockStore,
    repo: *Repository,
    ref: []const u8,
) !ipld.CID {
    if (ref.len >= 8 and !std.mem.startsWith(u8, ref, "HEAD")) {
        return ipld.CID.fromHex(ref) catch return error.InvalidCID;
    }

    const head_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "ipld_head" });
    defer allocator.free(head_path);

    const head_content = try std.Io.Dir.cwd().readFileAlloc(io, head_path, allocator, .limited(64));
    defer allocator.free(head_content);
    const head_cid = try ipld.CID.fromHex(std.mem.trim(u8, head_content, "\n\r "));

    if (std.mem.eql(u8, ref, "HEAD")) return head_cid;

    if (std.mem.startsWith(u8, ref, "HEAD~")) {
        const n = std.fmt.parseInt(usize, ref[5..], 10) catch 1;
        var current = head_cid;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const node = store.getNode(allocator, io, current) catch break;
            defer node.deinit(allocator);
            current = node.getLink("parent") orelse break;
        }
        return current;
    }

    return head_cid;
}

pub fn printSemanticDiff(
    allocator: std.mem.Allocator,
    diff: *const SemanticDiff,
    metric_filter: ?[]const u8,
    format: []const u8,
) !void {
    const short_a = try diff.cid_a.toShort(allocator);
    defer allocator.free(short_a);
    const short_b = try diff.cid_b.toShort(allocator);
    defer allocator.free(short_b);

    if (std.mem.eql(u8, format, "json")) {
        try printJsonDiff(allocator, diff, short_a, short_b);
        return;
    }

    std.debug.print("🔬 Semantic Diff: {s} → {s}\n\n", .{ short_a, short_b });

    const overall_icon: []const u8 = switch (diff.summary.overall) {
        .improved => "✅",
        .degraded => "❌",
        .mixed => "⚠️ ",
        .unchanged => "➡️ ",
    };
    const overall_text: []const u8 = switch (diff.summary.overall) {
        .improved => "IMPROVED",
        .degraded => "DEGRADED",
        .mixed => "MIXED",
        .unchanged => "UNCHANGED",
    };
    std.debug.print("   {s} Overall: {s}\n\n", .{ overall_icon, overall_text });

    if (diff.metrics.len > 0) {
        std.debug.print("📊 Metrics:\n\n", .{});
        for (diff.metrics) |d| {
            if (metric_filter) |f| {
                if (!std.mem.eql(u8, d.key, f)) continue;
            }

            const icon: []const u8 = switch (d.direction) {
                .improved => "✅",
                .degraded => "❌",
                .unchanged => "➡️ ",
                .only_a => "🗑️ ",
                .only_b => "🆕",
            };

            std.debug.print("   {s} {s}:\n", .{ icon, d.key });

            switch (d.direction) {
                .only_b => {
                    std.debug.print("      new: {d:.4}\n\n", .{d.val_b.?});
                },
                .only_a => {
                    std.debug.print("      removed: {d:.4}\n\n", .{d.val_a.?});
                },
                .unchanged => {
                    std.debug.print("      {d:.4} (no change)\n\n", .{d.val_a.?});
                },
                else => {
                    const sign: []const u8 = if (d.delta > 0) "+" else "";
                    std.debug.print("      {d:.4} → {d:.4}  ({s}{d:.4}  {s}{d:.1}%)\n", .{ d.val_a.?, d.val_b.?, sign, d.delta, sign, d.pct });
                    const sig: []const u8 = switch (d.status) {
                        .large => "large change",
                        .moderate => "moderate change",
                        .small => "small change",
                        .negligible => "negligible",
                    };
                    std.debug.print("      [{s}]\n\n", .{sig});
                },
            }
        }
        std.debug.print("   Improved: {d}  Degraded: {d}  Unchanged: {d}\n\n", .{ diff.summary.metrics_improved, diff.summary.metrics_degraded, diff.summary.metrics_unchanged });
    } else {
        std.debug.print("📊 Metrics: none tracked\n\n", .{});
    }

    try file_diff.printFileDiffs(allocator, diff.file_diffs);

    std.debug.print("📂 Dataset: {s}\n\n", .{diff.dataset_note});

    std.debug.print("─────────────────────────────────\n", .{});
    std.debug.print("   {d} metric(s) improved\n", .{diff.summary.metrics_improved});
    std.debug.print("   {d} metric(s) degraded\n", .{diff.summary.metrics_degraded});
    std.debug.print("   {d} file(s) changed\n\n", .{diff.summary.files_changed + diff.summary.files_added + diff.summary.files_removed});
}

fn printJsonDiff(
    allocator: std.mem.Allocator,
    diff: *const SemanticDiff,
    short_a: []const u8,
    short_b: []const u8,
) !void {
    std.debug.print("{{\n", .{});
    std.debug.print("  \"from\": \"{s}\",\n", .{short_a});
    std.debug.print("  \"to\":   \"{s}\",\n", .{short_b});
    std.debug.print("  \"overall\": \"{s}\",\n", .{@tagName(diff.summary.overall)});
    std.debug.print("  \"metrics\": [\n", .{});
    for (diff.metrics, 0..) |d, i| {
        const comma: []const u8 = if (i < diff.metrics.len - 1) "," else "";
        std.debug.print("    {{\"key\":\"{s}\"", .{d.key});
        if (d.val_a) |v| std.debug.print(",\"from\":{d:.6}", .{v});
        if (d.val_b) |v| std.debug.print(",\"to\":{d:.6}", .{v});
        std.debug.print(",\"delta\":{d:.6}", .{d.delta});
        std.debug.print(",\"pct\":{d:.2}", .{d.pct});
        std.debug.print(",\"direction\":\"{s}\"", .{@tagName(d.direction)});
        std.debug.print(",\"status\":\"{s}\"}}{s}\n", .{ @tagName(d.status), comma });
    }
    std.debug.print("  ]\n}}\n", .{});
    _ = allocator;
}

pub fn cmdSemanticDiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    ref_a: []const u8,
    ref_b: []const u8,
    metric_filter: ?[]const u8,
    format: []const u8,
) !void {
    var store = try ipld.BlockStore.init(allocator, io, repo.path);
    defer store.deinit();

    const cid_a = resolveRef(allocator, io, &store, repo, ref_a) catch {
        std.debug.print("❌ Cannot resolve: {s}\n", .{ref_a});
        std.debug.print("   Run: zev ipld migrate\n\n", .{});
        return;
    };
    const cid_b = resolveRef(allocator, io, &store, repo, ref_b) catch {
        std.debug.print("❌ Cannot resolve: {s}\n", .{ref_b});
        return;
    };

    const short_a = try cid_a.toShort(allocator);
    defer allocator.free(short_a);
    const short_b = try cid_b.toShort(allocator);
    defer allocator.free(short_b);

    if (std.mem.eql(u8, short_a, short_b)) {
        std.debug.print("➡️  No difference — same CID: {s}\n\n", .{short_a});
        return;
    }

    const diff = try computeSemanticDiff(allocator, io, &store, cid_a, cid_b);
    try printSemanticDiff(allocator, &diff, metric_filter, format);

    for (diff.metrics) |d| allocator.free(d.key);
    allocator.free(diff.metrics);
    for (diff.file_diffs) |fd| {
        for (fd.semantic) |sc| {
            allocator.free(sc.what);
            allocator.free(sc.detail);
        }
        allocator.free(fd.semantic);
        allocator.free(fd.name);
        allocator.free(fd.hash_a);
        allocator.free(fd.hash_b);
    }
    allocator.free(diff.file_diffs);
}

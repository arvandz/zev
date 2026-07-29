const std = @import("std");
const ipld = @import("ipld.zig");
const semantic_diff = @import("semantic_diff.zig");
const Repository = @import("repository.zig").Repository;

pub const ThresholdConfig = struct {
    metric: []const u8,
    min_value: ?f64,
    max_value: ?f64,
    warn_delta: ?f64,
    warn_pct: ?f64,

    pub fn deinit(self: ThresholdConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.metric);
    }
};

pub fn loadThresholds(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
) ![]ThresholdConfig {
    const path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "regression_config" });
    defer allocator.free(path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch return try allocator.alloc(ThresholdConfig, 0);
    defer allocator.free(content);

    var configs = std.ArrayList(ThresholdConfig){};
    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var parts = std.mem.splitSequence(u8, trimmed, " ");
        const metric = parts.next() orelse continue;
        var cfg = ThresholdConfig{
            .metric = try allocator.dupe(u8, metric),
            .min_value = null,
            .max_value = null,
            .warn_delta = null,
            .warn_pct = null,
        };
        while (parts.next()) |part| {
            if (std.mem.startsWith(u8, part, "min="))
                cfg.min_value = std.fmt.parseFloat(f64, part[4..]) catch null;
            if (std.mem.startsWith(u8, part, "max="))
                cfg.max_value = std.fmt.parseFloat(f64, part[4..]) catch null;
            if (std.mem.startsWith(u8, part, "warn_delta="))
                cfg.warn_delta = std.fmt.parseFloat(f64, part[11..]) catch null;
            if (std.mem.startsWith(u8, part, "warn_pct="))
                cfg.warn_pct = std.fmt.parseFloat(f64, part[9..]) catch null;
        }
        try configs.append(allocator, cfg);
    }
    return configs.toOwnedSlice(allocator);
}

pub fn saveThreshold(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    cfg: ThresholdConfig,
) !void {
    const path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "regression_config" });
    defer allocator.free(path);

    var lines = std.ArrayList(u8){};
    defer lines.deinit(allocator);

    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch "";
    defer if (existing.len > 0) allocator.free(existing);

    var found = false;
    var it = std.mem.splitSequence(u8, existing, "\n");
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var parts = std.mem.splitSequence(u8, trimmed, " ");
        const m = parts.next() orelse "";
        if (std.mem.eql(u8, m, cfg.metric)) {
            found = true;
            try appendThresholdLine(allocator, &lines, cfg);
        } else {
            try lines.appendSlice(allocator, line);
            try lines.append(allocator, '\n');
        }
    }
    if (!found) try appendThresholdLine(allocator, &lines, cfg);

    const f = try std.Io.Dir.cwd().createFile(path, .{});
    defer f.close(io);
    try f.writeAll(lines.items);
}

fn appendThresholdLine(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    cfg: ThresholdConfig,
) !void {
    try buf.appendSlice(allocator, cfg.metric);
    if (cfg.min_value) |v| {
        const s = try std.fmt.allocPrint(allocator, " min={d:.6}", .{v});
        defer allocator.free(s);
        try buf.appendSlice(allocator, s);
    }
    if (cfg.max_value) |v| {
        const s = try std.fmt.allocPrint(allocator, " max={d:.6}", .{v});
        defer allocator.free(s);
        try buf.appendSlice(allocator, s);
    }
    if (cfg.warn_delta) |v| {
        const s = try std.fmt.allocPrint(allocator, " warn_delta={d:.6}", .{v});
        defer allocator.free(s);
        try buf.appendSlice(allocator, s);
    }
    if (cfg.warn_pct) |v| {
        const s = try std.fmt.allocPrint(allocator, " warn_pct={d:.2}", .{v});
        defer allocator.free(s);
        try buf.appendSlice(allocator, s);
    }
    try buf.append(allocator, '\n');
}

pub const MetricRecord = struct {
    commit_short: []const u8,
    metric: []const u8,
    value: f64,
    timestamp: i64,

    pub fn deinit(self: MetricRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.commit_short);
        allocator.free(self.metric);
    }
};

pub fn appendMetricHistory(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    commit_short: []const u8,
    metric: []const u8,
    value: f64,
) !void {
    const path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "metric_history" });
    defer allocator.free(path);

    const now = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);
    const f = blk: {
        if (std.Io.Dir.cwd().openFile(path, .{ .mode = .read_write })) |file| {
            break :blk file;
        } else |_| {}
        break :blk try std.Io.Dir.cwd().createFile(path, .{});
    };
    defer f.close(io);
    try f.seekFromEnd(0);
    const line = try std.fmt.allocPrint(allocator, "{s} {s} {d:.6} {d}\n", .{ commit_short, metric, value, now });
    defer allocator.free(line);
    try f.writeAll(line);
}

pub fn loadMetricHistory(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    metric: []const u8,
) ![]MetricRecord {
    const path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "metric_history" });
    defer allocator.free(path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch return try allocator.alloc(MetricRecord, 0);
    defer allocator.free(content);

    var records = std.ArrayList(MetricRecord){};
    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var parts = std.mem.splitSequence(u8, trimmed, " ");
        const commit = parts.next() orelse continue;
        const m = parts.next() orelse continue;
        if (!std.mem.eql(u8, m, metric)) continue;
        const val_str = parts.next() orelse continue;
        const ts_str = parts.next() orelse "0";
        const val = std.fmt.parseFloat(f64, val_str) catch continue;
        const ts = std.fmt.parseInt(i64, ts_str, 10) catch 0;
        try records.append(allocator, MetricRecord{
            .commit_short = try allocator.dupe(u8, commit),
            .metric = try allocator.dupe(u8, m),
            .value = val,
            .timestamp = ts,
        });
    }
    return records.toOwnedSlice(allocator);
}

pub fn getBestHistorical(
    allocator: std.mem.Allocator,
    repo: *Repository,
    metric: []const u8,
) !?f64 {
    const records = try loadMetricHistory(allocator, repo, metric);
    defer {
        for (records) |r| r.deinit(allocator);
        allocator.free(records);
    }
    if (records.len == 0) return null;

    const higher_better = isHigherBetter(metric);
    var best: f64 = records[0].value;
    for (records[1..]) |r| {
        if (higher_better and r.value > best) best = r.value;
        if (!higher_better and r.value < best) best = r.value;
    }
    return best;
}

fn isHigherBetter(metric: []const u8) bool {
    const lower_better = [_][]const u8{
        "loss",    "error",  "mse",    "mae",   "rmse", "perplexity",
        "latency", "memory", "params", "flops",
    };
    for (lower_better) |lb| {
        if (std.mem.indexOf(u8, metric, lb) != null) return false;
    }
    return true;
}

pub const Severity = enum { critical, warning, info };

pub const Regression = struct {
    metric: []const u8,
    severity: Severity,
    kind: Kind,
    current: f64,
    reference: f64,
    delta: f64,
    message: []const u8,

    pub const Kind = enum {
        below_minimum,
        above_maximum,
        delta_exceeded,
        pct_exceeded,
        vs_best_ever,
    };

    pub fn deinit(self: Regression, allocator: std.mem.Allocator) void {
        allocator.free(self.metric);
        allocator.free(self.message);
    }
};

pub fn detectRegressions(
    allocator: std.mem.Allocator,
    repo: *Repository,
    deltas: []const semantic_diff.MetricDelta,
) ![]Regression {
    const thresholds = try loadThresholds(allocator, repo);
    defer {
        for (thresholds) |t| t.deinit(allocator);
        allocator.free(thresholds);
    }

    var regressions = std.ArrayList(Regression){};

    for (deltas) |d| {
        const current = d.val_b orelse continue;

        for (thresholds) |t| {
            if (!std.mem.eql(u8, t.metric, d.key)) continue;

            if (t.min_value) |min| {
                if (current < min) {
                    const msg = try std.fmt.allocPrint(allocator, "{s} = {d:.4} is below minimum {d:.4}", .{ d.key, current, min });
                    try regressions.append(allocator, .{
                        .metric = try allocator.dupe(u8, d.key),
                        .severity = .critical,
                        .kind = .below_minimum,
                        .current = current,
                        .reference = min,
                        .delta = current - min,
                        .message = msg,
                    });
                }
            }

            if (t.max_value) |max| {
                if (current > max) {
                    const msg = try std.fmt.allocPrint(allocator, "{s} = {d:.4} exceeds maximum {d:.4}", .{ d.key, current, max });
                    try regressions.append(allocator, .{
                        .metric = try allocator.dupe(u8, d.key),
                        .severity = .critical,
                        .kind = .above_maximum,
                        .current = current,
                        .reference = max,
                        .delta = current - max,
                        .message = msg,
                    });
                }
            }

            if (t.warn_delta) |wd| {
                if (d.direction == .degraded and @abs(d.delta) > wd) {
                    const msg = try std.fmt.allocPrint(allocator, "{s} dropped by {d:.4} (threshold: {d:.4})", .{ d.key, @abs(d.delta), wd });
                    try regressions.append(allocator, .{
                        .metric = try allocator.dupe(u8, d.key),
                        .severity = .warning,
                        .kind = .delta_exceeded,
                        .current = current,
                        .reference = d.val_a orelse 0,
                        .delta = d.delta,
                        .message = msg,
                    });
                }
            }

            if (t.warn_pct) |wp| {
                if (d.direction == .degraded and @abs(d.pct) > wp) {
                    const msg = try std.fmt.allocPrint(allocator, "{s} dropped by {d:.1}% (threshold: {d:.1}%)", .{ d.key, @abs(d.pct), wp });
                    try regressions.append(allocator, .{
                        .metric = try allocator.dupe(u8, d.key),
                        .severity = .warning,
                        .kind = .pct_exceeded,
                        .current = current,
                        .reference = d.val_a orelse 0,
                        .delta = d.delta,
                        .message = msg,
                    });
                }
            }
        }

        if (d.direction == .degraded) {
            const best = try getBestHistorical(allocator, repo, d.key) orelse continue;
            const vs_best_delta = current - best;
            const higher_better = isHigherBetter(d.key);
            const is_regression = (higher_better and vs_best_delta < -0.05) or
                (!higher_better and vs_best_delta > 0.05);

            if (is_regression) {
                const pct = @abs(vs_best_delta / @abs(best + 0.0001)) * 100.0;
                const msg = try std.fmt.allocPrint(allocator, "{s} = {d:.4} vs best-ever {d:.4} ({d:.1}% below best)", .{ d.key, current, best, pct });
                const severity: Severity = if (pct > 10.0) .critical else if (pct > 5.0) .warning else .info;
                try regressions.append(allocator, .{
                    .metric = try allocator.dupe(u8, d.key),
                    .severity = severity,
                    .kind = .vs_best_ever,
                    .current = current,
                    .reference = best,
                    .delta = vs_best_delta,
                    .message = msg,
                });
            }
        }
    }

    const items = regressions.items;
    for (0..items.len) |i| {
        for (0..items.len - i - 1) |j| {
            if (@intFromEnum(items[j].severity) > @intFromEnum(items[j + 1].severity)) {
                const tmp = items[j];
                items[j] = items[j + 1];
                items[j + 1] = tmp;
            }
        }
    }

    return regressions.toOwnedSlice(allocator);
}

pub fn printRegressions(regressions: []const Regression) void {
    if (regressions.len == 0) {
        std.debug.print("✅ No regressions detected\n\n", .{});
        return;
    }

    std.debug.print("⚠️  Regression Report ({d} issue(s)):\n\n", .{regressions.len});
    for (regressions) |r| {
        const icon: []const u8 = switch (r.severity) {
            .critical => "🚨 CRITICAL",
            .warning => "⚠️  WARNING ",
            .info => "ℹ️  INFO    ",
        };
        std.debug.print("   {s}  {s}\n", .{ icon, r.message });
    }
    std.debug.print("\n", .{});
}

pub fn recordMetricsToHistory(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    store: *ipld.BlockStore,
    commit_cid: ipld.CID,
) !void {
    const commit_short = try commit_cid.toShort(allocator);
    defer allocator.free(commit_short);

    const bp = store.base_path;
    const suffix = "/.zev/ipld";
    const repo_path = if (std.mem.endsWith(u8, bp, suffix))
        bp[0 .. bp.len - suffix.len]
    else
        bp;

    var text_hash: ?[]u8 = null;
    defer if (text_hash) |th| allocator.free(th);
    {
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
                    text_hash = try allocator.dupe(u8, entry.name);
                    break;
                }
            }
        } else |_| {}
    }

    var root_dir = std.Io.Dir.cwd().openDir(io, store.base_path, .{ .iterate = true }) catch return;
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
            const v = store.getNode(allocator, c) catch continue;
            defer v.deinit(allocator);
            if (v != .map) continue;
            if (!std.mem.eql(u8, v.getString("zev") orelse "", "metrics")) continue;

            var belongs = false;
            if (v.getLink("commit")) |cc| {
                const cs = try cc.toShort(allocator);
                defer allocator.free(cs);
                if (text_hash) |th| {
                    const mlen = @min(8, @min(th.len, cs.len));
                    belongs = std.mem.eql(u8, th[0..mlen], cs[0..mlen]);
                }
                if (!belongs) {
                    const mlen = @min(8, @min(commit_short.len, cs.len));
                    belongs = std.mem.eql(u8, commit_short[0..mlen], cs[0..mlen]);
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
                        try appendMetricHistory(allocator, io, repo, commit_short, entry.key, val);
                    }
                }
            }
        }
    }
}

pub fn cmdThresholdSet(
    allocator: std.mem.Allocator,
    repo: *Repository,
    metric: []const u8,
    args: []const []const u8,
) !void {
    var cfg = ThresholdConfig{
        .metric = try allocator.dupe(u8, metric),
        .min_value = null,
        .max_value = null,
        .warn_delta = null,
        .warn_pct = null,
    };
    defer cfg.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--min") and i + 1 < args.len) {
            i += 1;
            cfg.min_value = std.fmt.parseFloat(f64, args[i]) catch null;
        } else if (std.mem.eql(u8, args[i], "--max") and i + 1 < args.len) {
            i += 1;
            cfg.max_value = std.fmt.parseFloat(f64, args[i]) catch null;
        } else if (std.mem.eql(u8, args[i], "--warn-delta") and i + 1 < args.len) {
            i += 1;
            cfg.warn_delta = std.fmt.parseFloat(f64, args[i]) catch null;
        } else if (std.mem.eql(u8, args[i], "--warn-pct") and i + 1 < args.len) {
            i += 1;
            cfg.warn_pct = std.fmt.parseFloat(f64, args[i]) catch null;
        }
    }

    try saveThreshold(allocator, repo, cfg);

    std.debug.print("✅ Threshold set for {s}:\n", .{metric});
    if (cfg.min_value) |v| std.debug.print("   min:        {d:.4}\n", .{v});
    if (cfg.max_value) |v| std.debug.print("   max:        {d:.4}\n", .{v});
    if (cfg.warn_delta) |v| std.debug.print("   warn_delta: {d:.4}\n", .{v});
    if (cfg.warn_pct) |v| std.debug.print("   warn_pct:   {d:.1}%\n", .{v});
    std.debug.print("\n", .{});
}

pub fn cmdThresholdList(
    allocator: std.mem.Allocator,
    repo: *Repository,
) !void {
    const thresholds = try loadThresholds(allocator, repo);
    defer {
        for (thresholds) |t| t.deinit(allocator);
        allocator.free(thresholds);
    }

    if (thresholds.len == 0) {
        std.debug.print("No thresholds configured.\n\n", .{});
        std.debug.print("Set one: zev threshold set accuracy --min 0.90 --warn-delta 0.02\n\n", .{});
        return;
    }

    std.debug.print("📏 Configured thresholds:\n\n", .{});
    std.debug.print("   {s:<20} {s:<12} {s:<12} {s:<12} {s}\n", .{ "metric", "min", "max", "warn_delta", "warn_pct%" });
    std.debug.print("   {s}\n", .{"─"**65});
    for (thresholds) |t| {
        std.debug.print("   {s:<20}", .{t.metric});
        if (t.min_value) |v| std.debug.print(" {d:<11.4}", .{v}) else std.debug.print(" {s:<11}", .{"-"});
        if (t.max_value) |v| std.debug.print(" {d:<11.4}", .{v}) else std.debug.print(" {s:<11}", .{"-"});
        if (t.warn_delta) |v| std.debug.print(" {d:<11.4}", .{v}) else std.debug.print(" {s:<11}", .{"-"});
        if (t.warn_pct) |v| std.debug.print(" {d:.1}%", .{v}) else std.debug.print(" -", .{});
        std.debug.print("\n", .{});
    }
    std.debug.print("\n", .{});
}

pub fn cmdCheck(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    ref: []const u8,
) !u8 {
    var store = try ipld.BlockStore.init(allocator, io, repo.path);
    defer store.deinit();

    std.debug.print("🔎 Regression check: {s}\n\n", .{ref});

    const cid_b = semantic_diff.resolveRef(allocator, &store, repo, ref) catch {
        std.debug.print("❌ Cannot resolve: {s}\n", .{ref});
        return 2;
    };

    const node_b = store.getNode(allocator, cid_b) catch {
        std.debug.print("❌ Cannot load node: {s}\n", .{ref});
        return 2;
    };
    defer node_b.deinit(allocator);

    const parent_cid = if (node_b == .map) node_b.getLink("parent") else null;
    if (parent_cid == null) {
        std.debug.print("✅ First commit — no parent to compare against.\n\n", .{});
        return 0;
    }

    try recordMetricsToHistory(allocator, repo, &store, parent_cid.?);
    try recordMetricsToHistory(allocator, repo, &store, cid_b);

    const diff = try semantic_diff.computeSemanticDiff(allocator, io, &store, parent_cid.?, cid_b);
    defer {
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

    const short_a = try parent_cid.?.toShort(allocator);
    defer allocator.free(short_a);
    const short_b = try cid_b.toShort(allocator);
    defer allocator.free(short_b);

    std.debug.print("   {s} → {s}\n\n", .{ short_a, short_b });

    if (diff.metrics.len > 0) {
        for (diff.metrics) |d| {
            const icon: []const u8 = switch (d.direction) {
                .improved => "✅",
                .degraded => "❌",
                .unchanged => "➡️ ",
                else => "🆕",
            };
            if (d.val_a != null and d.val_b != null) {
                const sign: []const u8 = if (d.delta >= 0) "+" else "";
                const sign2: []const u8 = if (d.pct >= 0) "+" else "";
                std.debug.print("   {s} {s}: {d:.4} → {d:.4}  ({s}{d:.4}  {s}{d:.1}%)\n", .{ icon, d.key, d.val_a.?, d.val_b.?, sign, d.delta, sign2, d.pct });
            }
        }
        std.debug.print("\n", .{});
    }

    const regressions = try detectRegressions(allocator, repo, diff.metrics);
    defer {
        for (regressions) |r| r.deinit(allocator);
        allocator.free(regressions);
    }

    printRegressions(regressions);

    var n_critical: usize = 0;
    var n_warning: usize = 0;
    for (regressions) |r| {
        if (r.severity == .critical) n_critical += 1;
        if (r.severity == .warning) n_warning += 1;
    }

    if (n_critical > 0) {
        std.debug.print("❌ Check FAILED: {d} critical regression(s)\n\n", .{n_critical});
        return 1;
    }
    if (n_warning > 0) {
        std.debug.print("⚠️  Check PASSED with {d} warning(s)\n\n", .{n_warning});
        return 0;
    }
    std.debug.print("✅ Check PASSED\n\n", .{});
    return 0;
}

pub fn cmdHistory(
    allocator: std.mem.Allocator,
    repo: *Repository,
    metric: []const u8,
) !void {
    const records = try loadMetricHistory(allocator, repo, metric);
    defer {
        for (records) |r| r.deinit(allocator);
        allocator.free(records);
    }

    if (records.len == 0) {
        std.debug.print("No history for metric '{s}'.\n\n", .{metric});
        std.debug.print("Run 'zev check' or 'zev sdiff' to record metric history.\n\n", .{});
        return;
    }

    std.debug.print("📈 Metric history: {s}\n\n", .{metric});

    const higher_better = isHigherBetter(metric);
    var best: f64 = records[0].value;
    var worst: f64 = records[0].value;
    for (records) |r| {
        if (r.value > best) best = r.value;
        if (r.value < worst) worst = r.value;
    }

    const blocks = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
    const range = best - worst;

    std.debug.print("   ", .{});
    for (records) |r| {
        const idx: usize = if (range < 0.0001) 3 else blk: {
            const norm = (r.value - worst) / range;
            break :blk @intFromFloat(@min(7.0, norm * 7.0));
        };
        std.debug.print("{s}", .{blocks[idx]});
    }
    std.debug.print("\n\n", .{});

    std.debug.print("   {s:<12} {s:<10} {s}\n", .{ "commit", "value", "trend" });
    std.debug.print("   {s}\n", .{"─"**35});

    var prev: ?f64 = null;
    for (records) |r| {
        const trend: []const u8 = if (prev == null) "  (first)" else if (higher_better and r.value > prev.?) "  ↑" else if (higher_better and r.value < prev.?) "  ↓ ⚠️" else if (!higher_better and r.value < prev.?) "  ↓" else if (!higher_better and r.value > prev.?) "  ↑ ⚠️" else "  →";
        const short8 = r.commit_short[0..@min(8, r.commit_short.len)];
        std.debug.print("   {s:<10} {d:<10.4}{s}\n", .{ short8, r.value, trend });
        prev = r.value;
    }

    std.debug.print("\n", .{});
    if (higher_better) {
        std.debug.print("   Best:  {d:.4}  Worst: {d:.4}\n\n", .{ best, worst });
    } else {
        std.debug.print("   Best:  {d:.4}  Worst: {d:.4}\n\n", .{ worst, best });
    }
}

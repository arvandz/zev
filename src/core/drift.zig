const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");

pub const ThresholdDirection = enum {
    higher_is_better,
    lower_is_better,
    any,
};

pub const DriftThreshold = struct {
    metric: []const u8,
    max_delta: f64,
    max_pct: f64,
    direction: ThresholdDirection,
};

pub const DriftResult = struct {
    metric: []const u8,
    baseline_val: f64,
    current_val: f64,
    delta: f64,
    pct_change: f64,
    drifted: bool,
    direction: []const u8,
};

pub const DriftConfig = struct {
    baseline_ref: []u8,
    webhook_url: []u8,
    watch_interval: u32,
    thresholds: std.ArrayList(DriftThreshold),

    pub fn deinit(self: *DriftConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.baseline_ref);
        allocator.free(self.webhook_url);
        for (self.thresholds.items) |t| allocator.free(t.metric);
        self.thresholds.deinit(allocator);
    }
};

fn driftConfigPath(allocator: std.mem.Allocator, repo: *Repository) ![]u8 {
    return try std.fs.path.join(allocator, &.{ repo.path, ".zev", "drift_config" });
}

fn driftHistoryDir(allocator: std.mem.Allocator, repo: *Repository) ![]u8 {
    const dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "drift_history" });
    try std.Io.Dir.cwd().makePath(dir);
    return dir;
}

fn writeFile(allocator: std.mem.Allocator,
    io: std.Io, path: []const u8, content: []const u8) !void {
    _ = allocator;
    const f = try std.Io.Dir.cwd().createFile(path, .{});
    defer f.close(io);
    try f.writeAll(content);
}

fn buildConfigContent(
    allocator: std.mem.Allocator,
    baseline_ref: []const u8,
    webhook_url: []const u8,
    watch_interval: u32,
    thresholds: []const DriftThreshold,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const s1 = try std.fmt.allocPrint(allocator, "baseline={s}\n", .{baseline_ref});
    defer allocator.free(s1);
    try out.appendSlice(allocator, s1);
    const s2 = try std.fmt.allocPrint(allocator, "webhook={s}\n", .{webhook_url});
    defer allocator.free(s2);
    try out.appendSlice(allocator, s2);
    const s3 = try std.fmt.allocPrint(allocator, "watch_interval={d}\n", .{watch_interval});
    defer allocator.free(s3);
    try out.appendSlice(allocator, s3);
    try out.appendSlice(allocator, "thresholds=\n");
    for (thresholds) |t| {
        const dir_str: []const u8 = switch (t.direction) {
            .higher_is_better => "hib",
            .lower_is_better => "lib",
            .any => "any",
        };
        const s = try std.fmt.allocPrint(allocator, "  {s}:{d}:{d}:{s}\n", .{ t.metric, t.max_delta, t.max_pct, dir_str });
        defer allocator.free(s);
        try out.appendSlice(allocator, s);
    }
    return out.toOwnedSlice(allocator);
}

pub fn saveConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    baseline_ref: []const u8,
    thresholds: []const DriftThreshold,
    webhook_url: []const u8,
    watch_interval: u32,
) !void {
    const path = try driftConfigPath(allocator, repo);
    defer allocator.free(path);
    const content = try buildConfigContent(allocator, baseline_ref, webhook_url, watch_interval, thresholds);
    defer allocator.free(content);
    try writeFile(allocator, io, path, content);
}

pub fn loadConfig(allocator: std.mem.Allocator, io: std.Io, repo: *Repository) !?DriftConfig {
    const path = try driftConfigPath(allocator, repo);
    defer allocator.free(path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(content);

    var baseline_ref: []u8 = try allocator.dupe(u8, "");
    var webhook_url: []u8 = try allocator.dupe(u8, "");
    var watch_interval: u32 = 300;
    var thresholds: std.ArrayList(DriftThreshold) = .empty;

    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0) continue;
        if (std.mem.startsWith(u8, t, "baseline=")) {
            allocator.free(baseline_ref);
            baseline_ref = try allocator.dupe(u8, t[9..]);
        } else if (std.mem.startsWith(u8, t, "webhook=")) {
            allocator.free(webhook_url);
            webhook_url = try allocator.dupe(u8, t[8..]);
        } else if (std.mem.startsWith(u8, t, "watch_interval=")) {
            watch_interval = std.fmt.parseInt(u32, t[15..], 10) catch 300;
        } else if (std.mem.indexOf(u8, t, ":") != null and t[0] != 't') {
            var parts = std.mem.splitSequence(u8, t, ":");
            const metric = parts.next() orelse continue;
            const delta_str = parts.next() orelse continue;
            const pct_str = parts.next() orelse continue;
            const dir_str = parts.next() orelse "any";
            const max_delta = std.fmt.parseFloat(f64, delta_str) catch continue;
            const max_pct = std.fmt.parseFloat(f64, pct_str) catch 0;
            const direction: ThresholdDirection = if (std.mem.eql(u8, dir_str, "hib"))
                .higher_is_better
            else if (std.mem.eql(u8, dir_str, "lib"))
                .lower_is_better
            else
                .any;
            try thresholds.append(allocator, DriftThreshold{
                .metric = try allocator.dupe(u8, metric),
                .max_delta = max_delta,
                .max_pct = max_pct,
                .direction = direction,
            });
        }
    }
    return DriftConfig{ .baseline_ref = baseline_ref, .webhook_url = webhook_url, .watch_interval = watch_interval, .thresholds = thresholds };
}

fn loadMetricsForHash(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, hash: []const u8) !std.StringHashMap(f64) {
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
        const k = try allocator.dupe(u8, kv[0..eq]);
        const v = std.fmt.parseFloat(f64, kv[eq + 1 ..]) catch {
            allocator.free(k);
            continue;
        };
        try map.put(k, v);
    }
    return map;
}

fn freeMetricsMap(allocator: std.mem.Allocator, map: *std.StringHashMap(f64)) void {
    var it = map.iterator();
    while (it.next()) |e| allocator.free(e.key_ptr.*);
    map.deinit();
}

fn loadMetricsFromSnapshot(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, name: []const u8) !?std.StringHashMap(f64) {
    const dir_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "snapshots" });
    defer allocator.free(dir_path);
    var dir = std.Io.Dir.cwd().openDir(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or std.mem.endsWith(u8, entry.name, ".name")) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(content);
        var snap_name: []u8 = try allocator.dupe(u8, "");
        var metrics_raw: []u8 = try allocator.dupe(u8, "");
        defer allocator.free(snap_name);
        defer allocator.free(metrics_raw);
        var li = std.mem.splitSequence(u8, content, "\n");
        while (li.next()) |line| {
            if (std.mem.startsWith(u8, line, "name=")) {
                allocator.free(snap_name);
                snap_name = try allocator.dupe(u8, line[5..]);
            } else if (std.mem.startsWith(u8, line, "metrics_snapshot=")) {
                allocator.free(metrics_raw);
                metrics_raw = try allocator.dupe(u8, line[17..]);
            }
        }
        if (!std.mem.eql(u8, snap_name, name)) continue;
        var map = std.StringHashMap(f64).init(allocator);
        var mi = std.mem.splitSequence(u8, metrics_raw, ";");
        while (mi.next()) |kv| {
            const eq = std.mem.indexOf(u8, kv, "=") orelse continue;
            const k = try allocator.dupe(u8, kv[0..eq]);
            const v = std.fmt.parseFloat(f64, kv[eq + 1 ..]) catch {
                allocator.free(k);
                continue;
            };
            try map.put(k, v);
        }
        return map;
    }
    return null;
}

fn runDriftCheck(
    allocator: std.mem.Allocator,
    baseline_metrics: *std.StringHashMap(f64),
    current_metrics: *std.StringHashMap(f64),
    thresholds: []const DriftThreshold,
    results: *std.ArrayList(DriftResult),
) !bool {
    var any_drift = false;
    for (thresholds) |threshold| {
        const bv = baseline_metrics.get(threshold.metric) orelse {
            std.debug.print("   ⚠️  '{s}' not in baseline\n", .{threshold.metric});
            continue;
        };
        const cv = current_metrics.get(threshold.metric) orelse {
            std.debug.print("   ⚠️  '{s}' not in current commit\n", .{threshold.metric});
            continue;
        };
        const delta = cv - bv;
        const pct = if (bv != 0) (delta / @abs(bv)) * 100.0 else 0.0;
        const drifted = switch (threshold.direction) {
            .higher_is_better => delta < -threshold.max_delta or (threshold.max_pct > 0 and pct < -threshold.max_pct),
            .lower_is_better => delta > threshold.max_delta or (threshold.max_pct > 0 and pct > threshold.max_pct),
            .any => @abs(delta) > threshold.max_delta or (threshold.max_pct > 0 and @abs(pct) > threshold.max_pct),
        };
        if (drifted) any_drift = true;
        const dir_str: []const u8 = if (delta > 0.0001) "▲" else if (delta < -0.0001) "▼" else "=";
        try results.append(allocator, DriftResult{
            .metric = try allocator.dupe(u8, threshold.metric),
            .baseline_val = bv,
            .current_val = cv,
            .delta = delta,
            .pct_change = pct,
            .drifted = drifted,
            .direction = dir_str,
        });
    }
    var it = current_metrics.iterator();
    while (it.next()) |entry| {
        var has_t = false;
        for (thresholds) |t| {
            if (std.mem.eql(u8, t.metric, entry.key_ptr.*)) {
                has_t = true;
                break;
            }
        }
        if (has_t) continue;
        const bv = baseline_metrics.get(entry.key_ptr.*) orelse continue;
        const delta = entry.value_ptr.* - bv;
        const dir_str: []const u8 = if (delta > 0.0001) "▲" else if (delta < -0.0001) "▼" else "=";
        try results.append(allocator, DriftResult{
            .metric = try allocator.dupe(u8, entry.key_ptr.*),
            .baseline_val = bv,
            .current_val = entry.value_ptr.*,
            .delta = delta,
            .pct_change = if (bv != 0) (delta / @abs(bv)) * 100.0 else 0,
            .drifted = false,
            .direction = dir_str,
        });
    }
    return any_drift;
}

fn printDriftResults(results: []const DriftResult, baseline_ref: []const u8, current_ref: []const u8, any_drift: bool) void {
    std.debug.print("\n   {s:<22} {s:<14} {s:<14} {s:<12} {s}\n", .{ "Metric", baseline_ref[0..@min(12, baseline_ref.len)], current_ref[0..@min(12, current_ref.len)], "Change", "Status" });
    std.debug.print("   {s}\n", .{"─"**70});
    for (results) |r| {
        const status: []const u8 = if (r.drifted) "🚨 DRIFT" else "✅ OK";
        std.debug.print("   {s:<22} {d:<14.4} {d:<14.4} {s}{d:<8.4} {s}\n", .{ r.metric, r.baseline_val, r.current_val, r.direction, @abs(r.delta), status });
    }
    std.debug.print("\n", .{});
    if (any_drift) {
        std.debug.print("   🚨 DRIFT DETECTED — metrics have regressed beyond thresholds\n\n", .{});
    } else {
        std.debug.print("   ✅ No drift detected — all metrics within thresholds\n\n", .{});
    }
}

fn saveHistory(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    baseline_ref: []const u8,
    current_hash: []const u8,
    results: []const DriftResult,
    any_drift: bool,
    timestamp: i64,
) !void {
    const dir = try driftHistoryDir(allocator, repo);
    defer allocator.free(dir);
    const fname = try std.fmt.allocPrint(allocator, "{d}", .{timestamp});
    defer allocator.free(fname);
    const path = try std.fs.path.join(allocator, &.{ dir, fname });
    defer allocator.free(path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const s1 = try std.fmt.allocPrint(allocator, "timestamp={d}\n", .{timestamp});
    defer allocator.free(s1);
    try out.appendSlice(allocator, s1);
    const s2 = try std.fmt.allocPrint(allocator, "baseline={s}\n", .{baseline_ref});
    defer allocator.free(s2);
    try out.appendSlice(allocator, s2);
    const s3 = try std.fmt.allocPrint(allocator, "current={s}\n", .{current_hash[0..@min(8, current_hash.len)]});
    defer allocator.free(s3);
    try out.appendSlice(allocator, s3);
    const s4 = try std.fmt.allocPrint(allocator, "any_drift={s}\n", .{if (any_drift) "true" else "false"});
    defer allocator.free(s4);
    try out.appendSlice(allocator, s4);
    for (results) |r| {
        const sr = try std.fmt.allocPrint(allocator, "metric={s}:{d:.6}:{d:.6}:{s}\n", .{ r.metric, r.baseline_val, r.current_val, if (r.drifted) "drifted" else "ok" });
        defer allocator.free(sr);
        try out.appendSlice(allocator, sr);
    }
    try writeFile(allocator, io, path, out.items);
}

fn fireWebhook(allocator: std.mem.Allocator,
    io: std.Io, webhook_url: []const u8, payload: []const u8) !void {
    if (webhook_url.len == 0) return;
    const tmp = "/tmp/zev_drift_webhook.json";
    try writeFile(allocator, io, tmp, payload);
    var child = try std.process.spawn(io, .{
        .argv = &.{ "curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "--data", "@/tmp/zev_drift_webhook.json", webhook_url },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try child.wait(io);
}

pub fn driftBaseline(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, baseline_ref: []const u8) !void {
    var cfg = (try loadConfig(allocator, repo)) orelse DriftConfig{
        .baseline_ref = try allocator.dupe(u8, ""),
        .webhook_url = try allocator.dupe(u8, ""),
        .watch_interval = 300,
        .thresholds = .empty,
    };
    defer cfg.deinit(allocator);
    try saveConfig(allocator, io, repo, baseline_ref, cfg.thresholds.items, cfg.webhook_url, cfg.watch_interval);
    std.debug.print("📍 Drift baseline set: {s}\n", .{baseline_ref});
    std.debug.print("   Run 'zev drift check' to compare current metrics\n", .{});
}

pub fn driftConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    metric: []const u8,
    max_delta: f64,
    max_pct: f64,
    direction_str: []const u8,
    webhook_url: ?[]const u8,
    watch_interval: ?u32,
) !void {
    var cfg = (try loadConfig(allocator, repo)) orelse DriftConfig{
        .baseline_ref = try allocator.dupe(u8, ""),
        .webhook_url = try allocator.dupe(u8, ""),
        .watch_interval = 300,
        .thresholds = .empty,
    };
    defer cfg.deinit(allocator);

    const direction: ThresholdDirection = if (std.mem.eql(u8, direction_str, "hib"))
        .higher_is_better
    else if (std.mem.eql(u8, direction_str, "lib"))
        .lower_is_better
    else
        .any;

    var new_t: std.ArrayList(DriftThreshold) = .empty;
    defer {
        for (new_t.items) |t| allocator.free(t.metric);
        new_t.deinit(allocator);
    }
    for (cfg.thresholds.items) |t| {
        if (!std.mem.eql(u8, t.metric, metric)) {
            try new_t.append(allocator, DriftThreshold{
                .metric = try allocator.dupe(u8, t.metric),
                .max_delta = t.max_delta,
                .max_pct = t.max_pct,
                .direction = t.direction,
            });
        }
    }
    try new_t.append(allocator, DriftThreshold{
        .metric = try allocator.dupe(u8, metric),
        .max_delta = max_delta,
        .max_pct = max_pct,
        .direction = direction,
    });

    const wh = webhook_url orelse cfg.webhook_url;
    const wi = watch_interval orelse cfg.watch_interval;
    try saveConfig(allocator, io, repo, cfg.baseline_ref, new_t.items, wh, wi);

    const dir_label: []const u8 = switch (direction) {
        .higher_is_better => "higher is better",
        .lower_is_better => "lower is better",
        .any => "any change",
    };
    std.debug.print("✅ Threshold set for '{s}': delta={d}, direction={s}\n", .{ metric, max_delta, dir_label });
}

pub fn driftCheck(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, baseline_override: ?[]const u8) !void {
    var cfg = (try loadConfig(allocator, repo)) orelse {
        std.debug.print("No drift config. Set up with:\n", .{});
        std.debug.print("  zev drift baseline <snapshot-name>\n", .{});
        std.debug.print("  zev drift config --metric accuracy --delta 0.05 --direction hib\n", .{});
        return;
    };
    defer cfg.deinit(allocator);

    const baseline_ref = baseline_override orelse cfg.baseline_ref;
    if (baseline_ref.len == 0) {
        std.debug.print("No baseline set. Run: zev drift baseline <snapshot-or-commit>\n", .{});
        return;
    }

    var baseline_metrics = (try loadMetricsFromSnapshot(allocator, repo, baseline_ref)) orelse
        try loadMetricsForHash(allocator, repo, baseline_ref);
    defer freeMetricsMap(allocator, &baseline_metrics);

    if (baseline_metrics.count(io, ) == 0) {
        std.debug.print("No metrics found for baseline '{s}'\n", .{baseline_ref});
        return;
    }

    const head = repo.getHeadCommit() catch {
        std.debug.print("No commits yet.\n", .{});
        return;
    };
    const current_hash = try head.toString(allocator);
    defer allocator.free(current_hash);

    var current_metrics = try loadMetricsForHash(allocator, repo, current_hash);
    defer freeMetricsMap(allocator, &current_metrics);

    if (current_metrics.count(io, ) == 0) {
        std.debug.print("No metrics on current HEAD ({s})\n", .{current_hash[0..8]});
        return;
    }

    std.debug.print("📊 Drift Check\n", .{});
    std.debug.print("   Baseline: {s}\n", .{baseline_ref});
    std.debug.print("   Current:  {s}\n", .{current_hash[0..8]});

    var results: std.ArrayList(DriftResult) = .empty;
    defer {
        for (results.items) |r| allocator.free(r.metric);
        results.deinit(allocator);
    }

    var effective: []DriftThreshold = cfg.thresholds.items;
    var auto_t: std.ArrayList(DriftThreshold) = .empty;
    defer {
        for (auto_t.items) |t| allocator.free(t.metric);
        auto_t.deinit(allocator);
    }
    if (cfg.thresholds.items.len == 0) {
        std.debug.print("   ℹ️  No thresholds — showing deltas only\n", .{});
        var bit = baseline_metrics.iterator();
        while (bit.next()) |e| {
            try auto_t.append(allocator, DriftThreshold{
                .metric = try allocator.dupe(u8, e.key_ptr.*),
                .max_delta = 1e9,
                .max_pct = 0,
                .direction = .any,
            });
        }
        effective = auto_t.items;
    }

    const any_drift = try runDriftCheck(allocator, &baseline_metrics, &current_metrics, effective, &results);
    printDriftResults(results.items, baseline_ref, current_hash[0..8], any_drift);

    const now = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);
    try saveHistory(allocator, io, repo, baseline_ref, current_hash, results.items, any_drift, now);

    if (any_drift and cfg.webhook_url.len > 0) {
        const payload = try std.fmt.allocPrint(allocator, "{{\"event\":\"drift\",\"baseline\":\"{s}\",\"current\":\"{s}\",\"timestamp\":{d}}}", .{ baseline_ref, current_hash[0..8], now });
        defer allocator.free(payload);
        fireWebhook(allocator, io, cfg.webhook_url, payload) catch
            std.debug.print("   ⚠️  Webhook failed\n", .{});
    }
}

pub fn driftHistory(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, limit: usize) !void {
    const dir = try driftHistoryDir(allocator, repo);
    defer allocator.free(dir);
    var d = std.Io.Dir.cwd().openDir(dir, .{ .iterate = true }) catch {
        std.debug.print("No drift history yet. Run: zev drift check\n", .{});
        return;
    };
    defer d.close(io);

    var entries: std.ArrayList([]u8) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e);
        entries.deinit(allocator);
    }
    var it = d.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        try entries.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, entries.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .gt;
        }
    }.lt);

    std.debug.print("📈 Drift History (most recent first):\n\n", .{});
    var shown: usize = 0;
    for (entries.items) |name| {
        if (shown >= limit) break;
        const path = try std.fs.path.join(allocator, &.{ dir, name });
        defer allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(content);
        var timestamp: i64 = 0;
        var baseline: []u8 = try allocator.dupe(u8, "");
        var current: []u8 = try allocator.dupe(u8, "");
        var any_drift = false;
        defer allocator.free(baseline);
        defer allocator.free(current);
        var li = std.mem.splitSequence(u8, content, "\n");
        while (li.next()) |line| {
            if (std.mem.startsWith(u8, line, "timestamp="))
                timestamp = std.fmt.parseInt(i64, line[10..], 10) catch 0
            else if (std.mem.startsWith(u8, line, "baseline=")) {
                allocator.free(baseline);
                baseline = try allocator.dupe(u8, line[9..]);
            } else if (std.mem.startsWith(u8, line, "current=")) {
                allocator.free(current);
                current = try allocator.dupe(u8, line[8..]);
            } else if (std.mem.startsWith(u8, line, "any_drift="))
                any_drift = std.mem.eql(u8, line[10..], "true");
        }
        const status: []const u8 = if (any_drift) "🚨 DRIFT" else "✅ OK   ";
        std.debug.print("  {s}  t={d}  baseline={s}  commit={s}\n", .{ status, timestamp, baseline, current });
        shown += 1;
    }
    if (shown == 0) std.debug.print("  No history entries yet.\n", .{});
    std.debug.print("\n", .{});
}

pub fn driftWatch(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, interval_secs: u32) !void {
    var cfg = (try loadConfig(allocator, repo)) orelse {
        std.debug.print("No drift config. Set baseline: zev drift baseline <ref>\n", .{});
        return;
    };
    const effective_interval = if (interval_secs > 0) interval_secs else cfg.watch_interval;
    const baseline = try allocator.dupe(u8, cfg.baseline_ref);
    defer allocator.free(baseline);
    cfg.thresholds.deinit(allocator);
    allocator.free(cfg.baseline_ref);
    allocator.free(cfg.webhook_url);

    std.debug.print("👁️  Drift watch — checking every {d}s. Ctrl+C to stop\n\n", .{effective_interval});
    var n: u32 = 0;
    while (true) {
        n += 1;
        std.debug.print("─── Check #{d} ─────────────────────────────\n", .{n});
        try driftCheck(allocator, io, repo, baseline);
        std.posix.nanosleep(effective_interval, 0);
    }
}

pub fn driftShow(allocator: std.mem.Allocator, repo: *Repository) !void {
    var cfg = (try loadConfig(allocator, repo)) orelse {
        std.debug.print("No drift config yet.\n", .{});
        std.debug.print("Start with: zev drift baseline <snapshot-name>\n", .{});
        return;
    };
    defer cfg.deinit(allocator);
    std.debug.print("📊 Drift Configuration\n\n", .{});
    std.debug.print("   Baseline:       {s}\n", .{cfg.baseline_ref});
    std.debug.print("   Watch interval: {d}s\n", .{cfg.watch_interval});
    if (cfg.webhook_url.len > 0)
        std.debug.print("   Webhook:        {s}\n", .{cfg.webhook_url});
    if (cfg.thresholds.items.len > 0) {
        std.debug.print("\n   Thresholds:\n", .{});
        for (cfg.thresholds.items) |t| {
            const d: []const u8 = switch (t.direction) {
                .higher_is_better => "higher-is-better",
                .lower_is_better => "lower-is-better",
                .any => "any-change",
            };
            std.debug.print("   {s:<22} delta={d:<8} [{s}]\n", .{ t.metric, t.max_delta, d });
        }
    } else {
        std.debug.print("   Thresholds:     (none)\n", .{});
    }
}

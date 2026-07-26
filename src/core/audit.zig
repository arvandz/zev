const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");
const commit_mod = @import("commit.zig");
const context_mod = @import("context.zig");
const tree_mod = @import("tree.zig");

pub const EventKind = enum {
    commit,
    metrics,
    snapshot,
    experiment,
    lineage,
    notarization,
    drift_check,
    reproduce,
    peer_announce,
    export_op,
    context_record,
};

pub const AuditEvent = struct {
    kind: EventKind,
    timestamp: i64,
    ref: []const u8,
    summary: []const u8,
    detail: []const u8,
    status: []const u8,
};

fn readFileSafe(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound or err == error.IsDir) return null;
        return err;
    };
}

fn zevPath(allocator: std.mem.Allocator, repo: *Repository, sub: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ repo.path, ".zev", sub });
}

fn getAuthor(allocator: std.mem.Allocator, repo: *Repository) ![]u8 {
    const path = try zevPath(allocator, repo, "config");
    defer allocator.free(path);
    const content = (try readFileSafe(allocator, path)) orelse
        return try allocator.dupe(u8, "unknown");
    defer allocator.free(content);
    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "user.name="))
            return try allocator.dupe(u8, line[10..]);
    }
    return try allocator.dupe(u8, "unknown");
}

fn collectCommits(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    events: *std.ArrayList(AuditEvent),
) !void {
    const head_path = try zevPath(allocator, repo, "HEAD");
    defer allocator.free(head_path);
    const head_content = (try readFileSafe(allocator, head_path)) orelse return;
    defer allocator.free(head_content);

    var branch_ref: []u8 = try allocator.dupe(u8, "");
    defer allocator.free(branch_ref);
    if (std.mem.startsWith(u8, head_content, "ref: ")) {
        allocator.free(branch_ref);
        branch_ref = try allocator.dupe(u8, std.mem.trim(u8, head_content[5..], "\n\r "));
    }

    const ref_path = try zevPath(allocator, repo, branch_ref);
    defer allocator.free(ref_path);
    const ref_content = (try readFileSafe(allocator, ref_path)) orelse return;
    defer allocator.free(ref_content);

    var current_hash = try allocator.dupe(u8, std.mem.trim(u8, ref_content, "\n\r "));
    defer allocator.free(current_hash);

    var depth: usize = 0;
    while (current_hash.len == 64 and depth < 200) : (depth += 1) {
        var hash: [32]u8 = undefined;
        var valid = true;
        for (0..32) |i| {
            const hi = std.fmt.charToDigit(current_hash[i * 2], 16) catch {
                valid = false;
                break;
            };
            const lo = std.fmt.charToDigit(current_hash[i * 2 + 1], 16) catch {
                valid = false;
                break;
            };
            hash[i] = (hi << 4) | lo;
        }
        if (!valid) break;

        const commit_cid = cid_mod.CID{ .hash = hash };
        const commit_data = repo.store.get(io, commit_cid) catch break;
        defer allocator.free(commit_data);

        const c = commit_mod.Commit.deserialize(allocator, commit_data) catch break;
        defer allocator.free(c.author);
        defer allocator.free(c.message);

        const summary = try std.fmt.allocPrint(allocator, "commit by {s}: {s}", .{ c.author, c.message[0..@min(60, c.message.len)] });
        const detail = try std.fmt.allocPrint(allocator, "hash={s}", .{current_hash[0..8]});

        try events.append(allocator, AuditEvent{
            .kind = .commit,
            .timestamp = c.timestamp,
            .ref = try allocator.dupe(u8, current_hash[0..8]),
            .summary = summary,
            .detail = detail,
            .status = try allocator.dupe(u8, "info"),
        });

        const metrics_path = try zevPath(allocator, repo, try std.fmt.allocPrint(allocator, "metrics/{s}", .{current_hash}));
        defer allocator.free(metrics_path);
        if (try readFileSafe(allocator, metrics_path)) |mf| {
            defer allocator.free(mf);
            var metric_parts: std.ArrayList(u8) = .empty;
            defer metric_parts.deinit(allocator);
            var mi = std.mem.splitSequence(u8, mf, "\n");
            var first = true;
            while (mi.next()) |line| {
                if (line.len == 0) continue;
                const tab = std.mem.indexOf(u8, line, "\t") orelse line.len;
                if (line[0..tab].len == 0) continue;
                if (!first) try metric_parts.append(allocator, ' ');
                try metric_parts.appendSlice(allocator, line[0..tab]);
                first = false;
            }
            if (metric_parts.items.len > 0) {
                const ms = try allocator.dupe(u8, metric_parts.items);
                try events.append(allocator, AuditEvent{
                    .kind = .metrics,
                    .timestamp = c.timestamp,
                    .ref = try allocator.dupe(u8, current_hash[0..8]),
                    .summary = try std.fmt.allocPrint(allocator, "metrics recorded: {s}", .{ms}),
                    .detail = ms,
                    .status = try allocator.dupe(u8, "ok"),
                });
            }
        }

        const parent_str = try (c.parent_cid orelse break).toString(allocator);
        defer allocator.free(parent_str);
        const _pcid = c.parent_cid orelse break;
        const is_genesis = blk: {
            var all_zero = true;
            for (_pcid.hash) |b| {
                if (b != 0) {
                    all_zero = false;
                    break;
                }
            }
            break :blk all_zero;
        };
        if (is_genesis) break;
        allocator.free(current_hash);
        current_hash = try allocator.dupe(u8, parent_str);
    }
}

fn collectSnapshots(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    events: *std.ArrayList(AuditEvent),
    filter_name: ?[]const u8,
) !void {
    const dir_path = try zevPath(allocator, repo, "snapshots");
    defer allocator.free(dir_path);
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or std.mem.endsWith(u8, entry.name, ".name")) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const content = (try readFileSafe(allocator, path)) orelse continue;
        defer allocator.free(content);

        var name: []u8 = try allocator.dupe(u8, "");
        var desc: []u8 = try allocator.dupe(u8, "");
        var metrics: []u8 = try allocator.dupe(u8, "");
        var commit_hash: []u8 = try allocator.dupe(u8, "");
        var tags: []u8 = try allocator.dupe(u8, "");
        var timestamp: i64 = 0;
        defer allocator.free(name);
        defer allocator.free(desc);
        defer allocator.free(metrics);
        defer allocator.free(commit_hash);
        defer allocator.free(tags);

        var li = std.mem.splitSequence(u8, content, "\n");
        while (li.next()) |line| {
            if (std.mem.startsWith(u8, line, "name=")) {
                allocator.free(name);
                name = try allocator.dupe(u8, line[5..]);
            } else if (std.mem.startsWith(u8, line, "description=")) {
                allocator.free(desc);
                desc = try allocator.dupe(u8, line[12..]);
            } else if (std.mem.startsWith(u8, line, "metrics_snapshot=")) {
                allocator.free(metrics);
                metrics = try allocator.dupe(u8, line[17..]);
            } else if (std.mem.startsWith(u8, line, "commit_hash=")) {
                allocator.free(commit_hash);
                commit_hash = try allocator.dupe(u8, line[12..]);
            } else if (std.mem.startsWith(u8, line, "tags=")) {
                allocator.free(tags);
                tags = try allocator.dupe(u8, line[5..]);
            } else if (std.mem.startsWith(u8, line, "timestamp=")) {
                timestamp = std.fmt.parseInt(i64, line[10..], 10) catch 0;
            }
        }

        if (filter_name != null and !std.mem.eql(u8, name, filter_name.?)) continue;

        const detail = try std.fmt.allocPrint(allocator, "commit={s} metrics=[{s}] tags=[{s}]", .{ commit_hash[0..@min(8, commit_hash.len)], metrics, tags });

        try events.append(allocator, AuditEvent{
            .kind = .snapshot,
            .timestamp = timestamp,
            .ref = try allocator.dupe(u8, name),
            .summary = try std.fmt.allocPrint(allocator, "snapshot created: {s} — {s}", .{ name, desc }),
            .detail = detail,
            .status = try allocator.dupe(u8, "ok"),
        });
    }
}

fn collectNotarizations(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    events: *std.ArrayList(AuditEvent),
    filter_ref: ?[]const u8,
) !void {
    const dir_path = try zevPath(allocator, repo, "notarizations");
    defer allocator.free(dir_path);
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const content = (try readFileSafe(allocator, path)) orelse continue;
        defer allocator.free(content);

        var subject_id: []u8 = try allocator.dupe(u8, "");
        var chain: []u8 = try allocator.dupe(u8, "");
        var tx_hash: []u8 = try allocator.dupe(u8, "");
        var rec_id: []u8 = try allocator.dupe(u8, "");
        var timestamp: i64 = 0;
        defer allocator.free(subject_id);
        defer allocator.free(chain);
        defer allocator.free(tx_hash);
        defer allocator.free(rec_id);

        var li = std.mem.splitSequence(u8, content, "\n");
        while (li.next()) |line| {
            if (std.mem.startsWith(u8, line, "subject_id=")) {
                allocator.free(subject_id);
                subject_id = try allocator.dupe(u8, line[11..]);
            } else if (std.mem.startsWith(u8, line, "chain=")) {
                allocator.free(chain);
                chain = try allocator.dupe(u8, line[6..]);
            } else if (std.mem.startsWith(u8, line, "tx_hash=")) {
                allocator.free(tx_hash);
                tx_hash = try allocator.dupe(u8, line[8..]);
            } else if (std.mem.startsWith(u8, line, "id=")) {
                allocator.free(rec_id);
                rec_id = try allocator.dupe(u8, line[3..]);
            } else if (std.mem.startsWith(u8, line, "timestamp=")) {
                timestamp = std.fmt.parseInt(i64, line[10..], 10) catch 0;
            }
        }

        if (filter_ref != null and !std.mem.eql(u8, subject_id, filter_ref.?)) continue;

        try events.append(allocator, AuditEvent{
            .kind = .notarization,
            .timestamp = timestamp,
            .ref = try allocator.dupe(u8, rec_id[0..@min(16, rec_id.len)]),
            .summary = try std.fmt.allocPrint(allocator, "notarized '{s}' on {s}", .{ subject_id, chain }),
            .detail = try std.fmt.allocPrint(allocator, "proof={s}", .{tx_hash[0..@min(16, tx_hash.len)]}),
            .status = try allocator.dupe(u8, "ok"),
        });
    }
}

fn collectDriftHistory(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    events: *std.ArrayList(AuditEvent),
) !void {
    const dir_path = try zevPath(allocator, repo, "drift_history");
    defer allocator.free(dir_path);
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const content = (try readFileSafe(allocator, path)) orelse continue;
        defer allocator.free(content);

        var baseline: []u8 = try allocator.dupe(u8, "");
        var current: []u8 = try allocator.dupe(u8, "");
        var any_drift = false;
        var timestamp: i64 = 0;
        defer allocator.free(baseline);
        defer allocator.free(current);

        var li = std.mem.splitSequence(u8, content, "\n");
        while (li.next()) |line| {
            if (std.mem.startsWith(u8, line, "baseline=")) {
                allocator.free(baseline);
                baseline = try allocator.dupe(u8, line[9..]);
            } else if (std.mem.startsWith(u8, line, "current=")) {
                allocator.free(current);
                current = try allocator.dupe(u8, line[8..]);
            } else if (std.mem.startsWith(u8, line, "any_drift=")) {
                any_drift = std.mem.eql(u8, line[10..], "true");
            } else if (std.mem.startsWith(u8, line, "timestamp=")) {
                timestamp = std.fmt.parseInt(i64, line[10..], 10) catch 0;
            }
        }

        const status = if (any_drift) "warn" else "ok";
        try events.append(allocator, AuditEvent{
            .kind = .drift_check,
            .timestamp = timestamp,
            .ref = try allocator.dupe(u8, current),
            .summary = try std.fmt.allocPrint(allocator, "drift check: {s} vs {s} — {s}", .{ current, baseline, if (any_drift) "DRIFT DETECTED" else "no drift" }),
            .detail = try std.fmt.allocPrint(allocator, "baseline={s}", .{baseline}),
            .status = try allocator.dupe(u8, status),
        });
    }
}

fn collectReproductions(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    events: *std.ArrayList(AuditEvent),
    filter_ref: ?[]const u8,
) !void {
    const dir_path = try zevPath(allocator, repo, "reproduce");
    defer allocator.free(dir_path);
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const content = (try readFileSafe(allocator, path)) orelse continue;
        defer allocator.free(content);

        var subject_id: []u8 = try allocator.dupe(u8, "");
        var run_cmd: []u8 = try allocator.dupe(u8, "");
        var status: []u8 = try allocator.dupe(u8, "");
        var timestamp: i64 = 0;
        var duration_ms: u64 = 0;
        defer allocator.free(subject_id);
        defer allocator.free(run_cmd);
        defer allocator.free(status);

        var li = std.mem.splitSequence(u8, content, "\n");
        while (li.next()) |line| {
            if (std.mem.startsWith(u8, line, "subject_id=")) {
                allocator.free(subject_id);
                subject_id = try allocator.dupe(u8, line[11..]);
            } else if (std.mem.startsWith(u8, line, "run_command=")) {
                allocator.free(run_cmd);
                run_cmd = try allocator.dupe(u8, line[12..]);
            } else if (std.mem.startsWith(u8, line, "status=")) {
                allocator.free(status);
                status = try allocator.dupe(u8, line[7..]);
            } else if (std.mem.startsWith(u8, line, "timestamp=")) {
                timestamp = std.fmt.parseInt(i64, line[10..], 10) catch 0;
            } else if (std.mem.startsWith(u8, line, "duration_ms=")) {
                duration_ms = std.fmt.parseInt(u64, line[12..], 10) catch 0;
            }
        }

        if (filter_ref != null and !std.mem.eql(u8, subject_id, filter_ref.?)) continue;

        const ev_status = if (std.mem.eql(u8, status, "success")) "ok" else if (std.mem.eql(u8, status, "partial")) "warn" else "fail";

        try events.append(allocator, AuditEvent{
            .kind = .reproduce,
            .timestamp = timestamp,
            .ref = try allocator.dupe(u8, subject_id),
            .summary = try std.fmt.allocPrint(allocator, "reproduce '{s}': {s} ({d}ms)", .{ subject_id, status, duration_ms }),
            .detail = try std.fmt.allocPrint(allocator, "cmd={s}", .{run_cmd[0..@min(50, run_cmd.len)]}),
            .status = try allocator.dupe(u8, ev_status),
        });
    }
}

fn collectExperiments(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    events: *std.ArrayList(AuditEvent),
) !void {
    const dir_path = try zevPath(allocator, repo, "experiments");
    defer allocator.free(dir_path);
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const content = (try readFileSafe(allocator, path)) orelse continue;
        defer allocator.free(content);

        var name: []u8 = try allocator.dupe(u8, "");
        var status: []u8 = try allocator.dupe(u8, "");
        var hypothesis: []u8 = try allocator.dupe(u8, "");
        var timestamp: i64 = 0;
        defer allocator.free(name);
        defer allocator.free(status);
        defer allocator.free(hypothesis);

        var li = std.mem.splitSequence(u8, content, "\n");
        while (li.next()) |line| {
            if (std.mem.startsWith(u8, line, "name=")) {
                allocator.free(name);
                name = try allocator.dupe(u8, line[5..]);
            } else if (std.mem.startsWith(u8, line, "status=")) {
                allocator.free(status);
                status = try allocator.dupe(u8, line[7..]);
            } else if (std.mem.startsWith(u8, line, "hypothesis=")) {
                allocator.free(hypothesis);
                hypothesis = try allocator.dupe(u8, line[11..]);
            } else if (std.mem.startsWith(u8, line, "created=")) {
                timestamp = std.fmt.parseInt(i64, line[8..], 10) catch 0;
            }
        }

        if (name.len == 0) continue;

        const ev_status = if (std.mem.eql(u8, status, "completed")) "ok" else if (std.mem.eql(u8, status, "running")) "info" else "warn";

        try events.append(allocator, AuditEvent{
            .kind = .experiment,
            .timestamp = timestamp,
            .ref = try allocator.dupe(u8, name),
            .summary = try std.fmt.allocPrint(allocator, "experiment '{s}' [{s}]", .{ name, status }),
            .detail = try std.fmt.allocPrint(allocator, "hypothesis: {s}", .{hypothesis[0..@min(60, hypothesis.len)]}),
            .status = try allocator.dupe(u8, ev_status),
        });
    }
}

fn collectContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    events: *std.ArrayList(AuditEvent),
) !void {
    const dir_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "context" });
    defer allocator.free(dir_path);
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const file_content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(file_content);
        var file_path: []u8 = try allocator.dupe(u8, "");
        var model: []u8 = try allocator.dupe(u8, "");
        var kind: []u8 = try allocator.dupe(u8, "");
        var ts: i64 = 0;
        defer allocator.free(file_path);
        defer allocator.free(model);
        defer allocator.free(kind);
        var li = std.mem.splitSequence(u8, file_content, "\n");
        while (li.next()) |line| {
            if (std.mem.startsWith(u8, line, "file_path=")) {
                allocator.free(file_path);
                file_path = try allocator.dupe(u8, line[10..]);
            } else if (std.mem.startsWith(u8, line, "model=")) {
                allocator.free(model);
                model = try allocator.dupe(u8, line[6..]);
            } else if (std.mem.startsWith(u8, line, "author_kind=")) {
                allocator.free(kind);
                kind = try allocator.dupe(u8, line[12..]);
            } else if (std.mem.startsWith(u8, line, "generation_ts=")) {
                ts = std.fmt.parseInt(i64, line[14..], 10) catch 0;
            }
        }
        if (file_path.len == 0) continue;
        try events.append(allocator, AuditEvent{
            .kind = .context_record,
            .timestamp = ts,
            .ref = try allocator.dupe(u8, file_path[0..@min(20, file_path.len)]),
            .summary = try std.fmt.allocPrint(allocator, "context: {s} [{s}]", .{ file_path, kind }),
            .detail = try std.fmt.allocPrint(allocator, "model={s}", .{model}),
            .status = try allocator.dupe(u8, "ok"),
        });
    }
}

fn sortByTimestamp(_: void, a: AuditEvent, b: AuditEvent) bool {
    return a.timestamp < b.timestamp;
}

fn kindLabel(kind: EventKind) []const u8 {
    return switch (kind) {
        .commit => "COMMIT      ",
        .metrics => "METRICS     ",
        .snapshot => "SNAPSHOT    ",
        .experiment => "EXPERIMENT  ",
        .lineage => "LINEAGE     ",
        .notarization => "NOTARIZE    ",
        .drift_check => "DRIFT       ",
        .reproduce => "REPRODUCE   ",
        .peer_announce => "PEER        ",
        .export_op => "EXPORT      ",
        .context_record => "CONTEXT     ",
    };
}

fn kindIcon(kind: EventKind) []const u8 {
    return switch (kind) {
        .commit => "●",
        .metrics => "📊",
        .snapshot => "📸",
        .experiment => "🧪",
        .lineage => "🔗",
        .notarization => "⛓️ ",
        .drift_check => "📈",
        .reproduce => "🔬",
        .peer_announce => "🌐",
        .export_op => "📦",
        .context_record => "🤖",
    };
}

fn statusIcon(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "ok")) return "✅";
    if (std.mem.eql(u8, status, "warn")) return "⚠️ ";
    if (std.mem.eql(u8, status, "fail")) return "❌";
    return "ℹ️ ";
}

fn renderTerminal(events: []const AuditEvent, repo_path: []const u8, filter: ?[]const u8) void {
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  ZEV PROVENANCE AUDIT REPORT                                     ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("   Repository: {s}\n", .{repo_path});
    if (filter) |f| std.debug.print("   Filter:     {s}\n", .{f});
    std.debug.print("   Events:     {d}\n", .{events.len});
    std.debug.print("\n", .{});
    std.debug.print("   {s:<12} {s:<14} {s:<14} {s}\n", .{ "Type", "Ref", "Status", "Summary" });
    const divider = comptime blk: {
        var s: []const u8 = "";
        for (0..78) |_| s = s ++ "─";
        break :blk s;
    };

    for (events) |ev| {
        std.debug.print("   {s}{s:<11} {s:<14} {s}  {s}\n", .{
            kindIcon(ev.kind),
            kindLabel(ev.kind),
            ev.ref[0..@min(12, ev.ref.len)],
            statusIcon(ev.status),
            ev.summary[0..@min(55, ev.summary.len)],
        });
        if (ev.detail.len > 0) {
            std.debug.print("              {s}\n", .{ev.detail[0..@min(70, ev.detail.len)]});
        }
    }
    std.debug.print("   {s}\n", .{divider});
}

fn renderMarkdown(
    allocator: std.mem.Allocator,
    events: []const AuditEvent,
    repo_path: []const u8,
    filter: ?[]const u8,
    output_path: []const u8,
) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const appendStr = struct {
        fn f(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
            try list.appendSlice(alloc, s);
        }
    }.f;

    try appendStr(&out, allocator, "# Zev Provenance Audit Report\n\n");
    {
        const s = try std.fmt.allocPrint(allocator, "**Repository:** `{s}`\n\n", .{repo_path});
        defer allocator.free(s);
        try appendStr(&out, allocator, s);
    }
    if (filter) |f| {
        const s = try std.fmt.allocPrint(allocator, "**Filter:** `{s}`\n\n", .{f});
        defer allocator.free(s);
        try appendStr(&out, allocator, s);
    }
    {
        const s = try std.fmt.allocPrint(allocator, "**Total events:** {d}\n\n", .{events.len});
        defer allocator.free(s);
        try appendStr(&out, allocator, s);
    }
    try appendStr(&out, allocator, "---\n\n");
    try appendStr(&out, allocator, "## Timeline\n\n");
    try appendStr(&out, allocator, "| Type | Ref | Status | Summary |\n");
    try appendStr(&out, allocator, "|------|-----|--------|----------|\n");

    for (events) |ev| {
        const status_md: []const u8 = if (std.mem.eql(u8, ev.status, "ok")) "✅ OK" else if (std.mem.eql(u8, ev.status, "warn")) "⚠️ WARN" else if (std.mem.eql(u8, ev.status, "fail")) "❌ FAIL" else "ℹ️ INFO";
        const row = try std.fmt.allocPrint(allocator, "| {s} | `{s}` | {s} | {s} |\n", .{ kindLabel(ev.kind), ev.ref[0..@min(12, ev.ref.len)], status_md, ev.summary[0..@min(80, ev.summary.len)] });
        defer allocator.free(row);
        try appendStr(&out, allocator, row);
    }

    try appendStr(&out, allocator, "\n---\n\n## Event Details\n\n");
    for (events) |ev| {
        const hdr = try std.fmt.allocPrint(allocator, "### {s} `{s}`\n\n- **Summary:** {s}\n- **Detail:** {s}\n- **Timestamp:** {d}\n\n", .{ kindLabel(ev.kind), ev.ref, ev.summary, ev.detail, ev.timestamp });
        defer allocator.free(hdr);
        try appendStr(&out, allocator, hdr);
    }

    try appendStr(&out, allocator, "---\n\n## Summary\n\n");
    var ok_count: usize = 0;
    var warn_count: usize = 0;
    var fail_count: usize = 0;
    for (events) |ev| {
        if (std.mem.eql(u8, ev.status, "ok")) ok_count += 1 else if (std.mem.eql(u8, ev.status, "warn")) warn_count += 1 else if (std.mem.eql(u8, ev.status, "fail")) fail_count += 1;
    }
    {
        const s = try std.fmt.allocPrint(allocator, "- ✅ OK: {d}\n- ⚠️ Warnings: {d}\n- ❌ Failures: {d}\n\n", .{ ok_count, warn_count, fail_count });
        defer allocator.free(s);
        try appendStr(&out, allocator, s);
    }

    const overall: []const u8 = if (fail_count > 0) "❌ AUDIT FAILED" else if (warn_count > 0) "⚠️ AUDIT PASSED WITH WARNINGS" else "✅ AUDIT PASSED";
    {
        const s = try std.fmt.allocPrint(allocator, "**Overall: {s}**\n", .{overall});
        defer allocator.free(s);
        try appendStr(&out, allocator, s);
    }

    const f = try std.Io.Dir.cwd().createFile(output_path, .{});
    defer f.close(io);
    try f.writeAll(out.items);

    std.debug.print("📄 Markdown report: {s} ({d} bytes)\n", .{ output_path, out.items.len });
}

fn renderJson(
    allocator: std.mem.Allocator,
    events: []const AuditEvent,
    repo_path: []const u8,
    output_path: []const u8,
) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "{\n");
    {
        const s = try std.fmt.allocPrint(allocator, "  \"repo\": \"{s}\",\n  \"event_count\": {d},\n  \"events\": [\n", .{ repo_path, events.len });
        defer allocator.free(s);
        try out.appendSlice(allocator, s);
    }

    for (events, 0..) |ev, i| {
        const comma: []const u8 = if (i < events.len - 1) "," else "";
        const s = try std.fmt.allocPrint(allocator, "    {{\"kind\":\"{s}\",\"ref\":\"{s}\",\"timestamp\":{d},\"status\":\"{s}\",\"summary\":\"{s}\"}}{s}\n", .{ kindLabel(ev.kind), ev.ref, ev.timestamp, ev.status, ev.summary[0..@min(100, ev.summary.len)], comma });
        defer allocator.free(s);
        try out.appendSlice(allocator, s);
    }

    try out.appendSlice(allocator, "  ]\n}\n");

    if (std.mem.eql(u8, output_path, "-")) {
        std.debug.print("{s}", .{out.items});
    } else {
        const f = try std.Io.Dir.cwd().createFile(output_path, .{});
        defer f.close(io);
        try f.writeAll(out.items);
        std.debug.print("📄 JSON report: {s} ({d} bytes)\n", .{ output_path, out.items.len });
    }
}

fn printSummary(events: []const AuditEvent) void {
    var ok_count: usize = 0;
    var warn_count: usize = 0;
    var fail_count: usize = 0;
    var by_kind: [11]usize = @splat(0);

    for (events) |ev| {
        if (std.mem.eql(u8, ev.status, "ok")) ok_count += 1 else if (std.mem.eql(u8, ev.status, "warn")) warn_count += 1 else if (std.mem.eql(u8, ev.status, "fail")) fail_count += 1;
        by_kind[@intFromEnum(ev.kind)] += 1;
    }

    std.debug.print("   ─── Summary ────────────────────────────────────────────────\n", .{});
    if (by_kind[@intFromEnum(EventKind.commit)] > 0)
        std.debug.print("   Commits:        {d}\n", .{by_kind[@intFromEnum(EventKind.commit)]});
    if (by_kind[@intFromEnum(EventKind.metrics)] > 0)
        std.debug.print("   Metric records: {d}\n", .{by_kind[@intFromEnum(EventKind.metrics)]});
    if (by_kind[@intFromEnum(EventKind.snapshot)] > 0)
        std.debug.print("   Snapshots:      {d}\n", .{by_kind[@intFromEnum(EventKind.snapshot)]});
    if (by_kind[@intFromEnum(EventKind.experiment)] > 0)
        std.debug.print("   Experiments:    {d}\n", .{by_kind[@intFromEnum(EventKind.experiment)]});
    if (by_kind[@intFromEnum(EventKind.notarization)] > 0)
        std.debug.print("   Notarizations:  {d}\n", .{by_kind[@intFromEnum(EventKind.notarization)]});
    if (by_kind[@intFromEnum(EventKind.drift_check)] > 0)
        std.debug.print("   Drift checks:   {d}\n", .{by_kind[@intFromEnum(EventKind.drift_check)]});
    if (by_kind[@intFromEnum(EventKind.reproduce)] > 0)
        std.debug.print("   Reproductions:  {d}\n", .{by_kind[@intFromEnum(EventKind.reproduce)]});
    if (by_kind[@intFromEnum(EventKind.context_record)] > 0)
        std.debug.print("   Context records:{d}\n", .{by_kind[@intFromEnum(EventKind.context_record)]});
    std.debug.print("\n", .{});
    std.debug.print("   ✅ OK: {d}  ⚠️  Warnings: {d}  ❌ Failures: {d}\n\n", .{ ok_count, warn_count, fail_count });

    const overall: []const u8 = if (fail_count > 0)
        "❌ AUDIT FAILED"
    else if (warn_count > 0)
        "⚠️  AUDIT PASSED WITH WARNINGS"
    else
        "✅ AUDIT PASSED";
    std.debug.print("   Overall: {s}\n\n", .{overall});
}

pub fn runAudit(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    filter_snapshot: ?[]const u8,
    format: []const u8,
    output_path: ?[]const u8,
) !void {
    var events: std.ArrayList(AuditEvent) = .empty;
    defer {
        for (events.items) |ev| {
            allocator.free(ev.ref);
            allocator.free(ev.summary);
            allocator.free(ev.detail);
            allocator.free(ev.status);
        }
        events.deinit(allocator);
    }

    try collectCommits(allocator, io, repo, &events);
    try collectSnapshots(allocator, repo, &events, filter_snapshot);
    try collectNotarizations(allocator, repo, &events, filter_snapshot);
    try collectDriftHistory(allocator, repo, &events);
    try collectReproductions(allocator, repo, &events, filter_snapshot);
    try collectExperiments(allocator, repo, &events);
    try collectContext(allocator, repo, &events);

    std.mem.sort(AuditEvent, events.items, {}, sortByTimestamp);

    const filter_label: ?[]const u8 = if (filter_snapshot) |f|
        try std.fmt.allocPrint(allocator, "snapshot: {s}", .{f})
    else
        null;
    defer if (filter_label) |fl| allocator.free(fl);

    if (std.mem.eql(u8, format, "md")) {
        const out = output_path orelse "zev-audit.md";
        try renderMarkdown(allocator, events.items, repo.path, filter_label, out);
        renderTerminal(events.items, repo.path, filter_label);
        printSummary(events.items);
    } else if (std.mem.eql(u8, format, "json")) {
        const out = output_path orelse "-";
        try renderJson(allocator, events.items, repo.path, out);
    } else {
        renderTerminal(events.items, repo.path, filter_label);
        printSummary(events.items);
        const out = output_path orelse "zev-audit.md";
        try renderMarkdown(allocator, events.items, repo.path, filter_label, out);
    }
}

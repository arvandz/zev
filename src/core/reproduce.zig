const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");
const commit_mod = @import("commit.zig");
const tree_mod = @import("tree.zig");

pub const ReproduceStatus = enum {
    success,
    partial,
    failed,
    error_run,
    no_metrics,
};

pub const MetricMatch = struct {
    key: []const u8,
    original: f64,
    reproduced: f64,
    delta: f64,
    matched: bool,
};

pub const ReproduceRecord = struct {
    id: []const u8,
    subject_type: []const u8,
    subject_id: []const u8,
    commit_hash: []const u8,
    run_command: []const u8,
    timestamp: i64,
    status: []const u8,
    tolerance: f64,
    matches: []MetricMatch,
    exit_code: i32,
    duration_ms: u64,
};

fn reproduceDir(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository) ![]u8 {
    const dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "reproduce" });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn captureDir(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository) ![]u8 {
    const dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "capture" });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn saveReproduceRecord(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    rec: ReproduceRecord,
) !void {
    const dir = try reproduceDir(allocator, io, repo);
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, rec.id });
    defer allocator.free(path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    inline for ([_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "id", .v = rec.id },
        .{ .k = "subject_type", .v = rec.subject_type },
        .{ .k = "subject_id", .v = rec.subject_id },
        .{ .k = "commit_hash", .v = rec.commit_hash },
        .{ .k = "run_command", .v = rec.run_command },
        .{ .k = "status", .v = rec.status },
    }) |field| {
        const s = try std.fmt.allocPrint(allocator, "{s}={s}\n", .{ field.k, field.v });
        defer allocator.free(s);
        try out.appendSlice(allocator, s);
    }
    const nums = try std.fmt.allocPrint(allocator, "timestamp={d}\ntolerance={d:.6}\nexit_code={d}\nduration_ms={d}\n", .{ rec.timestamp, rec.tolerance, rec.exit_code, rec.duration_ms });
    defer allocator.free(nums);
    try out.appendSlice(allocator, nums);

    for (rec.matches) |m| {
        const ms = try std.fmt.allocPrint(allocator, "match={s}:{d:.6}:{d:.6}:{s}\n", .{ m.key, m.original, m.reproduced, if (m.matched) "ok" else "fail" });
        defer allocator.free(ms);
        try out.appendSlice(allocator, ms);
    }

    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    var f_buffer: [512]u8 = undefined;
    var f_writer = f.writer(io, &f_buffer);
    defer f.close(io);
    try f_writer.interface.writeAll(out.items);
    try f_writer.flush();
}

pub fn captureRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    run_command: []const u8,
    env_file: ?[]const u8,
) !void {
    const head = repo.getHeadCommit(io) catch {
        std.debug.print("No commits yet. Make a commit first.\n", .{});
        return;
    };
    const commit_hash = try head.toString(allocator);
    defer allocator.free(commit_hash);

    const dir = try captureDir(allocator, io, repo);
    defer allocator.free(dir);

    const cmd_path = try std.fs.path.join(allocator, &.{ dir, commit_hash });
    defer allocator.free(cmd_path);
    const f = try std.Io.Dir.cwd().createFile(io, cmd_path, .{});
    var f_buffer: [512]u8 = undefined;
    var f_writer = f.writer(io, &f_buffer);
    defer f.close(io);

    const content = try std.fmt.allocPrint(allocator, "run={s}\ncommit={s}\n", .{ run_command, commit_hash });
    defer allocator.free(content);
    try f_writer.interface.writeAll(content);
    try f_writer.flush();

    const rc_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "run_command" });
    defer allocator.free(rc_path);
    const rcf = try std.Io.Dir.cwd().createFile(io, rc_path, .{});
    var rcf_buffer: [512]u8 = undefined;
    var rcf_writer = rcf.writer(io, &rcf_buffer);
    defer rcf.close(io);
    try rcf_writer.interface.writeAll(run_command);
    try rcf_writer.flush();

    if (env_file) |ef| {
        const env_dst = try std.fs.path.join(allocator, &.{ dir, "environment.txt" });
        defer allocator.free(env_dst);
        const env_content = std.Io.Dir.cwd().readFileAlloc(io, ef, allocator, .limited(1024 * 1024)) catch |err| {
            std.debug.print("Warning: could not read env file: {}\n", .{err});
            return;
        };
        defer allocator.free(env_content);
        const edf = try std.Io.Dir.cwd().createFile(io, env_dst, .{});
        var edf_buffer: [512]u8 = undefined;
        var edf_writer = edf.writer(io, &edf_buffer);
        defer edf.close(io);
        try edf_writer.interface.writeAll(env_content);
        try edf_writer.flush();
        std.debug.print("   Environment captured from: {s}\n", .{ef});
    } else {
        try captureAutoEnv(allocator, io, dir);
    }

    std.debug.print("📋 Captured run command for commit {s}\n", .{commit_hash[0..8]});
    std.debug.print("   Command: {s}\n", .{run_command});
    std.debug.print("   Stored in .zev/capture/\n", .{});
    std.debug.print("   Reproduce later: zev reproduce HEAD\n", .{});
}

fn captureAutoEnv(allocator: std.mem.Allocator,
    io: std.Io, capture_dir: []const u8) !void {
    if (std.process.spawn(io, .{
        .argv = &.{ "pip", "freeze" },
        .stdout = .pipe,
        .stderr = .ignore,
    })) |pip_child_result| {
        var pip_child = pip_child_result;
        var buf: [65536]u8 = undefined;
        var pip_child_scratch: [4096]u8 = undefined;
        var pip_child_reader = pip_child.stdout.?.reader(io, &pip_child_scratch);
        const n = pip_child_reader.interface.readSliceShort(&buf) catch 0;
        _ = pip_child.wait(io) catch {};
        if (n > 0) {
            const env_path = try std.fs.path.join(allocator, &.{ capture_dir, "pip_freeze.txt" });
            defer allocator.free(env_path);
            const ef = try std.Io.Dir.cwd().createFile(io, env_path, .{});
            var ef_buffer: [512]u8 = undefined;
            var ef_writer = ef.writer(io, &ef_buffer);
            defer ef.close(io);
            try ef_writer.interface.writeAll(buf[0..n]);
            try ef_writer.flush();
            std.debug.print("   Python env captured (pip freeze → .zev/capture/pip_freeze.txt)\n", .{});
            return;
        }
    } else |_| {}

    if (std.process.spawn(io, .{
        .argv = &.{ "conda", "env", "export" },
        .stdout = .pipe,
        .stderr = .ignore,
    })) |conda_child_result| {
        var conda_child = conda_child_result;
        var buf: [65536]u8 = undefined;
        var conda_child_scratch: [4096]u8 = undefined;
        var conda_child_reader = conda_child.stdout.?.reader(io, &conda_child_scratch);
        const n = conda_child_reader.interface.readSliceShort(&buf) catch 0;
        _ = conda_child.wait(io) catch {};
        if (n > 0) {
            const env_path = try std.fs.path.join(allocator, &.{ capture_dir, "conda_env.yml" });
            defer allocator.free(env_path);
            const ef = try std.Io.Dir.cwd().createFile(io, env_path, .{});
            var ef_buffer: [512]u8 = undefined;
            var ef_writer = ef.writer(io, &ef_buffer);
            defer ef.close(io);
            try ef_writer.interface.writeAll(buf[0..n]);
            try ef_writer.flush();
            std.debug.print("   Conda env captured → .zev/capture/conda_env.yml\n", .{});
            return;
        }
    } else |_| {}

    std.debug.print("   (No Python/Conda env detected — install manually if needed)\n", .{});
}

fn loadRunCommand(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, commit_hash: []const u8) !?[]u8 {
    const dir = try captureDir(allocator, io, repo);
    defer allocator.free(dir);

    const cmd_path = try std.fs.path.join(allocator, &.{ dir, commit_hash });
    defer allocator.free(cmd_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, cmd_path, allocator, .limited(4096)) catch null;
    if (content) |c| {
        defer allocator.free(c);
        var iter = std.mem.splitSequence(u8, c, "\n");
        while (iter.next()) |line| {
            if (std.mem.startsWith(u8, line, "run="))
                return try allocator.dupe(u8, line[4..]);
        }
    }

    const rc_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "run_command" });
    defer allocator.free(rc_path);
    return std.Io.Dir.cwd().readFileAlloc(io, rc_path, allocator, .limited(4096)) catch null;
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

fn loadMetricsFromSnapshot(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, name: []const u8) !?struct { metrics: std.StringHashMap(f64), commit: []u8 } {
    const dir_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "snapshots" });
    defer allocator.free(dir_path);
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or std.mem.endsWith(u8, entry.name, ".name")) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(content);
        var snap_name: []u8 = try allocator.dupe(u8, "");
        var metrics_raw: []u8 = try allocator.dupe(u8, "");
        var commit_hash: []u8 = try allocator.dupe(u8, "");
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
            } else if (std.mem.startsWith(u8, line, "commit_hash=")) {
                allocator.free(commit_hash);
                commit_hash = try allocator.dupe(u8, line[12..]);
            }
        }
        if (!std.mem.eql(u8, snap_name, name)) {
            allocator.free(commit_hash);
            continue;
        }
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
        return .{ .metrics = map, .commit = commit_hash };
    }
    return null;
}

fn freeMetricsMap(allocator: std.mem.Allocator, map: *std.StringHashMap(f64)) void {
    var it = map.iterator();
    while (it.next()) |e| allocator.free(e.key_ptr.*);
    map.deinit();
}

fn checkoutCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    commit_hash: []const u8,
    target_dir: []const u8,
) !usize {
    if (commit_hash.len != 64) return error.InvalidHash;

    var hash: [32]u8 = undefined;
    for (0..32) |i| {
        const hi = try std.fmt.charToDigit(commit_hash[i * 2], 16);
        const lo = try std.fmt.charToDigit(commit_hash[i * 2 + 1], 16);
        hash[i] = (hi << 4) | lo;
    }
    const commit_cid = cid_mod.CID{ .hash = hash };

    const commit_data = try repo.store.get(io, commit_cid);
    defer allocator.free(commit_data);
    const c = try commit_mod.Commit.deserialize(allocator, commit_data);
    defer allocator.free(c.author);
    defer allocator.free(c.message);

    const tree_data = try repo.store.get(io, c.tree_cid);
    defer allocator.free(tree_data);
    var t = try tree_mod.Tree.deserialize(allocator, tree_data);
    defer t.deinit();

    var count: usize = 0;
    for (t.entries.items) |entry| {
        const blob_data = repo.store.get(io, entry.cid) catch continue;
        defer allocator.free(blob_data);

        const file_path = try std.fs.path.join(allocator, &.{ target_dir, entry.name });
        defer allocator.free(file_path);

        const f = try std.Io.Dir.cwd().createFile(io, file_path, .{});
        var f_buffer: [512]u8 = undefined;
        var f_writer = f.writer(io, &f_buffer);
        defer f.close(io);
        try f_writer.interface.writeAll(blob_data);
        try f_writer.flush();
        count += 1;
    }
    return count;
}

fn parseMetricsFromOutput(
    allocator: std.mem.Allocator,
    output: []const u8,
) !std.StringHashMap(f64) {
    var map = std.StringHashMap(f64).init(allocator);

    var line_iter = std.mem.splitSequence(u8, output, "\n");
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (std.mem.startsWith(u8, trimmed, "zev_metric:") or
            std.mem.startsWith(u8, trimmed, "ZEV_METRIC"))
        {
            const after = if (std.mem.startsWith(u8, trimmed, "zev_metric:"))
                trimmed[11..]
            else
                trimmed[10..];
            const kv = std.mem.trim(u8, after, " \t");
            const eq = std.mem.indexOf(u8, kv, "=") orelse continue;
            const k = try allocator.dupe(u8, std.mem.trim(u8, kv[0..eq], " "));
            const v = std.fmt.parseFloat(f64, std.mem.trim(u8, kv[eq + 1 ..], " ")) catch {
                allocator.free(k);
                continue;
            };
            try map.put(k, v);
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "METRIC:")) {
            const after = std.mem.trim(u8, trimmed[7..], " \t");
            const eq = std.mem.indexOf(u8, after, "=") orelse continue;
            const k = try allocator.dupe(u8, std.mem.trim(u8, after[0..eq], " "));
            const v = std.fmt.parseFloat(f64, std.mem.trim(u8, after[eq + 1 ..], " ")) catch {
                allocator.free(k);
                continue;
            };
            try map.put(k, v);
            continue;
        }

        if (std.mem.indexOf(u8, trimmed, "=") != null and
            std.mem.indexOf(u8, trimmed, " ") == null and
            trimmed.len < 60)
        {
            const eq = std.mem.indexOf(u8, trimmed, "=") orelse continue;
            const k = trimmed[0..eq];
            if (isMetricName(k)) {
                const val = std.fmt.parseFloat(f64, trimmed[eq + 1 ..]) catch continue;
                const kdup = try allocator.dupe(u8, k);
                try map.put(kdup, val);
            }
        }
    }
    return map;
}

fn isMetricName(s: []const u8) bool {
    if (s.len == 0 or s.len > 40) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    const known = [_][]const u8{
        "accuracy", "loss",       "val_accuracy", "val_loss", "f1",    "precision",
        "recall",   "auc",        "mae",          "mse",      "rmse",  "r2",
        "bleu",     "perplexity", "score",        "metric",   "error", "rate",
    };
    for (known) |k| {
        if (std.mem.eql(u8, s, k)) return true;
        if (std.mem.indexOf(u8, s, k) != null) return true;
    }
    return false;
}

fn doReproduce(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    subject_type: []const u8,
    subject_id: []const u8,
    commit_hash: []const u8,
    original_metrics: *std.StringHashMap(f64),
    tolerance: f64,
    run_cmd_override: ?[]const u8,
    dry_run: bool,
) !void {
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));

    const id_raw = try std.fmt.allocPrint(allocator, "repro:{s}:{d}", .{ commit_hash, now });
    defer allocator.free(id_raw);
    const id_cid = cid_mod.CID.fromBytes(id_raw);
    const rec_id = try id_cid.toString(allocator);
    defer allocator.free(rec_id);
    const rec_id_short = rec_id[0..16];

    std.debug.print("\n🔬 Reproducing {s}: {s}\n", .{ subject_type, subject_id });
    std.debug.print("   Commit:    {s}\n", .{commit_hash[0..8]});
    std.debug.print("   Record ID: {s}\n\n", .{rec_id_short});

    const work_dir = try std.fmt.allocPrint(allocator, "/tmp/zev-repro-{s}", .{commit_hash[0..8]});
    defer allocator.free(work_dir);
    try std.Io.Dir.cwd().createDirPath(io, work_dir);
    defer std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};

    std.debug.print("   📁 Workspace: {s}\n", .{work_dir});

    std.debug.print("   📦 Checking out commit {s}...\n", .{commit_hash[0..8]});
    const file_count = checkoutCommit(allocator, io, repo, commit_hash, work_dir) catch |err| {
        std.debug.print("   ❌ Checkout failed: {}\n", .{err});
        return;
    };
    std.debug.print("   ✅ Checked out {d} file(s)\n", .{file_count});

    const run_cmd = run_cmd_override orelse
        (try loadRunCommand(allocator, io, repo, commit_hash)) orelse {
        std.debug.print("\n   ⚠️  No run command found for this commit.\n", .{});
        std.debug.print("   Capture one with:\n", .{});
        std.debug.print("   zev reproduce capture \"python train.py\"\n", .{});
        std.debug.print("\n   Or provide it directly:\n", .{});
        std.debug.print("   zev reproduce {s} --cmd \"python train.py\"\n", .{subject_id});

        std.debug.print("\n   Files checked out to {s}:\n", .{work_dir});
        var wd = std.Io.Dir.cwd().openDir(io, work_dir, .{ .iterate = true }) catch return;
        defer wd.close(io);
        var wdit = wd.iterate();
        while (try wdit.next(io)) |e| {
            std.debug.print("   - {s}\n", .{e.name});
        }
        return;
    };
    defer if (run_cmd_override == null) allocator.free(run_cmd);

    std.debug.print("   🚀 Run command: {s}\n", .{run_cmd});

    if (dry_run) {
        std.debug.print("\n   🔍 Dry run — would execute in {s}:\n", .{work_dir});
        std.debug.print("   $ {s}\n\n", .{run_cmd});
        std.debug.print("   Original metrics to match (tolerance ±{d}):\n", .{tolerance});
        var oit = original_metrics.iterator();
        while (oit.next()) |e| {
            std.debug.print("   {s} = {d:.4}\n", .{ e.key_ptr.*, e.value_ptr.* });
        }
        return;
    }

    std.debug.print("\n   ⏱️  Running...\n", .{});
    const start_inst = std.Io.Timestamp.now(io, .awake);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    {
        var ci: usize = 0;
        while (ci < run_cmd.len) {
            while (ci < run_cmd.len and run_cmd[ci] == ' ') ci += 1;
            if (ci >= run_cmd.len) break;
            const quote = run_cmd[ci];
            if (quote == '"' or quote == @as(u8, 39)) {
                ci += 1;
                const start = ci;
                while (ci < run_cmd.len and run_cmd[ci] != quote) ci += 1;
                if (start < ci) try argv.append(allocator, run_cmd[start..ci]);
                if (ci < run_cmd.len) ci += 1; // skip closing quote
            } else {
                const start = ci;
                while (ci < run_cmd.len and run_cmd[ci] != ' ') ci += 1;
                if (start < ci) try argv.append(allocator, run_cmd[start..ci]);
            }
        }
    }

    {
        const cap_dir_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "capture" });
        defer allocator.free(cap_dir_path);
        var repo_dir = std.Io.Dir.cwd().openDir(io, repo.path, .{ .iterate = true }) catch unreachable;
        defer repo_dir.close(io);
        var rdit = repo_dir.iterate();
        while (try rdit.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            const src = try std.fs.path.join(allocator, &.{ repo.path, entry.name });
            defer allocator.free(src);
            const dst = try std.fs.path.join(allocator, &.{ work_dir, entry.name });
            defer allocator.free(dst);
            std.Io.Dir.cwd().access(io, dst, .{}) catch {
                const data = std.Io.Dir.cwd().readFileAlloc(io, src, allocator, .limited(1024 * 1024)) catch continue;
                defer allocator.free(data);
                const wf = std.Io.Dir.cwd().createFile(io, dst, .{}) catch continue;
                defer wf.close(io);
                var wf_buffer: [512]u8 = undefined;
                var wf_writer = wf.writer(io, &wf_buffer);
                wf_writer.interface.writeAll(data) catch continue;
                wf_writer.flush() catch continue;
            };
        }
    }
    var exit_code: i32 = -1;
    var output_buf: [65536]u8 = undefined;
    var output_len: usize = 0;

    if (std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .path = work_dir },
        .stdout = .pipe,
        .stderr = .pipe,
    })) |child_result| {
        var child = child_result;
        var child_scratch: [4096]u8 = undefined;
        var child_reader = child.stdout.?.reader(io, &child_scratch);
        output_len = child_reader.interface.readSliceShort(&output_buf) catch 0;
        const term = child.wait(io) catch std.process.Child.Term{ .exited = 1 };
        exit_code = switch (term) {
            .exited => |c| @intCast(c),
            else => -1,
        };
    } else |err| {
        std.debug.print("   ❌ Failed to run command: {}\n", .{err});
        exit_code = -1;
    }

    const elapsed_ms: u64 = @intCast(start_inst.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds());
    std.debug.print("   Completed in {d}ms, exit code: {d}\n\n", .{ elapsed_ms, exit_code });

    const output = output_buf[0..output_len];
    var repro_metrics = try parseMetricsFromOutput(allocator, output);
    defer freeMetricsMap(allocator, &repro_metrics);

    const metrics_out_path = try std.fs.path.join(allocator, &.{ work_dir, "metrics.txt" });
    defer allocator.free(metrics_out_path);
    if (std.Io.Dir.cwd().readFileAlloc(io, metrics_out_path, allocator, .limited(64 * 1024))) |mf| {
        defer allocator.free(mf);
        var mi = std.mem.splitSequence(u8, mf, "\n");
        while (mi.next()) |line| {
            const eq = std.mem.indexOf(u8, line, "=") orelse continue;
            const k = try allocator.dupe(u8, line[0..eq]);
            const v = std.fmt.parseFloat(f64, line[eq + 1 ..]) catch {
                allocator.free(k);
                continue;
            };
            try repro_metrics.put(k, v);
        }
    } else |_| {}

    std.debug.print("   📊 Metric Comparison (tolerance: ±{d}):\n\n", .{tolerance});
    std.debug.print("   {s:<22} {s:<14} {s:<14} {s}\n", .{ "Metric", "Original", "Reproduced", "Match" });
    const divider60 = comptime blk: {
        var s: []const u8 = "";
        for (0..60) |_| s = s ++ "─";
        break :blk s;
    };
    std.debug.print("   {s}\n", .{divider60});

    var matches: std.ArrayList(MetricMatch) = .empty;
    defer {
        for (matches.items) |m| allocator.free(m.key);
        matches.deinit(allocator);
    }

    var total: usize = 0;
    var matched: usize = 0;

    var oit = original_metrics.iterator();
    while (oit.next()) |entry| {
        total += 1;
        const orig = entry.value_ptr.*;
        const repro_val = repro_metrics.get(entry.key_ptr.*);
        const delta = if (repro_val) |rv| @abs(rv - orig) else std.math.inf(f64);
        const did_match = delta <= tolerance;
        if (did_match) matched += 1;

        const status: []const u8 = if (repro_val == null) "❓ missing" else if (did_match) "✅ match" else "❌ differ";

        if (repro_val) |rv| {
            std.debug.print("   {s:<22} {d:<14.4} {d:<14.4} {s}\n", .{ entry.key_ptr.*, orig, rv, status });
        } else {
            std.debug.print("   {s:<22} {d:<14.4} {s:<14} {s}\n", .{ entry.key_ptr.*, orig, "(none)", status });
        }

        try matches.append(allocator, MetricMatch{
            .key = try allocator.dupe(u8, entry.key_ptr.*),
            .original = orig,
            .reproduced = repro_val orelse -1,
            .delta = delta,
            .matched = did_match,
        });
    }

    var rit = repro_metrics.iterator();
    while (rit.next()) |entry| {
        if (original_metrics.contains(entry.key_ptr.*)) continue;
        std.debug.print("   {s:<22} {s:<14} {d:<14.4} ➕ new\n", .{ entry.key_ptr.*, "(none)", entry.value_ptr.* });
    }

    std.debug.print("\n", .{});

    const repro_status: ReproduceStatus = if (exit_code != 0)
        .error_run
    else if (repro_metrics.count() == 0)
        .no_metrics
    else if (matched == total and total > 0)
        .success
    else if (matched > 0)
        .partial
    else
        .failed;

    const status_str: []const u8 = switch (repro_status) {
        .success => "✅ REPRODUCED — all metrics match",
        .partial => "⚠️  PARTIAL — some metrics matched",
        .failed => "❌ FAILED — metrics diverged",
        .error_run => "❌ ERROR — script did not run successfully",
        .no_metrics => "⚠️  NO METRICS — script ran but produced no parseable metrics",
    };
    std.debug.print("   {s}\n", .{status_str});
    if (total > 0)
        std.debug.print("   {d}/{d} metrics matched within ±{d}\n\n", .{ matched, total, tolerance });

    if (repro_status == .no_metrics) {
        std.debug.print("   To emit metrics from your script, print:\n", .{});
        std.debug.print("   zev_metric: accuracy=0.91\n", .{});
        std.debug.print("   Or write key=value pairs to metrics.txt\n\n", .{});
    }

    const status_name: []const u8 = switch (repro_status) {
        .success => "success",
        .partial => "partial",
        .failed => "failed",
        .error_run => "error_run",
        .no_metrics => "no_metrics",
    };
    const rec = ReproduceRecord{
        .id = rec_id,
        .subject_type = subject_type,
        .subject_id = subject_id,
        .commit_hash = commit_hash,
        .run_command = run_cmd,
        .timestamp = now,
        .status = status_name,
        .tolerance = tolerance,
        .matches = matches.items,
        .exit_code = exit_code,
        .duration_ms = elapsed_ms,
    };
    try saveReproduceRecord(allocator, io, repo, rec);
    std.debug.print("   Record saved: {s}\n", .{rec_id_short});
    std.debug.print("   View history: zev reproduce status\n\n", .{});
}

pub fn reproduceSnapshot(io: std.Io, allocator: std.mem.Allocator, repo: *Repository, snap_name: []const u8, tolerance: f64, run_cmd: ?[]const u8, dry_run: bool) !void {
    const snap = (try loadMetricsFromSnapshot(allocator, io, repo, snap_name)) orelse {
        std.debug.print("Snapshot '{s}' not found.\n", .{snap_name});
        return;
    };
    var metrics = snap.metrics;
    defer freeMetricsMap(allocator, &metrics);
    defer allocator.free(snap.commit);

    try doReproduce(allocator, io, repo, "snapshot", snap_name, snap.commit, &metrics, tolerance, run_cmd, dry_run);
}

pub fn reproduceCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    commit_ref: []const u8,
    tolerance: f64,
    run_cmd: ?[]const u8,
    dry_run: bool,
) !void {
    const commit_hash = if (std.mem.eql(u8, commit_ref, "HEAD")) blk: {
        const head = repo.getHeadCommit(io) catch {
            std.debug.print("No commits yet.\n", .{});
            return;
        };
        break :blk try head.toString(allocator);
    } else try allocator.dupe(u8, commit_ref);
    defer allocator.free(commit_hash);

    var metrics = try loadMetricsForHash(allocator, io, repo, commit_hash);
    defer freeMetricsMap(allocator, &metrics);

    if (metrics.count() == 0) {
        std.debug.print("No metrics recorded for commit {s}.\n", .{commit_hash[0..8]});
        std.debug.print("Set metrics with: zev metrics set <key> <value>\n", .{});
    }

    try doReproduce(allocator, io, repo, "commit", commit_hash[0..8], commit_hash, &metrics, tolerance, run_cmd, dry_run);
}

pub fn reproduceStatus(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, limit: usize) !void {
    const dir = try reproduceDir(allocator, io, repo);
    defer allocator.free(dir);

    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch {
        std.debug.print("No reproduction records yet.\n", .{});
        std.debug.print("Run: zev reproduce <snapshot-name>\n", .{});
        return;
    };
    defer d.close(io);

    var entries: std.ArrayList([]u8) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e);
        entries.deinit(allocator);
    }
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try entries.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, entries.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .gt;
        }
    }.lt);

    std.debug.print("🔬 Reproduction History (most recent first):\n\n", .{});
    var shown: usize = 0;

    for (entries.items) |name| {
        if (shown >= limit) break;
        const path = try std.fs.path.join(allocator, &.{ dir, name });
        defer allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(content);

        var subject_id: []u8 = try allocator.dupe(u8, "");
        var subject_type: []u8 = try allocator.dupe(u8, "");
        var rec_status: []u8 = try allocator.dupe(u8, "");
        var run_cmd: []u8 = try allocator.dupe(u8, "");
        var timestamp: i64 = 0;
        var duration_ms: u64 = 0;
        defer allocator.free(subject_id);
        defer allocator.free(subject_type);
        defer allocator.free(rec_status);
        defer allocator.free(run_cmd);

        var li = std.mem.splitSequence(u8, content, "\n");
        while (li.next()) |line| {
            if (std.mem.startsWith(u8, line, "subject_id=")) {
                allocator.free(subject_id);
                subject_id = try allocator.dupe(u8, line[11..]);
            } else if (std.mem.startsWith(u8, line, "subject_type=")) {
                allocator.free(subject_type);
                subject_type = try allocator.dupe(u8, line[13..]);
            } else if (std.mem.startsWith(u8, line, "status=")) {
                allocator.free(rec_status);
                rec_status = try allocator.dupe(u8, line[7..]);
            } else if (std.mem.startsWith(u8, line, "run_command=")) {
                allocator.free(run_cmd);
                run_cmd = try allocator.dupe(u8, line[12..]);
            } else if (std.mem.startsWith(u8, line, "timestamp="))
                timestamp = std.fmt.parseInt(i64, line[10..], 10) catch 0
            else if (std.mem.startsWith(u8, line, "duration_ms="))
                duration_ms = std.fmt.parseInt(u64, line[12..], 10) catch 0;
        }

        const icon: []const u8 = if (std.mem.eql(u8, rec_status, "success")) "✅" else if (std.mem.eql(u8, rec_status, "partial")) "⚠️ " else "❌";

        std.debug.print("  {s} [{s}] {s}  t={d}  {d}ms\n", .{ icon, subject_type, subject_id, timestamp, duration_ms });
        std.debug.print("     cmd: {s}\n\n", .{run_cmd[0..@min(60, run_cmd.len)]});
        shown += 1;
    }
    if (shown == 0) std.debug.print("  No records yet.\n\n", .{});
}

pub fn capturePub(io: std.Io, allocator: std.mem.Allocator, repo: *Repository, run_command: []const u8, env_file: ?[]const u8) !void {
    try captureRun(allocator, io, repo, run_command, env_file);
}

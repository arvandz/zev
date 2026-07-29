const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");
const commit_mod = @import("commit.zig");

pub const PublishConfig = struct {
    endpoint: []const u8,
    token: []const u8,
    username: []const u8,
};

fn loadPublishConfig(allocator: std.mem.Allocator, io: std.Io, repo: *Repository) !?PublishConfig {
    const config_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "config" });
    defer allocator.free(config_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(64 * 1024)) catch return null;
    defer allocator.free(content);

    var endpoint: []u8 = try allocator.dupe(u8, "");
    var token: []u8 = try allocator.dupe(u8, "");
    var username: []u8 = try allocator.dupe(u8, "");

    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOf(u8, line, "=") orelse continue;
        const k = line[0..eq];
        const v = line[eq + 1 ..];
        if (std.mem.eql(u8, k, "publish.endpoint")) {
            allocator.free(endpoint);
            endpoint = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "publish.token")) {
            allocator.free(token);
            token = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "publish.username")) {
            allocator.free(username);
            username = try allocator.dupe(u8, v);
        }
    }

    if (endpoint.len == 0) {
        allocator.free(endpoint);
        allocator.free(token);
        allocator.free(username);
        return null;
    }

    return PublishConfig{ .endpoint = endpoint, .token = token, .username = username };
}

fn freePublishConfig(allocator: std.mem.Allocator, cfg: PublishConfig) void {
    allocator.free(cfg.endpoint);
    allocator.free(cfg.token);
    allocator.free(cfg.username);
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

fn readMetrics(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, hash: []const u8) ![]u8 {
    const metrics_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "metrics", hash });
    defer allocator.free(metrics_path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, metrics_path, allocator, .limited(64 * 1024)) catch
        return try allocator.dupe(u8, "");
    defer allocator.free(content);

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
    return result.toOwnedSlice(allocator);
}

fn getAuthor(allocator: std.mem.Allocator, io: std.Io, repo: *Repository) ![]u8 {
    const config_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "config" });
    defer allocator.free(config_path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(4096)) catch
        return try allocator.dupe(u8, "unknown");
    defer allocator.free(content);
    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "user.name=")) {
            return try allocator.dupe(u8, line[10..]);
        }
    }
    return try allocator.dupe(u8, "unknown");
}

fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (input) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn buildCommitPayload(
    allocator: std.mem.Allocator,
    commit_hash: []const u8,
    message: []const u8,
    author: []const u8,
    branch: []const u8,
    metrics: []const u8,
    tags: []const u8,
    note: []const u8,
    username: []const u8,
    repo_name: []const u8,
) ![]u8 {
    const msg_esc = try jsonEscape(allocator, message);
    defer allocator.free(msg_esc);
    const note_esc = try jsonEscape(allocator, note);
    defer allocator.free(note_esc);

    return try std.fmt.allocPrint(allocator,
        \\{{
        \\  "type": "commit",
        \\  "commit_hash": "{s}",
        \\  "message": "{s}",
        \\  "author": "{s}",
        \\  "branch": "{s}",
        \\  "metrics": "{s}",
        \\  "tags": "{s}",
        \\  "note": "{s}",
        \\  "username": "{s}",
        \\  "repo": "{s}"
        \\}}
    , .{ commit_hash, msg_esc, author, branch, metrics, tags, note_esc, username, repo_name });
}

fn buildExperimentPayload(
    allocator: std.mem.Allocator,
    exp_name: []const u8,
    description: []const u8,
    hypothesis: []const u8,
    status: []const u8,
    branch: []const u8,
    tags: []const u8,
    metrics: []const u8,
    username: []const u8,
    repo_name: []const u8,
) ![]u8 {
    const desc_esc = try jsonEscape(allocator, description);
    defer allocator.free(desc_esc);
    const hyp_esc = try jsonEscape(allocator, hypothesis);
    defer allocator.free(hyp_esc);

    return try std.fmt.allocPrint(allocator,
        \\{{
        \\  "type": "experiment",
        \\  "name": "{s}",
        \\  "description": "{s}",
        \\  "hypothesis": "{s}",
        \\  "status": "{s}",
        \\  "branch": "{s}",
        \\  "tags": "{s}",
        \\  "metrics": "{s}",
        \\  "username": "{s}",
        \\  "repo": "{s}"
        \\}}
    , .{ exp_name, desc_esc, hyp_esc, status, branch, tags, metrics, username, repo_name });
}

fn buildSnapshotPayload(
    allocator: std.mem.Allocator,
    snap_name: []const u8,
    snap_id: []const u8,
    description: []const u8,
    commit_hash: []const u8,
    branch: []const u8,
    metrics: []const u8,
    tags: []const u8,
    permanent: []const u8,
    username: []const u8,
    repo_name: []const u8,
) ![]u8 {
    const desc_esc = try jsonEscape(allocator, description);
    defer allocator.free(desc_esc);

    return try std.fmt.allocPrint(allocator,
        \\{{
        \\  "type": "snapshot",
        \\  "name": "{s}",
        \\  "id": "{s}",
        \\  "description": "{s}",
        \\  "commit_hash": "{s}",
        \\  "branch": "{s}",
        \\  "metrics": "{s}",
        \\  "tags": "{s}",
        \\  "permanent": {s},
        \\  "username": "{s}",
        \\  "repo": "{s}"
        \\}}
    , .{ snap_name, snap_id, desc_esc, commit_hash, branch, metrics, tags, permanent, username, repo_name });
}

fn httpPost(allocator: std.mem.Allocator,
    io: std.Io, endpoint: []const u8, token: []const u8, payload: []const u8) !struct { status: u32, body: []u8 } {
    const tmp_path = "/tmp/zev_publish_payload.json";
    const tmp_file = try std.Io.Dir.cwd().createFile(tmp_path, .{});
    try tmp_file.writeAll(payload);
    tmp_file.close(io);

    const auth_header = if (token.len > 0)
        try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{token})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(auth_header);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        "curl", "-s",                                                   "-w", "\n__STATUS__%{http_code}",
        "-X",   "POST",                                                 "-H", "Content-Type: application/json",
        "-d",   try std.fmt.allocPrint(allocator, "@{s}", .{tmp_path}),
    });
    if (auth_header.len > 0) {
        try argv.appendSlice(allocator, &.{ "-H", auth_header });
    }
    try argv.append(allocator, endpoint);

    var child = std.process.Child.init(io, argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var out_buf: [65536]u8 = undefined;
    const bytes_read = try child.stdout.?.read(&out_buf);
    const stdout = try allocator.dupe(u8, out_buf[0..bytes_read]);
    _ = try child.wait();

    var status: u32 = 0;
    var body: []u8 = stdout;
    if (std.mem.lastIndexOf(u8, stdout, "\n__STATUS__")) |idx| {
        const status_str = stdout[idx + 11 ..];
        status = std.fmt.parseInt(u32, status_str, 10) catch 0;
        body = try allocator.dupe(u8, stdout[0..idx]);
        allocator.free(stdout);
    }

    return .{ .status = status, .body = body };
}

fn dryRunPublish(payload: []const u8, endpoint: []const u8) void {
    std.debug.print("🔍 Dry run — would POST to: {s}\n\n", .{endpoint});
    std.debug.print("Payload:\n{s}\n", .{payload});
}

pub fn publishCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    tags: []const u8,
    note: []const u8,
    dry_run: bool,
    repo_name: []const u8,
) !void {
    const cfg = (try loadPublishConfig(allocator, io, repo)) orelse {
        std.debug.print("Error: No publish endpoint configured.\n", .{});
        std.debug.print("Set it with: zev publish config --endpoint https://yourplatform.com/api/zev\n", .{});
        std.debug.print("             zev publish config --token YOUR_TOKEN\n", .{});
        return;
    };
    defer freePublishConfig(allocator, cfg);

    const head = repo.getHeadCommit() catch {
        std.debug.print("Error: No commits yet.\n", .{});
        return;
    };
    const commit_hash = try head.toString(allocator);
    defer allocator.free(commit_hash);

    const commit_data = try repo.store.get(io, head);
    defer allocator.free(commit_data);
    const commit = try commit_mod.Commit.deserialize(allocator, commit_data);
    defer allocator.free(commit.author);
    defer allocator.free(commit.message);

    const branch = try getCurrentBranch(allocator, io, repo);
    defer allocator.free(branch);

    const metrics = try readMetrics(allocator, repo, commit_hash);
    defer allocator.free(metrics);

    const author = try getAuthor(allocator, repo);
    defer allocator.free(author);

    const payload = try buildCommitPayload(allocator, commit_hash, commit.message, author, branch, metrics, tags, note, cfg.username, repo_name);
    defer allocator.free(payload);

    std.debug.print("🚀 Publishing commit {s}...\n", .{commit_hash[0..8]});
    std.debug.print("   Message: {s}\n", .{commit.message});
    std.debug.print("   Branch:  {s}\n", .{branch});
    if (metrics.len > 0)
        std.debug.print("   Metrics: {s}\n", .{metrics});

    if (dry_run) {
        dryRunPublish(payload, cfg.endpoint);
        return;
    }

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/commits", .{cfg.endpoint});
    defer allocator.free(endpoint);

    const result = httpPost(allocator, io, endpoint, cfg.token, payload) catch |err| {
        std.debug.print("❌ Publish failed: {}\n", .{err});
        std.debug.print("   (Is your endpoint reachable? Try --dry-run to preview the payload)\n", .{});
        return;
    };
    defer allocator.free(result.body);

    if (result.status >= 200 and result.status < 300) {
        std.debug.print("✅ Published! Status: {d}\n", .{result.status});
        if (result.body.len > 0 and result.body.len < 500)
            std.debug.print("   Response: {s}\n", .{result.body});
    } else {
        std.debug.print("❌ Server returned status {d}\n", .{result.status});
        if (result.body.len > 0 and result.body.len < 500)
            std.debug.print("   Response: {s}\n", .{result.body});
    }
}

pub fn publishExperiment(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    exp_name: []const u8,
    dry_run: bool,
    repo_name: []const u8,
) !void {
    const cfg = (try loadPublishConfig(allocator, io, repo)) orelse {
        std.debug.print("Error: No publish endpoint configured.\n", .{});
        std.debug.print("Set it: zev publish config --endpoint https://yourplatform.com/api/zev\n", .{});
        return;
    };
    defer freePublishConfig(allocator, cfg);

    const exp_dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "experiments", exp_name });
    defer allocator.free(exp_dir);
    const exp_content = std.Io.Dir.cwd().readFileAlloc(io, exp_dir, allocator, .limited(64 * 1024)) catch {
        std.debug.print("Error: Experiment '{s}' not found\n", .{exp_name});
        return;
    };
    defer allocator.free(exp_content);

    var description: []u8 = try allocator.dupe(u8, "");
    var hypothesis: []u8 = try allocator.dupe(u8, "");
    var status: []u8 = try allocator.dupe(u8, "running");
    var exp_branch: []u8 = try allocator.dupe(u8, "");
    var tags: []u8 = try allocator.dupe(u8, "");
    defer allocator.free(description);
    defer allocator.free(hypothesis);
    defer allocator.free(status);
    defer allocator.free(exp_branch);
    defer allocator.free(tags);

    var iter = std.mem.splitSequence(u8, exp_content, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOf(u8, line, "=") orelse continue;
        const k = line[0..eq];
        const v = line[eq + 1 ..];
        if (std.mem.eql(u8, k, "description")) {
            allocator.free(description);
            description = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "hypothesis")) {
            allocator.free(hypothesis);
            hypothesis = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "status")) {
            allocator.free(status);
            status = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "branch")) {
            allocator.free(exp_branch);
            exp_branch = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "tags")) {
            allocator.free(tags);
            tags = try allocator.dupe(u8, v);
        }
    }

    const refs_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "heads", exp_branch });
    defer allocator.free(refs_path);
    const branch_head = std.Io.Dir.cwd().readFileAlloc(io, refs_path, allocator, .limited(128)) catch
        try allocator.dupe(u8, "");
    defer allocator.free(branch_head);
    const head_hash = std.mem.trim(u8, branch_head, " \n\r\t");

    const metrics = try readMetrics(allocator, repo, head_hash);
    defer allocator.free(metrics);

    const payload = try buildExperimentPayload(allocator, exp_name, description, hypothesis, status, exp_branch, tags, metrics, cfg.username, repo_name);
    defer allocator.free(payload);

    std.debug.print("🚀 Publishing experiment '{s}'...\n", .{exp_name});
    std.debug.print("   Status: {s}  Branch: {s}\n", .{ status, exp_branch });
    if (metrics.len > 0)
        std.debug.print("   Metrics: {s}\n", .{metrics});

    if (dry_run) {
        dryRunPublish(payload, cfg.endpoint);
        return;
    }

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/experiments", .{cfg.endpoint});
    defer allocator.free(endpoint);

    const result = httpPost(allocator, io, endpoint, cfg.token, payload) catch |err| {
        std.debug.print("❌ Publish failed: {}\n", .{err});
        return;
    };
    defer allocator.free(result.body);

    if (result.status >= 200 and result.status < 300) {
        std.debug.print("✅ Published! Status: {d}\n", .{result.status});
    } else {
        std.debug.print("❌ Server returned {d}\n", .{result.status});
        if (result.body.len > 0 and result.body.len < 500)
            std.debug.print("   {s}\n", .{result.body});
    }
}

pub fn publishSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    snap_name: []const u8,
    dry_run: bool,
    repo_name: []const u8,
) !void {
    const cfg = (try loadPublishConfig(allocator, io, repo)) orelse {
        std.debug.print("Error: No publish endpoint configured.\n", .{});
        std.debug.print("Set it: zev publish config --endpoint https://yourplatform.com/api/zev\n", .{});
        return;
    };
    defer freePublishConfig(allocator, cfg);

    const snap_dir_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "snapshots" });
    defer allocator.free(snap_dir_path);

    var snap_dir = std.Io.Dir.cwd().openDir(io, snap_dir_path, .{ .iterate = true }) catch {
        std.debug.print("Error: No snapshots found\n", .{});
        return;
    };
    defer snap_dir.close(io);

    var found_id: ?[]u8 = null;
    var it = snap_dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".name")) continue;
        const full = try std.fs.path.join(allocator, &.{ snap_dir_path, entry.name });
        defer allocator.free(full);
        const stored_id = std.Io.Dir.cwd().readFileAlloc(io, full, allocator, .limited(128)) catch continue;
        defer allocator.free(stored_id);
        const snap_path = try std.fs.path.join(allocator, &.{ snap_dir_path, stored_id });
        defer allocator.free(snap_path);
        const snap_content = std.Io.Dir.cwd().readFileAlloc(io, snap_path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(snap_content);
        var name_check = std.mem.splitSequence(u8, snap_content, "\n");
        while (name_check.next()) |line| {
            if (std.mem.startsWith(u8, line, "name=")) {
                if (std.mem.eql(u8, line[5..], snap_name)) {
                    found_id = try allocator.dupe(u8, stored_id);
                }
            }
        }
        if (found_id != null) break;
    }

    const snap_id = found_id orelse {
        std.debug.print("Error: Snapshot '{s}' not found\n", .{snap_name});
        return;
    };
    defer allocator.free(snap_id);

    const snap_path = try std.fs.path.join(allocator, &.{ snap_dir_path, snap_id });
    defer allocator.free(snap_path);
    const snap_content = try std.Io.Dir.cwd().readFileAlloc(io, snap_path, allocator, .limited(64 * 1024));
    defer allocator.free(snap_content);

    var description: []u8 = try allocator.dupe(u8, "");
    var commit_hash: []u8 = try allocator.dupe(u8, "");
    var branch: []u8 = try allocator.dupe(u8, "");
    var metrics_snap: []u8 = try allocator.dupe(u8, "");
    var tags: []u8 = try allocator.dupe(u8, "");
    var permanent_str: []u8 = try allocator.dupe(u8, "false");
    defer allocator.free(description);
    defer allocator.free(commit_hash);
    defer allocator.free(branch);
    defer allocator.free(metrics_snap);
    defer allocator.free(tags);
    defer allocator.free(permanent_str);

    var siter = std.mem.splitSequence(u8, snap_content, "\n");
    while (siter.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOf(u8, line, "=") orelse continue;
        const k = line[0..eq];
        const v = line[eq + 1 ..];
        if (std.mem.eql(u8, k, "description")) {
            allocator.free(description);
            description = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "commit_hash")) {
            allocator.free(commit_hash);
            commit_hash = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "branch")) {
            allocator.free(branch);
            branch = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "metrics_snapshot")) {
            allocator.free(metrics_snap);
            metrics_snap = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "tags")) {
            allocator.free(tags);
            tags = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "permanent")) {
            allocator.free(permanent_str);
            permanent_str = try allocator.dupe(u8, v);
        }
    }

    const payload = try buildSnapshotPayload(allocator, snap_name, snap_id, description, commit_hash, branch, metrics_snap, tags, permanent_str, cfg.username, repo_name);
    defer allocator.free(payload);

    const perm_icon: []const u8 = if (std.mem.eql(u8, permanent_str, "true")) " 🔒" else "";
    std.debug.print("🚀 Publishing snapshot '{s}'{s}...\n", .{ snap_name, perm_icon });
    std.debug.print("   ID:     {s}\n", .{snap_id[0..@min(16, snap_id.len)]});
    std.debug.print("   Commit: {s}\n", .{commit_hash[0..@min(8, commit_hash.len)]});

    if (dry_run) {
        dryRunPublish(payload, cfg.endpoint);
        return;
    }

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/snapshots", .{cfg.endpoint});
    defer allocator.free(endpoint);

    const result = httpPost(allocator, io, endpoint, cfg.token, payload) catch |err| {
        std.debug.print("❌ Publish failed: {}\n", .{err});
        return;
    };
    defer allocator.free(result.body);

    if (result.status >= 200 and result.status < 300) {
        std.debug.print("✅ Published! Status: {d}\n", .{result.status});
    } else {
        std.debug.print("❌ Server returned {d}\n", .{result.status});
        if (result.body.len > 0 and result.body.len < 500)
            std.debug.print("   {s}\n", .{result.body});
    }
}

pub fn publishConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    endpoint: ?[]const u8,
    token: ?[]const u8,
    username: ?[]const u8,
) !void {
    const config_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "config" });
    defer allocator.free(config_path);

    const existing = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(64 * 1024)) catch
        try allocator.dupe(u8, "");
    defer allocator.free(existing);

    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(allocator);

    var endpoint_written = false;
    var token_written = false;
    var username_written = false;

    var iter = std.mem.splitSequence(u8, existing, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;

        if (endpoint != null and std.mem.startsWith(u8, line, "publish.endpoint=")) {
            const new = try std.fmt.allocPrint(allocator, "publish.endpoint={s}\n", .{endpoint.?});
            defer allocator.free(new);
            try lines.appendSlice(allocator, new);
            endpoint_written = true;
        } else if (token != null and std.mem.startsWith(u8, line, "publish.token=")) {
            const new = try std.fmt.allocPrint(allocator, "publish.token={s}\n", .{token.?});
            defer allocator.free(new);
            try lines.appendSlice(allocator, new);
            token_written = true;
        } else if (username != null and std.mem.startsWith(u8, line, "publish.username=")) {
            const new = try std.fmt.allocPrint(allocator, "publish.username={s}\n", .{username.?});
            defer allocator.free(new);
            try lines.appendSlice(allocator, new);
            username_written = true;
        } else {
            try lines.appendSlice(allocator, line);
            try lines.append(allocator, '\n');
        }
    }

    if (endpoint != null and !endpoint_written) {
        const new = try std.fmt.allocPrint(allocator, "publish.endpoint={s}\n", .{endpoint.?});
        defer allocator.free(new);
        try lines.appendSlice(allocator, new);
    }
    if (token != null and !token_written) {
        const new = try std.fmt.allocPrint(allocator, "publish.token={s}\n", .{token.?});
        defer allocator.free(new);
        try lines.appendSlice(allocator, new);
    }
    if (username != null and !username_written) {
        const new = try std.fmt.allocPrint(allocator, "publish.username={s}\n", .{username.?});
        defer allocator.free(new);
        try lines.appendSlice(allocator, new);
    }

    const file = try std.Io.Dir.cwd().createFile(config_path, .{});
    defer file.close(io);
    try file.writeAll(lines.items);

    std.debug.print("✅ Publish config updated:\n", .{});
    if (endpoint) |e| std.debug.print("   endpoint: {s}\n", .{e});
    if (token) |t| std.debug.print("   token:    {s}***\n", .{t[0..@min(8, t.len)]});
    if (username) |u| std.debug.print("   username: {s}\n", .{u});
}

pub fn publishConfigShow(allocator: std.mem.Allocator, io: std.Io, repo: *Repository) !void {
    const cfg = (try loadPublishConfig(allocator, io, repo)) orelse {
        std.debug.print("No publish config set.\n", .{});
        std.debug.print("Set endpoint: zev publish config --endpoint https://yourplatform.com/api/zev\n", .{});
        return;
    };
    defer freePublishConfig(allocator, cfg);

    std.debug.print("📡 Publish config:\n", .{});
    std.debug.print("   Endpoint: {s}\n", .{cfg.endpoint});
    std.debug.print("   Username: {s}\n", .{cfg.username});
    if (cfg.token.len > 0) {
        std.debug.print("   Token:    {s}*** (set)\n", .{cfg.token[0..@min(8, cfg.token.len)]});
    } else {
        std.debug.print("   Token:    (not set)\n", .{});
    }
}

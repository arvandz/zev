const std = @import("std");
const ipld = @import("ipld.zig");
const Repository = @import("repository.zig").Repository;

pub const TextCommit = struct {
    hash: []u8,
    parent: ?[]u8,
    author: []u8,
    email: []u8,
    message: []u8,
    timestamp: i64,
    branch: []u8,
    tree_cid: []u8,

    pub fn deinit(self: TextCommit, allocator: std.mem.Allocator) void {
        allocator.free(self.hash);
        if (self.parent) |p| allocator.free(p);
        allocator.free(self.author);
        allocator.free(self.email);
        allocator.free(self.message);
        allocator.free(self.branch);
        allocator.free(self.tree_cid);
    }
};

pub fn readTextCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    hash: []const u8,
) !TextCommit {
    const path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "objects", hash });
    defer allocator.free(path);

    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(content);

    var author: []u8 = try allocator.dupe(u8, "");
    var email: []u8 = try allocator.dupe(u8, "");
    var message: []u8 = try allocator.dupe(u8, "");
    const branch: []u8 = try allocator.dupe(u8, "main");
    var tree_cid: []u8 = try allocator.dupe(u8, "");
    var parent: ?[]u8 = null;
    var timestamp: i64 = 0;

    var iter = std.mem.splitSequence(u8, content, "\n");
    var past_headers = false;
    var msg_buf: std.ArrayList(u8) = .empty;
    defer msg_buf.deinit(allocator);
    while (iter.next()) |line| {
        if (!past_headers) {
            if (std.mem.startsWith(u8, line, "tree ")) {
                allocator.free(tree_cid);
                tree_cid = try allocator.dupe(u8, std.mem.trim(u8, line[5..], " \r"));
            } else if (std.mem.startsWith(u8, line, "author ")) {
                const rest = line[7..];
                if (std.mem.indexOf(u8, rest, " <")) |lt| {
                    allocator.free(author);
                    author = try allocator.dupe(u8, rest[0..lt]);
                    const gt = std.mem.indexOf(u8, rest[lt..], ">") orelse rest.len - lt;
                    allocator.free(email);
                    email = try allocator.dupe(u8, rest[lt + 2 .. lt + gt]);
                } else {
                    allocator.free(author);
                    author = try allocator.dupe(u8, rest);
                }
            } else if (std.mem.startsWith(u8, line, "timestamp ")) {
                timestamp = std.fmt.parseInt(i64, std.mem.trim(u8, line[10..], " \r"), 10) catch 0;
            } else if (std.mem.startsWith(u8, line, "parent ") and line.len > 7) {
                const p = std.mem.trim(u8, line[7..], " \r");
                if (p.len >= 16) {
                    if (parent) |op| allocator.free(op);
                    parent = try allocator.dupe(u8, p);
                }
            } else if (line.len == 0 or std.mem.eql(u8, line, "\r")) {
                past_headers = true;
            } else {
                past_headers = true;
                try msg_buf.appendSlice(allocator, line);
            }
        } else {
            if (msg_buf.items.len > 0) try msg_buf.append(allocator, '\n');
            try msg_buf.appendSlice(allocator, line);
        }
    }
    if (msg_buf.items.len > 0) {
        allocator.free(message);
        message = try allocator.dupe(u8, std.mem.trim(u8, msg_buf.items, " \r\n"));
    }
    return TextCommit{
        .hash = try allocator.dupe(u8, hash),
        .parent = parent,
        .author = author,
        .email = email,
        .message = message,
        .timestamp = timestamp,
        .branch = branch,
        .tree_cid = tree_cid,
    };
}

const MetricEntry = struct { key: []u8, value: f64 };

fn readMetricsForCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    commit_hash: []const u8,
) ![]MetricEntry {
    const short = commit_hash[0..@min(8, commit_hash.len)];
    const metrics_dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "metrics" });
    defer allocator.free(metrics_dir);

    var dir = std.Io.Dir.cwd().openDir(io, metrics_dir, .{ .iterate = true }) catch
        return try allocator.alloc(MetricEntry, 0);
    defer dir.close(io);

    var entries: std.ArrayList(MetricEntry) = .empty;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, short)) continue;
        if (entry.kind != .file) continue;

        const path = try std.fs.path.join(allocator, &.{ metrics_dir, entry.name });
        defer allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096)) catch continue;
        defer allocator.free(content);

        var li = std.mem.splitSequence(u8, content, "\n");
        while (li.next()) |line| {
            const sep = std.mem.indexOf(u8, line, "=") orelse continue;
            const k = line[0..sep];
            const v = line[sep + 1 ..];
            if (std.mem.eql(u8, k, "metric")) {
                const colon = std.mem.indexOf(u8, v, ":") orelse continue;
                const mkey = v[0..colon];
                const mval = std.fmt.parseFloat(f64, v[colon + 1 ..]) catch continue;
                try entries.append(allocator, MetricEntry{
                    .key = try allocator.dupe(u8, mkey),
                    .value = mval,
                });
            }
        }
    }

    return entries.toOwnedSlice(allocator);
}

pub fn textCommitToIPLD(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *ipld.BlockStore,
    tc: TextCommit,
    parent_ipld_cid: ?ipld.CID,
    metrics: []const MetricEntry,
) !ipld.CID {
    const tree_cid = ipld.CID.fromHex(tc.tree_cid) catch
        ipld.CID.raw(tc.tree_cid);

    const metrics_cid: ?ipld.CID = if (metrics.len > 0) blk: {
        const commit_cid_for_metrics = ipld.CID.fromHex(tc.hash) catch ipld.CID.raw(tc.hash);

        var metric_entries = try allocator.alloc(ipld.MetricsNode.MetricEntry, metrics.len);
        defer allocator.free(metric_entries);
        for (metrics, 0..) |m, i| {
            metric_entries[i] = .{ .key = m.key, .value = m.value };
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const mn = ipld.MetricsNode{
            .commit = commit_cid_for_metrics,
            .entries = metric_entries,
            .timestamp = tc.timestamp,
        };
        const mv = try mn.toValue(aa);
        const mcid = try store.putNode(aa, io, mv);
        break :blk mcid;
    } else null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const cn = ipld.CommitNode{
        .parent = parent_ipld_cid,
        .tree = tree_cid,
        .metrics = metrics_cid,
        .experiment = null,
        .context = null,
        .notarize = null,
        .dataset = null,
        .author = tc.author,
        .message = tc.message,
        .timestamp = tc.timestamp,
        .branch = tc.branch,
    };

    const cv = try cn.toValue(aa);
    return try store.putNode(aa, io, cv);
}

pub fn migrateCommitsToIPLD(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
) !void {
    var store = try ipld.BlockStore.init(allocator, io, repo.path);
    defer store.deinit();

    const head_hash = try resolveHEAD(allocator, repo);
    defer allocator.free(head_hash);

    var chain: std.ArrayList([]u8) = .empty;
    defer {
        for (chain.items) |h| allocator.free(h);
        chain.deinit(allocator);
    }

    var current = try allocator.dupe(u8, head_hash);
    while (true) {
        try chain.append(allocator, current);
        const tc = readTextCommit(allocator, repo, current) catch break;
        if (tc.parent) |p| {
            current = try allocator.dupe(u8, p);
            tc.deinit(allocator);
        } else {
            tc.deinit(allocator);
            break;
        }
    }

    std.mem.reverse([]u8, chain.items);

    std.debug.print("🔄 Migrating {d} commit(s) to IPLD\n\n", .{chain.items.len});

    var parent_ipld_cid: ?ipld.CID = null;
    var migrated: usize = 0;

    for (chain.items) |hash| {
        const tc = readTextCommit(allocator, repo, hash) catch continue;
        defer tc.deinit(allocator);

        const metrics = readMetricsForCommit(allocator, repo, hash) catch
            try allocator.alloc(MetricEntry, 0);
        defer {
            for (metrics) |m| allocator.free(m.key);
            allocator.free(metrics);
        }

        const existing_cid = loadCommitCIDMapping(allocator, repo, hash) catch null;
        const commit_cid = if (existing_cid) |e| e else blk: {
            const c = try textCommitToIPLD(allocator, io, &store, tc, parent_ipld_cid, metrics);
            try saveCommitCIDMapping(allocator, io, repo, hash, c);
            break :blk c;
        };
        try saveCommitCIDMapping(allocator, io, repo, hash, commit_cid);

        parent_ipld_cid = commit_cid;
        migrated += 1;

        const short = try commit_cid.toShort(allocator);
        defer allocator.free(short);
        std.debug.print("  ● {s} → IPLD:{s}", .{ hash[0..8], short });
        if (metrics.len > 0) {
            std.debug.print(" + 📊 {d} metrics", .{metrics.len});
        }
        std.debug.print("\n", .{});
    }

    if (parent_ipld_cid) |head_cid| {
        try saveIPLDHead(allocator, io, repo, head_cid);
        const short = try head_cid.toShort(allocator);
        defer allocator.free(short);
        std.debug.print("\n✅ IPLD HEAD: {s}\n\n", .{short});
    }

    std.debug.print("   Migrated: {d} commits\n\n", .{migrated});
    std.debug.print("   Now try:\n", .{});
    std.debug.print("   zev dag query all:commit\n", .{});
    std.debug.print("   zev dag query all:metrics\n", .{});
    std.debug.print("   zev dag export HEAD --output history.car\n\n", .{});
}

pub fn onNewCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    commit_hash: []const u8,
) !void {
    var store = try ipld.BlockStore.init(allocator, io, repo.path);
    defer store.deinit();

    const tc = readTextCommit(allocator, io, repo, commit_hash) catch return;
    defer tc.deinit(allocator);

    const parent_ipld_cid: ?ipld.CID = if (tc.parent) |ph|
        loadCommitCIDMapping(allocator, io, repo, ph) catch null
    else
        null;

    const empty_metrics: []MetricEntry = &.{};

    const commit_cid = try textCommitToIPLD(allocator, io, &store, tc, parent_ipld_cid, empty_metrics);

    try saveCommitCIDMapping(allocator, io, repo, commit_hash, commit_cid);
    try saveIPLDHead(allocator, io, repo, commit_cid);

    const short = try commit_cid.toShort(allocator);
    defer allocator.free(short);
    std.debug.print("   IPLD: {s}\n", .{short});
}

pub fn onMetricsSet(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    commit_hash: []const u8,
    metric_key: []const u8,
    metric_value: f64,
) !void {
    var store = try ipld.BlockStore.init(allocator, io, repo.path);
    defer store.deinit();

    const all_metrics = try readMetricsForCommit(allocator, repo, commit_hash);
    defer {
        for (all_metrics) |m| allocator.free(m.key);
        allocator.free(all_metrics);
    }

    var metrics: std.ArrayList(ipld.MetricsNode.MetricEntry) = .empty;
    defer metrics.deinit(allocator);

    var found_new = false;
    for (all_metrics) |m| {
        try metrics.append(allocator, .{ .key = m.key, .value = m.value });
        if (std.mem.eql(u8, m.key, metric_key)) found_new = true;
    }
    if (!found_new) {
        try metrics.append(allocator, .{ .key = metric_key, .value = metric_value });
    }

    const commit_cid_for_metrics = ipld.CID.fromHex(commit_hash) catch
        ipld.CID.raw(commit_hash);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const mn = ipld.MetricsNode{
        .commit = commit_cid_for_metrics,
        .entries = metrics.items,
        .timestamp = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s),
    };
    const mv = try mn.toValue(aa);
    const metrics_cid = try store.putNode(aa, io, mv);
    _ = metrics_cid;
}

fn cloneValueShallow(allocator: std.mem.Allocator, v: ipld.Value) !ipld.Value {
    return switch (v) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .int => |i| .{ .int = i },
        .uint => |u| .{ .uint = u },
        .float => |f| .{ .float = f },
        .bool => |b| .{ .bool = b },
        .link => |c| .{ .link = c },
        .null => .null,
        else => .null,
    };
}

pub fn ipldLog(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    max_entries: usize,
) !void {
    var store = try ipld.BlockStore.init(allocator, io, repo.path);
    defer store.deinit();

    const head_cid = loadIPLDHead(allocator, repo) catch blk: {
        var best: ?ipld.CID = null;
        var best_ts: i64 = 0;
        var root_dir = std.Io.Dir.cwd().openDir(io, store.base_path, .{ .iterate = true }) catch {
            std.debug.print("No IPLD history yet. Run: zev ipld migrate\n\n", .{});
            return;
        };
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
        if (best) |c| {
            saveIPLDHead(allocator, io, repo, c) catch {};
            break :blk c;
        }
        std.debug.print("No IPLD history yet. Run: zev ipld migrate\n\n", .{});
        return;
    };

    std.debug.print("🔷 IPLD Commit Log\n\n", .{});

    var current_cid = head_cid;
    var count: usize = 0;

    while (count < max_entries) {
        const node = store.getNode(allocator, current_cid) catch break;
        defer node.deinit(allocator);

        if (node != .map) break;

        const short = try current_cid.toShort(allocator);
        defer allocator.free(short);

        const author = node.getString("author") orelse "?";
        const message = node.getString("message") orelse "?";
        const branch = node.getString("branch") orelse "main";
        const timestamp = node.getInt("timestamp") orelse 0;

        std.debug.print("  ● {s}  [{s}]\n", .{ short, branch });
        std.debug.print("    {s}: {s}\n", .{ author, message });
        std.debug.print("    t={d}\n", .{timestamp});

        if (node.getLink("metrics")) |mc| {
            const ms = try mc.toShort(allocator);
            defer allocator.free(ms);
            std.debug.print("    📊 metrics → {s}\n", .{ms});

            const mv = store.getNode(allocator, mc) catch continue;
            defer mv.deinit(allocator);
            if (mv == .map) {
                if (mv.getField("metrics")) |mmap| {
                    if (mmap == .map) {
                        for (mmap.map) |me| {
                            if (me.value == .float)
                                std.debug.print("       {s}: {d:.4}\n", .{ me.key, me.value.float });
                        }
                    }
                }
            }
        }
        if (node.getLink("tree")) |tc| {
            const ts = try tc.toShort(allocator);
            defer allocator.free(ts);
            std.debug.print("    🌲 tree → {s}\n", .{ts});
        }
        std.debug.print("\n", .{});

        const parent_cid = node.getLink("parent") orelse break;
        current_cid = parent_cid;
        count += 1;
    }
}

fn saveCommitCIDMapping(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    commit_hash: []const u8,
    cid: ipld.CID,
) !void {
    const dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "ipld_commits" });
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const short_hash = commit_hash[0..@min(16, commit_hash.len)];
    const path = try std.fs.path.join(allocator, &.{ dir, short_hash });
    defer allocator.free(path);

    const cid_str = try cid.toShort(allocator);
    defer allocator.free(cid_str);

    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    var f_buffer: [512]u8 = undefined;
    var f_writer = f.writer(io, &f_buffer);
    defer f.close(io);
    try f_writer.interface.writeAll(cid_str);
    try f_writer.flush();
}

fn loadCommitCIDMapping(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    commit_hash: []const u8,
) !ipld.CID {
    const dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "ipld_commits" });
    defer allocator.free(dir);

    const short_hash = commit_hash[0..@min(16, commit_hash.len)];
    const path = try std.fs.path.join(allocator, &.{ dir, short_hash });
    defer allocator.free(path);

    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64));
    defer allocator.free(content);

    return ipld.CID.fromHex(std.mem.trim(u8, content, "\n\r "));
}

fn saveIPLDHead(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    cid: ipld.CID,
) !void {
    const path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "ipld_head" });
    defer allocator.free(path);

    const cid_str = try cid.toShort(allocator);
    defer allocator.free(cid_str);

    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    var f_buffer: [512]u8 = undefined;
    var f_writer = f.writer(io, &f_buffer);
    defer f.close(io);
    try f_writer.interface.writeAll(cid_str);
    try f_writer.flush();
}

fn loadIPLDHead(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
) !ipld.CID {
    const path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "ipld_head" });
    defer allocator.free(path);

    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64));
    defer allocator.free(content);

    return ipld.CID.fromHex(std.mem.trim(u8, content, "\n\r "));
}

fn resolveHEAD(allocator: std.mem.Allocator, io: std.Io, repo: *Repository) ![]u8 {
    const head_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "HEAD" });
    defer allocator.free(head_path);

    const head = try std.Io.Dir.cwd().readFileAlloc(io, head_path, allocator, .limited(256));
    defer allocator.free(head);

    if (std.mem.startsWith(u8, head, "ref: ")) {
        const ref = std.mem.trim(u8, head[5..], "\n\r ");
        const rp = try std.fs.path.join(allocator, &.{ repo.path, ".zev", ref });
        defer allocator.free(rp);
        const rc = try std.Io.Dir.cwd().readFileAlloc(io, rp, allocator, .limited(256));
        defer allocator.free(rc);
        return allocator.dupe(u8, std.mem.trim(u8, rc, "\n\r "));
    }
    return allocator.dupe(u8, std.mem.trim(u8, head, "\n\r "));
}

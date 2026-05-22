const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");

fn metricsPath(allocator: std.mem.Allocator, repo: *Repository, commit_hash: []const u8) ![]u8 {
    const metrics_dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "metrics" });
    defer allocator.free(metrics_dir);
    try std.fs.cwd().makePath(metrics_dir);
    return try std.fs.path.join(allocator, &.{ repo.path, ".zev", "metrics", commit_hash });
}

pub fn setMetric(allocator: std.mem.Allocator, repo: *Repository, key: []const u8, value: []const u8) !void {
    const head = try repo.getHeadCommit();
    const hash_str = try head.toString(allocator);
    defer allocator.free(hash_str);

    const path = try metricsPath(allocator, repo, hash_str);
    defer allocator.free(path);

    var lines: std.ArrayList(u8) = .{};
    defer lines.deinit(allocator);

    const existing = std.fs.cwd().readFileAlloc(path, allocator, @enumFromInt(64 * 1024)) catch |err| blk: {
        if (err == error.FileNotFound) break :blk try allocator.dupe(u8, "");
        return err;
    };
    defer allocator.free(existing);

    var found = false;
    var iter = std.mem.splitSequence(u8, existing, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOf(u8, line, "=") orelse {
            try lines.appendSlice(allocator, line);
            try lines.append(allocator, '\n');
            continue;
        };
        const k = line[0..eq];
        if (std.mem.eql(u8, k, key)) {
            const now = (std.time.Instant.now() catch unreachable).timestamp.sec;
            const new_line = try std.fmt.allocPrint(allocator, "{s}={s}\t{d}\n", .{ key, value, now });
            defer allocator.free(new_line);
            try lines.appendSlice(allocator, new_line);
            found = true;
        } else {
            try lines.appendSlice(allocator, line);
            try lines.append(allocator, '\n');
        }
    }

    if (!found) {
        const now = (std.time.Instant.now() catch unreachable).timestamp.sec;
        const new_line = try std.fmt.allocPrint(allocator, "{s}={s}\t{d}\n", .{ key, value, now });
        defer allocator.free(new_line);
        try lines.appendSlice(allocator, new_line);
    }

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(lines.items);

    std.debug.print("📊 Metric set: {s} = {s}\n", .{ key, value });
    std.debug.print("   Commit: {s}\n", .{hash_str[0..8]});
}

pub fn showMetrics(allocator: std.mem.Allocator, repo: *Repository, hash_opt: ?[]const u8) !void {
    const hash_str = if (hash_opt) |h|
        try allocator.dupe(u8, h)
    else blk: {
        const head = try repo.getHeadCommit();
        break :blk try head.toString(allocator);
    };
    defer allocator.free(hash_str);

    const path = try metricsPath(allocator, repo, hash_str);
    defer allocator.free(path);

    const content = std.fs.cwd().readFileAlloc(path, allocator, @enumFromInt(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("No metrics for commit {s}\n", .{hash_str[0..8]});
            return;
        }
        return err;
    };
    defer allocator.free(content);

    std.debug.print("📊 Metrics for commit {s}:\n", .{hash_str[0..8]});
    std.debug.print("   ----------------------------------------\n", .{});

    var iter = std.mem.splitSequence(u8, content, "\n");
    var count: usize = 0;
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOf(u8, line, "\t") orelse line.len;
        const kv = line[0..tab];
        const eq = std.mem.indexOf(u8, kv, "=") orelse continue;
        const k = kv[0..eq];
        const v = kv[eq + 1 ..];
        std.debug.print("   {s:<20} {s}\n", .{ k, v });
        count += 1;
    }

    if (count == 0) {
        std.debug.print("   (no metrics)\n", .{});
    }
}

pub fn listMetrics(allocator: std.mem.Allocator, repo: *Repository) !void {
    const commit_mod = @import("commit.zig");

    const head = repo.getHeadCommit() catch {
        std.debug.print("No commits yet.\n", .{});
        return;
    };

    std.debug.print("📊 Commits with metrics:\n\n", .{});

    var current_opt: ?cid_mod.CID = head;
    var shown: usize = 0;
    while (current_opt) |current| {
        const hash_str = try current.toString(allocator);
        defer allocator.free(hash_str);

        const path = try metricsPath(allocator, repo, hash_str);
        defer allocator.free(path);

        const content = std.fs.cwd().readFileAlloc(path, allocator, @enumFromInt(64 * 1024)) catch null;
        defer if (content) |c| allocator.free(c);

        const cdata = repo.store.get(current) catch break;
        defer allocator.free(cdata);
        const commit = commit_mod.Commit.deserialize(allocator, cdata) catch break;
        defer allocator.free(commit.author);
        defer allocator.free(commit.message);

        if (content) |c| {
            const msg = std.mem.trim(u8, commit.message, " \n\r\t");
            std.debug.print("commit {s}  {s}\n", .{ hash_str[0..8], msg[0..@min(40, msg.len)] });

            var it2 = std.mem.splitSequence(u8, c, "\n");
            while (it2.next()) |line| {
                if (line.len == 0) continue;
                const tab = std.mem.indexOf(u8, line, "\t") orelse line.len;
                const kv = line[0..tab];
                const eq = std.mem.indexOf(u8, kv, "=") orelse continue;
                std.debug.print("   {s:<20} {s}\n", .{ kv[0..eq], kv[eq + 1 ..] });
            }
            std.debug.print("\n", .{});
            shown += 1;
        }

        current_opt = commit.parent_cid;
    }

    if (shown == 0) {
        std.debug.print("No commits have metrics yet.\n", .{});
        std.debug.print("Use: zev metrics set <key> <value>\n", .{});
    }
}

pub fn compareMetrics(allocator: std.mem.Allocator, repo: *Repository, hash_a: []const u8, hash_b: []const u8) !void {
    const path_a = try metricsPath(allocator, repo, hash_a);
    defer allocator.free(path_a);
    const path_b = try metricsPath(allocator, repo, hash_b);
    defer allocator.free(path_b);

    const content_a = std.fs.cwd().readFileAlloc(path_a, allocator, @enumFromInt(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("No metrics for {s}\n", .{hash_a[0..8]});
            return;
        }
        return err;
    };
    defer allocator.free(content_a);

    const content_b = std.fs.cwd().readFileAlloc(path_b, allocator, @enumFromInt(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("No metrics for {s}\n", .{hash_b[0..8]});
            return;
        }
        return err;
    };
    defer allocator.free(content_b);

    var map_a = std.StringHashMap([]const u8).init(allocator);
    defer map_a.deinit();
    var map_b = std.StringHashMap([]const u8).init(allocator);
    defer map_b.deinit();

    var iter_a = std.mem.splitSequence(u8, content_a, "\n");
    while (iter_a.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOf(u8, line, "\t") orelse line.len;
        const kv = line[0..tab];
        const eq = std.mem.indexOf(u8, kv, "=") orelse continue;
        try map_a.put(kv[0..eq], kv[eq + 1 ..]);
    }

    var iter_b = std.mem.splitSequence(u8, content_b, "\n");
    while (iter_b.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOf(u8, line, "\t") orelse line.len;
        const kv = line[0..tab];
        const eq = std.mem.indexOf(u8, kv, "=") orelse continue;
        try map_b.put(kv[0..eq], kv[eq + 1 ..]);
    }

    std.debug.print("📊 Metrics comparison:\n", .{});
    std.debug.print("   {s:<20} {s:<16} {s:<16} {s}\n", .{ "Key", hash_a[0..8], hash_b[0..8], "Change" });
    std.debug.print("   ----------------------------------------------------\n", .{});

    var it = map_a.iterator();
    while (it.next()) |entry| {
        const val_a = entry.value_ptr.*;
        const val_b = map_b.get(entry.key_ptr.*) orelse "(missing)";

        const fa = std.fmt.parseFloat(f64, val_a) catch null;
        const fb = std.fmt.parseFloat(f64, val_b) catch null;

        if (fa != null and fb != null) {
            const delta = fb.? - fa.?;
            const arrow: []const u8 = if (delta > 0) "up" else if (delta < 0) "dn" else "==";
            var delta_buf: [32]u8 = undefined;
            const delta_str = std.fmt.bufPrint(&delta_buf, "{s} {d:.4}", .{ arrow, @abs(delta) }) catch "?";
            std.debug.print("   {s:<20} {s:<16} {s:<16} {s}\n", .{ entry.key_ptr.*, val_a, val_b, delta_str });
        } else {
            const changed: []const u8 = if (std.mem.eql(u8, val_a, val_b)) "==" else "changed";
            std.debug.print("   {s:<20} {s:<16} {s:<16} {s}\n", .{ entry.key_ptr.*, val_a, val_b, changed });
        }
    }
}

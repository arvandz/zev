const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");
const commit_mod = @import("commit.zig");
const checkout_mod = @import("checkout.zig");

pub const BisectState = struct {
    good: []const u8,
    bad: []const u8,
    current: []const u8,
};

pub fn bisectStart(allocator: std.mem.Allocator, repo: *Repository) !void {
    const head = try repo.getHeadCommit();
    const head_str = try head.toString(allocator);
    defer allocator.free(head_str);

    const state_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "BISECT_STATE" });
    defer allocator.free(state_path);

    const file = try std.fs.cwd().createFile(state_path, .{});
    defer file.close();
    try file.writeAll("good=\nbad=\ncurrent=\n");

    std.debug.print("🔍 Bisect started\n", .{});
    std.debug.print("  Mark commits: zev bisect good <hash>\n", .{});
    std.debug.print("               zev bisect bad <hash>\n", .{});
    std.debug.print("  Or mark current: zev bisect good / zev bisect bad\n", .{});
}

fn loadState(allocator: std.mem.Allocator, repo: *Repository) !?struct { good: []u8, bad: []u8, current: []u8 } {
    const state_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "BISECT_STATE" });
    defer allocator.free(state_path);

    const file = std.fs.cwd().openFile(state_path, .{}) catch return null;
    defer file.close();

    const stat = try file.stat();
    const content = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(content);
    _ = try file.read(content);

    var good: []u8 = try allocator.dupe(u8, "");
    var bad: []u8 = try allocator.dupe(u8, "");
    var current: []u8 = try allocator.dupe(u8, "");

    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "good=")) {
            allocator.free(good);
            good = try allocator.dupe(u8, line[5..]);
        } else if (std.mem.startsWith(u8, line, "bad=")) {
            allocator.free(bad);
            bad = try allocator.dupe(u8, line[4..]);
        } else if (std.mem.startsWith(u8, line, "current=")) {
            allocator.free(current);
            current = try allocator.dupe(u8, line[8..]);
        }
    }
    return .{ .good = good, .bad = bad, .current = current };
}

fn saveState(allocator: std.mem.Allocator, repo: *Repository, good: []const u8, bad: []const u8, current: []const u8) !void {
    const state_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "BISECT_STATE" });
    defer allocator.free(state_path);

    const file = try std.fs.cwd().createFile(state_path, .{});
    defer file.close();

    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "good={s}\nbad={s}\ncurrent={s}\n", .{ good, bad, current });
    try file.writeAll(line);
}

fn collectHistory(allocator: std.mem.Allocator, repo: *Repository, tip: cid_mod.CID) !std.ArrayList(cid_mod.CID) {
    var history: std.ArrayList(cid_mod.CID) = .{};
    var current = tip;
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        try history.append(allocator, current);
        const data = repo.store.get(current) catch break;
        defer allocator.free(data);
        const c = commit_mod.Commit.deserialize(allocator, data) catch break;
        defer allocator.free(c.author);
        defer allocator.free(c.message);
        if (c.parent_cid) |parent| {
            current = parent;
        } else break;
    }
    return history;
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

fn checkoutForBisect(allocator: std.mem.Allocator, repo: *Repository, commit_cid: cid_mod.CID) !void {
    const data = try repo.store.get(commit_cid);
    defer allocator.free(data);
    const c = try commit_mod.Commit.deserialize(allocator, data);
    defer allocator.free(c.author);
    defer allocator.free(c.message);

    checkout_mod.checkoutCommit(allocator, repo, commit_cid) catch {};

    const hash = try commit_cid.toString(allocator);
    defer allocator.free(hash);
    const msg = std.mem.trim(u8, c.message, " \n\r\t");
    std.debug.print("📍 Now testing: [{s}] {s}\n", .{ hash[0..8], msg[0..@min(50, msg.len)] });
    std.debug.print("  Test your code, then run:\n", .{});
    std.debug.print("  zev bisect good  (if this commit is good)\n", .{});
    std.debug.print("  zev bisect bad   (if this commit is bad)\n", .{});
}

fn resolveHash(allocator: std.mem.Allocator, repo: *Repository, hash_opt: ?[]const u8, state_current: []const u8) ![]u8 {
    if (hash_opt) |h| {
        return try allocator.dupe(u8, h);
    }
    if (state_current.len == 64) {
        return try allocator.dupe(u8, state_current);
    }
    const head = try repo.getHeadCommit();
    return try head.toString(allocator);
}

pub fn bisectGood(allocator: std.mem.Allocator, repo: *Repository, hash_opt: ?[]const u8) !void {
    var state = (try loadState(allocator, repo)) orelse {
        std.debug.print("No bisect in progress. Run: zev bisect start\n", .{});
        return;
    };
    defer allocator.free(state.good);
    defer allocator.free(state.bad);
    defer allocator.free(state.current);

    const good_hash = try resolveHash(allocator, repo, hash_opt, state.current);
    defer allocator.free(good_hash);

    std.debug.print("✅ Marked {s} as good\n", .{good_hash[0..8]});
    try saveState(allocator, repo, good_hash, state.bad, state.current);
    try bisectStep(allocator, repo, good_hash, state.bad);
}

pub fn bisectBad(allocator: std.mem.Allocator, repo: *Repository, hash_opt: ?[]const u8) !void {
    var state = (try loadState(allocator, repo)) orelse {
        std.debug.print("No bisect in progress. Run: zev bisect start\n", .{});
        return;
    };
    defer allocator.free(state.good);
    defer allocator.free(state.bad);
    defer allocator.free(state.current);

    const bad_hash = try resolveHash(allocator, repo, hash_opt, state.current);
    defer allocator.free(bad_hash);

    std.debug.print("❌ Marked {s} as bad\n", .{bad_hash[0..8]});
    try saveState(allocator, repo, state.good, bad_hash, state.current);
    try bisectStep(allocator, repo, state.good, bad_hash);
}

fn bisectStep(allocator: std.mem.Allocator, repo: *Repository, good_str: []const u8, bad_str: []const u8) !void {
    if (good_str.len == 0 or bad_str.len == 0) {
        std.debug.print("Need both good and bad commits marked\n", .{});
        std.debug.print("  zev bisect good <hash>\n", .{});
        std.debug.print("  zev bisect bad <hash>\n", .{});
        return;
    }

    const bad_hash = try hashFromStr(bad_str);
    const good_hash = try hashFromStr(good_str);
    const bad_cid = cid_mod.CID{ .hash = bad_hash };
    const good_cid = cid_mod.CID{ .hash = good_hash };

    var history = try collectHistory(allocator, repo, bad_cid);
    defer history.deinit(allocator);

    var good_pos: ?usize = null;
    for (history.items, 0..) |c, idx| {
        if (c.equals(good_cid)) {
            good_pos = idx;
            break;
        }
    }

    if (good_pos == null) {
        std.debug.print("Good commit not found in bad commit ancestry\n", .{});
        return;
    }

    const range = good_pos.?;

    if (range <= 1) {
        std.debug.print("\n🎯 Found the culprit commit!\n", .{});
        const data = try repo.store.get(bad_cid);
        defer allocator.free(data);
        const c = try commit_mod.Commit.deserialize(allocator, data);
        defer allocator.free(c.author);
        defer allocator.free(c.message);
        const msg = std.mem.trim(u8, c.message, " \n\r\t");
        std.debug.print("  Commit: {s}\n", .{bad_str[0..8]});
        std.debug.print("  Author: {s}\n", .{c.author});
        std.debug.print("  Message: {s}\n", .{msg});
        try bisectReset(allocator, repo);
        return;
    }

    const mid = range / 2;
    const mid_cid = history.items[mid];
    const mid_str = try mid_cid.toString(allocator);
    defer allocator.free(mid_str);

    try saveState(allocator, repo, good_str, bad_str, mid_str);
    try checkoutForBisect(allocator, repo, mid_cid);

    std.debug.print("  ~{} commits remaining to test\n", .{range / 2});
}

pub fn bisectReset(allocator: std.mem.Allocator, repo: *Repository) !void {
    const state_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "BISECT_STATE" });
    defer allocator.free(state_path);
    std.fs.cwd().deleteFile(state_path) catch {};
    std.debug.print("🔄 Bisect reset\n", .{});
}

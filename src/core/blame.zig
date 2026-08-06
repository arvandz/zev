const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");
const commit_mod = @import("commit.zig");
const tree_mod = @import("tree.zig");

pub const BlameLine = struct {
    line_num: usize,
    content: []const u8,
    commit_hash: [32]u8,
    author: []const u8,
    timestamp: i64,
    message: []const u8,
};

pub fn blame(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    filename: []const u8,
) !void {
    const head = repo.getHeadCommit(io) catch {
        std.debug.print("No commits yet.\n", .{});
        return;
    };

    const HistoryEntry = struct {
        commit_cid: cid_mod.CID,
        author: []const u8,
        message: []const u8,
        timestamp: i64,
        content: []const u8,
    };

    var history: std.ArrayList(HistoryEntry) = .empty;
    defer {
        for (history.items) |entry| {
            allocator.free(entry.author);
            allocator.free(entry.message);
            allocator.free(entry.content);
        }
        history.deinit(allocator);
    }

    var raw_history: std.ArrayList(HistoryEntry) = .empty;
    defer raw_history.deinit(allocator);

    var current = head;
    var walked: usize = 0;
    while (walked < 10000) : (walked += 1) {
        const cdata = repo.store.get(io, current) catch break;
        defer allocator.free(cdata);

        const c = commit_mod.Commit.deserialize(allocator, cdata) catch break;
        errdefer allocator.free(c.author);
        errdefer allocator.free(c.message);

        const file_content = getFileAtCommit(allocator, io, repo, c.tree_cid, filename) catch {
            allocator.free(c.author);
            allocator.free(c.message);
            if (c.parent_cid) |parent| {
                current = parent;
                continue;
            }
            break;
        };

        try raw_history.append(allocator, .{
            .commit_cid = current,
            .author = c.author,
            .message = c.message,
            .timestamp = c.timestamp,
            .content = file_content,
        });

        if (c.parent_cid) |parent| {
            current = parent;
        } else break;
    }

    if (raw_history.items.len == 0) {
        std.debug.print("File '{s}' not found in history\n", .{filename});
        return;
    }

    std.mem.reverse(HistoryEntry, raw_history.items);

    const latest = raw_history.items[raw_history.items.len - 1];
    var lines = std.mem.splitSequence(u8, latest.content, "\n");
    var line_list: std.ArrayList([]const u8) = .empty;
    defer line_list.deinit(allocator);
    while (lines.next()) |line| {
        try line_list.append(allocator, line);
    }

    const num_lines = line_list.items.len;
    const blame_commits = try allocator.alloc(usize, num_lines);
    defer allocator.free(blame_commits);

    const prev_lines = try allocator.alloc([]const u8, num_lines);
    defer allocator.free(prev_lines);

    for (0..num_lines) |li| {
        blame_commits[li] = 0;
        prev_lines[li] = "";
    }

    for (raw_history.items, 0..) |entry, commit_idx| {
        var entry_lines = std.mem.splitSequence(u8, entry.content, "\n");
        var eli: usize = 0;
        while (entry_lines.next()) |eline| {
            if (eli < num_lines) {
                if (!std.mem.eql(u8, eline, prev_lines[eli])) {
                    blame_commits[eli] = commit_idx;
                    prev_lines[eli] = eline;
                }
            }
            eli += 1;
        }
    }

    std.debug.print("\n", .{});
    for (line_list.items, 0..) |line, li| {
        if (line.len == 0 and li == line_list.items.len - 1) continue;

        const entry = raw_history.items[blame_commits[li]];
        const tmp_cid = cid_mod.CID{ .hash = entry.commit_cid.hash };
        const hash_str = try tmp_cid.toString(allocator);
        defer allocator.free(hash_str);

        const short_author = blk: {
            if (std.mem.indexOf(u8, entry.author, " <")) |angle| {
                break :blk entry.author[0..angle];
            }
            break :blk entry.author;
        };

        const msg = std.mem.trim(u8, entry.message, " \n\r\t");
        const short_msg = msg[0..@min(20, msg.len)];

        std.debug.print("{s} ({s:<12}) {d:>4} | {s}\n", .{
            hash_str[0..8],
            short_author[0..@min(12, short_author.len)],
            li + 1,
            line,
        });
        _ = short_msg;
    }
}

fn getFileAtCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    tree_cid: cid_mod.CID,
    filename: []const u8,
) ![]const u8 {
    const tree_data = try repo.store.get(io, tree_cid);
    defer allocator.free(tree_data);

    var t = try tree_mod.Tree.deserialize(allocator, tree_data);
    defer t.deinit();

    for (t.entries.items) |entry| {
        if (std.mem.eql(u8, entry.name, filename)) {
            return try repo.store.get(io, entry.cid);
        }
    }
    return error.FileNotFound;
}

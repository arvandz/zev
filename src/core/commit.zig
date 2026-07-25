const std = @import("std");
const cid = @import("cid.zig");
const tree = @import("tree.zig");

pub const Commit = struct {
    tree_cid: cid.CID,
    parent_cid: ?cid.CID,
    author: []const u8,
    message: []const u8,
    timestamp: i64,

    pub fn init(io: std.Io, tree_cid: cid.CID, parent_cid: ?cid.CID, author: []const u8, message: []const u8) Commit {
        const now = std.Io.Timestamp.now(io, .real);
        const epoch_seconds = @divTrunc(now.nanoseconds, std.time.ns_per_s);

        return Commit{
            .tree_cid = tree_cid,
            .parent_cid = parent_cid,
            .author = author,
            .message = message,
            .timestamp = epoch_seconds,
        };
    }

    pub fn serialize(self: Commit, allocator: std.mem.Allocator) ![]u8 {
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(allocator);

        const tree_str = try self.tree_cid.toString(allocator);
        defer allocator.free(tree_str);

        try buffer.print(allocator, "tree {s}\n", .{tree_str});

        if (self.parent_cid) |parent| {
            const parent_str = try parent.toString(allocator);
            defer allocator.free(parent_str);
            try buffer.print(allocator, "parent {s}\n", .{parent_str});
        }

        try buffer.print(allocator, "author {s}\n", .{self.author});
        try buffer.print(allocator, "timestamp {}\n", .{self.timestamp});
        try buffer.print(allocator, "\n{s}\n", .{self.message});

        return buffer.toOwnedSlice(allocator);
    }

    pub fn deserialize(allocator: std.mem.Allocator,
    io: std.Io, data: []const u8) !Commit {
        var lines = std.mem.splitSequence(u8, data, "\n");

        var tree_cid_opt: ?cid.CID = null;
        var parent_cid_opt: ?cid.CID = null;
        var author_opt: ?[]const u8 = null;
        var timestamp_opt: ?i64 = null;
        var message_started = false;
        var message_buffer: std.ArrayList(u8) = .empty;
        defer message_buffer.deinit(allocator);

        while (lines.next()) |line| {
            if (message_started) {
                try message_buffer.appendSlice(allocator, line);
                try message_buffer.append(allocator, '\n');
                continue;
            }

            if (line.len == 0) {
                message_started = true;
                continue;
            }

            if (std.mem.startsWith(u8, line, "tree ")) {
                const hash_str = line[5..];
                var hash: [32]u8 = undefined;
                for (0..32) |i| {
                    const high = try std.fmt.charToDigit(hash_str[i * 2], 16);
                    const low = try std.fmt.charToDigit(hash_str[i * 2 + 1], 16);
                    hash[i] = (high << 4) | low;
                }
                tree_cid_opt = cid.CID{ .hash = hash };
            } else if (std.mem.startsWith(u8, line, "parent ")) {
                const hash_str = line[7..];
                var hash: [32]u8 = undefined;
                for (0..32) |i| {
                    const high = try std.fmt.charToDigit(hash_str[i * 2], 16);
                    const low = try std.fmt.charToDigit(hash_str[i * 2 + 1], 16);
                    hash[i] = (high << 4) | low;
                }
                parent_cid_opt = cid.CID{ .hash = hash };
            } else if (std.mem.startsWith(u8, line, "author ")) {
                author_opt = try allocator.dupe(u8, line[7..]);
            } else if (std.mem.startsWith(u8, line, "timestamp ")) {
                timestamp_opt = try std.fmt.parseInt(i64, line[10..], 10);
            }
        }

        const message = try message_buffer.toOwnedSlice(allocator);

        return Commit{
            .tree_cid = tree_cid_opt orelse return error.MissingTree,
            .parent_cid = parent_cid_opt,
            .author = author_opt orelse return error.MissingAuthor,
            .message = message,
            .timestamp = timestamp_opt orelse return error.MissingTimestamp,
        };
    }
};

test "commit serialization" {
    const allocator = std.testing.allocator;

    const tree_cid = cid.CID.fromBytes(io, "test tree");
    const commit = Commit.init(io, tree_cid, null, "Test Author", "Initial commit");

    const serialized = try commit.serialize(allocator);
    defer allocator.free(serialized);

    try std.testing.expect(serialized.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "tree") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "author Test Author") != null);
}

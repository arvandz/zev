const std = @import("std");
const cid = @import("cid.zig");

pub const FileEntry = struct {
    name: []const u8,
    cid: cid.CID,
    size: u64,
    mode: u32,

    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !FileEntry {
        var parts = std.mem.splitSequence(u8, data, " ");
        const name = parts.next() orelse return error.InvalidFormat;
        const cid_str = parts.next() orelse return error.InvalidFormat;
        const size_str = parts.next() orelse return error.InvalidFormat;
        const mode_str = parts.next() orelse return error.InvalidFormat;

        if (cid_str.len != 64) return error.InvalidCID;

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        var hash: [32]u8 = undefined;
        for (0..32) |i| {
            const high = try std.fmt.charToDigit(cid_str[i * 2], 16);
            const low = try std.fmt.charToDigit(cid_str[i * 2 + 1], 16);
            hash[i] = (high << 4) | low;
        }

        return FileEntry{
            .name = name_copy,
            .cid = cid.CID{ .hash = hash },
            .size = try std.fmt.parseInt(u64, size_str, 10),
            .mode = try std.fmt.parseInt(u32, mode_str, 10),
        };
    }
};

pub const Tree = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(FileEntry),

    pub fn init(allocator: std.mem.Allocator) Tree {
        return Tree{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Tree) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn addEntry(self: *Tree, name: []const u8, entry_cid: cid.CID, size: u64, mode: u32) !void {
        const entry = FileEntry{
            .name = try self.allocator.dupe(u8, name),
            .cid = entry_cid,
            .size = size,
            .mode = mode,
        };
        try self.entries.append(self.allocator, entry);
    }

    pub fn getEntry(self: *Tree, name: []const u8) ?FileEntry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry;
            }
        }
        return null;
    }

    pub fn serialize(self: *Tree) ![]u8 {
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(self.allocator);

        for (self.entries.items) |entry| {
            const cid_str = try entry.cid.toString(self.allocator);
            defer self.allocator.free(cid_str);

            try buffer.print(self.allocator, "{s} {s} {} {}\n", .{
                entry.name,
                cid_str,
                entry.size,
                entry.mode,
            });
        }

        return buffer.toOwnedSlice(self.allocator);
    }

    pub fn deserialize(allocator: std.mem.Allocator,
    io: std.Io, data: []const u8) !Tree {
        var tree_obj = Tree.init(allocator, io, io, io, );
        errdefer tree_obj.deinit();

        if (data.len == 0) {
            return tree_obj;
        }

        var lines = std.mem.splitSequence(u8, data, "\n");
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            const entry = FileEntry.deserialize(allocator, io, line) catch |err| {
                std.debug.print("Failed to deserialize line: '{s}'\n", .{line});
                return err;
            };
            try tree_obj.entries.append(allocator, entry);
        }

        return tree_obj;
    }
};

test "tree serialization" {
    const allocator = std.testing.allocator;

    var tree_obj = Tree.init(allocator, io, io, io, );
    defer tree_obj.deinit();

    const test_cid = cid.CID.fromBytes(io, "test content");
    try tree_obj.addEntry("file.txt", test_cid, 100, 0o644);

    const serialized = try tree_obj.serialize();
    defer allocator.free(serialized);

    try std.testing.expect(serialized.len > 0);
}

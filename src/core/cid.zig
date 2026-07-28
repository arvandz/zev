const std = @import("std");

pub const CID = struct {
    hash: [32]u8,

    pub fn fromBytes(io: std.Io,  data: []const u8) CID {
        var hasher = std.crypto.hash.sha2.Sha256.init(io, .{});
        hasher.update(data);
        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        return CID{ .hash = hash };
    }

    pub fn toString(self: CID, allocator: std.mem.Allocator) ![]u8 {
        const hex_chars = "0123456789abcdef";
        var result = try allocator.alloc(u8, 64);

        for (self.hash, 0..) |byte, i| {
            result[i * 2] = hex_chars[byte >> 4];
            result[i * 2 + 1] = hex_chars[byte & 0x0f];
        }

        return result;
    }

    pub fn equals(  self: CID, other: CID) bool {
        return std.mem.eql(u8, &self.hash, &other.hash);
    }
};

test "CID generation" {
    const data = "hello world";
    const cid = CID.fromBytes(data);

    try std.testing.expect(cid.hash.len == 32);
}

test "CID to string" {
    const allocator = std.testing.allocator;
    const data = "hello world";
    const cid = CID.fromBytes(data);

    const str = try cid.toString(allocator);
    defer allocator.free(str);

    try std.testing.expect(str.len == 64);
}

test "CID equality" {
    const data1 = "hello world";
    const data2 = "hello world";
    const data3 = "goodbye world";

    const cid1 = CID.fromBytes(data1);
    const cid2 = CID.fromBytes(data2);
    const cid3 = CID.fromBytes(data3);

    try std.testing.expect(cid1.equals(cid2));
    try std.testing.expect(!cid1.equals(cid3));
}

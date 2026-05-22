const std = @import("std");
const cid = @import("cid.zig");

pub const Blob = struct {
    cid: cid.CID,
    data: []const u8,
    size: usize,

    pub fn init(data: []const u8) Blob {
        return Blob{
            .cid = cid.CID.fromBytes(data),
            .data = data,
            .size = data.len,
        };
    }
};

pub const BlobStore = struct {
    allocator: std.mem.Allocator,
    store_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, store_path: []const u8) !BlobStore {
        try std.fs.cwd().makePath(store_path);
        return BlobStore{
            .allocator = allocator,
            .store_path = store_path,
        };
    }

    pub fn put(self: *BlobStore, data: []const u8) !cid.CID {
        const blob = Blob.init(data);
        const hash_str = try blob.cid.toString(self.allocator);
        defer self.allocator.free(hash_str);

        const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.store_path, hash_str });
        defer self.allocator.free(file_path);

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        try file.writeAll(data);

        return blob.cid;
    }

    pub fn get(self: *BlobStore, content_id: cid.CID) ![]u8 {
        const hash_str = try content_id.toString(self.allocator);
        defer self.allocator.free(hash_str);

        const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.store_path, hash_str });
        defer self.allocator.free(file_path);

        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const file_size = (try file.stat()).size;
        const buffer = try self.allocator.alloc(u8, file_size);
        _ = try file.read(buffer);

        return buffer;
    }

    pub fn has(self: *BlobStore, content_id: cid.CID) !bool {
        const hash_str = try content_id.toString(self.allocator);
        defer self.allocator.free(hash_str);

        const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.store_path, hash_str });
        defer self.allocator.free(file_path);

        std.fs.cwd().access(file_path, .{}) catch {
            return false;
        };

        return true;
    }
};

test "blob creation" {
    const data = "hello world";
    const blob = Blob.init(data);

    try std.testing.expect(blob.size == 11);
    try std.testing.expect(std.mem.eql(u8, blob.data, data));
}

test "blob store put and get" {
    const allocator = std.testing.allocator;
    const test_dir = "test_blobs";

    var store = try BlobStore.init(allocator, test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const data = "test data for blob store";
    const content_id = try store.put(data);

    const retrieved = try store.get(content_id);
    defer allocator.free(retrieved);

    try std.testing.expect(std.mem.eql(u8, data, retrieved));
}

test "blob store has" {
    const allocator = std.testing.allocator;
    const test_dir = "test_blobs_has";

    var store = try BlobStore.init(allocator, test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const data = "test data";
    const content_id = try store.put(data);

    try std.testing.expect(try store.has(content_id));

    const fake_cid = cid.CID.fromBytes("nonexistent");
    try std.testing.expect(!try store.has(fake_cid));
}

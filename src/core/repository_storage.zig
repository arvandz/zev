const std = @import("std");
const Repository = @import("repository.zig").Repository;
const StorageManager = @import("storage.zig").StorageManager;
const StorageConfig = @import("storage.zig").StorageConfig;
const Commit = @import("commit.zig").Commit;
const CID = @import("cid.zig").CID;

pub const RepositoryWithStorage = struct {
    repo: Repository,
    storage: StorageManager,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8, storage_config: StorageConfig) !RepositoryWithStorage {
        const repo = try Repository.init(allocator, io, io, io, io, path, storage_config.ipfs_enabled);
        const storage = try StorageManager.init(allocator, io, io, io, storage_config);

        return RepositoryWithStorage{
            .repo = repo,
            .storage = storage,
        };
    }

    pub fn deinit(self: *RepositoryWithStorage) void {
        self.repo.deinit();
    }

    pub fn storeCommit(self: *RepositoryWithStorage, commit_obj: *const Commit) ![]const u8 {
        var commit_data = std.ArrayList(u8).empty;
        defer commit_data.deinit(self.repo.allocator);

        try commit_data.appendSlice(self.repo.allocator, "tree ");
        const tree_str = try commit_obj.tree_cid.toString(self.repo.allocator);
        defer self.repo.allocator.free(tree_str);
        try commit_data.appendSlice(self.repo.allocator, tree_str);
        try commit_data.appendSlice(self.repo.allocator, "\n");

        if (commit_obj.parent_cid) |parent| {
            try commit_data.appendSlice(self.repo.allocator, "parent ");
            const parent_str = try parent.toString(self.repo.allocator);
            defer self.repo.allocator.free(parent_str);
            try commit_data.appendSlice(self.repo.allocator, parent_str);
            try commit_data.appendSlice(self.repo.allocator, "\n");
        }

        try commit_data.appendSlice(self.repo.allocator, "author ");
        try commit_data.appendSlice(self.repo.allocator, commit_obj.author);
        try commit_data.appendSlice(self.repo.allocator, "\n");

        try commit_data.appendSlice(self.repo.allocator, "timestamp ");
        var timestamp_buf: [32]u8 = undefined;
        const timestamp_str = try std.fmt.bufPrint(&timestamp_buf, "{d}", .{commit_obj.timestamp});
        try commit_data.appendSlice(self.repo.allocator, timestamp_str);
        try commit_data.appendSlice(self.repo.allocator, "\n\n");

        try commit_data.appendSlice(self.repo.allocator, commit_obj.message);

        return try self.storage.storeObject(commit_data.items);
    }

    pub fn storeBlob(self: *RepositoryWithStorage, data: []const u8) ![]const u8 {
        return try self.storage.storeObject(data);
    }

    pub fn getCommit(self: *RepositoryWithStorage, io: std.Io, commit_cid: []const u8) !Commit {
        const commit_data = try self.storage.getObject(io, commit_cid);
        defer self.repo.allocator.free(commit_data);
        return try parseCommit(self.repo.allocator, commit_data);
    }

    pub fn getBlob(self: *RepositoryWithStorage, io: std.Io, blob_cid: []const u8) ![]u8 {
        return try self.storage.getObject(io, blob_cid);
    }
};

fn parseCommit(allocator: std.mem.Allocator, data: []const u8) !Commit {
    var lines = std.mem.split(u8, data, "\n");

    var tree_cid: ?CID = null;
    var parent_cid: ?CID = null;
    var author: ?[]const u8 = null;
    var timestamp: i64 = 0;
    var message_start: usize = 0;

    var line_index: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) {
            message_start = line_index + 1;
            break;
        }

        if (std.mem.startsWith(u8, line, "tree ")) {
            const hash_str = line[5..];
            tree_cid = try parseCIDFromString(hash_str);
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            const hash_str = line[7..];
            parent_cid = try parseCIDFromString(hash_str);
        } else if (std.mem.startsWith(u8, line, "author ")) {
            author = try allocator.dupe(u8, line[7..]);
        } else if (std.mem.startsWith(u8, line, "timestamp ")) {
            timestamp = try std.fmt.parseInt(i64, line[10..], 10);
        }

        line_index += line.len + 1;
    }

    const message_data = if (message_start < data.len)
        data[message_start..]
    else
        "";

    return Commit{
        .tree_cid = tree_cid orelse return error.InvalidCommit,
        .parent_cid = parent_cid,
        .author = author orelse return error.InvalidCommit,
        .timestamp = timestamp,
        .message = try allocator.dupe(u8, message_data),
    };
}

fn parseCIDFromString(hash_str: []const u8) !CID {
    if (hash_str.len != 64) return error.InvalidCIDLength;

    var hash: [32]u8 = undefined;
    for (0..32) |i| {
        const high = try std.fmt.charToDigit(hash_str[i * 2], 16);
        const low = try std.fmt.charToDigit(hash_str[i * 2 + 1], 16);
        hash[i] = (high << 4) | low;
    }

    return CID{ .hash = hash };
}

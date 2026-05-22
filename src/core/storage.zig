const std = @import("std");
const Repository = @import("repository.zig").Repository;
const IPFSClient = @import("ipfs.zig").IPFSClient;

pub const StorageBackend = enum {
    local,
    ipfs,
    hybrid,
};

pub const StorageConfig = struct {
    backend: StorageBackend,
    ipfs_enabled: bool,
    ipfs_url: []const u8,
    auto_pin: bool,

    pub fn default() StorageConfig {
        return .{
            .backend = .local,
            .ipfs_enabled = false,
            .ipfs_url = "http://127.0.0.1:5001",
            .auto_pin = true,
        };
    }

    pub fn withIPFS() StorageConfig {
        return .{
            .backend = .hybrid,
            .ipfs_enabled = true,
            .ipfs_url = "http://127.0.0.1:5001",
            .auto_pin = true,
        };
    }
};

pub const StorageManager = struct {
    allocator: std.mem.Allocator,
    config: StorageConfig,
    ipfs_client: ?IPFSClient,

    pub fn init(allocator: std.mem.Allocator, config: StorageConfig) !StorageManager {
        var ipfs_client: ?IPFSClient = null;

        if (config.ipfs_enabled) {
            ipfs_client = IPFSClient.init(allocator, config.ipfs_url);
        }

        return StorageManager{
            .allocator = allocator,
            .config = config,
            .ipfs_client = ipfs_client,
        };
    }

    pub fn storeObject(self: *StorageManager, object_data: []const u8) ![]const u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(object_data, &hash, .{});

        var cid_buffer: [64]u8 = undefined;
        const cid = std.fmt.bytesToHex(hash, .lower);
        @memcpy(&cid_buffer, &cid);

        switch (self.config.backend) {
            .local => {
                try self.storeLocal(&cid_buffer, object_data);
                return try self.allocator.dupe(u8, &cid_buffer);
            },
            .ipfs => {
                if (self.ipfs_client) |*client| {
                    return try client.blockPut(object_data, self.config.auto_pin);
                }
                return error.IPFSNotConfigured;
            },
            .hybrid => {
                try self.storeLocal(&cid_buffer, object_data);

                if (self.ipfs_client) |*client| {
                    const ipfs_cid = try client.blockPut(object_data, self.config.auto_pin);

                    try self.storeIPFSMapping(&cid_buffer, ipfs_cid);

                    self.allocator.free(ipfs_cid);
                }

                return try self.allocator.dupe(u8, &cid_buffer);
            },
        }
    }

    pub fn getObject(self: *StorageManager, cid: []const u8) ![]u8 {
        if (self.config.backend == .local or self.config.backend == .hybrid) {
            if (self.getLocal(cid)) |local_data| {
                return local_data;
            } else |err| {
                if (err != error.FileNotFound and self.config.backend == .local) {
                    return err;
                }
            }
        }

        if (self.config.backend == .ipfs or self.config.backend == .hybrid) {
            if (self.ipfs_client) |*client| {
                const ipfs_cid = try self.getIPFSMapping(cid);
                defer if (ipfs_cid) |c| self.allocator.free(c);

                const cid_to_fetch = ipfs_cid orelse cid;
                return try client.blockGet(cid_to_fetch);
            }
        }

        return error.ObjectNotFound;
    }

    fn storeLocal(self: *StorageManager, cid: []const u8, data: []const u8) !void {
        _ = self;
        const prefix = cid[0..2];
        const suffix = cid[2..];

        var objects_dir = try std.fs.cwd().makeOpenPath(".zev/objects", .{});
        defer objects_dir.close();

        var prefix_dir = try objects_dir.makeOpenPath(prefix, .{});
        defer prefix_dir.close();

        const file = try prefix_dir.createFile(suffix, .{});
        defer file.close();

        try file.writeAll(data);
    }

    fn getLocal(self: *StorageManager, cid: []const u8) ![]u8 {
        const prefix = cid[0..2];
        const suffix = cid[2..];

        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, ".zev/objects/{s}/{s}", .{ prefix, suffix });

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const data = try self.allocator.alloc(u8, @intCast(stat.size));
        _ = try file.read(data);
        return data;
    }

    fn storeIPFSMapping(self: *StorageManager, local_cid: []const u8, ipfs_cid: []const u8) !void {
        _ = self;
        var ipfs_map_dir = try std.fs.cwd().makeOpenPath(".zev/ipfs-map", .{});
        defer ipfs_map_dir.close();

        const file = try ipfs_map_dir.createFile(local_cid, .{});
        defer file.close();

        try file.writeAll(ipfs_cid);
    }

    fn getIPFSMapping(self: *StorageManager, local_cid: []const u8) !?[]u8 {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, ".zev/ipfs-map/{s}", .{local_cid});

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        const data = try self.allocator.alloc(u8, @intCast(stat.size));
        _ = try file.read(data);
        return data;
    }
};

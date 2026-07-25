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

    pub fn init(allocator: std.mem.Allocator,
    io: std.Io, config: StorageConfig) !StorageManager {
        var ipfs_client: ?IPFSClient = null;

        if (config.ipfs_enabled) {
            ipfs_client = IPFSClient.init(allocator, io, io, io, config.ipfs_url);
        }

        return StorageManager{
            .allocator = allocator,
            .config = config,
            .ipfs_client = ipfs_client,
        };
    }

    pub fn storeObject(self: *StorageManager, io: std.Io, object_data: []const u8) ![]const u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(object_data, &hash, .{});

        var cid_buffer: [64]u8 = undefined;
        const cid = std.fmt.bytesToHex(hash, .lower);
        @memcpy(&cid_buffer, &cid);

        switch (self.config.backend) {
            .local => {
                try self.storeLocal(io, &cid_buffer, object_data);
                return try self.allocator.dupe(u8, &cid_buffer);
            },
            .ipfs => {
                if (self.ipfs_client) |*client| {
                    return try client.blockPut(io, object_data, self.config.auto_pin);
                }
                return error.IPFSNotConfigured;
            },
            .hybrid => {
                try self.storeLocal(io, &cid_buffer, object_data);

                if (self.ipfs_client) |*client| {
                    const ipfs_cid = try client.blockPut(io, object_data, self.config.auto_pin);

                    try self.storeIPFSMapping(io, &cid_buffer, ipfs_cid);

                    self.allocator.free(ipfs_cid);
                }

                return try self.allocator.dupe(u8, &cid_buffer);
            },
        }
    }

    pub fn getObject(self: *StorageManager, io: std.Io, cid: []const u8) ![]u8 {
        if (self.config.backend == .local or self.config.backend == .hybrid) {
            if (self.getLocal(io, cid)) |local_data| {
                return local_data;
            } else |err| {
                if (err != error.FileNotFound and self.config.backend == .local) {
                    return err;
                }
            }
        }

        if (self.config.backend == .ipfs or self.config.backend == .hybrid) {
            if (self.ipfs_client) |*client| {
                const ipfs_cid = try self.getIPFSMapping(io, cid);
                defer if (ipfs_cid) |c| self.allocator.free(c);

                const cid_to_fetch = ipfs_cid orelse cid;
                return try client.blockGet(io, cid_to_fetch);
            }
        }

        return error.ObjectNotFound;
    }

    fn storeLocal(self: *StorageManager, io: std.Io, cid: []const u8, data: []const u8) !void {
        _ = self;
        const prefix = cid[0..2];
        const suffix = cid[2..];

        var objects_dir = try std.Io.Dir.cwd().createDirPathOpen(io, ".zev/objects", .{});
        defer objects_dir.close(io);

        var prefix_dir = try objects_dir.createDirPathOpen(io, prefix, .{});
        defer prefix_dir.close(io);

        const file = try prefix_dir.createFile(io, suffix, .{});
        defer file.close(io);

        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll(data);
        try writer.flush();
    }

    fn getLocal(self: *StorageManager, io: std.Io, cid: []const u8) ![]u8 {
        const prefix = cid[0..2];
        const suffix = cid[2..];

        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, ".zev/objects/{s}/{s}", .{ prefix, suffix });

        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        const data = try self.allocator.alloc(u8, @intCast(stat.size));
        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        _ = try reader.interface.readSliceShort(data);
        return data;
    }

    fn storeIPFSMapping(self: *StorageManager, io: std.Io, local_cid: []const u8, ipfs_cid: []const u8) !void {
        _ = self;
        var ipfs_map_dir = try std.Io.Dir.cwd().createDirPathOpen(io, ".zev/ipfs-map", .{});
        defer ipfs_map_dir.close(io);
        const file = try ipfs_map_dir.createFile(io, local_cid, .{});
        defer file.close(io);
        var buffer: [256]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll(ipfs_cid);
        try writer.flush();
    }

    fn getIPFSMapping(self: *StorageManager, io: std.Io, local_cid: []const u8) !?[]u8 {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, ".zev/ipfs-map/{s}", .{local_cid});
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close(io);

        const stat = try file.stat(io, );
        const data = try self.allocator.alloc(u8, @intCast(stat.size));
        _ = try file.read(data);
        return data;
    }
};

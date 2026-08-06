const std = @import("std");
const procutil = @import("procutil.zig");

pub const IPFSClient = struct {
    allocator: std.mem.Allocator,
    api_url: []const u8,

    pub fn init(allocator: std.mem.Allocator, api_url: []const u8) IPFSClient {
        return IPFSClient{
            .allocator = allocator,
            .api_url = api_url,
        };
    }

    pub fn add(self: *IPFSClient, io: std.Io, data: []const u8) ![]const u8 {
        const temp_path = "/tmp/zev_ipfs_temp";
        const temp_file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer temp_file.close(io);
        var write_buf: [4096]u8 = undefined;
        var writer = temp_file.writer(io, &write_buf);
        try writer.interface.writeAll(data);
        try writer.flush();
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/v0/add?pin=true", .{self.api_url});
        defer self.allocator.free(url);
        var child = try std.process.spawn(io, .{
            .argv = &.{ "curl", "-s", "-X", "POST", "-F", "file=@/tmp/zev_ipfs_temp", url },
            .stdout = .pipe,
            .stderr = .ignore,
        });
        const stdout = try procutil.readAllStdout(io, self.allocator, child.stdout.?, 1024 * 1024);
        defer self.allocator.free(stdout);
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) {
            self.allocator.free(stdout);
            return error.IPFSFailed;
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, stdout, .{});
        defer parsed.deinit();

        const hash = parsed.value.object.get("Hash") orelse return error.NoCIDInResponse;
        return try self.allocator.dupe(u8, hash.string);
    }

    pub fn cat(self: *IPFSClient, io: std.Io, ipfs_cid: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/v0/cat?arg={s}", .{ self.api_url, ipfs_cid });
        defer self.allocator.free(url);
        var child = try std.process.spawn(io, .{
            .argv = &.{ "curl", "-s", "-X", "POST", url },
            .stdout = .pipe,
            .stderr = .ignore,
        });
        const stdout = try procutil.readAllStdout(io, self.allocator, child.stdout.?, 10 * 1024 * 1024);
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) {
            self.allocator.free(stdout);
            return error.IPFSFailed;
        }
        return stdout;
    }

    pub fn blockGet(self: *IPFSClient, io: std.Io, ipfs_cid: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/v0/block/get?arg={s}", .{ self.api_url, ipfs_cid });
        defer self.allocator.free(url);
        var child = try std.process.spawn(io, .{
            .argv = &.{ "curl", "-s", "-X", "POST", url },
            .stdout = .pipe,
            .stderr = .ignore,
        });
        const stdout = try procutil.readAllStdout(io, self.allocator, child.stdout.?, 10 * 1024 * 1024);
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) {
            self.allocator.free(stdout);
            return error.IPFSFailed;
        }

        return stdout;
    }

    pub fn blockPut(self: *IPFSClient, io: std.Io, data: []const u8, should_pin: bool) ![]const u8 {
        const temp_path = "/tmp/zev_ipfs_temp";
        const temp_file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer temp_file.close(io);
        var write_buf: [4096]u8 = undefined;
        var writer = temp_file.writer(io, &write_buf);
        try writer.interface.writeAll(data);
        try writer.flush();
        const pin_str = if (should_pin) "true" else "false";
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/v0/block/put?pin={s}", .{ self.api_url, pin_str });
        defer self.allocator.free(url);
        var child = try std.process.spawn(io, .{
            .argv = &.{ "curl", "-s", "-X", "POST", "-F", "file=@/tmp/zev_ipfs_temp", url },
            .stdout = .pipe,
            .stderr = .ignore,
        });
        const stdout = try procutil.readAllStdout(io, self.allocator, child.stdout.?, 1024 * 1024);
        defer self.allocator.free(stdout);
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) return error.IPFSFailed;

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, stdout, .{});
        defer parsed.deinit();

        const key = parsed.value.object.get("Key") orelse return error.NoCIDInResponse;
        return try self.allocator.dupe(u8, key.string);
    }

    pub fn blockStat(self: *IPFSClient, io: std.Io, ipfs_cid: []const u8) !BlockStat {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/v0/block/stat?arg={s}", .{ self.api_url, ipfs_cid });
        defer self.allocator.free(url);

        var child = try std.process.spawn(io, .{
            .argv = &.{ "curl", "-s", "-X", "POST", url },
            .stdout = .pipe,
            .stderr = .ignore,
        });
        const stdout = try procutil.readAllStdout(io, self.allocator, child.stdout.?, 1024 * 1024);
        defer self.allocator.free(stdout);

        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) return error.IPFSFailed;

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, stdout, .{});
        defer parsed.deinit();

        const key = parsed.value.object.get("Key") orelse return error.NoKey;
        const size = parsed.value.object.get("Size") orelse return error.NoSize;

        return BlockStat{
            .key = try self.allocator.dupe(u8, key.string),
            .size = @intCast(size.integer),
        };
    }

    pub fn pin(self: *IPFSClient, io: std.Io, ipfs_cid: []const u8) !void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/v0/pin/add?arg={s}", .{ self.api_url, ipfs_cid });
        defer self.allocator.free(url);

        var child = try std.process.spawn(io, .{
            .argv = &.{ "curl", "-s", "-X", "POST", url },
            .stdout = .ignore,
            .stderr = .ignore,
        });
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) return error.IPFSFailed;
    }

    pub fn unpin(self: *IPFSClient, io: std.Io, ipfs_cid: []const u8) !void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/v0/pin/rm?arg={s}", .{ self.api_url, ipfs_cid });
        defer self.allocator.free(url);

        var child = try std.process.spawn(io, .{
            .argv = &.{ "curl", "-s", "-X", "POST", url },
            .stdout = .ignore,
            .stderr = .ignore,
        });
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) return error.IPFSFailed;
    }

    pub fn version(self: *IPFSClient, io: std.Io) ![]const u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/v0/version", .{self.api_url});
        defer self.allocator.free(url);

        var child = try std.process.spawn(io, .{
            .argv = &.{ "curl", "-s", "-X", "POST", url },
            .stdout = .pipe,
            .stderr = .ignore,
        });
        const stdout = try procutil.readAllStdout(io, self.allocator, child.stdout.?, 1024 * 1024);
        defer self.allocator.free(stdout);

        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) return error.IPFSFailed;

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, stdout, .{});
        defer parsed.deinit();

        const version_obj = parsed.value.object.get("Version") orelse return error.NoVersion;
        return try self.allocator.dupe(u8, version_obj.string);
    }

    pub fn id(self: *IPFSClient, io: std.Io) !NodeID {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/v0/id", .{self.api_url});
        defer self.allocator.free(url);

        var child = try std.process.spawn(io, .{
            .argv = &.{ "curl", "-s", "-X", "POST", url },
            .stdout = .pipe,
            .stderr = .ignore,
        });
        const stdout = try procutil.readAllStdout(io, self.allocator, child.stdout.?, 1024 * 1024);
        defer self.allocator.free(stdout);

        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) return error.IPFSFailed;

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, stdout, .{});
        defer parsed.deinit();

        const id_obj = parsed.value.object.get("ID") orelse return error.NoID;
        const agent_obj = parsed.value.object.get("AgentVersion") orelse return error.NoAgent;

        return NodeID{
            .id = try self.allocator.dupe(u8, id_obj.string),
            .agent_version = try self.allocator.dupe(u8, agent_obj.string),
        };
    }
};

pub const BlockStat = struct {
    key: []const u8,
    size: u64,

    pub fn deinit(self: *BlockStat, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }
};

pub const NodeID = struct {
    id: []const u8,
    agent_version: []const u8,

    pub fn deinit(self: *NodeID, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.agent_version);
    }
};

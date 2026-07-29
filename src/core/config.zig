const std = @import("std");
const storage_mod = @import("storage.zig");
const validation = @import("config_validation.zig");

pub const Config = struct {
    user_name: []const u8,
    user_email: []const u8,

    storage_backend: storage_mod.StorageBackend,
    ipfs_enabled: bool,
    ipfs_url: []const u8,
    ipfs_auto_pin: bool,

    default_branch: []const u8,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .user_name = "Zev User",
            .user_email = "user@example.com",
            .storage_backend = .local,
            .ipfs_enabled = false,
            .ipfs_url = "http://127.0.0.1:5001",
            .ipfs_auto_pin = true,
            .default_branch = "main",
            .allocator = allocator,
        };
    }

    pub fn load(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8) !Config {
        var config = Config.init(allocator);

        const config_path = try std.fs.path.join(allocator, &[_][]const u8{ repo_path, ".zev", "config" });
        defer allocator.free(config_path);

        const file = std.Io.Dir.cwd().openFile(io, config_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return config;
            }
            return err;
        };
        defer file.close(io);

        const stat = try file.stat(io);
        const content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        const bytes_read = try reader.interface.readSliceShort(content);
        const actual_content = content[0..bytes_read];

        var lines = std.mem.splitScalar(u8, actual_content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            var parts = std.mem.splitScalar(u8, trimmed, '=');
            const key = std.mem.trim(u8, parts.next() orelse continue, " \t");
            const value = std.mem.trim(u8, parts.next() orelse continue, " \t");

            if (std.mem.eql(u8, key, "user.name")) {
                config.user_name = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "user.email")) {
                config.user_email = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "storage.backend")) {
                if (std.mem.eql(u8, value, "local")) {
                    config.storage_backend = .local;
                } else if (std.mem.eql(u8, value, "ipfs")) {
                    config.storage_backend = .ipfs;
                    config.ipfs_enabled = true;
                } else if (std.mem.eql(u8, value, "hybrid")) {
                    config.storage_backend = .hybrid;
                    config.ipfs_enabled = true;
                }
            } else if (std.mem.eql(u8, key, "ipfs.url")) {
                config.ipfs_url = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "ipfs.auto_pin")) {
                config.ipfs_auto_pin = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "core.default_branch")) {
                config.default_branch = try allocator.dupe(u8, value);
            }
        }

        return config;
    }

    pub fn save(self: *const Config, io: std.Io, repo_path: []const u8) !void {
        const config_path = try std.fs.path.join(self.allocator, &[_][]const u8{ repo_path, ".zev", "config" });
        defer self.allocator.free(config_path);
        const file = try std.Io.Dir.cwd().createFile(io, config_path, .{});
        defer file.close(io);
        var buffer: [512]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll("# Zev Configuration File\n");
        try writer.interface.writeAll("# Generated automatically - you can edit this file\n\n");
        try writer.interface.writeAll("# User Information\n");
        var line_buf: [512]u8 = undefined;
        var line = try std.fmt.bufPrint(&line_buf, "user.name={s}\n", .{self.user_name});
        try writer.interface.writeAll(line);
        line = try std.fmt.bufPrint(&line_buf, "user.email={s}\n", .{self.user_email});
        try writer.interface.writeAll(line);
        try writer.interface.writeAll("\n# Storage Backend\n");
        try writer.interface.writeAll("# Options: local, ipfs, hybrid\n");
        const backend_str = switch (self.storage_backend) {
            .local => "local",
            .ipfs => "ipfs",
            .hybrid => "hybrid",
        };
        line = try std.fmt.bufPrint(&line_buf, "storage.backend={s}\n", .{backend_str});
        try writer.interface.writeAll(line);
        try writer.interface.writeAll("\n# IPFS Configuration\n");
        line = try std.fmt.bufPrint(&line_buf, "ipfs.url={s}\n", .{self.ipfs_url});
        try writer.interface.writeAll(line);
        line = try std.fmt.bufPrint(&line_buf, "ipfs.auto_pin={s}\n", .{if (self.ipfs_auto_pin) "true" else "false"});
        try writer.interface.writeAll(line);
        try writer.interface.writeAll("\n# Repository Settings\n");
        line = try std.fmt.bufPrint(&line_buf, "core.default_branch={s}\n", .{self.default_branch});
        try writer.interface.writeAll(line);
        try writer.flush();
    }

    pub fn get(self: *const Config, key: []const u8) ![]const u8 {
        if (std.mem.eql(u8, key, "user.name")) return self.user_name;
        if (std.mem.eql(u8, key, "user.email")) return self.user_email;
        if (std.mem.eql(u8, key, "storage.backend")) {
            return switch (self.storage_backend) {
                .local => "local",
                .ipfs => "ipfs",
                .hybrid => "hybrid",
            };
        }
        if (std.mem.eql(u8, key, "ipfs.url")) return self.ipfs_url;
        if (std.mem.eql(u8, key, "ipfs.auto_pin")) return if (self.ipfs_auto_pin) "true" else "false";
        if (std.mem.eql(u8, key, "core.default_branch")) return self.default_branch;
        return error.UnknownConfigKey;
    }

    pub fn set(self: *Config, key: []const u8, value: []const u8) !void {
        const defaults = Config.init(self.allocator);
        if (std.mem.eql(u8, key, "user.name")) {
            try validation.validateUserName(value);
            if (self.user_name.ptr != defaults.user_name.ptr) self.allocator.free(self.user_name);
            self.user_name = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "user.email")) {
            try validation.validateEmail(value);
            if (self.user_email.ptr != defaults.user_email.ptr) self.allocator.free(self.user_email);
            self.user_email = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "storage.backend")) {
            try validation.validateStorageBackend(value);
            if (std.mem.eql(u8, value, "local")) {
                self.storage_backend = .local;
                self.ipfs_enabled = false;
            } else if (std.mem.eql(u8, value, "ipfs")) {
                self.storage_backend = .ipfs;
                self.ipfs_enabled = true;
            } else if (std.mem.eql(u8, value, "hybrid")) {
                self.storage_backend = .hybrid;
                self.ipfs_enabled = true;
            }
        } else if (std.mem.eql(u8, key, "ipfs.url")) {
            try validation.validateIpfsUrl(value);
            if (self.ipfs_url.ptr != defaults.ipfs_url.ptr) self.allocator.free(self.ipfs_url);
            self.ipfs_url = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "ipfs.auto_pin")) {
            try validation.validateBooleanValue(value);
            self.ipfs_auto_pin = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "core.default_branch")) {
            try validation.validateBranchName(value);
            if (self.default_branch.ptr != defaults.default_branch.ptr) self.allocator.free(self.default_branch);
            self.default_branch = try self.allocator.dupe(u8, value);
        } else {
            return error.UnknownConfigKey;
        }
    }
    pub fn list(self: *const Config, writer: anytype) !void {
        try writer.print("user.name={s}\n", .{self.user_name});
        try writer.print("user.email={s}\n", .{self.user_email});
        const backend_str = switch (self.storage_backend) {
            .local => "local",
            .ipfs => "ipfs",
            .hybrid => "hybrid",
        };
        try writer.print("storage.backend={s}\n", .{backend_str});
        try writer.print("ipfs.url={s}\n", .{self.ipfs_url});
        try writer.print("ipfs.auto_pin={s}\n", .{if (self.ipfs_auto_pin) "true" else "false"});
        try writer.print("core.default_branch={s}\n", .{self.default_branch});
    }

    pub fn listDirect(self: *const Config) !void {
        std.debug.print("user.name={s}\n", .{self.user_name});
        std.debug.print("user.email={s}\n", .{self.user_email});
        const backend_str = switch (self.storage_backend) {
            .local => "local",
            .ipfs => "ipfs",
            .hybrid => "hybrid",
        };
        std.debug.print("storage.backend={s}\n", .{backend_str});
        std.debug.print("ipfs.url={s}\n", .{self.ipfs_url});
        std.debug.print("ipfs.auto_pin={s}\n", .{if (self.ipfs_auto_pin) "true" else "false"});
        std.debug.print("core.default_branch={s}\n", .{self.default_branch});
    }
    pub fn deinit(self: *Config) void {
        const defaults = Config.init(self.allocator);
        if (self.user_name.ptr != defaults.user_name.ptr)
            self.allocator.free(self.user_name);
        if (self.user_email.ptr != defaults.user_email.ptr)
            self.allocator.free(self.user_email);
        if (self.ipfs_url.ptr != defaults.ipfs_url.ptr)
            self.allocator.free(self.ipfs_url);
        if (self.default_branch.ptr != defaults.default_branch.ptr)
            self.allocator.free(self.default_branch);
    }
};

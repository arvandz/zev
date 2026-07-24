const std = @import("std");

pub const IgnoreList = struct {
    patterns: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) IgnoreList {
        return .{
            .patterns = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IgnoreList) void {
        for (self.patterns.items) |pattern| {
            self.allocator.free(pattern);
        }
        self.patterns.deinit(self.allocator);
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8) !IgnoreList {
        var list = IgnoreList.init(allocator);
        errdefer list.deinit();
        try list.patterns.append(allocator, try allocator.dupe(u8, ".zev"));
        const ignore_path = try std.fs.path.join(allocator, &.{ repo_path, ".zevignore" });
        defer allocator.free(ignore_path);
        const file = std.Io.Dir.cwd().openFile(io, ignore_path, .{}) catch |err| {
            if (err == error.FileNotFound) return list;
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

        var lines = std.mem.splitSequence(u8, actual_content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue;
            try list.patterns.append(allocator, try allocator.dupe(u8, trimmed));
        }

        return list;
    }

    pub fn loadDefault(allocator: std.mem.Allocator) !IgnoreList {
        var list = IgnoreList.init(allocator);
        errdefer list.deinit();
        try list.patterns.append(allocator, try allocator.dupe(u8, ".zev"));
        return list;
    }

    pub fn isIgnored(self: *const IgnoreList, path: []const u8) bool {
        for (self.patterns.items) |pattern| {
            if (matchPattern(pattern, path)) return true;
        }
        return false;
    }

    fn matchPattern(pattern: []const u8, path: []const u8) bool {
        if (pattern.len > 0 and pattern[0] == '!') return false;

        const filename = std.fs.path.basename(path);

        if (std.mem.eql(u8, pattern, path)) return true;
        if (std.mem.eql(u8, pattern, filename)) return true;

        if (std.mem.startsWith(u8, pattern, "*.")) {
            const ext = pattern[1..];
            if (std.mem.endsWith(u8, filename, ext)) return true;
            if (std.mem.endsWith(u8, path, ext)) return true;
        }

        if (std.mem.endsWith(u8, pattern, "/")) {
            const dir_pattern = pattern[0 .. pattern.len - 1];
            if (std.mem.eql(u8, dir_pattern, filename)) return true;
            if (std.mem.startsWith(u8, path, pattern)) return true;
        }

        if (std.mem.endsWith(u8, pattern, "/*")) {
            const prefix = pattern[0 .. pattern.len - 2];
            if (std.mem.startsWith(u8, path, prefix)) return true;
        }

        if (std.mem.startsWith(u8, pattern, "**/")) {
            const suffix = pattern[3..];
            if (std.mem.eql(u8, suffix, filename)) return true;
            if (std.mem.endsWith(u8, path, suffix)) return true;
        }

        return false;
    }
};

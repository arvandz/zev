const std = @import("std");
const cid = @import("cid.zig");

pub const IndexEntry = struct {
    path: []const u8,
    cid: cid.CID,
    size: u64,
    mode: u32,
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(IndexEntry),
    index_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, index_path: []const u8) Index {
        return Index{
            .allocator = allocator,
            .entries = .empty,
            .index_path = index_path,
        };
    }

    pub fn deinit(self: *Index) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.path);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn addEntry(self: *Index, path: []const u8, file_cid: cid.CID, size: u64, mode: u32) !void {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.path, path)) {
                self.allocator.free(entry.path);
                self.entries.items[i] = IndexEntry{
                    .path = try self.allocator.dupe(u8, path),
                    .cid = file_cid,
                    .size = size,
                    .mode = mode,
                };
                return;
            }
        }

        const entry = IndexEntry{
            .path = try self.allocator.dupe(u8, path),
            .cid = file_cid,
            .size = size,
            .mode = mode,
        };
        try self.entries.append(self.allocator, entry);
    }

    pub fn removeEntry(self: *Index, path: []const u8) !void {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.path, path)) {
                self.allocator.free(entry.path);
                _ = self.entries.orderedRemove(i);
                return;
            }
        }
        return error.EntryNotFound;
    }

    pub fn getEntry(self: *Index, path: []const u8) ?IndexEntry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                return entry;
            }
        }
        return null;
    }

    pub fn hasEntry(self: *Index, path: []const u8) bool {
        return self.getEntry(path) != null;
    }

    pub fn write(self: *Index, io: std.Io) !void {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(self.allocator);

        for (self.entries.items) |entry| {
            const cid_str = try entry.cid.toString(self.allocator);
            defer self.allocator.free(cid_str);

            try buffer.print(self.allocator, "{s} {s} {} {}\n", .{
                entry.path,
                cid_str,
                entry.size,
                entry.mode,
            });
        }

        const file = try std.Io.Dir.cwd().createFile(io, self.index_path, .{});
        defer file.close(io);
        var file_buffer: [512]u8 = undefined;
        var file_writer = file.writer(io, &file_buffer);
        try file_writer.interface.writeAll(buffer.items);
        try file_writer.flush();
    }

    pub fn read(self: *Index, io: std.Io) !void {
        const file = std.Io.Dir.cwd().openFile(io, io, self.index_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return;
            }
            return err;
        };
        defer file.close(io);

        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        const content = try reader.interface.allocRemaining(self.allocator, .unlimited);
        defer self.allocator.free(content);

        var lines = std.mem.splitSequence(u8, content, "\n");
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            var parts = std.mem.splitSequence(u8, line, " ");
            const path = parts.next() orelse continue;
            const cid_str = parts.next() orelse continue;
            const size_str = parts.next() orelse continue;
            const mode_str = parts.next() orelse continue;

            if (cid_str.len != 64) continue;
            var hash: [32]u8 = undefined;
            for (0..32) |i| {
                const high = try std.fmt.charToDigit(cid_str[i * 2], 16);
                const low = try std.fmt.charToDigit(cid_str[i * 2 + 1], 16);
                hash[i] = (high << 4) | low;
            }

            const entry = IndexEntry{
                .path = try self.allocator.dupe(u8, path),
                .cid = cid.CID{ .hash = hash },
                .size = try std.fmt.parseInt(u64, size_str, 10),
                .mode = try std.fmt.parseInt(u32, mode_str, 10),
            };
            try self.entries.append(self.allocator, entry);
        }
    }

    pub fn clear(self: *Index) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.path);
        }
        self.entries.clearRetainingCapacity();
    }
};

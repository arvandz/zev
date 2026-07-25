const std = @import("std");
const repository = @import("repository.zig");
const cid = @import("cid.zig");

pub fn showStatus(allocator: std.mem.Allocator, io: std.Io, repo: *repository.Repository) !void {
    std.debug.print("On branch main\n", .{});
    if (repo.index.entries.items.len > 0) {
        std.debug.print("\nChanges to be committed:\n", .{});
        for (repo.index.entries.items) |entry| {
            std.debug.print("  new file:   {s}\n", .{entry.path});
        }
    }
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var has_changes = false;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (std.mem.startsWith(u8, entry.name, ".zev")) continue;
        const is_staged = repo.index.hasEntry(entry.name);
        if (is_staged) continue;
        const file_data = std.Io.Dir.cwd().readFileAlloc(io, entry.name, allocator, .unlimited) catch continue;
        defer allocator.free(file_data);
        const file_cid = cid.CID.fromBytes(file_data);
io, file_data);
        const in_store = try repo.store.has(io, file_cid);

        if (!in_store) {
            if (!has_changes) {
                std.debug.print("\nChanges not staged for commit:\n", .{});
                has_changes = true;
            }
            std.debug.print("  modified:   {s}\n", .{entry.name});
        }
    }

    if (repo.index.entries.items.len == 0 and !has_changes) {
        std.debug.print("\nNothing to commit, working tree clean\n", .{});
    }
}

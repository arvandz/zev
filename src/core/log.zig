const std = @import("std");
const cid = @import("cid.zig");
const commit = @import("commit.zig");
const blob = @import("blob.zig");

pub fn printLog(allocator: std.mem.Allocator,
    io: std.Io, store: *blob.BlobStore, start_cid: cid.CID, max_count: usize) !void {
    var current_cid: ?cid.CID = start_cid;
    var count: usize = 0;

    while (current_cid) |commit_cid| {
        if (count >= max_count) break;

        const commit_data = try store.get(commit_cid);
        defer allocator.free(commit_data);

        const current_commit = try commit.Commit.deserialize(allocator, io, commit_data);
        defer allocator.free(current_commit.author);
        defer allocator.free(current_commit.message);

        const cid_str = try commit_cid.toString(allocator);
        defer allocator.free(cid_str);

        std.debug.print("commit {s}\n", .{cid_str});
        std.debug.print("Author: {s}\n", .{current_commit.author});

        const timestamp = current_commit.timestamp;
        std.debug.print("Date: {}\n", .{timestamp});
        std.debug.print("\n    {s}\n", .{current_commit.message});

        current_cid = current_commit.parent_cid;
        count += 1;
    }
}

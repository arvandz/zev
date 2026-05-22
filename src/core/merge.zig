const std = @import("std");
const repository = @import("repository.zig");

pub const MergeResult = enum {
    FastForward,
    AlreadyUpToDate,
    ThreeWaySuccess,
    ConflictDetected,
};

pub fn merge(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    source_branch: []const u8,
) !MergeResult {
    const head_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "HEAD" });
    defer allocator.free(head_path);
    const head = std.fs.cwd().readFileAlloc(head_path, allocator, @enumFromInt(256)) catch return error.NoHEAD;
    defer allocator.free(head);

    const src_ref = try std.fmt.allocPrint(allocator, ".zev/refs/heads/{s}", .{source_branch});
    defer allocator.free(src_ref);
    const src_path = try std.fs.path.join(allocator, &.{ repo.path, src_ref });
    defer allocator.free(src_path);

    const src_hash = std.fs.cwd().readFileAlloc(src_path, allocator, @enumFromInt(256)) catch {
        std.debug.print("Branch '{s}' not found.\n", .{source_branch});
        return error.BranchNotFound;
    };
    defer allocator.free(src_hash);

    const trimmed_head = std.mem.trim(u8, head, "\n\r ");
    var current_hash: []const u8 = "";
    if (std.mem.startsWith(u8, trimmed_head, "ref: ")) {
        const ref = trimmed_head[5..];
        const cur_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", ref });
        defer allocator.free(cur_path);
        const cur = std.fs.cwd().readFileAlloc(cur_path, allocator, @enumFromInt(256)) catch return .AlreadyUpToDate;
        defer allocator.free(cur);
        current_hash = std.mem.trim(u8, cur, "\n\r ");
    }

    const src_trimmed = std.mem.trim(u8, src_hash, "\n\r ");
    if (std.mem.eql(u8, current_hash, src_trimmed)) return .AlreadyUpToDate;

    if (std.mem.startsWith(u8, trimmed_head, "ref: ")) {
        const ref = trimmed_head[5..];
        const cur_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", ref });
        defer allocator.free(cur_path);
        const f = std.fs.cwd().createFile(cur_path, .{}) catch return .ConflictDetected;
        defer f.close();
        try f.writeAll(src_trimmed);
    }

    return .FastForward;
}

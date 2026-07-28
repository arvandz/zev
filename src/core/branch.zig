const std = @import("std");
const repository = @import("repository.zig");
const cid = @import("cid.zig");

pub fn createBranch(allocator: std.mem.Allocator,
    io: std.Io, repo: *repository.Repository, branch_name: []const u8) !void {
    const head_cid = try repo.getHeadCommit();

    const zev_path = try std.fs.path.join(allocator, &[_][]const u8{ repo.path, ".zev" });
    defer allocator.free(zev_path);

    const branch_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "refs", "heads", branch_name });
    defer allocator.free(branch_path);

    if (std.Io.Dir.cwd().access(branch_path, .{})) {
        return error.BranchAlreadyExists;
    } else |err| {
        if (err != error.FileNotFound) return err;
    }

    const branch_file = try std.Io.Dir.cwd().createFile(branch_path, .{});
    defer branch_file.close(io);

    const cid_str = try head_cid.toString(allocator);
    defer allocator.free(cid_str);

    try branch_file.writeAll(cid_str);
}

pub fn checkoutBranch(allocator: std.mem.Allocator,
    io: std.Io, repo: *repository.Repository, branch_name: []const u8) !void {
    const zev_path = try std.fs.path.join(allocator, &[_][]const u8{ repo.path, ".zev" });
    defer allocator.free(zev_path);

    const branch_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "refs", "heads", branch_name });
    defer allocator.free(branch_path);

    std.Io.Dir.cwd().access(branch_path, .{}) catch {
        return error.BranchNotFound;
    };

    const head_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "HEAD" });
    defer allocator.free(head_path);

    const head_file = try std.Io.Dir.cwd().createFile(head_path, .{});
    defer head_file.close(io);

    const ref_content = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{branch_name});
    defer allocator.free(ref_content);

    try head_file.writeAll(ref_content);
}

pub fn getCurrentBranch(allocator: std.mem.Allocator,
    io: std.Io, repo: *repository.Repository) ![]const u8 {
    const zev_path = try std.fs.path.join(allocator, &[_][]const u8{ repo.path, ".zev" });
    defer allocator.free(zev_path);

    const head_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "HEAD" });
    defer allocator.free(head_path);

    const head_file = try std.Io.Dir.cwd().openFile(head_path, .{});
    defer head_file.close(io);

    var buffer: [256]u8 = undefined;
    var head_file_scratch: [4096]u8 = undefined;
    var head_file_reader = head_file.reader(io, &head_file_scratch);
    const bytes_read = try head_file_reader.interface.readSliceShort(&buffer);
    const head_content = std.mem.trim(u8, buffer[0..bytes_read], " \n\r\t");

    if (std.mem.startsWith(u8, head_content, "ref: refs/heads/")) {
        const branch_name = head_content[16..];
        return try allocator.dupe(u8, branch_name);
    }

    return error.DetachedHead;
}

pub fn listBranches(allocator: std.mem.Allocator,
    io: std.Io, repo: *repository.Repository) !void {
    const zev_path = try std.fs.path.join(allocator, &[_][]const u8{ repo.path, ".zev" });
    defer allocator.free(zev_path);

    const heads_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "refs", "heads" });
    defer allocator.free(heads_path);

    var heads_dir = try std.Io.Dir.cwd().openDir(io, heads_path, .{ .iterate = true });
    defer heads_dir.close(io);

    const current_branch = getCurrentBranch(allocator, io, repo) catch "HEAD";
    defer allocator.free(current_branch);

    var iterator = heads_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;

        const is_current = std.mem.eql(u8, entry.name, current_branch);
        if (is_current) {
            std.debug.print("* {s}\n", .{entry.name});
        } else {
            std.debug.print("  {s}\n", .{entry.name});
        }
    }
}

pub fn deleteBranch(allocator: std.mem.Allocator,
    io: std.Io, repo: *repository.Repository, branch_name: []const u8) !void {
    const current = try getCurrentBranch(allocator, io, repo);
    defer allocator.free(current);

    if (std.mem.eql(u8, current, branch_name)) {
        return error.CannotDeleteCurrentBranch;
    }

    const zev_path = try std.fs.path.join(allocator, &[_][]const u8{ repo.path, ".zev" });
    defer allocator.free(zev_path);

    const branch_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "refs", "heads", branch_name });
    defer allocator.free(branch_path);

    try std.Io.Dir.cwd().deleteFile(branch_path);
}

const std = @import("std");
const repository = @import("repository.zig");
const cid = @import("cid.zig");
const commit = @import("commit.zig");
const tree = @import("tree.zig");

pub const DiffLine = struct {
    type: enum { add, remove, context },
    line_num_old: ?usize,
    line_num_new: ?usize,
    content: []const u8,
};

pub fn diffFiles(allocator: std.mem.Allocator, old_content: []const u8, new_content: []const u8) !void {
    var old_lines: std.ArrayList([]const u8) = .empty;
    defer old_lines.deinit(allocator);

    var new_lines: std.ArrayList([]const u8) = .empty;
    defer new_lines.deinit(allocator);

    var old_iter = std.mem.splitSequence(u8, old_content, "\n");
    while (old_iter.next()) |line| {
        try old_lines.append(allocator, line);
    }

    var new_iter = std.mem.splitSequence(u8, new_content, "\n");
    while (new_iter.next()) |line| {
        try new_lines.append(allocator, line);
    }

    const max_lines = @max(old_lines.items.len, new_lines.items.len);

    for (0..max_lines) |i| {
        const old_line = if (i < old_lines.items.len) old_lines.items[i] else null;
        const new_line = if (i < new_lines.items.len) new_lines.items[i] else null;

        if (old_line == null and new_line != null) {
            std.debug.print("\x1b[32m+{s}\x1b[0m\n", .{new_line.?});
        } else if (old_line != null and new_line == null) {
            std.debug.print("\x1b[31m-{s}\x1b[0m\n", .{old_line.?});
        } else if (old_line != null and new_line != null) {
            if (!std.mem.eql(u8, old_line.?, new_line.?)) {
                std.debug.print("\x1b[31m-{s}\x1b[0m\n", .{old_line.?});
                std.debug.print("\x1b[32m+{s}\x1b[0m\n", .{new_line.?});
            } else {
                std.debug.print(" {s}\n", .{old_line.?});
            }
        }
    }
}

pub fn diffWorkingToStaging(allocator: std.mem.Allocator, io: std.Io, repo: *repository.Repository, filename: []const u8) !void {
    const working_content = try std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(working_content);

    const staged_entry = repo.index.getEntry(filename);

    if (staged_entry) |entry| {
        const staged_content = try repo.store.get(io, entry.cid);
        defer allocator.free(staged_content);

        std.debug.print("diff --zev a/{s} b/{s}\n", .{ filename, filename });
        std.debug.print("--- a/{s}\n", .{filename});
        std.debug.print("+++ b/{s}\n", .{filename});

        try diffFiles(allocator, staged_content, working_content);
    } else {
        std.debug.print("File '{s}' not in staging area\n", .{filename});
    }
}

pub fn diffCommits(allocator: std.mem.Allocator, io: std.Io, repo: *repository.Repository, commit1_cid: cid.CID, commit2_cid: cid.CID) !void {
    const commit1_data = try repo.store.get(io, commit1_cid);
    defer allocator.free(commit1_data);
    const commit1_obj = try commit.Commit.deserialize(allocator, commit1_data);
    defer allocator.free(commit1_obj.author);
    defer allocator.free(commit1_obj.message);

    const commit2_data = try repo.store.get(io, commit2_cid);
    defer allocator.free(commit2_data);
    const commit2_obj = try commit.Commit.deserialize(allocator, commit2_data);
    defer allocator.free(commit2_obj.author);
    defer allocator.free(commit2_obj.message);

    const tree1_data = try repo.store.get(io, commit1_obj.tree_cid);
    defer allocator.free(tree1_data);
    var tree1_obj = try tree.Tree.deserialize(allocator, io, tree1_data);
    defer tree1_obj.deinit();

    const tree2_data = try repo.store.get(io, commit2_obj.tree_cid);
    defer allocator.free(tree2_data);
    var tree2_obj = try tree.Tree.deserialize(allocator, io, tree2_data);
    defer tree2_obj.deinit();

    const cid1_str = try commit1_cid.toString(allocator);
    defer allocator.free(cid1_str);
    const cid2_str = try commit2_cid.toString(allocator);
    defer allocator.free(cid2_str);

    std.debug.print("diff --zev commit {s}..{s}\n", .{ cid1_str, cid2_str });

    var tree1_map = std.StringHashMap(tree.FileEntry).init(allocator, io, io, io, );
    defer tree1_map.deinit();

    for (tree1_obj.entries.items) |entry| {
        try tree1_map.put(entry.name, entry);
    }

    for (tree2_obj.entries.items) |entry2| {
        if (tree1_map.get(entry2.name)) |entry1| {
            if (!entry1.cid.equals(entry2.cid)) {
                std.debug.print("\nModified: {s}\n", .{entry2.name});

                const content1 = try repo.store.get(io, entry1.cid);
                defer allocator.free(content1);
                const content2 = try repo.store.get(io, entry2.cid);
                defer allocator.free(content2);

                std.debug.print("--- a/{s}\n", .{entry2.name});
                std.debug.print("+++ b/{s}\n", .{entry2.name});
                try diffFiles(allocator, content1, content2);
            }
        } else {
            std.debug.print("\nNew file: {s}\n", .{entry2.name});
            const content = try repo.store.get(io, entry2.cid);
            defer allocator.free(content);

            std.debug.print("+++ b/{s}\n", .{entry2.name});
            try diffFiles(allocator, "", content);
        }
    }

    for (tree1_obj.entries.items) |entry1| {
        var found = false;
        for (tree2_obj.entries.items) |entry2| {
            if (std.mem.eql(u8, entry1.name, entry2.name)) {
                found = true;
                break;
            }
        }

        if (!found) {
            std.debug.print("\nDeleted: {s}\n", .{entry1.name});
            const content = try repo.store.get(io, entry1.cid);
            defer allocator.free(content);

            std.debug.print("--- a/{s}\n", .{entry1.name});
            try diffFiles(allocator, content, "");
        }
    }
}

pub fn diffUnstaged(allocator: std.mem.Allocator, io: std.Io, repo: *repository.Repository) !void {
    const head_cid = repo.getHeadCommit() catch {
        std.debug.print("No commits yet\n", .{});
        return;
    };

    const commit_data = try repo.store.get(io, head_cid);
    defer allocator.free(commit_data);
    const commit_obj = try commit.Commit.deserialize(allocator, commit_data);
    defer allocator.free(commit_obj.author);
    defer allocator.free(commit_obj.message);

    const tree_data = try repo.store.get(io, commit_obj.tree_cid);
    defer allocator.free(tree_data);
    var tree_obj = try tree.Tree.deserialize(allocator, io, tree_data);
    defer tree_obj.deinit();

    for (tree_obj.entries.items) |entry| {
        const working_content = std.Io.Dir.cwd().readFileAlloc(io, entry.name, allocator, .limited(10 * 1024 * 1024)) catch continue;
        defer allocator.free(working_content);

        const working_cid = cid.CID.fromBytes(io, working_content);

        if (!working_cid.equals(entry.cid)) {
            std.debug.print("\nModified: {s}\n", .{entry.name});

            const head_content = try repo.store.get(io, entry.cid);
            defer allocator.free(head_content);

            std.debug.print("--- a/{s}\n", .{entry.name});
            std.debug.print("+++ b/{s}\n", .{entry.name});
            try diffFiles(allocator, head_content, working_content);
        }
    }
}

pub fn diffStaged(allocator: std.mem.Allocator, io: std.Io, repo: *repository.Repository) !void {
    if (repo.index.entries.items.len == 0) {
        std.debug.print("No staged changes\n", .{});
        return;
    }

    const head_cid = repo.getHeadCommit() catch {
        for (repo.index.entries.items) |entry| {
            std.debug.print("\nNew file: {s}\n", .{entry.path});
            const content = try repo.store.get(io, entry.cid);
            defer allocator.free(content);

            std.debug.print("+++ b/{s}\n", .{entry.path});
            try diffFiles(allocator, "", content);
        }
        return;
    };

    const commit_data = try repo.store.get(io, head_cid);
    defer allocator.free(commit_data);
    const commit_obj = try commit.Commit.deserialize(allocator, commit_data);
    defer allocator.free(commit_obj.author);
    defer allocator.free(commit_obj.message);

    const tree_data = try repo.store.get(io, commit_obj.tree_cid);
    defer allocator.free(tree_data);
    var tree_obj = try tree.Tree.deserialize(allocator, io, tree_data);
    defer tree_obj.deinit();

    var head_map = std.StringHashMap(tree.FileEntry).init(allocator, io, io, io, );
    defer head_map.deinit();

    for (tree_obj.entries.items) |entry| {
        try head_map.put(entry.name, entry);
    }

    for (repo.index.entries.items) |staged| {
        if (head_map.get(staged.path)) |head_entry| {
            if (!staged.cid.equals(head_entry.cid)) {
                std.debug.print("\nModified: {s}\n", .{staged.path});

                const head_content = try repo.store.get(io, head_entry.cid);
                defer allocator.free(head_content);
                const staged_content = try repo.store.get(io, staged.cid);
                defer allocator.free(staged_content);

                std.debug.print("--- a/{s}\n", .{staged.path});
                std.debug.print("+++ b/{s}\n", .{staged.path});
                try diffFiles(allocator, head_content, staged_content);
            }
        } else {
            std.debug.print("\nNew file: {s}\n", .{staged.path});
            const content = try repo.store.get(io, staged.cid);
            defer allocator.free(content);

            std.debug.print("+++ b/{s}\n", .{staged.path});
            try diffFiles(allocator, "", content);
        }
    }
}

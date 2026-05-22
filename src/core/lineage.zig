const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");

pub const NodeType = enum {
    dataset,
    script,
    model,
    experiment,
    artifact,

    pub fn toString(self: NodeType) []const u8 {
        return switch (self) {
            .dataset => "dataset",
            .script => "script",
            .model => "model",
            .experiment => "experiment",
            .artifact => "artifact",
        };
    }

    pub fn fromString(s: []const u8) ?NodeType {
        if (std.mem.eql(u8, s, "dataset")) return .dataset;
        if (std.mem.eql(u8, s, "script")) return .script;
        if (std.mem.eql(u8, s, "model")) return .model;
        if (std.mem.eql(u8, s, "experiment")) return .experiment;
        if (std.mem.eql(u8, s, "artifact")) return .artifact;
        return null;
    }

    pub fn icon(self: NodeType) []const u8 {
        return switch (self) {
            .dataset => "📦",
            .script => "📜",
            .model => "🤖",
            .experiment => "🧪",
            .artifact => "📁",
        };
    }
};

pub const LineageNode = struct {
    id: []const u8,
    node_type: NodeType,
    description: []const u8,
    file_cid: []const u8,
    created_at: i64,
    tags: []const u8,
    parents: []const u8,
    version: []const u8,
};

fn lineageDir(allocator: std.mem.Allocator, repo: *Repository) ![]u8 {
    const dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "lineage" });
    try std.fs.cwd().makePath(dir);
    return dir;
}

fn nodePath(allocator: std.mem.Allocator, repo: *Repository, id: []const u8) ![]u8 {
    const dir = try lineageDir(allocator, repo);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, id });
}

fn saveNode(allocator: std.mem.Allocator, repo: *Repository, node: LineageNode) !void {
    const path = try nodePath(allocator, repo, node.id);
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const content = try std.fmt.allocPrint(allocator, "id={s}\ntype={s}\ndescription={s}\nfile_cid={s}\ncreated_at={d}\ntags={s}\nparents={s}\nversion={s}\n", .{ node.id, node.node_type.toString(), node.description, node.file_cid, node.created_at, node.tags, node.parents, node.version });
    defer allocator.free(content);
    try file.writeAll(content);
}

fn loadNode(allocator: std.mem.Allocator, repo: *Repository, id: []const u8) !?LineageNode {
    const path = try nodePath(allocator, repo, id);
    defer allocator.free(path);

    const content = std.fs.cwd().readFileAlloc(path, allocator, @enumFromInt(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(content);

    var node_id: []u8 = try allocator.dupe(u8, "");
    var node_type: NodeType = .artifact;
    var description: []u8 = try allocator.dupe(u8, "");
    var file_cid: []u8 = try allocator.dupe(u8, "");
    var created_at: i64 = 0;
    var tags: []u8 = try allocator.dupe(u8, "");
    var parents: []u8 = try allocator.dupe(u8, "");
    var version: []u8 = try allocator.dupe(u8, "1.0");

    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOf(u8, line, "=") orelse continue;
        const k = line[0..eq];
        const v = line[eq + 1 ..];
        if (std.mem.eql(u8, k, "id")) {
            allocator.free(node_id);
            node_id = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "type")) {
            node_type = NodeType.fromString(v) orelse .artifact;
        } else if (std.mem.eql(u8, k, "description")) {
            allocator.free(description);
            description = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "file_cid")) {
            allocator.free(file_cid);
            file_cid = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "created_at")) {
            created_at = std.fmt.parseInt(i64, v, 10) catch 0;
        } else if (std.mem.eql(u8, k, "tags")) {
            allocator.free(tags);
            tags = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "parents")) {
            allocator.free(parents);
            parents = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "version")) {
            allocator.free(version);
            version = try allocator.dupe(u8, v);
        }
    }

    return LineageNode{
        .id = node_id,
        .node_type = node_type,
        .description = description,
        .file_cid = file_cid,
        .created_at = created_at,
        .tags = tags,
        .parents = parents,
        .version = version,
    };
}

fn freeNode(allocator: std.mem.Allocator, node: LineageNode) void {
    allocator.free(node.id);
    allocator.free(node.description);
    allocator.free(node.file_cid);
    allocator.free(node.tags);
    allocator.free(node.parents);
    allocator.free(node.version);
}

pub fn lineageAdd(
    allocator: std.mem.Allocator,
    repo: *Repository,
    id: []const u8,
    node_type_str: []const u8,
    description: []const u8,
    file_path: ?[]const u8,
    tags: []const u8,
    version: []const u8,
) !void {
    const node_type = NodeType.fromString(node_type_str) orelse {
        std.debug.print("Unknown node type: {s}\n", .{node_type_str});
        std.debug.print("Valid types: dataset, script, model, experiment, artifact\n", .{});
        return;
    };

    const existing = try loadNode(allocator, repo, id);
    if (existing != null) {
        const e = existing.?;
        freeNode(allocator, e);
        std.debug.print("Error: Lineage node '{s}' already exists\n", .{id});
        std.debug.print("Use 'zev lineage link' to add relationships\n", .{});
        return;
    }

    var file_cid: []u8 = try allocator.dupe(u8, "");
    defer allocator.free(file_cid);

    if (file_path) |fp| {
        const file_data = std.fs.cwd().readFileAlloc(fp, allocator, @enumFromInt(100 * 1024 * 1024)) catch |err| {
            std.debug.print("Warning: Could not read file '{s}': {}\n", .{ fp, err });
            const node = LineageNode{
                .id = id,
                .node_type = node_type,
                .description = description,
                .file_cid = "",
                .created_at = (std.time.Instant.now() catch unreachable).timestamp.sec,
                .tags = tags,
                .parents = "",
                .version = version,
            };
            try saveNode(allocator, repo, node);
            std.debug.print("{s} Added lineage node '{s}' [{s}]\n", .{ node_type.icon(), id, node_type.toString() });
            return;
        };
        defer allocator.free(file_data);

        const content_cid = cid_mod.CID.fromBytes(file_data);
        allocator.free(file_cid);
        file_cid = try content_cid.toString(allocator);

        _ = try repo.store.put(file_data);
        std.debug.print("   Stored {s} in object store\n", .{fp});
    }

    const now = (std.time.Instant.now() catch unreachable).timestamp.sec;
    const node = LineageNode{
        .id = id,
        .node_type = node_type,
        .description = description,
        .file_cid = file_cid,
        .created_at = now,
        .tags = tags,
        .parents = "",
        .version = version,
    };
    try saveNode(allocator, repo, node);

    std.debug.print("{s} Added lineage node '{s}'\n", .{ node_type.icon(), id });
    std.debug.print("   Type:    {s}\n", .{node_type.toString()});
    if (description.len > 0)
        std.debug.print("   Desc:    {s}\n", .{description});
    if (file_cid.len > 0)
        std.debug.print("   CID:     {s}\n", .{file_cid[0..@min(16, file_cid.len)]});
    if (tags.len > 0)
        std.debug.print("   Tags:    {s}\n", .{tags});
    std.debug.print("   Version: {s}\n", .{version});
}

pub fn lineageLink(
    allocator: std.mem.Allocator,
    repo: *Repository,
    child_id: []const u8,
    parent_id: []const u8,
) !void {
    const parent = (try loadNode(allocator, repo, parent_id)) orelse {
        std.debug.print("Error: Parent node '{s}' not found\n", .{parent_id});
        return;
    };
    freeNode(allocator, parent);

    var child = (try loadNode(allocator, repo, child_id)) orelse {
        std.debug.print("Error: Child node '{s}' not found\n", .{child_id});
        return;
    };
    defer freeNode(allocator, child);

    const new_parents = if (child.parents.len == 0)
        try allocator.dupe(u8, parent_id)
    else
        try std.fmt.allocPrint(allocator, "{s},{s}", .{ child.parents, parent_id });
    defer allocator.free(new_parents);

    const updated = LineageNode{
        .id = child.id,
        .node_type = child.node_type,
        .description = child.description,
        .file_cid = child.file_cid,
        .created_at = child.created_at,
        .tags = child.tags,
        .parents = new_parents,
        .version = child.version,
    };
    try saveNode(allocator, repo, updated);

    std.debug.print("🔗 Linked: {s} -> {s}\n", .{ parent_id, child_id });
    std.debug.print("   {s} {s} derives from {s} {s}\n", .{
        child.node_type.icon(),  child_id,
        parent.node_type.icon(), parent_id,
    });
}

pub fn lineageShow(allocator: std.mem.Allocator, repo: *Repository, id: []const u8) !void {
    const node = (try loadNode(allocator, repo, id)) orelse {
        std.debug.print("Error: Node '{s}' not found\n", .{id});
        return;
    };
    defer freeNode(allocator, node);

    std.debug.print("\n{s} Lineage for: {s} (v{s})\n", .{ node.node_type.icon(), node.id, node.version });
    std.debug.print("   Type:    {s}\n", .{node.node_type.toString()});
    if (node.description.len > 0)
        std.debug.print("   Desc:    {s}\n", .{node.description});
    if (node.file_cid.len > 0)
        std.debug.print("   CID:     {s}\n", .{node.file_cid[0..@min(16, node.file_cid.len)]});
    if (node.tags.len > 0)
        std.debug.print("   Tags:    {s}\n", .{node.tags});

    if (node.parents.len > 0) {
        std.debug.print("\n   Provenance chain:\n", .{});
        try printAncestors(allocator, repo, id, 0, 10);
    } else {
        std.debug.print("\n   (Root node - no parents)\n", .{});
    }
    std.debug.print("\n", .{});
}

fn printAncestors(
    allocator: std.mem.Allocator,
    repo: *Repository,
    id: []const u8,
    depth: usize,
    max_depth: usize,
) !void {
    if (depth > max_depth) return;

    const node = (try loadNode(allocator, repo, id)) orelse return;
    defer freeNode(allocator, node);

    var indent_buf: [64]u8 = undefined;
    const indent_len = @min(depth * 3, 60);
    @memset(indent_buf[0..indent_len], ' ');
    const indent = indent_buf[0..indent_len];

    if (depth == 0) {
        std.debug.print("   {s}{s} {s} (v{s})\n", .{ indent, node.node_type.icon(), node.id, node.version });
    } else {
        std.debug.print("   {s}└─ {s} {s} (v{s})\n", .{ indent, node.node_type.icon(), node.id, node.version });
    }
    if (node.description.len > 0)
        std.debug.print("   {s}   {s}\n", .{ indent, node.description });

    if (node.parents.len > 0) {
        var parent_iter = std.mem.splitSequence(u8, node.parents, ",");
        while (parent_iter.next()) |parent_id| {
            const trimmed = std.mem.trim(u8, parent_id, " ");
            if (trimmed.len > 0) {
                try printAncestors(allocator, repo, trimmed, depth + 1, max_depth);
            }
        }
    }
}

pub fn lineageList(allocator: std.mem.Allocator, repo: *Repository) !void {
    const dir_path = try lineageDir(allocator, repo);
    defer allocator.free(dir_path);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        std.debug.print("No lineage nodes yet.\n", .{});
        std.debug.print("Add one with: zev lineage add <id> <type> <description>\n", .{});
        return;
    };
    defer dir.close();

    std.debug.print("🔗 Lineage Graph:\n\n", .{});

    var counts = [_]usize{0} ** 5;
    var total: usize = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        const node = (try loadNode(allocator, repo, entry.name)) orelse continue;
        defer freeNode(allocator, node);
        total += 1;

        const type_idx: usize = switch (node.node_type) {
            .dataset => 0,
            .script => 1,
            .model => 2,
            .experiment => 3,
            .artifact => 4,
        };
        counts[type_idx] += 1;

        std.debug.print("  {s} {s:<20} v{s:<6} ", .{ node.node_type.icon(), node.id, node.version });
        if (node.parents.len > 0) {
            std.debug.print("← {s}", .{node.parents});
        } else {
            std.debug.print("(root)", .{});
        }
        std.debug.print("\n", .{});
        if (node.description.len > 0)
            std.debug.print("     {s}\n", .{node.description});
    }

    if (total == 0) {
        std.debug.print("  No nodes yet.\n", .{});
        std.debug.print("  Add one: zev lineage add <id> <type> <description>\n", .{});
    } else {
        std.debug.print("\n  Nodes: {d} total  ({d} datasets, {d} scripts, {d} models, {d} experiments, {d} artifacts)\n", .{ total, counts[0], counts[1], counts[2], counts[3], counts[4] });
    }
}

pub fn lineageGraph(allocator: std.mem.Allocator, repo: *Repository) !void {
    const dir_path = try lineageDir(allocator, repo);
    defer allocator.free(dir_path);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        std.debug.print("No lineage nodes yet.\n", .{});
        return;
    };
    defer dir.close();

    std.debug.print("\n🔗 Lineage DAG:\n\n", .{});

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        const node = (try loadNode(allocator, repo, entry.name)) orelse continue;
        defer freeNode(allocator, node);

        if (node.parents.len == 0) {
            try printDescendants(allocator, repo, node.id, 0, 8);
            std.debug.print("\n", .{});
        }
    }
}

fn printDescendants(
    allocator: std.mem.Allocator,
    repo: *Repository,
    id: []const u8,
    depth: usize,
    max_depth: usize,
) !void {
    if (depth > max_depth) return;

    const node = (try loadNode(allocator, repo, id)) orelse return;
    defer freeNode(allocator, node);

    var indent_buf: [64]u8 = undefined;
    const indent_len = @min(depth * 3, 60);
    @memset(indent_buf[0..indent_len], ' ');
    const indent = indent_buf[0..indent_len];

    if (depth == 0) {
        std.debug.print("  {s}{s} {s} v{s}\n", .{ indent, node.node_type.icon(), node.id, node.version });
    } else {
        std.debug.print("  {s}└─► {s} {s} v{s}\n", .{ indent, node.node_type.icon(), node.id, node.version });
    }
    if (node.description.len > 0)
        std.debug.print("  {s}    {s}\n", .{ indent, node.description });

    const dir_path = try lineageDir(allocator, repo);
    defer allocator.free(dir_path);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var child_iter = dir.iterate();
    while (try child_iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, id)) continue;

        const child = (try loadNode(allocator, repo, entry.name)) orelse continue;
        defer freeNode(allocator, child);

        var parent_iter = std.mem.splitSequence(u8, child.parents, ",");
        while (parent_iter.next()) |pid| {
            const trimmed = std.mem.trim(u8, pid, " ");
            if (std.mem.eql(u8, trimmed, id)) {
                try printDescendants(allocator, repo, child.id, depth + 1, max_depth);
                break;
            }
        }
    }
}

pub fn lineageProvenance(allocator: std.mem.Allocator, repo: *Repository, cid_prefix: []const u8) !void {
    const dir_path = try lineageDir(allocator, repo);
    defer allocator.free(dir_path);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        std.debug.print("No lineage nodes yet.\n", .{});
        return;
    };
    defer dir.close();

    std.debug.print("🔍 Searching for CID prefix: {s}\n\n", .{cid_prefix});
    var found: usize = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        const node = (try loadNode(allocator, repo, entry.name)) orelse continue;
        defer freeNode(allocator, node);

        if (std.mem.startsWith(u8, node.file_cid, cid_prefix)) {
            found += 1;
            std.debug.print("{s} Found: {s}\n", .{ node.node_type.icon(), node.id });
            std.debug.print("   CID:  {s}\n", .{node.file_cid});
            std.debug.print("   Type: {s}\n", .{node.node_type.toString()});
            if (node.description.len > 0)
                std.debug.print("   Desc: {s}\n", .{node.description});
        }
    }

    if (found == 0) {
        std.debug.print("No lineage node found with CID starting with '{s}'\n", .{cid_prefix});
    }
}

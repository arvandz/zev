const std = @import("std");
const Repository = @import("repository.zig").Repository;
const branch_mod = @import("branch.zig");
const cid_mod = @import("cid.zig");
const commit_mod = @import("commit.zig");

pub const Experiment = struct {
    name: []const u8,
    description: []const u8,
    hypothesis: []const u8,
    status: []const u8,
    branch: []const u8,
    created_at: i64,
    tags: []const u8,
};

fn experimentsDir(allocator: std.mem.Allocator, repo: *Repository) ![]u8 {
    const dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "experiments" });
    try std.Io.Dir.cwd().makePath(dir);
    return dir;
}

fn sanitizeName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const buf = try allocator.dupe(u8, name);
    for (buf) |*c| {
        if (c.* == '/') c.* = '-';
    }
    return buf;
}

fn experimentPath(allocator: std.mem.Allocator, repo: *Repository, name: []const u8) ![]u8 {
    const dir = try experimentsDir(allocator, repo);
    defer allocator.free(dir);
    const safe = try sanitizeName(allocator, name);
    defer allocator.free(safe);
    return try std.fs.path.join(allocator, &.{ dir, safe });
}

fn saveExperiment(allocator: std.mem.Allocator, repo: *Repository, exp: Experiment) !void {
    const path = try experimentPath(allocator, repo, exp.name);
    defer allocator.free(path);

    const file = try std.Io.Dir.cwd().createFile(path, .{});
    defer file.close(io);

    const content = try std.fmt.allocPrint(allocator, "name={s}\ndescription={s}\nhypothesis={s}\nstatus={s}\nbranch={s}\ncreated_at={d}\ntags={s}\n", .{ exp.name, exp.description, exp.hypothesis, exp.status, exp.branch, exp.created_at, exp.tags });
    defer allocator.free(content);
    try file.writeAll(content);
}

fn loadExperiment(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, name: []const u8) !?Experiment {
    const path = try experimentPath(allocator, repo, name);
    defer allocator.free(path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(content);

    var exp_name: []u8 = try allocator.dupe(u8, "");
    var description: []u8 = try allocator.dupe(u8, "");
    var hypothesis: []u8 = try allocator.dupe(u8, "");
    var status: []u8 = try allocator.dupe(u8, "running");
    var exp_branch: []u8 = try allocator.dupe(u8, "");
    var created_at: i64 = 0;
    var tags: []u8 = try allocator.dupe(u8, "");

    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOf(u8, line, "=") orelse continue;
        const k = line[0..eq];
        const v = line[eq + 1 ..];
        if (std.mem.eql(u8, k, "name")) {
            allocator.free(exp_name);
            exp_name = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "description")) {
            allocator.free(description);
            description = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "hypothesis")) {
            allocator.free(hypothesis);
            hypothesis = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "status")) {
            allocator.free(status);
            status = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "branch")) {
            allocator.free(exp_branch);
            exp_branch = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "created_at")) {
            created_at = std.fmt.parseInt(i64, v, 10) catch 0;
        } else if (std.mem.eql(u8, k, "tags")) {
            allocator.free(tags);
            tags = try allocator.dupe(u8, v);
        }
    }

    return Experiment{
        .name = exp_name,
        .description = description,
        .hypothesis = hypothesis,
        .status = status,
        .branch = exp_branch,
        .created_at = created_at,
        .tags = tags,
    };
}

fn freeExperiment(allocator: std.mem.Allocator, exp: Experiment) void {
    allocator.free(exp.name);
    allocator.free(exp.description);
    allocator.free(exp.hypothesis);
    allocator.free(exp.status);
    allocator.free(exp.branch);
    allocator.free(exp.tags);
}

pub fn experimentStart(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    name: []const u8,
    description: []const u8,
    hypothesis: []const u8,
    tags: []const u8,
) !void {
    for (name) |c| {
        if (c == ' ' or c == '/') {
            std.debug.print("Error: Experiment name cannot contain spaces or slashes\n", .{});
            return;
        }
    }

    const existing = try loadExperiment(allocator, repo, name);
    if (existing != null) {
        const e = existing.?;
        freeExperiment(allocator, e);
        std.debug.print("Error: Experiment '{s}' already exists\n", .{name});
        return;
    }

    const exp_refs_dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "heads", "exp" });
    defer allocator.free(exp_refs_dir);
    try std.Io.Dir.cwd().makePath(exp_refs_dir);

    const branch_name = try std.fmt.allocPrint(allocator, "exp/{s}", .{name});
    defer allocator.free(branch_name);

    branch_mod.createBranch(allocator, repo, branch_name) catch |err| {
        if (err == error.BranchAlreadyExists) {
            std.debug.print("Warning: Branch '{s}' already exists, reusing\n", .{branch_name});
        } else return err;
    };

    const now = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);

    const exp = Experiment{
        .name = name,
        .description = description,
        .hypothesis = hypothesis,
        .status = "running",
        .branch = branch_name,
        .created_at = now,
        .tags = tags,
    };

    try saveExperiment(allocator, repo, exp);

    branch_mod.checkoutBranch(allocator, repo, branch_name) catch |err| {
        std.debug.print("Warning: Could not switch to experiment branch: {}\n", .{err});
    };

    std.debug.print("🧪 Experiment '{s}' started!\n", .{name});
    std.debug.print("   Branch:      {s}\n", .{branch_name});
    if (description.len > 0)
        std.debug.print("   Description: {s}\n", .{description});
    if (hypothesis.len > 0)
        std.debug.print("   Hypothesis:  {s}\n", .{hypothesis});
    if (tags.len > 0)
        std.debug.print("   Tags:        {s}\n", .{tags});
    std.debug.print("\n💡 You are now on branch '{s}'\n", .{branch_name});
    std.debug.print("   Commit your changes, set metrics with 'zev metrics set'\n", .{});
    std.debug.print("   Then: zev experiment complete {s}\n", .{name});
}

pub fn experimentComplete(allocator: std.mem.Allocator, repo: *Repository, name: []const u8, notes: []const u8) !void {
    const exp = (try loadExperiment(allocator, repo, name)) orelse {
        std.debug.print("Error: Experiment '{s}' not found\n", .{name});
        return;
    };
    defer freeExperiment(allocator, exp);

    const updated = Experiment{
        .name = exp.name,
        .description = exp.description,
        .hypothesis = exp.hypothesis,
        .status = "completed",
        .branch = exp.branch,
        .created_at = exp.created_at,
        .tags = exp.tags,
    };
    try saveExperiment(allocator, repo, updated);

    if (notes.len > 0) {
        const results_path = try experimentPath(allocator, repo, try std.fmt.allocPrint(allocator, "{s}.results", .{name}));
        defer allocator.free(results_path);
        const f = try std.Io.Dir.cwd().createFile(results_path, .{});
        defer f.close(io);
        try f.writeAll(notes);
    }

    std.debug.print("✅ Experiment '{s}' marked as completed\n", .{name});
    if (notes.len > 0)
        std.debug.print("   Notes: {s}\n", .{notes});
    std.debug.print("   Branch '{s}' preserved for review\n", .{exp.branch});
    std.debug.print("   Use 'zev metrics show' to see final metrics\n", .{});
}

pub fn experimentAbandon(allocator: std.mem.Allocator, repo: *Repository, name: []const u8, reason: []const u8) !void {
    const exp = (try loadExperiment(allocator, repo, name)) orelse {
        std.debug.print("Error: Experiment '{s}' not found\n", .{name});
        return;
    };
    defer freeExperiment(allocator, exp);

    const updated = Experiment{
        .name = exp.name,
        .description = exp.description,
        .hypothesis = exp.hypothesis,
        .status = "abandoned",
        .branch = exp.branch,
        .created_at = exp.created_at,
        .tags = exp.tags,
    };
    try saveExperiment(allocator, repo, updated);

    std.debug.print("🗑️  Experiment '{s}' abandoned\n", .{name});
    if (reason.len > 0)
        std.debug.print("   Reason: {s}\n", .{reason});
}

pub fn experimentShow(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, name: []const u8) !void {
    const exp = (try loadExperiment(allocator, repo, name)) orelse {
        std.debug.print("Error: Experiment '{s}' not found\n", .{name});
        return;
    };
    defer freeExperiment(allocator, exp);

    const status_icon: []const u8 = if (std.mem.eql(u8, exp.status, "running")) "🔄" else if (std.mem.eql(u8, exp.status, "completed")) "✅" else "🗑️ ";

    std.debug.print("\n{s} Experiment: {s}\n", .{ status_icon, exp.name });
    std.debug.print("   ----------------------------------------\n", .{});
    std.debug.print("   Status:      {s}\n", .{exp.status});
    std.debug.print("   Branch:      {s}\n", .{exp.branch});
    if (exp.description.len > 0)
        std.debug.print("   Description: {s}\n", .{exp.description});
    if (exp.hypothesis.len > 0)
        std.debug.print("   Hypothesis:  {s}\n", .{exp.hypothesis});
    if (exp.tags.len > 0)
        std.debug.print("   Tags:        {s}\n", .{exp.tags});
    std.debug.print("   Created:     {d}\n", .{exp.created_at});

    const results_path = try experimentPath(allocator, repo, try std.fmt.allocPrint(allocator, "{s}.results", .{name}));
    defer allocator.free(results_path);
    const notes = std.Io.Dir.cwd().readFileAlloc(io, results_path, allocator, .limited(64 * 1024)) catch null;
    defer if (notes) |n| allocator.free(n);
    if (notes) |n| {
        std.debug.print("   Results:     {s}\n", .{n});
    }
    std.debug.print("\n", .{});
}

pub fn experimentList(allocator: std.mem.Allocator, repo: *Repository) !void {
    const dir_path = try experimentsDir(allocator, repo);
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        std.debug.print("No experiments yet.\n", .{});
        std.debug.print("Start one with: zev experiment start <name> [description]\n", .{});
        return;
    };
    defer dir.close(io);

    std.debug.print("🧪 Experiments:\n\n", .{});

    var running: usize = 0;
    var completed: usize = 0;
    var abandoned: usize = 0;
    var found: usize = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".results")) continue;
        if (entry.kind != .file) continue;

        const exp = (try loadExperiment(allocator, repo, entry.name)) orelse continue;
        defer freeExperiment(allocator, exp);

        found += 1;
        const icon: []const u8 = if (std.mem.eql(u8, exp.status, "running")) "🔄" else if (std.mem.eql(u8, exp.status, "completed")) "✅" else "🗑️ ";

        if (std.mem.eql(u8, exp.status, "running")) running += 1 else if (std.mem.eql(u8, exp.status, "completed")) completed += 1 else abandoned += 1;

        std.debug.print("  {s} {s:<25} [{s}]", .{ icon, exp.name, exp.branch });
        if (exp.tags.len > 0)
            std.debug.print("  tags: {s}", .{exp.tags});
        std.debug.print("\n", .{});
        if (exp.description.len > 0)
            std.debug.print("     {s}\n", .{exp.description});
    }

    if (found == 0) {
        std.debug.print("  No experiments yet.\n", .{});
        std.debug.print("  Start one with: zev experiment start <name> [description]\n", .{});
    } else {
        std.debug.print("\n  Summary: {d} running, {d} completed, {d} abandoned\n", .{ running, completed, abandoned });
    }
}

pub fn experimentCompare(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, name_a: []const u8, name_b: []const u8) !void {
    const metrics_mod = @import("metrics.zig");

    const exp_a = (try loadExperiment(allocator, repo, name_a)) orelse {
        std.debug.print("Error: Experiment '{s}' not found\n", .{name_a});
        return;
    };
    defer freeExperiment(allocator, exp_a);

    const exp_b = (try loadExperiment(allocator, repo, name_b)) orelse {
        std.debug.print("Error: Experiment '{s}' not found\n", .{name_b});
        return;
    };
    defer freeExperiment(allocator, exp_b);

    const refs_dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "heads" });
    defer allocator.free(refs_dir);

    const path_a = try std.fs.path.join(allocator, &.{ refs_dir, exp_a.branch });
    defer allocator.free(path_a);
    const path_b = try std.fs.path.join(allocator, &.{ refs_dir, exp_b.branch });
    defer allocator.free(path_b);

    const hash_a = std.Io.Dir.cwd().readFileAlloc(io, path_a, allocator, .limited(1024)) catch {
        std.debug.print("Cannot read branch head for '{s}'\n", .{name_a});
        return;
    };
    defer allocator.free(hash_a);

    const hash_b = std.Io.Dir.cwd().readFileAlloc(io, path_b, allocator, .limited(1024)) catch {
        std.debug.print("Cannot read branch head for '{s}'\n", .{name_b});
        return;
    };
    defer allocator.free(hash_b);

    const ha = std.mem.trim(u8, hash_a, " \n\r\t");
    const hb = std.mem.trim(u8, hash_b, " \n\r\t");

    std.debug.print("🧪 Comparing experiments:\n", .{});
    std.debug.print("   A: {s} (branch: {s})\n", .{ name_a, exp_a.branch });
    std.debug.print("   B: {s} (branch: {s})\n\n", .{ name_b, exp_b.branch });

    try metrics_mod.compareMetrics(allocator, repo, ha, hb);
}

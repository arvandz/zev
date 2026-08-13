const std = @import("std");

const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const RED = "\x1b[31m";
const ORANGE = "\x1b[38;5;208m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const CYAN = "\x1b[36m";
const MAGENTA = "\x1b[35m";

fn httpGet(allocator: std.mem.Allocator, io: std.Io, url: []const u8, token: ?[]const u8) !struct { status: u32, body: []u8 } {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "curl", "-s", "-w", "\n__STATUS__%{http_code}" });

    var auth_header: ?[]u8 = null;
    defer if (auth_header) |h| allocator.free(h);
    if (token) |t| {
        auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{t});
        try argv.appendSlice(allocator, &.{ "-H", auth_header.? });
    }
    try argv.append(allocator, url);

    var child = try std.process.spawn(io, .{ .argv = argv.items, .stdout = .pipe, .stderr = .pipe });

    var out_buf: [1024 * 1024]u8 = undefined;
    var scratch: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &scratch);
    const bytes_read = reader.interface.readSliceShort(&out_buf) catch 0;
    const stdout = try allocator.dupe(u8, out_buf[0..bytes_read]);
    _ = try child.wait(io);

    var status: u32 = 0;
    var body: []u8 = stdout;
    if (std.mem.lastIndexOf(u8, stdout, "\n__STATUS__")) |idx| {
        status = std.fmt.parseInt(u32, stdout[idx + 11 ..], 10) catch 0;
        body = try allocator.dupe(u8, stdout[0..idx]);
        allocator.free(stdout);
    }
    return .{ .status = status, .body = body };
}

fn isInCycle(cycles: std.json.Array, node_id: []const u8) bool {
    for (cycles.items) |cycle| {
        if (cycle != .array) continue;
        for (cycle.array.items) |member| {
            if (member != .string) continue;
            if (std.mem.eql(u8, member.string, node_id)) return true;
        }
    }
    return false;
}

pub fn cmdDependencyGraph(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    owner: []const u8,
    repo: []const u8,
    commit_hash: []const u8,
    token: ?[]const u8,
) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/v1/repos/{s}/{s}/dependency-graph/{s}", .{ base_url, owner, repo, commit_hash });
    defer allocator.free(url);

    std.debug.print("{s}{s}Resolving AI dependency graph...{s}\n\n", .{ BOLD, CYAN, RESET });

    const result = httpGet(allocator, io, url, token) catch |err| {
        std.debug.print("{s}Request failed: {}{s}\n\n", .{ RED, err, RESET });
        return;
    };
    defer allocator.free(result.body);

    if (result.status != 200) {
        std.debug.print("{s}Server returned {d}: {s}{s}\n\n", .{ RED, result.status, result.body, RESET });
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.body, .{}) catch {
        std.debug.print("{s}Could not parse response{s}\n\n", .{ RED, RESET });
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return;
    const obj = parsed.value.object;

    const nodes_val = obj.get("nodes") orelse return;
    if (nodes_val != .array) return;
    const nodes = nodes_val.array;

    if (nodes.items.len == 0) {
        std.debug.print("{s}No dependency graph found for this commit (no agent manifest, or no dependencies declared).{s}\n\n", .{ DIM, RESET });
        return;
    }

    const edges_val = obj.get("edges") orelse return;
    if (edges_val != .array) return;
    const edges = edges_val.array;

    const cycles_val = obj.get("cycles") orelse return;
    if (cycles_val != .array) return;
    const cycles = cycles_val.array;

    std.debug.print("{s}================================================={s}\n", .{ MAGENTA, RESET });
    std.debug.print("  {s}{s}AI Supply Chain Dependency Graph{s}\n", .{ BOLD, MAGENTA, RESET });
    std.debug.print("{s}================================================={s}\n\n", .{ MAGENTA, RESET });

    std.debug.print("  {s}Nodes ({d}){s}\n", .{ BOLD, nodes.items.len, RESET });
    for (nodes.items) |n| {
        if (n != .object) continue;
        const id = if (n.object.get("id")) |v| v.string else "?";
        const icon = if (n.object.get("icon")) |v| v.string else "";
        const in_cycle = isInCycle(cycles, id);
        const color: []const u8 = if (in_cycle) ORANGE else GREEN;
        const marker: []const u8 = if (in_cycle) " [CYCLE]" else "";
        std.debug.print("    {s}{s} {s}{s}{s}\n", .{ color, icon, id, marker, RESET });
    }

    std.debug.print("\n  {s}Edges ({d}){s}\n", .{ BOLD, edges.items.len, RESET });
    for (edges.items) |e| {
        if (e != .object) continue;
        const from = if (e.object.get("from")) |v| v.string else "?";
        const to = if (e.object.get("to")) |v| v.string else "?";
        std.debug.print("    {s}{s}{s} {s}-->{s} {s}\n", .{ DIM, from, RESET, CYAN, RESET, to });
    }

    if (cycles.items.len > 0) {
        std.debug.print("\n  {s}{s}\xe2\x9a\xa0  CIRCULAR DEPENDENCIES DETECTED{s}\n", .{ BOLD, ORANGE, RESET });
        for (cycles.items, 0..) |cycle, i| {
            if (cycle != .array) continue;
            std.debug.print("    {s}Cycle {d}:{s} ", .{ ORANGE, i + 1, RESET });
            for (cycle.array.items, 0..) |member, j| {
                if (j > 0) std.debug.print("{s} -> {s}", .{ ORANGE, RESET });
                if (member == .string) std.debug.print("{s}{s}{s}", .{ ORANGE, member.string, RESET });
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("\n  {s}This graph cannot be safely deployed until the cycle is broken.{s}\n\n", .{ YELLOW, RESET });
    } else {
        if (obj.get("deployment_order")) |order_val| {
            if (order_val == .array) {
                std.debug.print("\n  {s}{s}\xe2\x9c\x93 Safe deployment order{s}\n", .{ BOLD, GREEN, RESET });
                for (order_val.array.items, 0..) |item, i| {
                    if (item != .string) continue;
                    std.debug.print("    {s}{d}.{s} {s}\n", .{ GREEN, i + 1, RESET, item.string });
                }
            }
        }
        std.debug.print("\n", .{});
    }
}

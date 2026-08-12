const std = @import("std");

const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const RED = "\x1b[31m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const BLUE = "\x1b[34m";
const MAGENTA = "\x1b[35m";
const CYAN = "\x1b[36m";

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

fn typeColor(t: []const u8) []const u8 {
    if (std.mem.eql(u8, t, "model")) return MAGENTA;
    if (std.mem.eql(u8, t, "dataset")) return GREEN;
    if (std.mem.eql(u8, t, "agent")) return CYAN;
    return BLUE;
}

pub fn cmdRepoDashboard(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/v1/repos/{s}/{s}/dashboard", .{ base_url, owner, repo });
    defer allocator.free(url);

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

    const repo_owner = if (obj.get("owner")) |v| v.string else owner;
    const repo_name = if (obj.get("name")) |v| v.string else repo;
    const visibility = if (obj.get("visibility")) |v| v.string else "?";
    const repo_type = if (obj.get("type")) |v| v.string else "code";
    const icon = if (obj.get("icon")) |v| v.string else "";
    const label = if (obj.get("label")) |v| v.string else "Code";
    const stars = if (obj.get("stars")) |v| v.integer else 0;
    const starred_by_you = if (obj.get("starred_by_you")) |v| v.bool else false;
    const branch_count = if (obj.get("branch_count")) |v| v.integer else 0;
    const collaborator_count = if (obj.get("collaborator_count")) |v| v.integer else 0;
    const open_prs = if (obj.get("open_pull_requests")) |v| v.integer else 0;
    const merged_prs = if (obj.get("merged_pull_requests")) |v| v.integer else 0;
    const open_issues = if (obj.get("open_issues")) |v| v.integer else 0;
    const closed_issues = if (obj.get("closed_issues")) |v| v.integer else 0;

    const tcolor = typeColor(repo_type);
    const vis_icon: []const u8 = if (std.mem.eql(u8, visibility, "public")) "\xf0\x9f\x8c\x90" else "\xf0\x9f\x94\x92";

    std.debug.print("\n{s}================================================={s}\n", .{ tcolor, RESET });
    std.debug.print("{s} {s} {s}{s} {s}/{s}{s}\n", .{ tcolor, RESET, icon, BOLD, repo_owner, repo_name, RESET });
    std.debug.print("{s} {s}  {s} {s}   {s}{s}{s}\n", .{ tcolor, RESET, vis_icon, visibility, tcolor, label, RESET });
    std.debug.print("{s}================================================={s}\n\n", .{ tcolor, RESET });

    const star_color: []const u8 = if (starred_by_you) YELLOW else DIM;
    const star_icon: []const u8 = if (starred_by_you) "\xe2\x98\x85" else "\xe2\x98\x86";
    std.debug.print("  {s}{s} {d} star(s){s}{s}\n", .{ star_color, star_icon, stars, if (starred_by_you) " (you starred this)" else "", RESET });
    std.debug.print("  {s}\xf0\x9f\x8c\xbf {d} branch(es){s}\n", .{ CYAN, branch_count, RESET });
    std.debug.print("  {s}\xf0\x9f\x91\xa5 {d} collaborator(s){s}\n\n", .{ BLUE, collaborator_count, RESET });

    std.debug.print("  {s}{s}Pull Requests{s}\n", .{ BOLD, GREEN, RESET });
    std.debug.print("    {s}open:   {d}{s}\n", .{ GREEN, open_prs, RESET });
    std.debug.print("    {s}merged: {d}{s}\n\n", .{ MAGENTA, merged_prs, RESET });

    std.debug.print("  {s}{s}Issues{s}\n", .{ BOLD, YELLOW, RESET });
    std.debug.print("    {s}open:   {d}{s}\n", .{ YELLOW, open_issues, RESET });
    std.debug.print("    {s}closed: {d}{s}\n\n", .{ DIM, closed_issues, RESET });

    const branches_val = obj.get("branches");
    if (branches_val) |bv| {
        if (bv == .array and bv.array.items.len > 0) {
            std.debug.print("  {s}{s}Branches{s}\n", .{ BOLD, CYAN, RESET });
            for (bv.array.items) |b| {
                if (b == .string) {
                    std.debug.print("    {s}\xf0\x9f\x8c\xbf {s}{s}\n", .{ CYAN, b.string, RESET });
                }
            }
            std.debug.print("\n", .{});
        }
    }
}

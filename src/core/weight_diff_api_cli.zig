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
const WHITE = "\x1b[37m";
const BG_MAGENTA = "\x1b[45m";

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

    var out_buf: [4 * 1024 * 1024]u8 = undefined;
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

fn cosineBar(cosine: f64, buf: []u8) []const u8 {
    const width = 20;
    const filled: usize = @intFromFloat(@max(0.0, @min(1.0, cosine)) * @as(f64, width));
    var i: usize = 0;
    var pos: usize = 0;
    buf[pos] = '[';
    pos += 1;
    while (i < width) : (i += 1) {
        buf[pos] = if (i < filled) '#' else '-';
        pos += 1;
    }
    buf[pos] = ']';
    pos += 1;
    return buf[0..pos];
}

fn cosineColor(cosine: f64) []const u8 {
    if (cosine > 0.999) return GREEN;
    if (cosine > 0.99) return YELLOW;
    return RED;
}

fn changeIcon(change: []const u8) []const u8 {
    if (std.mem.eql(u8, change, "added")) return "➕";
    if (std.mem.eql(u8, change, "removed")) return "➖";
    if (std.mem.eql(u8, change, "modified")) return "🔄";
    return "✅";
}

fn changeColor(change: []const u8) []const u8 {
    if (std.mem.eql(u8, change, "added")) return GREEN;
    if (std.mem.eql(u8, change, "removed")) return RED;
    if (std.mem.eql(u8, change, "modified")) return YELLOW;
    return DIM;
}

pub fn cmdWeightDiffApi(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    owner: []const u8,
    repo: []const u8,
    branch: []const u8,
    hash_a: []const u8,
    hash_b: []const u8,
    filename: []const u8,
    token: ?[]const u8,
) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/v1/repos/{s}/{s}/branches/{s}/weight-diff/{s}/{s}/{s}", .{
        base_url, owner, repo, branch, hash_a, hash_b, filename,
    });
    defer allocator.free(url);

    std.debug.print("{s}{s}🧬 Fetching weight diff...{s}\n\n", .{ BOLD, CYAN, RESET });

    const result = httpGet(allocator, io, url, token) catch |err| {
        std.debug.print("{s}❌ Request failed: {}{s}\n\n", .{ RED, err, RESET });
        return;
    };
    defer allocator.free(result.body);

    if (result.status != 200) {
        std.debug.print("{s}❌ Server returned {d}: {s}{s}\n\n", .{ RED, result.status, result.body, RESET });
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.body, .{}) catch {
        std.debug.print("{s}❌ Could not parse response{s}\n\n", .{ RED, RESET });
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return;
    const obj = parsed.value.object;

    const file = if (obj.get("file")) |v| v.string else filename;
    const format_a = if (obj.get("format_a")) |v| v.string else "?";
    const format_b = if (obj.get("format_b")) |v| v.string else "?";
    const total_params_b = if (obj.get("total_params_b")) |v| v.integer else 0;
    const total_bytes_b = if (obj.get("total_bytes_b")) |v| v.integer else 0;
    const arch_changed = if (obj.get("arch_changed")) |v| v.bool else false;

    std.debug.print("{s}╔══════════════════════════════════════════════════════════════╗{s}\n", .{ MAGENTA, RESET });
    std.debug.print("{s}║{s} {s}🧬 WEIGHT DIFF{s}  {s}{s}{s}\n", .{ MAGENTA, RESET, BOLD, RESET, DIM, file, RESET });
    std.debug.print("{s}╚══════════════════════════════════════════════════════════════╝{s}\n\n", .{ MAGENTA, RESET });

    std.debug.print("   {s}📄 Format:{s}  {s} → {s}\n", .{ CYAN, RESET, format_a, format_b });
    std.debug.print("   {s}🔢 Params:{s}  {d}\n", .{ CYAN, RESET, total_params_b });
    std.debug.print("   {s}💾 Bytes:{s}   {d}\n", .{ CYAN, RESET, total_bytes_b });

    if (arch_changed) {
        std.debug.print("   {s}⚠️  Architecture changed{s}\n", .{ YELLOW, RESET });
    } else {
        std.debug.print("   {s}✅ Architecture unchanged{s}\n", .{ GREEN, RESET });
    }

    std.debug.print("\n{s}─────────────────────────────────────────────────────────────────{s}\n\n", .{ DIM, RESET });

    const tensors = if (obj.get("tensors")) |v| v.array.items else &[_]std.json.Value{};

    for (tensors) |tv| {
        if (tv != .object) continue;
        const t = tv.object;
        const name = if (t.get("name")) |v| v.string else "?";
        const change = if (t.get("change")) |v| v.string else "unchanged";
        const dtype_a = if (t.get("dtype_a")) |v| v.string else "?";
        const dtype_b = if (t.get("dtype_b")) |v| v.string else "?";
        const cosine = if (t.get("cosine_sim")) |v| v.float else 1.0;
        const norm_delta = if (t.get("norm_delta_pct")) |v| v.float else 0.0;
        const params_b = if (t.get("params_b")) |v| v.integer else 0;

        const icon = changeIcon(change);
        const color = changeColor(change);
        var bar_buf: [32]u8 = undefined;
        const bar = cosineBar(cosine, &bar_buf);
        const cos_color = cosineColor(cosine);

        std.debug.print("  {s} {s}{s}{s}\n", .{ icon, color, name, RESET });
        std.debug.print("      {s}dtype:{s} {s} → {s}    {s}params:{s} {d}\n", .{ DIM, RESET, dtype_a, dtype_b, DIM, RESET, params_b });

        if (std.mem.eql(u8, change, "modified") or std.mem.eql(u8, change, "unchanged")) {
            const sign_str: []const u8 = if (norm_delta >= 0) "+" else "";
            std.debug.print("      {s}cosine:{s} {s}{s} {d:.4}{s}   {s}Δnorm:{s} {s}{s}{d:.3}%{s}\n", .{
                DIM, RESET, cos_color, bar, cosine, RESET,
                DIM, RESET, if (@abs(norm_delta) > 5.0) YELLOW else DIM, sign_str, norm_delta, RESET,
            });
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("{s}─────────────────────────────────────────────────────────────────{s}\n", .{ DIM, RESET });
    std.debug.print("{s}✨ Diff complete — {d} tensor(s) analyzed{s}\n\n", .{ BOLD, tensors.len, RESET });
}

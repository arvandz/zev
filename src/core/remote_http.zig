const std = @import("std");
const Repository = @import("repository.zig").Repository;

const HttpResult = struct { status: u32, body: []u8 };

fn httpPostBinary(allocator: std.mem.Allocator, io: std.Io, url: []const u8, token: []const u8, data: []const u8) !HttpResult {
    const tmp_path = "/tmp/zev_push_object.bin";
    const tmp_file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    var tmp_buf: [65536]u8 = undefined;
    var tmp_writer = tmp_file.writer(io, &tmp_buf);
    try tmp_writer.interface.writeAll(data);
    try tmp_writer.flush();
    tmp_file.close(io);

    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{token});
    defer allocator.free(auth_header);
    const data_arg = try std.fmt.allocPrint(allocator, "@{s}", .{tmp_path});
    defer allocator.free(data_arg);

    var child = try std.process.spawn(io, .{
        .argv = &.{
            "curl", "-s", "-w", "\n__STATUS__%{http_code}",
            "-X", "POST",
            "-H", auth_header,
            "--data-binary", data_arg,
            url,
        },
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var out_buf: [65536]u8 = undefined;
    var child_scratch: [4096]u8 = undefined;
    var child_reader = child.stdout.?.reader(io, &child_scratch);
    const bytes_read = child_reader.interface.readSliceShort(&out_buf) catch 0;
    const stdout = try allocator.dupe(u8, out_buf[0..bytes_read]);
    _ = try child.wait(io);

    return parseStatusBody(allocator, stdout);
}

fn httpPutJson(allocator: std.mem.Allocator, io: std.Io, url: []const u8, token: []const u8, json: []const u8) !HttpResult {
    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{token});
    defer allocator.free(auth_header);

    var child = try std.process.spawn(io, .{
        .argv = &.{
            "curl", "-s", "-w", "\n__STATUS__%{http_code}",
            "-X", "PUT",
            "-H", "Content-Type: application/json",
            "-H", auth_header,
            "-d", json,
            url,
        },
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var out_buf: [65536]u8 = undefined;
    var child_scratch: [4096]u8 = undefined;
    var child_reader = child.stdout.?.reader(io, &child_scratch);
    const bytes_read = child_reader.interface.readSliceShort(&out_buf) catch 0;
    const stdout = try allocator.dupe(u8, out_buf[0..bytes_read]);
    _ = try child.wait(io);

    return parseStatusBody(allocator, stdout);
}

fn httpGetBinary(allocator: std.mem.Allocator, io: std.Io, url: []const u8, token: ?[]const u8) !HttpResult {
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

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var out_buf: [8 * 1024 * 1024]u8 = undefined;
    var child_scratch: [4096]u8 = undefined;
    var child_reader = child.stdout.?.reader(io, &child_scratch);
    const bytes_read = child_reader.interface.readSliceShort(&out_buf) catch 0;
    const stdout = try allocator.dupe(u8, out_buf[0..bytes_read]);
    _ = try child.wait(io);

    return parseStatusBody(allocator, stdout);
}

fn parseStatusBody(allocator: std.mem.Allocator, stdout: []u8) !HttpResult {
    var status: u32 = 0;
    var body: []u8 = stdout;
    if (std.mem.lastIndexOf(u8, stdout, "\n__STATUS__")) |idx| {
        const status_str = stdout[idx + 11 ..];
        status = std.fmt.parseInt(u32, status_str, 10) catch 0;
        body = try allocator.dupe(u8, stdout[0..idx]);
        allocator.free(stdout);
    }
    return .{ .status = status, .body = body };
}

fn jsonGetString(allocator: std.mem.Allocator, json_text: []const u8, key: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const val = parsed.value.object.get(key) orelse return null;
    if (val != .string) return null;
    return try allocator.dupe(u8, val.string);
}

pub const ApiTarget = struct {
    base_url: []u8,
    owner: []u8,
    repo_name: []u8,

    pub fn deinit(self: ApiTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        allocator.free(self.owner);
        allocator.free(self.repo_name);
    }
};

pub fn parseZevApiUrl(allocator: std.mem.Allocator, url: []const u8) !?ApiTarget {
    const prefix = "zevapi://";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const rest = url[prefix.len..];

    const first_slash = std.mem.indexOf(u8, rest, "/") orelse return null;
    const host_part = rest[0..first_slash];
    const path_part = rest[first_slash + 1 ..];

    var path_it = std.mem.splitScalar(u8, path_part, '/');
    const owner = path_it.next() orelse return null;
    const repo_name = path_it.next() orelse return null;

    return ApiTarget{
        .base_url = try std.fmt.allocPrint(allocator, "http://{s}", .{host_part}),
        .owner = try allocator.dupe(u8, owner),
        .repo_name = try allocator.dupe(u8, repo_name),
    };
}

fn collectAncestorCommits(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_path: []const u8,
    start_hash: []const u8,
    out: *std.ArrayList([]u8),
    seen: *std.StringHashMap(void),
) !void {
    if (seen.contains(start_hash)) return;

    const obj_path = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "objects", start_hash });
    defer allocator.free(obj_path);

    const data = std.Io.Dir.cwd().readFileAlloc(io, obj_path, allocator, .limited(64 * 1024)) catch return;
    defer allocator.free(data);

    const hash_owned = try allocator.dupe(u8, start_hash);
    try seen.put(hash_owned, {});
    try out.append(allocator, try allocator.dupe(u8, start_hash));

    var lines = std.mem.splitSequence(u8, data, "\n");
    var tree_hash: ?[]const u8 = null;
    var parent_hash: ?[]const u8 = null;

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "tree ")) tree_hash = line[5..];
        if (std.mem.startsWith(u8, line, "parent ")) parent_hash = line[7..];
    }

    if (tree_hash) |th| {
        if (!seen.contains(th)) {
            const th_owned = try allocator.dupe(u8, th);
            try seen.put(th_owned, {});
            try out.append(allocator, try allocator.dupe(u8, th));

            const tree_path = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "objects", th });
            defer allocator.free(tree_path);
            const tree_data = std.Io.Dir.cwd().readFileAlloc(io, tree_path, allocator, .limited(1024 * 1024)) catch null;
            if (tree_data) |td| {
                defer allocator.free(td);
                var tree_lines = std.mem.splitSequence(u8, td, "\n");
                while (tree_lines.next()) |tline| {
                    if (tline.len == 0) continue;
                    var parts = std.mem.splitScalar(u8, tline, ' ');
                    _ = parts.next();
                    const blob_hash = parts.next() orelse continue;
                    if (blob_hash.len < 16) continue;
                    if (!seen.contains(blob_hash)) {
                        const bh_owned = try allocator.dupe(u8, blob_hash);
                        try seen.put(bh_owned, {});
                        try out.append(allocator, try allocator.dupe(u8, blob_hash));
                    }
                }
            }
        }
    }

    if (parent_hash) |ph| {
        try collectAncestorCommits(allocator, io, repo_path, ph, out, seen);
    }
}

pub fn pushToApi(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    remote_url: []const u8,
    branch: []const u8,
    token: []const u8,
) !void {
    const target = (try parseZevApiUrl(allocator, remote_url)) orelse {
        std.debug.print("Not a zevapi:// URL: {s}\n\n", .{remote_url});
        return;
    };
    defer target.deinit(allocator);

    const head_cid = repo.getHeadCommit(io) catch {
        std.debug.print("No commits yet.\n\n", .{});
        return;
    };
    const head_hash = try head_cid.toString(allocator);
    defer allocator.free(head_hash);

    std.debug.print("Pushing to {s}/{s} ({s})\n\n", .{ target.owner, target.repo_name, target.base_url });
    std.debug.print("   HEAD: {s}\n", .{head_hash[0..16]});

    var objects = std.ArrayList([]u8).empty;
    defer {
        for (objects.items) |o| allocator.free(o);
        objects.deinit(allocator);
    }
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    try collectAncestorCommits(allocator, io, repo.path, head_hash, &objects, &seen);
    std.debug.print("   Objects to sync: {d}\n\n", .{objects.items.len});

    const objects_url = try std.fmt.allocPrint(allocator, "{s}/v1/repos/{s}/{s}/objects", .{ target.base_url, target.owner, target.repo_name });
    defer allocator.free(objects_url);

    var uploaded: usize = 0;
    var head_remote_hash: ?[]u8 = null;
    defer if (head_remote_hash) |h| allocator.free(h);

    var manifest = std.ArrayList(u8).empty;
    defer manifest.deinit(allocator);
    try manifest.appendSlice(allocator, "{\"head_local_hash\":\"");
    try manifest.appendSlice(allocator, head_hash);
    try manifest.appendSlice(allocator, "\",\"objects\":[");

    for (objects.items, 0..) |hash, idx| {
        const obj_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "objects", hash });
        defer allocator.free(obj_path);

        const data = std.Io.Dir.cwd().readFileAlloc(io, obj_path, allocator, .unlimited) catch {
            std.debug.print("   Could not read local object {s}, skipping\n", .{hash[0..16]});
            continue;
        };
        defer allocator.free(data);

        const result = httpPostBinary(allocator, io, objects_url, token, data) catch |err| {
            std.debug.print("   Upload failed for {s}: {}\n", .{ hash[0..16], err });
            continue;
        };
        defer allocator.free(result.body);

        if (result.status == 201 or result.status == 200) {
            const remote_hash = try jsonGetString(allocator, result.body, "hash");
            if (remote_hash) |rh| {
                defer allocator.free(rh);

                if (idx > 0) try manifest.append(allocator, ',');
                try manifest.append(allocator, '{');
                try manifest.appendSlice(allocator, "\"local_hash\":\"");
                try manifest.appendSlice(allocator, hash);
                try manifest.appendSlice(allocator, "\",\"server_hash\":\"");
                try manifest.appendSlice(allocator, rh);
                try manifest.appendSlice(allocator, "\"}");

                if (std.mem.eql(u8, hash, head_hash)) {
                    head_remote_hash = try allocator.dupe(u8, rh);
                }
            }
            uploaded += 1;
        } else {
            std.debug.print("   Upload rejected ({d}) for {s}: {s}\n", .{ result.status, hash[0..16], result.body });
        }
    }
    try manifest.appendSlice(allocator, "]}");

    std.debug.print("   Uploaded: {d}/{d} objects\n\n", .{ uploaded, objects.items.len });

    if (uploaded < objects.items.len) {
        std.debug.print("Some objects failed to upload, ref not updated.\n\n", .{});
        return;
    }

    const manifest_result = try httpPostBinary(allocator, io, objects_url, token, manifest.items);
    defer allocator.free(manifest_result.body);

    if (manifest_result.status != 201 and manifest_result.status != 200) {
        std.debug.print("Manifest upload failed ({d}): {s}\n\n", .{ manifest_result.status, manifest_result.body });
        return;
    }

    const manifest_hash = (try jsonGetString(allocator, manifest_result.body, "hash")) orelse {
        std.debug.print("Manifest upload succeeded but no hash returned\n\n", .{});
        return;
    };
    defer allocator.free(manifest_hash);

    const ref_target = head_remote_hash orelse head_hash;

    const refs_url = try std.fmt.allocPrint(allocator, "{s}/v1/repos/{s}/{s}/refs/{s}", .{ target.base_url, target.owner, target.repo_name, branch });
    defer allocator.free(refs_url);
    const ref_payload = try std.fmt.allocPrint(allocator,
        \\{{"target_hash":"{s}"}}
    , .{ref_target});
    defer allocator.free(ref_payload);
    const ref_result = try httpPutJson(allocator, io, refs_url, token, ref_payload);
    defer allocator.free(ref_result.body);

    const manifest_ref_name = try std.fmt.allocPrint(allocator, "manifest%2F{s}", .{branch});
    defer allocator.free(manifest_ref_name);
    const manifest_refs_url = try std.fmt.allocPrint(allocator, "{s}/v1/repos/{s}/{s}/refs/{s}", .{ target.base_url, target.owner, target.repo_name, manifest_ref_name });
    defer allocator.free(manifest_refs_url);
    const manifest_ref_payload = try std.fmt.allocPrint(allocator,
        \\{{"target_hash":"{s}"}}
    , .{manifest_hash});
    defer allocator.free(manifest_ref_payload);
    const manifest_ref_result = try httpPutJson(allocator, io, manifest_refs_url, token, manifest_ref_payload);
    defer allocator.free(manifest_ref_result.body);

    if (ref_result.status == 200 and manifest_ref_result.status == 200) {
        std.debug.print("Push complete — {s} now at {s}\n\n", .{ branch, ref_target[0..16] });
    } else {
        std.debug.print("Ref update failed (ref={d}, manifest={d})\n\n", .{ ref_result.status, manifest_ref_result.status });
    }
}

pub fn pullFromApi(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_path: []const u8,
    remote_url: []const u8,
    branch: []const u8,
    token: ?[]const u8,
) !void {
    const target = (try parseZevApiUrl(allocator, remote_url)) orelse {
        std.debug.print("Not a zevapi:// URL: {s}\n\n", .{remote_url});
        return;
    };
    defer target.deinit(allocator);

    std.debug.print("Pulling from {s}/{s} ({s})\n\n", .{ target.owner, target.repo_name, target.base_url });

    const manifest_ref_name = try std.fmt.allocPrint(allocator, "manifest%2F{s}", .{branch});
    defer allocator.free(manifest_ref_name);
    const manifest_refs_url = try std.fmt.allocPrint(allocator, "{s}/v1/repos/{s}/{s}/refs/{s}", .{ target.base_url, target.owner, target.repo_name, manifest_ref_name });
    defer allocator.free(manifest_refs_url);

    const manifest_ref_result = try httpGetBinary(allocator, io, manifest_refs_url, token);
    defer allocator.free(manifest_ref_result.body);

    if (manifest_ref_result.status != 200) {
        std.debug.print("Could not find manifest ref (status {d}): {s}\n\n", .{ manifest_ref_result.status, manifest_ref_result.body });
        return;
    }

    const manifest_hash = (try jsonGetString(allocator, manifest_ref_result.body, "target_hash")) orelse {
        std.debug.print("Manifest ref response missing target_hash\n\n", .{});
        return;
    };
    defer allocator.free(manifest_hash);

    const manifest_obj_url = try std.fmt.allocPrint(allocator, "{s}/v1/repos/{s}/{s}/objects/{s}", .{ target.base_url, target.owner, target.repo_name, manifest_hash });
    defer allocator.free(manifest_obj_url);

    const manifest_result = try httpGetBinary(allocator, io, manifest_obj_url, token);
    defer allocator.free(manifest_result.body);

    if (manifest_result.status != 200) {
        std.debug.print("Could not download manifest (status {d})\n\n", .{manifest_result.status});
        return;
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_result.body, .{});
    defer parsed.deinit();

    if (parsed.value != .object) {
        std.debug.print("Invalid manifest format\n\n", .{});
        return;
    }

    const head_local_val = parsed.value.object.get("head_local_hash") orelse {
        std.debug.print("Manifest missing head_local_hash\n\n", .{});
        return;
    };
    const head_local_hash = head_local_val.string;

    const objects_val = parsed.value.object.get("objects") orelse {
        std.debug.print("Manifest missing objects list\n\n", .{});
        return;
    };
    if (objects_val != .array) {
        std.debug.print("Manifest objects field is not an array\n\n", .{});
        return;
    }

    std.debug.print("   HEAD: {s}\n", .{head_local_hash[0..16]});
    std.debug.print("   Objects to fetch: {d}\n\n", .{objects_val.array.items.len});

    const objects_dir = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "objects" });
    defer allocator.free(objects_dir);
    try std.Io.Dir.cwd().createDirPath(io, objects_dir);

    var fetched: usize = 0;
    var skipped: usize = 0;

    for (objects_val.array.items) |entry| {
        if (entry != .object) continue;
        const local_hash_val = entry.object.get("local_hash") orelse continue;
        const server_hash_val = entry.object.get("server_hash") orelse continue;
        if (local_hash_val != .string or server_hash_val != .string) continue;

        const local_hash = local_hash_val.string;
        const server_hash = server_hash_val.string;

        const local_obj_path = try std.fs.path.join(allocator, &.{ objects_dir, local_hash });
        defer allocator.free(local_obj_path);

        if (std.Io.Dir.cwd().access(io, local_obj_path, .{})) |_| {
            skipped += 1;
            continue;
        } else |_| {}

        const obj_url = try std.fmt.allocPrint(allocator, "{s}/v1/repos/{s}/{s}/objects/{s}", .{ target.base_url, target.owner, target.repo_name, server_hash });
        defer allocator.free(obj_url);

        const obj_result = httpGetBinary(allocator, io, obj_url, token) catch |err| {
            std.debug.print("   Fetch failed for {s}: {}\n", .{ local_hash[0..16], err });
            continue;
        };
        defer allocator.free(obj_result.body);

        if (obj_result.status != 200) {
            std.debug.print("   Fetch rejected ({d}) for {s}\n", .{ obj_result.status, local_hash[0..16] });
            continue;
        }

        const f = try std.Io.Dir.cwd().createFile(io, local_obj_path, .{});
        defer f.close(io);
        var wbuf: [65536]u8 = undefined;
        var writer = f.writer(io, &wbuf);
        try writer.interface.writeAll(obj_result.body);
        try writer.flush();

        fetched += 1;
    }

    std.debug.print("   Fetched: {d}, already had: {d}\n\n", .{ fetched, skipped });

    const refs_heads_dir = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "refs", "heads" });
    defer allocator.free(refs_heads_dir);
    try std.Io.Dir.cwd().createDirPath(io, refs_heads_dir);

    const branch_ref_path = try std.fs.path.join(allocator, &.{ refs_heads_dir, branch });
    defer allocator.free(branch_ref_path);
    {
        const f = try std.Io.Dir.cwd().createFile(io, branch_ref_path, .{});
        defer f.close(io);
        var wbuf: [128]u8 = undefined;
        var writer = f.writer(io, &wbuf);
        try writer.interface.writeAll(head_local_hash);
        try writer.flush();
    }

    const head_path = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "HEAD" });
    defer allocator.free(head_path);
    {
        const f = try std.Io.Dir.cwd().createFile(io, head_path, .{});
        defer f.close(io);
        const ref_line = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}", .{branch});
        defer allocator.free(ref_line);
        var wbuf: [128]u8 = undefined;
        var writer = f.writer(io, &wbuf);
        try writer.interface.writeAll(ref_line);
        try writer.flush();
    }

    std.debug.print("Pull complete — {s} is now at {s}\n", .{ branch, head_local_hash[0..16] });
    std.debug.print("   Run 'zev checkout {s}' to materialize working directory files.\n\n", .{branch});
}

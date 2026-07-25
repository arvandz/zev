const std = @import("std");
const Repository = @import("repository.zig").Repository;
const ipld = @import("ipld.zig");

pub fn dagShow(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    cid_str: []const u8,
) !void {
    var store = try ipld.BlockStore.init(allocator, io, io, io, repo.path);
    defer store.deinit();

    const c = parseCID(cid_str) catch {
        std.debug.print("❌ Invalid CID: {s}\n", .{cid_str});
        std.debug.print("   Use 'zev dag stat' to list known CIDs\n", .{});
        return;
    };

    const value = store.getNode(allocator, c) catch {
        std.debug.print("❌ Block not found: {s}\n", .{cid_str});
        std.debug.print("   This CID may exist on IPFS but not locally.\n", .{});
        std.debug.print("   Fetch with: zev graft {s} --as <alias>\n", .{cid_str});
        return;
    };
    defer value.deinit(allocator);

    const short = try c.toShort(allocator);
    defer allocator.free(short);

    std.debug.print("🔷 IPLD Node: {s}\n\n", .{short});
    try printValue(allocator, value, 0);
    std.debug.print("\n", .{});
}

pub fn dagWalk(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    cid_str: []const u8,
    max_depth: usize,
) !void {
    var store = try ipld.BlockStore.init(allocator, io, io, io, repo.path);
    defer store.deinit();

    const c = parseCID(cid_str) catch {
        std.debug.print("❌ Invalid CID: {s}\n", .{cid_str});
        return;
    };

    std.debug.print("🕸️  DAG Walk from {s} (depth={d})\n\n", .{ cid_str[0..@min(16, cid_str.len)], max_depth });

    var dag = ipld.walkDag(allocator, &store, c, max_depth) catch {
        std.debug.print("❌ Root block not found: {s}\n", .{cid_str});
        return;
    };
    defer dag.deinit(allocator);

    try printDagNode(allocator, dag, 0);
    std.debug.print("\n", .{});
}

fn printDagNode(
    allocator: std.mem.Allocator,
    node: ipld.DagNode,
    depth: usize,
) !void {
    const indent = depth * 2;
    const short = try node.cid.toShort(allocator);
    defer allocator.free(short);

    const node_type = if (node.value == .map)
        node.value.getString("zev") orelse "unknown"
    else
        @tagName(node.value);

    const icon: []const u8 = if (std.mem.eql(u8, node_type, "commit")) "●" else if (std.mem.eql(u8, node_type, "metrics")) "📊" else if (std.mem.eql(u8, node_type, "snapshot")) "📸" else if (std.mem.eql(u8, node_type, "context")) "🤖" else if (std.mem.eql(u8, node_type, "dataset_shard")) "📂" else if (std.mem.eql(u8, node_type, "graft")) "🔗" else "🔷";

    var i: usize = 0;
    while (i < indent) : (i += 1) std.debug.print(" ", .{});
    std.debug.print("{s} [{s}] {s}\n", .{ icon, node_type, short });

    if (node.value == .map) {
        for (node.value.map) |entry| {
            if (std.mem.eql(u8, entry.key, "zev")) continue;
            if (entry.value == .link) {
                var ii: usize = 0;
                while (ii < indent + 2) : (ii += 1) std.debug.print(" ", .{});
                const link_short = try entry.value.link.toShort(allocator);
                defer allocator.free(link_short);
                std.debug.print("→ {s}: {s}\n", .{ entry.key, link_short });
            } else if (entry.value == .string or entry.value == .int or
                entry.value == .uint or entry.value == .float)
            {
                var ii: usize = 0;
                while (ii < indent + 2) : (ii += 1) std.debug.print(" ", .{});
                try printScalar(entry.key, entry.value);
            }
        }
    }

    for (node.children) |child| {
        try printDagNode(allocator, child, depth + 1);
    }
}

pub fn dagPut(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    file_path: []const u8,
) !void {
    var store = try ipld.BlockStore.init(allocator, io, io, io, repo.path);
    defer store.deinit();

    const data = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(64 * 1024 * 1024)) catch |err| {
        std.debug.print("❌ Cannot read {s}: {}\n", .{ file_path, err });
        return;
    };
    defer allocator.free(data);

    const c = if (std.mem.startsWith(u8, data, "{") or std.mem.startsWith(u8, data, "[")) blk: {
        const v = simpleJsonToValue(allocator, data) catch {
            const rc = ipld.CID.raw(data);
            try store.put(rc, data);
            break :blk rc;
        };
        defer v.deinit(allocator);
        break :blk try store.putNode(allocator, v);
    } else blk: {
        const rc = ipld.CID.raw(data);
        try store.put(rc, data);
        break :blk rc;
    };

    const short = try c.toShort(allocator);
    defer allocator.free(short);

    std.debug.print("✅ Block stored\n\n", .{});
    std.debug.print("   File:  {s}\n", .{file_path});
    std.debug.print("   CID:   {s}\n", .{short});
    std.debug.print("   Size:  {d} bytes\n\n", .{data.len});
    std.debug.print("   Inspect: zev dag show {s}\n\n", .{short});
}

pub fn dagStat(allocator: std.mem.Allocator, io: std.Io, repo: *Repository) !void {
    var store = try ipld.BlockStore.init(allocator, io, io, io, repo.path);
    defer store.deinit();

    const block_count = store.count();

    var total_bytes: u64 = 0;
    var by_type = std.StringHashMap(usize).init(allocator);
    defer {
        var it = by_type.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        by_type.deinit();
    }

    const ipld_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "ipld" });
    defer allocator.free(ipld_path);

    var root_dir = std.Io.Dir.cwd().openDir(ipld_path, .{ .iterate = true }) catch {
        std.debug.print("📊 IPLD Block Store\n\n   No blocks yet.\n\n", .{});
        std.debug.print("   Blocks are created automatically when you use:\n", .{});
        std.debug.print("   zev dag put <file>\n", .{});
        std.debug.print("   zev graft <cid> --as <alias>\n\n", .{});
        return;
    };
    defer root_dir.close();

    var root_it = root_dir.iterate();
    while (try root_it.next()) |shard_entry| {
        if (shard_entry.kind != .directory) continue;
        const shard_path = try std.fs.path.join(allocator, &.{ ipld_path, shard_entry.name });
        defer allocator.free(shard_path);
        var shard_dir = std.Io.Dir.cwd().openDir(shard_path, .{ .iterate = true }) catch continue;
        defer shard_dir.close();
        var shard_it = shard_dir.iterate();
        while (try shard_it.next()) |block_entry| {
            if (block_entry.kind != .file) continue;
            const block_path = try std.fs.path.join(allocator, &.{ shard_path, block_entry.name });
            defer allocator.free(block_path);
            const stat = std.Io.Dir.cwd().statFile(io, block_path) catch continue;
            total_bytes += @intCast(stat.size);

            const data = std.Io.Dir.cwd().readFileAlloc(io, block_path, allocator, .limited(4096)) catch continue;
            defer allocator.free(data);
            const v = ipld.decode(allocator, data) catch {
                const e = try by_type.getOrPut("raw");
                if (!e.found_existing) {
                    e.key_ptr.* = try allocator.dupe(u8, "raw");
                    e.value_ptr.* = 0;
                }
                e.value_ptr.* += 1;
                continue;
            };
            defer v.deinit(allocator);
            const type_name = if (v == .map) v.getString("zev") orelse "unknown" else "raw";
            const e = try by_type.getOrPut(type_name);
            if (!e.found_existing) {
                e.key_ptr.* = try allocator.dupe(u8, type_name);
                e.value_ptr.* = 0;
            }
            e.value_ptr.* += 1;
        }
    }

    std.debug.print("📊 IPLD Block Store\n\n", .{});
    std.debug.print("   Blocks:     {d}\n", .{block_count});
    if (total_bytes < 1024) {
        std.debug.print("   Total size: {d} bytes\n\n", .{total_bytes});
    } else {
        std.debug.print("   Total size: {d} KB\n\n", .{total_bytes / 1024});
    }

    if (by_type.count() > 0) {
        std.debug.print("   By type:\n", .{});
        var it = by_type.iterator();
        while (it.next()) |entry| {
            std.debug.print("   {s:<20} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        std.debug.print("\n", .{});
    }
}

pub fn graftAdd(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    cid_str: []const u8,
    alias: []const u8,
    description: []const u8,
    fetch_from_ipfs: bool,
) !void {
    const now = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);

    const c = parseCID(cid_str) catch {
        std.debug.print("❌ Invalid CID: {s}\n", .{cid_str});
        return;
    };

    var store = try ipld.BlockStore.init(allocator, io, io, io, repo.path);
    defer store.deinit();

    const config_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "config" });
    defer allocator.free(config_path);
    const author = try loadConfigField(allocator, config_path, "user.name");
    defer allocator.free(author);

    if (fetch_from_ipfs and !store.has(c)) {
        std.debug.print("   Fetching from IPFS...\n", .{});
        const short = try c.toShort(allocator);
        defer allocator.free(short);
        try fetchFromIPFS(allocator, io, &store, short);
    }

    const graft = ipld.GraftNode{
        .target_cid = c,
        .alias = alias,
        .description = description,
        .grafted_at = now,
        .grafted_by = author,
    };

    var arena = std.heap.ArenaAllocator.init(allocator, io, io, io, );
    defer arena.deinit();
    const aa = arena.allocator();
    const graft_val = try graft.toValue(aa);
    const graft_cid = try store.putNode(aa, graft_val);

    try saveGraftAlias(allocator, io, repo, alias, cid_str, graft_cid);

    const short_target = try c.toShort(allocator);
    defer allocator.free(short_target);
    const short_graft = try graft_cid.toShort(allocator);
    defer allocator.free(short_graft);

    std.debug.print("🔗 Grafted external CID\n\n", .{});
    std.debug.print("   Alias:   {s}\n", .{alias});
    std.debug.print("   Target:  {s}\n", .{short_target});
    std.debug.print("   Graft:   {s}\n", .{short_graft});
    std.debug.print("   By:      {s}\n", .{author});
    if (description.len > 0)
        std.debug.print("   Desc:    {s}\n", .{description});
    std.debug.print("\n", .{});

    if (!store.has(c)) {
        std.debug.print("   ℹ️  Block not in local store (CID recorded as link only)\n", .{});
        std.debug.print("   The data lives wherever the CID points — IPFS, Filecoin, etc.\n", .{});
        std.debug.print("   To fetch: zev graft {s} --as {s} --fetch\n\n", .{ cid_str, alias });
    } else {
        std.debug.print("   ✅ Block available locally\n\n", .{});
    }

    std.debug.print("   Use in queries: zev dag show {s}\n", .{short_target});
    std.debug.print("   Or by alias:    zev graft resolve {s}\n\n", .{alias});
}

pub fn graftList(allocator: std.mem.Allocator, io: std.Io, repo: *Repository) !void {
    const graft_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "grafts" });
    defer allocator.free(graft_path);

    var dir = std.Io.Dir.cwd().openDir(graft_path, .{ .iterate = true }) catch {
        std.debug.print("No grafts yet.\n\n", .{});
        std.debug.print("Graft a foreign CID:\n", .{});
        std.debug.print("  zev graft <cid> --as dataset/imagenet-v2\n\n", .{});
        return;
    };
    defer dir.close();

    std.debug.print("🔗 Grafted External Links:\n\n", .{});
    std.debug.print("   {s:<30} {s:<20} {s}\n", .{ "Alias", "Target CID", "Description" });
    std.debug.print("   {s}\n", .{"─"**72});

    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ graft_path, entry.name });
        defer allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096)) catch continue;
        defer allocator.free(content);

        var alias: []u8 = try allocator.dupe(u8, "");
        var target: []u8 = try allocator.dupe(u8, "");
        var desc: []u8 = try allocator.dupe(u8, "");
        defer allocator.free(alias);
        defer allocator.free(target);
        defer allocator.free(desc);

        var li = std.mem.splitSequence(u8, content, "\n");
        while (li.next()) |line| {
            if (std.mem.startsWith(u8, line, "alias=")) {
                allocator.free(alias);
                alias = try allocator.dupe(u8, line[6..]);
            } else if (std.mem.startsWith(u8, line, "target=")) {
                allocator.free(target);
                target = try allocator.dupe(u8, line[7..]);
            } else if (std.mem.startsWith(u8, line, "desc=")) {
                allocator.free(desc);
                desc = try allocator.dupe(u8, line[5..]);
            }
        }

        std.debug.print("   {s:<30} {s:<20} {s}\n", .{ alias, target[0..@min(18, target.len)], desc });
        count += 1;
    }

    if (count == 0) {
        std.debug.print("   No grafts yet.\n\n", .{});
    } else {
        std.debug.print("\n   {d} graft(s) total\n\n", .{count});
    }
}

pub fn graftResolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    alias: []const u8,
) !void {
    const graft_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "grafts" });
    defer allocator.free(graft_path);

    const fname = try sanitizeAlias(allocator, alias);
    defer allocator.free(fname);
    const path = try std.fs.path.join(allocator, &.{ graft_path, fname });
    defer allocator.free(path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096)) catch {
        std.debug.print("❌ Alias '{s}' not found.\n", .{alias});
        std.debug.print("   List grafts: zev graft list\n\n", .{});
        return;
    };
    defer allocator.free(content);

    var target: []u8 = try allocator.dupe(u8, "");
    var desc: []u8 = try allocator.dupe(u8, "");
    var author: []u8 = try allocator.dupe(u8, "");
    var ts: i64 = 0;
    defer allocator.free(target);
    defer allocator.free(desc);
    defer allocator.free(author);

    var li = std.mem.splitSequence(u8, content, "\n");
    while (li.next()) |line| {
        if (std.mem.startsWith(u8, line, "target=")) {
            allocator.free(target);
            target = try allocator.dupe(u8, line[7..]);
        } else if (std.mem.startsWith(u8, line, "desc=")) {
            allocator.free(desc);
            desc = try allocator.dupe(u8, line[5..]);
        } else if (std.mem.startsWith(u8, line, "author=")) {
            allocator.free(author);
            author = try allocator.dupe(u8, line[7..]);
        } else if (std.mem.startsWith(u8, line, "ts=")) {
            ts = std.fmt.parseInt(i64, line[3..], 10) catch 0;
        }
    }

    std.debug.print("🔗 Graft: {s}\n\n", .{alias});
    std.debug.print("   Target:  {s}\n", .{target});
    std.debug.print("   By:      {s}\n", .{author});
    std.debug.print("   At:      t={d}\n", .{ts});
    if (desc.len > 0)
        std.debug.print("   Desc:    {s}\n", .{desc});
    std.debug.print("\n   Inspect: zev dag show {s}\n\n", .{target});
}

fn parseCID(s: []const u8) !ipld.CID {
    if (s.len >= 16 and s.len <= 64) {
        return ipld.CID.fromHex(s);
    }
    if (s.len > 10 and s[0] == 'b') {
        return ipld.CID.fromHex(s[1..@min(s.len, 17)]);
    }
    return error.InvalidCID;
}

fn printValue(allocator: std.mem.Allocator, value: ipld.Value, depth: usize) !void {
    const indent_s = depth * 2;
    switch (value) {
        .null => std.debug.print("null\n", .{}),
        .bool => |b| std.debug.print("{}\n", .{b}),
        .int => |i| std.debug.print("{d}\n", .{i}),
        .uint => |u| std.debug.print("{d}\n", .{u}),
        .float => |f| std.debug.print("{d:.6}\n", .{f}),
        .string => |s| std.debug.print("\"{s}\"\n", .{s}),
        .bytes => |b| std.debug.print("<{d} bytes>\n", .{b.len}),
        .link => |c| {
            const sh = try c.toShort(allocator);
            defer allocator.free(sh);
            std.debug.print("→ {s}\n", .{sh});
        },
        .list => |l| {
            std.debug.print("[\n", .{});
            for (l) |item| {
                var i: usize = 0;
                while (i < indent_s + 2) : (i += 1) std.debug.print(" ", .{});
                try printValue(allocator, item, depth + 1);
            }
            var i: usize = 0;
            while (i < indent_s) : (i += 1) std.debug.print(" ", .{});
            std.debug.print("]\n", .{});
        },
        .map => |m| {
            std.debug.print("{{\n", .{});
            for (m) |entry| {
                var i: usize = 0;
                while (i < indent_s + 2) : (i += 1) std.debug.print(" ", .{});
                std.debug.print("{s}: ", .{entry.key});
                try printValue(allocator, entry.value, depth + 1);
            }
            var i: usize = 0;
            while (i < indent_s) : (i += 1) std.debug.print(" ", .{});
            std.debug.print("}}\n", .{});
        },
    }
}

fn printScalar(key: []const u8, value: ipld.Value) !void {
    switch (value) {
        .string => |s| std.debug.print("{s}: \"{s}\"\n", .{ key, s }),
        .int => |i| std.debug.print("{s}: {d}\n", .{ key, i }),
        .uint => |u| std.debug.print("{s}: {d}\n", .{ key, u }),
        .float => |f| std.debug.print("{s}: {d:.4}\n", .{ key, f }),
        .bool => |b| std.debug.print("{s}: {}\n", .{ key, b }),
        else => {},
    }
}

fn loadConfigField(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8, field: []const u8) ![]u8 {
    const content = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(4096)) catch return try allocator.dupe(u8, "unknown");
    defer allocator.free(content);
    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, field) and line.len > field.len and line[field.len] == '=')
            return try allocator.dupe(u8, line[field.len + 1 ..]);
    }
    return try allocator.dupe(u8, "unknown");
}

fn saveGraftAlias(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    alias: []const u8,
    target_cid: []const u8,
    graft_cid: ipld.CID,
) !void {
    const graft_dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "grafts" });
    defer allocator.free(graft_dir);
    try std.Io.Dir.cwd().makePath(graft_dir);

    const fname = try sanitizeAlias(allocator, alias);
    defer allocator.free(fname);
    const path = try std.fs.path.join(allocator, &.{ graft_dir, fname });
    defer allocator.free(path);

    const graft_short = try graft_cid.toShort(allocator);
    defer allocator.free(graft_short);

    const now = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);

    const content = try std.fmt.allocPrint(allocator, "alias={s}\ntarget={s}\ngraft_cid={s}\nts={d}\n", .{ alias, target_cid, graft_short, now });
    defer allocator.free(content);

    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var f_buffer: [512]u8 = undefined;
    var f_writer = f.writer(io, &f_buffer);
    try f_writer.interface.writeAll(content);
    try f_writer.flush();
}

fn sanitizeAlias(allocator: std.mem.Allocator, alias: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, alias);
    for (out) |*c| {
        if (c.* == '/' or c.* == '\\' or c.* == ':' or c.* == ' ') c.* = '_';
    }
    return out;
}

fn fetchFromIPFS(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *ipld.BlockStore,
    cid_short: []const u8,
) !void {
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:5001/api/v0/block/get?arg={s}", .{cid_short});
    defer allocator.free(url);

    var child = std.process.Child.init(io, &.{ "curl", "-s", "-X", "POST", url }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch {
        std.debug.print("   ⚠️  curl not available — cannot fetch from IPFS\n", .{});
        return;
    };

    var buf: [1024 * 1024]u8 = undefined;
    var child_scratch: [4096]u8 = undefined;
    var child_reader = child.stdout.?.reader(io, &child_scratch);
    const n = child_reader.interface.readSliceShort(&buf) catch 0;
    _ = child.wait(io) catch {};

    if (n > 0) {
        const c = ipld.CID.raw(buf[0..n]);
        try store.put(c, buf[0..n]);
        std.debug.print("   ✅ Fetched {d} bytes from IPFS\n", .{n});
    } else {
        std.debug.print("   ⚠️  Block not found on local IPFS node\n", .{});
    }
}

fn simpleJsonToValue(allocator: std.mem.Allocator, data: []const u8) !ipld.Value {
    if (!std.mem.startsWith(u8, data, "{")) return error.NotAnObject;
    var entries: std.ArrayList(ipld.Value.MapEntry) = .empty;
    var pos: usize = 1;
    while (pos < data.len) {
        while (pos < data.len and (data[pos] == ' ' or data[pos] == '\n' or data[pos] == '\r')) pos += 1;
        if (pos >= data.len or data[pos] == '}') break;
        if (data[pos] != '"') return error.InvalidJson;
        pos += 1;
        const key_start = pos;
        while (pos < data.len and data[pos] != '"') pos += 1;
        const key = try allocator.dupe(u8, data[key_start..pos]);
        pos += 1;
        while (pos < data.len and data[pos] != ':') pos += 1;
        pos += 1;
        while (pos < data.len and data[pos] == ' ') pos += 1;
        const val: ipld.Value = if (pos < data.len and data[pos] == '"') blk: {
            pos += 1;
            const vs = pos;
            while (pos < data.len and data[pos] != '"') pos += 1;
            const v = try allocator.dupe(u8, data[vs..pos]);
            pos += 1;
            break :blk .{ .string = v };
        } else blk: {
            const vs = pos;
            while (pos < data.len and data[pos] != ',' and data[pos] != '}') pos += 1;
            const num_str = std.mem.trim(u8, data[vs..pos], " ");
            if (std.fmt.parseInt(i64, num_str, 10)) |iv| {
                break :blk .{ .int = iv };
            } else |_| {}
            if (std.fmt.parseFloat(f64, num_str)) |fv| {
                break :blk .{ .float = fv };
            } else |_| {}
            break :blk .null;
        };
        try entries.append(allocator, .{ .key = key, .value = val });
        while (pos < data.len and (data[pos] == ',' or data[pos] == ' ')) pos += 1;
    }
    return .{ .map = try entries.toOwnedSlice(allocator) };
}

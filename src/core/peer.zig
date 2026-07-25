const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");

const IPFS_API = "http://127.0.0.1:5001/api/v0";

fn ipfsPost(allocator: std.mem.Allocator,
    io: std.Io, endpoint: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ IPFS_API, endpoint });
    defer allocator.free(url);

    try argv.appendSlice(allocator, &.{ "curl", "-s", "-X", "POST", url });
    for (args) |arg| try argv.append(allocator, arg);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    var buf: [1024 * 256]u8 = undefined;
    var child_scratch: [4096]u8 = undefined;
    var child_reader = child.stdout.?.reader(io, &child_scratch);
    const n = try child_reader.interface.readSliceShort(&buf);
    _ = try child.wait(io);
    return try allocator.dupe(u8, buf[0..n]);
}

fn ipfsGet(allocator: std.mem.Allocator,
    io: std.Io, endpoint: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ IPFS_API, endpoint });
    defer allocator.free(url);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "curl", "-s", url },
        .stdout = .pipe,
        .stderr = .ignore,
    });

    var buf: [1024 * 256]u8 = undefined;
    var child_scratch: [4096]u8 = undefined;
    var child_reader = child.stdout.?.reader(io, &child_scratch);
    const n = try child_reader.interface.readSliceShort(&buf);
    _ = try child.wait(io);
    return try allocator.dupe(u8, buf[0..n]);
}

fn ipfsAlive(allocator: std.mem.Allocator,
    io: std.Io,) bool {
    const resp = ipfsPost(allocator, io, "/id", &.{}) catch return false;
    defer allocator.free(resp);
    return std.mem.indexOf(u8, resp, "ID") != null;
}

fn extractJsonStr(allocator: std.mem.Allocator, json: []const u8, field: []const u8) !?[]u8 {
    const search = try std.fmt.allocPrint(allocator, "\"{s}\":", .{field});
    defer allocator.free(search);

    const idx = std.mem.indexOf(u8, json, search) orelse return null;
    const after = json[idx + search.len ..];
    const trimmed = std.mem.trimLeft(u8, after, " \t\n\r");
    if (trimmed.len == 0 or trimmed[0] != '"') return null;
    const start = 1;
    const end = std.mem.indexOf(u8, trimmed[start..], "\"") orelse return null;
    return try allocator.dupe(u8, trimmed[start .. start + end]);
}

fn ipfsAddFile(allocator: std.mem.Allocator,
    io: std.Io, path: []const u8) !?[]u8 {
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/add?quieter=true&pin=true", .{IPFS_API});
    defer allocator.free(endpoint);

    const form_arg = try std.fmt.allocPrint(allocator, "-F file=@{s}", .{path});
    defer allocator.free(form_arg);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "curl", "-s", "-X", "POST", endpoint, form_arg },
        .stdout = .pipe,
        .stderr = .ignore,
    });
    var buf: [512]u8 = undefined;
    var child_scratch: [4096]u8 = undefined;
    var child_reader = child.stdout.?.reader(io, &child_scratch);
    const n = try child_reader.interface.readSliceShort(&buf);
    _ = try child.wait(io);

    const resp = buf[0..n];
    const trimmed = std.mem.trim(u8, resp, " \n\r\t{}\"");
    if (trimmed.len < 10) return null;
    if (std.mem.indexOf(u8, resp, "Hash")) |_| {
        return try extractJsonStr(allocator, resp, "Hash");
    }
    return try allocator.dupe(u8, trimmed);
}

fn ipfsAddDir(allocator: std.mem.Allocator,
    io: std.Io, dir_path: []const u8) !?[]u8 {
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/add?recursive=true&quieter=true&pin=true&wrap-with-directory=false", .{IPFS_API});
    defer allocator.free(endpoint);

    const argv = [_][]const u8{
        "ipfs", "add", "-r", "-Q", "--pin=true", dir_path,
    };

    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    var buf: [512]u8 = undefined;
    var child_scratch: [4096]u8 = undefined;
    var child_reader = child.stdout.?.reader(io, &child_scratch);
    const n = try child_reader.interface.readSliceShort(&buf);
    _ = try child.wait(io);

    const trimmed = std.mem.trim(u8, buf[0..n], " \n\r\t");
    if (trimmed.len < 10) return null;
    return try allocator.dupe(u8, trimmed);
}

fn ipfsPin(allocator: std.mem.Allocator,
    io: std.Io, hash: []const u8) !void {
    const endpoint = try std.fmt.allocPrint(allocator, "/pin/add?arg={s}", .{hash});
    defer allocator.free(endpoint);
    const resp = try ipfsPost(allocator, io, endpoint, &.{});
    allocator.free(resp);
}

fn getNodeId(allocator: std.mem.Allocator,
    io: std.Io,) ![]u8 {
    const resp = try ipfsPost(allocator, io, "/id", &.{});
    defer allocator.free(resp);
    return (try extractJsonStr(allocator, resp, "ID")) orelse
        try allocator.dupe(u8, "unknown");
}

fn getNodeAddrs(allocator: std.mem.Allocator,
    io: std.Io,) ![]u8 {
    const resp = try ipfsPost(allocator, io, "/id", &.{});
    defer allocator.free(resp);
    const idx = std.mem.indexOf(u8, resp, "Addresses") orelse return try allocator.dupe(u8, "");
    const after = resp[idx..];
    const bracket = std.mem.indexOf(u8, after, "[") orelse return try allocator.dupe(u8, "");
    const end = std.mem.indexOf(u8, after[bracket..], "]") orelse return try allocator.dupe(u8, "");
    const addrs_raw = after[bracket + 1 .. bracket + end];
    var iter = std.mem.splitSequence(u8, addrs_raw, ",");
    while (iter.next()) |addr| {
        const clean = std.mem.trim(u8, addr, " \t\n\r\"");
        if (clean.len > 0 and !std.mem.startsWith(u8, clean, "/ip4/127")) {
            return try allocator.dupe(u8, clean);
        }
    }
    var iter2 = std.mem.splitSequence(u8, addrs_raw, ",");
    if (iter2.next()) |first| {
        return try allocator.dupe(u8, std.mem.trim(u8, first, " \t\n\r\""));
    }
    return try allocator.dupe(u8, "");
}

const PEERS_FILE = ".zev/peers";
const PEER_STATE_FILE = ".zev/peer_state";

fn savePeerState(
    allocator: std.mem.Allocator,
    repo: *Repository,
    meta_cid: []const u8,
    node_id: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ repo.path, PEER_STATE_FILE });
    defer allocator.free(path);
    const f = try std.Io.Dir.cwd().createFile(path, .{});
    defer f.close();
    const content = try std.fmt.allocPrint(allocator, "meta_cid={s}\nnode_id={s}\n", .{ meta_cid, node_id });
    defer allocator.free(content);
    try f.writeAll(content);
}

fn loadPeerState(allocator: std.mem.Allocator, io: std.Io, repo: *Repository) !?struct { meta_cid: []u8, node_id: []u8 } {
    const path = try std.fs.path.join(allocator, &.{ repo.path, PEER_STATE_FILE });
    defer allocator.free(path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096)) catch return null;
    defer allocator.free(content);
    var meta_cid: []u8 = try allocator.dupe(u8, "");
    var node_id: []u8 = try allocator.dupe(u8, "");
    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "meta_cid=")) {
            allocator.free(meta_cid);
            meta_cid = try allocator.dupe(u8, line[9..]);
        } else if (std.mem.startsWith(u8, line, "node_id=")) {
            allocator.free(node_id);
            node_id = try allocator.dupe(u8, line[8..]);
        }
    }
    if (meta_cid.len == 0) {
        allocator.free(meta_cid);
        allocator.free(node_id);
        return null;
    }
    return .{ .meta_cid = meta_cid, .node_id = node_id };
}

fn addPeer(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, peer_id: []const u8, meta_cid: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ repo.path, PEERS_FILE });
    defer allocator.free(path);

    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch
        try allocator.dupe(u8, "");
    defer allocator.free(existing);

    if (std.mem.indexOf(u8, existing, peer_id) != null) return;

    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer f.close(io);
    var f_buffer: [512]u8 = undefined;
    var f_writer = f.writer(io, &f_buffer);
    try f.seekFromEnd(0);
    const line = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ peer_id, meta_cid });
    defer allocator.free(line);
    try f_writer.interface.writeAll(line);
    try f_writer.flush();
}

fn listPeers(allocator: std.mem.Allocator, io: std.Io, repo: *Repository) !void {
    const path = try std.fs.path.join(allocator, &.{ repo.path, PEERS_FILE });
    defer allocator.free(path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch {
        std.debug.print("  No known peers yet.\n", .{});
        return;
    };
    defer allocator.free(content);

    var iter = std.mem.splitSequence(u8, content, "\n");
    var count: usize = 0;
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        count += 1;
        var parts = std.mem.splitSequence(u8, line, " ");
        const pid = parts.next() orelse continue;
        const mcid = parts.next() orelse "(no meta CID)";
        std.debug.print("  🔗 {s}\n     Meta CID: {s}\n\n", .{ pid, mcid });
    }
    if (count == 0) std.debug.print("  No known peers yet.\n", .{});
}

fn buildManifest(allocator: std.mem.Allocator, repo: *Repository) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    const dirs = [_][]const u8{ "metrics", "experiments", "lineage", "snapshots" };

    for (dirs) |d| {
        const dir_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", d });
        defer allocator.free(dir_path);
        var dir = std.Io.Dir.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            const line = try std.fmt.allocPrint(allocator, "{s}/{s}\n", .{ d, entry.name });
            defer allocator.free(line);
            try result.appendSlice(allocator, line);
        }
    }

    const heads_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "heads" });
    defer allocator.free(heads_path);
    var heads_dir = std.Io.Dir.cwd().openDir(heads_path, .{ .iterate = true }) catch {
        return result.toOwnedSlice(allocator);
    };
    defer heads_dir.close();
    var hit = heads_dir.iterate();
    while (try hit.next()) |entry| {
        if (entry.kind != .file) continue;
        const line = try std.fmt.allocPrint(allocator, "refs/heads/{s}\n", .{entry.name});
        defer allocator.free(line);
        try result.appendSlice(allocator, line);
    }

    return result.toOwnedSlice(allocator);
}

pub fn peerAnnounce(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, topic: []const u8) !void {
    if (!ipfsAlive(allocator, io)) {
        std.debug.print("❌ IPFS daemon not running.\n", .{});
        std.debug.print("   Start it with: ipfs daemon\n", .{});
        return;
    }

    std.debug.print("📡 Announcing repo to peers...\n\n", .{});
    const zev_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev" });
    defer allocator.free(zev_path);

    std.debug.print("   Adding metadata to IPFS...\n", .{});
    const meta_cid = (try ipfsAddDir(allocator, io, zev_path)) orelse {
        std.debug.print("❌ Failed to add metadata to IPFS\n", .{});
        std.debug.print("   Is 'ipfs' in your PATH? Try: ipfs add -r {s}\n", .{zev_path});
        return;
    };
    defer allocator.free(meta_cid);

    const node_id = try getNodeId(allocator, io);
    defer allocator.free(node_id);
    const addr = try getNodeAddrs(allocator, io, );
    defer allocator.free(addr);

    const msg = try std.fmt.allocPrint(allocator, "{{\"type\":\"zev-announce\",\"node_id\":\"{s}\",\"meta_cid\":\"{s}\",\"addr\":\"{s}\"}}", .{ node_id, meta_cid, addr });
    defer allocator.free(msg);

    const pub_endpoint = try std.fmt.allocPrint(allocator, "/pubsub/pub?arg={s}", .{topic});
    defer allocator.free(pub_endpoint);

    const tmp = "/tmp/zev_pubsub_msg.json";
    const tf = try std.Io.Dir.cwd().createFile(tmp, .{});
    try tf.writeAll(msg);
    tf.close();

    const pub_resp = try ipfsPost(allocator, io, pub_endpoint, &.{ "--data-binary", "@/tmp/zev_pubsub_msg.json" });
    defer allocator.free(pub_resp);

    try savePeerState(allocator, repo, meta_cid, node_id);

    std.debug.print("✅ Repo announced!\n", .{});
    std.debug.print("   Node ID:  {s}\n", .{node_id});
    std.debug.print("   Meta CID: {s}\n", .{meta_cid});
    std.debug.print("   Topic:    {s}\n", .{topic});
    if (addr.len > 0)
        std.debug.print("   Address:  {s}\n", .{addr});
    std.debug.print("\n   Share this with peers:\n", .{});
    std.debug.print("   zev peer sync {s}\n", .{meta_cid});
}

pub fn peerSync(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, peer_meta_cid: []const u8) !void {
    if (!ipfsAlive(allocator, io)) {
        std.debug.print("❌ IPFS daemon not running. Start with: ipfs daemon\n", .{});
        return;
    }

    std.debug.print("🔄 Syncing from peer meta CID: {s}\n\n", .{peer_meta_cid});

    const ls_endpoint = try std.fmt.allocPrint(allocator, "/ls?arg={s}", .{peer_meta_cid});
    defer allocator.free(ls_endpoint);

    const ls_resp = try ipfsPost(allocator, io, ls_endpoint, &.{});
    defer allocator.free(ls_resp);

    if (ls_resp.len < 5 or std.mem.indexOf(u8, ls_resp, "Error") != null) {
        std.debug.print("❌ Could not list peer CID. Is it pinned/accessible?\n", .{});
        std.debug.print("   Response: {s}\n", .{ls_resp[0..@min(200, ls_resp.len)]});
        return;
    }

    std.debug.print("   Fetching metadata files...\n", .{});

    const sync_dirs = [_][]const u8{ "metrics", "experiments", "lineage", "snapshots", "refs" };

    var synced: usize = 0;
    var skipped: usize = 0;

    for (sync_dirs) |dir_name| {
        const subdir_endpoint = try std.fmt.allocPrint(allocator, "/ls?arg={s}/{s}", .{ peer_meta_cid, dir_name });
        defer allocator.free(subdir_endpoint);

        const subdir_resp = try ipfsPost(allocator, io, subdir_endpoint, &.{});
        defer allocator.free(subdir_resp);

        if (std.mem.indexOf(u8, subdir_resp, "Error") != null) continue;
        if (std.mem.indexOf(u8, subdir_resp, "Objects") == null) continue;

        var link_iter = std.mem.splitSequence(u8, subdir_resp, "\"Name\":");
        _ = link_iter.next();
        while (link_iter.next()) |chunk| {
            const name_start = std.mem.indexOf(u8, chunk, "\"") orelse continue;
            const name_end = std.mem.indexOf(u8, chunk[name_start + 1 ..], "\"") orelse continue;
            const file_name = chunk[name_start + 1 .. name_start + 1 + name_end];
            if (file_name.len == 0) continue;

            const hash_search = "\"Hash\":\"";
            const hi = std.mem.indexOf(u8, chunk, hash_search) orelse continue;
            const hash_start = hi + hash_search.len;
            const hash_end = std.mem.indexOf(u8, chunk[hash_start..], "\"") orelse continue;
            const file_hash = chunk[hash_start .. hash_start + hash_end];

            const local_dir: []u8 = if (std.mem.eql(u8, dir_name, "refs"))
                try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "heads" })
            else
                try std.fs.path.join(allocator, &.{ repo.path, ".zev", dir_name });
            defer allocator.free(local_dir);
            try std.Io.Dir.cwd().makePath(local_dir);

            const local_path = try std.fs.path.join(allocator, &.{ local_dir, file_name });
            defer allocator.free(local_path);

            std.Io.Dir.cwd().access(local_path, .{}) catch {
                const cat_endpoint = try std.fmt.allocPrint(allocator, "/cat?arg={s}", .{file_hash});
                defer allocator.free(cat_endpoint);
                const content = try ipfsPost(allocator, io, cat_endpoint, &.{});
                defer allocator.free(content);

                if (content.len > 0) {
                    const f = try std.Io.Dir.cwd().createFile(local_path, .{});
                    defer f.close();
                    try f.writeAll(content);
                    std.debug.print("   ✅ {s}/{s}\n", .{ dir_name, file_name });
                    synced += 1;
                }
                continue;
            };
            skipped += 1;
        }
    }

    const node_id = try getNodeId(allocator, io);
    defer allocator.free(node_id);
    try addPeer(allocator, repo, peer_meta_cid, peer_meta_cid);

    std.debug.print("\n✅ Sync complete!\n", .{});
    std.debug.print("   Synced:  {d} file(s)\n", .{synced});
    std.debug.print("   Skipped: {d} (already present)\n", .{skipped});
    std.debug.print("\n   Run 'zev log' to see synced commits\n", .{});
    std.debug.print("   Run 'zev lineage list' to see synced lineage\n", .{});
}

pub fn peerStatus(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository) !void {
    std.debug.print("🌐 Peer Status\n\n", .{});

    if (ipfsAlive(allocator, io)) {
        const node_id = try getNodeId(allocator, io);
        defer allocator.free(node_id);
        const addr = try getNodeAddrs(allocator, io, );
        defer allocator.free(addr);

        std.debug.print("   IPFS:     ✅ Running\n", .{});
        std.debug.print("   Node ID:  {s}\n", .{node_id});
        if (addr.len > 0)
            std.debug.print("   Address:  {s}\n", .{addr});
    } else {
        std.debug.print("   IPFS:     ❌ Not running (start with: ipfs daemon)\n", .{});
    }

    if (try loadPeerState(allocator, repo)) |state| {
        defer allocator.free(state.meta_cid);
        defer allocator.free(state.node_id);
        std.debug.print("   Meta CID: {s}\n", .{state.meta_cid});
        std.debug.print("\n   Share with peers: zev peer sync {s}\n", .{state.meta_cid});
    } else {
        std.debug.print("   Meta CID: (not announced yet)\n", .{});
        std.debug.print("   Announce: zev peer announce\n", .{});
    }

    std.debug.print("\n   Known peers:\n", .{});
    try listPeers(allocator, repo);
}

pub fn peerConnect(allocator: std.mem.Allocator,
    io: std.Io, multiaddr: []const u8) !void {
    if (!ipfsAlive(allocator, io)) {
        std.debug.print("❌ IPFS daemon not running. Start with: ipfs daemon\n", .{});
        return;
    }

    std.debug.print("🔗 Connecting to peer: {s}\n", .{multiaddr});

    const endpoint = try std.fmt.allocPrint(allocator, "/swarm/connect?arg={s}", .{multiaddr});
    defer allocator.free(endpoint);

    const resp = try ipfsPost(allocator, io, endpoint, &.{});
    defer allocator.free(resp);

    if (std.mem.indexOf(u8, resp, "success") != null or std.mem.indexOf(u8, resp, "connect") != null) {
        std.debug.print("✅ Connected!\n", .{});
        std.debug.print("   Now ask the peer to run: zev peer announce\n", .{});
        std.debug.print("   Then sync their meta CID: zev peer sync <meta-cid>\n", .{});
    } else {
        std.debug.print("⚠️  Response: {s}\n", .{resp[0..@min(300, resp.len)]});
    }
}

pub fn forkRepo(allocator: std.mem.Allocator,
    io: std.Io, peer_meta_cid: []const u8, target_dir: []const u8) !void {
    if (!ipfsAlive(allocator, io)) {
        std.debug.print("❌ IPFS daemon not running. Start with: ipfs daemon\n", .{});
        return;
    }

    std.debug.print("🍴 Forking repo from CID: {s}\n", .{peer_meta_cid});
    std.debug.print("   Target directory: {s}\n\n", .{target_dir});

    const zev_dir = try std.fs.path.join(allocator, &.{ target_dir, ".zev" });
    defer allocator.free(zev_dir);
    try std.Io.Dir.cwd().makePath(zev_dir);

    const subdirs = [_][]const u8{
        "objects", "refs/heads", "metrics", "experiments",
        "lineage", "snapshots",
    };
    for (subdirs) |sub| {
        const p = try std.fs.path.join(allocator, &.{ zev_dir, sub });
        defer allocator.free(p);
        try std.Io.Dir.cwd().makePath(p);
    }

    const head_path = try std.fs.path.join(allocator, &.{ zev_dir, "HEAD" });
    defer allocator.free(head_path);
    const hf = try std.Io.Dir.cwd().createFile(head_path, .{});
    try hf.writeAll("ref: refs/heads/main\n");
    hf.close();

    std.debug.print("   Fetching metadata from IPFS...\n", .{});

    const argv = [_][]const u8{
        "ipfs", "get", "--output", zev_dir, peer_meta_cid,
    };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var buf: [4096]u8 = undefined;
    _ = child.stderr.?.read(&buf) catch 0;
    const term = try child.wait(io);

    const success = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };

    if (success) {
        std.debug.print("✅ Fork complete!\n\n", .{});
        std.debug.print("   Directory: {s}\n", .{target_dir});
        std.debug.print("   Meta CID:  {s}\n\n", .{peer_meta_cid});
        std.debug.print("   Next steps:\n", .{});
        std.debug.print("   cd {s}\n", .{target_dir});
        std.debug.print("   zev log          # see synced commit history\n", .{});
        std.debug.print("   zev lineage list # see data provenance\n", .{});
        std.debug.print("   zev snapshot list\n", .{});
        std.debug.print("   zev search all \"\"\n", .{});
    } else {
        std.debug.print("   Trying file-by-file fetch...\n", .{});

        var tmp_repo = Repository.open(allocator, target_dir) catch {
            std.debug.print("❌ Could not open forked repo for sync\n", .{});
            return;
        };
        defer tmp_repo.deinit();

        try peerSync(allocator, io, &tmp_repo, peer_meta_cid);
    }

    try ipfsPin(allocator, io, peer_meta_cid);
    std.debug.print("   📌 Pinned CID to local IPFS node\n", .{});
}

pub fn peerListen(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, topic: []const u8, timeout_secs: u32) !void {
    if (!ipfsAlive(allocator, io)) {
        std.debug.print("❌ IPFS daemon not running. Start with: ipfs daemon\n", .{});
        return;
    }

    std.debug.print("👂 Listening for peers on topic '{s}' ({d}s)...\n\n", .{ topic, timeout_secs });

    const timeout_str = try std.fmt.allocPrint(allocator, "{d}", .{timeout_secs});
    defer allocator.free(timeout_str);

    const argv = [_][]const u8{ "timeout", timeout_str, "ipfs", "pubsub", "sub", topic };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    var total_buf: [65536]u8 = undefined;
    var total_read: usize = 0;
    var read_buf: [4096]u8 = undefined;
    while (true) {
        var child_scratch: [4096]u8 = undefined;
        var child_reader = child.stdout.?.reader(io, &child_scratch);
        const n = child_reader.interface.readSliceShort(&read_buf) catch break;
        if (n == 0) break;
        const space = total_buf.len - total_read;
        const to_copy = @min(n, space);
        @memcpy(total_buf[total_read .. total_read + to_copy], read_buf[0..to_copy]);
        total_read += to_copy;
    }
    _ = child.wait(io) catch {};

    const output = total_buf[0..total_read];
    if (output.len == 0) {
        std.debug.print("   No announcements received.\n", .{});
        std.debug.print("   Ask a peer to run: zev peer announce\n", .{});
        return;
    }

    var found: usize = 0;
    var line_iter = std.mem.splitSequence(u8, output, "\n");
    while (line_iter.next()) |line| {
        if (line.len < 10) continue;
        if (std.mem.indexOf(u8, line, "zev-announce") == null) continue;

        found += 1;
        const node_id = (try extractJsonStr(allocator, line, "node_id")) orelse
            try allocator.dupe(u8, "unknown");
        defer allocator.free(node_id);
        const meta_cid = (try extractJsonStr(allocator, line, "meta_cid")) orelse
            try allocator.dupe(u8, "");
        defer allocator.free(meta_cid);
        const addr = (try extractJsonStr(allocator, line, "addr")) orelse
            try allocator.dupe(u8, "");
        defer allocator.free(addr);

        std.debug.print("📡 Peer found:\n", .{});
        std.debug.print("   Node ID:  {s}\n", .{node_id});
        std.debug.print("   Meta CID: {s}\n", .{meta_cid});
        if (addr.len > 0) std.debug.print("   Address:  {s}\n", .{addr});
        std.debug.print("\n   To sync: zev peer sync {s}\n\n", .{meta_cid});

        if (meta_cid.len > 0) {
            try addPeer(allocator, repo, node_id, meta_cid);
        }
    }

    if (found == 0) {
        std.debug.print("   No valid zev announcements in received data.\n", .{});
    } else {
        std.debug.print("   Found {d} peer(s). Peers saved to .zev/peers\n", .{found});
    }
}

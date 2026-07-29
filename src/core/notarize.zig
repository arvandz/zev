const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");

pub const NotarizeResult = struct {
    tx_hash: []u8,
    block: []u8,
};

pub const NotarizationRecord = struct {
    id: []const u8,
    subject_type: []const u8,
    subject_id: []const u8,
    subject_cid: []const u8,
    metrics: []const u8,
    author: []const u8,
    timestamp: i64,
    chain: []const u8,
    tx_hash: []const u8,
    block: []const u8,
    verified: bool,
};

fn notarizeDir(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository) ![]u8 {
    const dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "notarizations" });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn saveRecord(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, rec: NotarizationRecord) !void {
    const dir = try notarizeDir(allocator, io, repo);
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, rec.id });
    defer allocator.free(path);

    const f = try std.Io.Dir.cwd().createFile(path, .{});
    defer f.close(io);

    const verified_str: []const u8 = if (rec.verified) "true" else "false";
    const content = try std.fmt.allocPrint(allocator, "id={s}\nsubject_type={s}\nsubject_id={s}\nsubject_cid={s}\nmetrics={s}\nauthor={s}\ntimestamp={d}\nchain={s}\ntx_hash={s}\nblock={s}\nverified={s}\n", .{ rec.id, rec.subject_type, rec.subject_id, rec.subject_cid, rec.metrics, rec.author, rec.timestamp, rec.chain, rec.tx_hash, rec.block, verified_str });
    defer allocator.free(content);
    try f.writeAll(content);
}

fn loadRecord(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, id: []const u8) !?NotarizationRecord {
    const dir = try notarizeDir(allocator, io, repo);
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, id });
    defer allocator.free(path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(content);

    var rec_id: []u8 = try allocator.dupe(u8, "");
    var subject_type: []u8 = try allocator.dupe(u8, "");
    var subject_id: []u8 = try allocator.dupe(u8, "");
    var subject_cid: []u8 = try allocator.dupe(u8, "");
    var metrics: []u8 = try allocator.dupe(u8, "");
    var author: []u8 = try allocator.dupe(u8, "");
    var timestamp: i64 = 0;
    var chain: []u8 = try allocator.dupe(u8, "");
    var tx_hash: []u8 = try allocator.dupe(u8, "");
    var block: []u8 = try allocator.dupe(u8, "");
    var verified: bool = false;

    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOf(u8, line, "=") orelse continue;
        const k = line[0..eq];
        const v = line[eq + 1 ..];
        if (std.mem.eql(u8, k, "id")) {
            allocator.free(rec_id);
            rec_id = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "subject_type")) {
            allocator.free(subject_type);
            subject_type = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "subject_id")) {
            allocator.free(subject_id);
            subject_id = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "subject_cid")) {
            allocator.free(subject_cid);
            subject_cid = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "metrics")) {
            allocator.free(metrics);
            metrics = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "author")) {
            allocator.free(author);
            author = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "timestamp")) {
            timestamp = std.fmt.parseInt(i64, v, 10) catch 0;
        } else if (std.mem.eql(u8, k, "chain")) {
            allocator.free(chain);
            chain = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "tx_hash")) {
            allocator.free(tx_hash);
            tx_hash = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "block")) {
            allocator.free(block);
            block = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "verified")) {
            verified = std.mem.eql(u8, v, "true");
        }
    }

    return NotarizationRecord{
        .id = rec_id,
        .subject_type = subject_type,
        .subject_id = subject_id,
        .subject_cid = subject_cid,
        .metrics = metrics,
        .author = author,
        .timestamp = timestamp,
        .chain = chain,
        .tx_hash = tx_hash,
        .block = block,
        .verified = verified,
    };
}

fn freeRecord(allocator: std.mem.Allocator, rec: NotarizationRecord) void {
    allocator.free(rec.id);
    allocator.free(rec.subject_type);
    allocator.free(rec.subject_id);
    allocator.free(rec.subject_cid);
    allocator.free(rec.metrics);
    allocator.free(rec.author);
    allocator.free(rec.chain);
    allocator.free(rec.tx_hash);
    allocator.free(rec.block);
}

fn getAuthor(allocator: std.mem.Allocator, io: std.Io, repo: *Repository) ![]u8 {
    const config_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "config" });
    defer allocator.free(config_path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(4096)) catch
        return try allocator.dupe(u8, "unknown");
    defer allocator.free(content);
    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "user.name="))
            return try allocator.dupe(u8, line[10..]);
    }
    return try allocator.dupe(u8, "unknown");
}

fn computeRecordId(allocator: std.mem.Allocator,
    io: std.Io, subject_cid: []const u8, timestamp: i64) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, "notarize:{s}:{d}", .{ subject_cid, timestamp });
    defer allocator.free(raw);
    const c = cid_mod.CID.fromBytes(io, raw);
    return try c.toString(allocator);
}

fn buildPayload(
    allocator: std.mem.Allocator,
    subject_type: []const u8,
    subject_id: []const u8,
    subject_cid: []const u8,
    metrics: []const u8,
    author: []const u8,
    timestamp: i64,
) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\{{
        \\  "zev": "1.0",
        \\  "type": "{s}",
        \\  "id": "{s}",
        \\  "cid": "{s}",
        \\  "metrics": "{s}",
        \\  "author": "{s}",
        \\  "timestamp": {d}
        \\}}
    , .{ subject_type, subject_id, subject_cid, metrics, author, timestamp });
}

fn runCmd(allocator: std.mem.Allocator,
    io: std.Io, argv: []const []const u8) ![]u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var buf: [65536]u8 = undefined;
    var child_scratch: [4096]u8 = undefined;
    var child_reader = child.stdout.?.reader(io, &child_scratch);
    const n = child_reader.interface.readSliceShort(&buf) catch 0;
    _ = try child.wait(io);
    return try allocator.dupe(u8, buf[0..n]);
}

fn loadEthConfig(allocator: std.mem.Allocator, io: std.Io, repo: *Repository) !struct {
    rpc_url: []u8,
    private_key: []u8,
    from_addr: []u8,
} {
    const config_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "config" });
    defer allocator.free(config_path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(64 * 1024)) catch
        return error.NoConfig;
    defer allocator.free(content);

    var rpc_url: []u8 = try allocator.dupe(u8, "");
    var private_key: []u8 = try allocator.dupe(u8, "");
    var from_addr: []u8 = try allocator.dupe(u8, "");

    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "notarize.eth.rpc=")) {
            allocator.free(rpc_url);
            rpc_url = try allocator.dupe(u8, line[17..]);
        } else if (std.mem.startsWith(u8, line, "notarize.eth.key=")) {
            allocator.free(private_key);
            private_key = try allocator.dupe(u8, line[17..]);
        } else if (std.mem.startsWith(u8, line, "notarize.eth.from=")) {
            allocator.free(from_addr);
            from_addr = try allocator.dupe(u8, line[18..]);
        }
    }
    return .{ .rpc_url = rpc_url, .private_key = private_key, .from_addr = from_addr };
}

fn submitEthereum(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, payload: []const u8) !NotarizeResult {
    const eth = loadEthConfig(allocator, repo) catch {
        return error.EthNotConfigured;
    };
    defer allocator.free(eth.rpc_url);
    defer allocator.free(eth.private_key);
    defer allocator.free(eth.from_addr);

    if (eth.rpc_url.len == 0 or eth.private_key.len == 0) {
        return error.EthNotConfigured;
    }

    const hex_payload = try hexEncode(allocator, payload);
    defer allocator.free(hex_payload);
    const data_field = try std.fmt.allocPrint(allocator, "0x{s}", .{hex_payload});
    defer allocator.free(data_field);

    const cast_available = blk: {
        const r = runCmd(allocator, io, &.{ "cast", "--version" }) catch {
            break :blk false;
        };
        allocator.free(r);
        break :blk true;
    };

    if (cast_available) {
        const argv = [_][]const u8{
            "cast",                                       "send",
            "--rpc-url",                                  eth.rpc_url,
            "--private-key",                              eth.private_key,
            "0x0000000000000000000000000000000000000000", "--value",
            "0",                                          "--data",
            data_field,                                   "--json",
        };
        const resp = try runCmd(allocator, io, &argv);
        defer allocator.free(resp);

        if (std.mem.indexOf(u8, resp, "transactionHash")) |_| {
            const tx = extractJsonFieldRaw(allocator, resp, "transactionHash") catch
                try allocator.dupe(u8, "unknown");
            const blk = extractJsonFieldRaw(allocator, resp, "blockNumber") catch
                try allocator.dupe(u8, "unknown");
            return .{ .tx_hash = tx, .block = blk };
        }
    }

    const nonce_req = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionCount\",\"params\":[\"{s}\",\"latest\"],\"id\":1}}", .{eth.from_addr});
    defer allocator.free(nonce_req);

    const tmp = "/tmp/zev_eth_req.json";
    const tf = try std.Io.Dir.cwd().createFile(tmp, .{});
    try tf.writeAll(nonce_req);
    tf.close(io);

    const nonce_resp = try runCmd(allocator, io, &.{
        "curl",   "-s",                     "-X",        "POST", "-H", "Content-Type: application/json",
        "--data", "@/tmp/zev_eth_req.json", eth.rpc_url,
    });
    defer allocator.free(nonce_resp);

    std.debug.print("⚠️  For full Ethereum support, install Foundry: https://getfoundry.sh\n", .{});
    std.debug.print("   curl -L https://foundry.paradigm.xyz | bash && foundryup\n", .{});
    return error.NeedsCast;
}

fn hexEncode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, data.len * 2);
    for (data, 0..) |byte, i| {
        const hi = byte >> 4;
        const lo = byte & 0x0f;
        out[i * 2] = if (hi < 10) '0' + hi else 'a' + hi - 10;
        out[i * 2 + 1] = if (lo < 10) '0' + lo else 'a' + lo - 10;
    }
    return out;
}

fn extractJsonFieldRaw(allocator: std.mem.Allocator, json: []const u8, field: []const u8) ![]u8 {
    const search = try std.fmt.allocPrint(allocator, "\"{s}\":", .{field});
    defer allocator.free(search);
    const idx = std.mem.indexOf(u8, json, search) orelse return error.FieldNotFound;
    const after = std.mem.trimLeft(u8, json[idx + search.len ..], " \t");
    if (after.len == 0) return error.FieldNotFound;
    if (after[0] == '"') {
        const end = std.mem.indexOf(u8, after[1..], "\"") orelse return error.FieldNotFound;
        return try allocator.dupe(u8, after[1 .. 1 + end]);
    }
    var end: usize = 0;
    while (end < after.len and after[end] != ',' and after[end] != '}' and after[end] != '\n') end += 1;
    return try allocator.dupe(u8, std.mem.trim(u8, after[0..end], " \t\r\n"));
}

fn submitArweave(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, payload: []const u8) !NotarizeResult {
    const config_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "config" });
    defer allocator.free(config_path);
    const config = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(64 * 1024)) catch
        return error.NoConfig;
    defer allocator.free(config);

    var arweave_key: []u8 = try allocator.dupe(u8, "");
    defer allocator.free(arweave_key);

    var iter = std.mem.splitSequence(u8, config, "\n");
    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "notarize.arweave.keyfile=")) {
            allocator.free(arweave_key);
            arweave_key = try allocator.dupe(u8, line[25..]);
        }
    }

    if (arweave_key.len == 0) return error.ArweaveNotConfigured;

    const tmp_payload = "/tmp/zev_arweave_payload.json";
    const tf = try std.Io.Dir.cwd().createFile(io, tmp_payload, .{});
    var tf_buffer: [512]u8 = undefined;
    var tf_writer = tf.writer(io, &tf_buffer);
    try tf_writer.interface.writeAll(payload);
    try tf_writer.flush();
    tf.close(io);

    const resp = runCmd(allocator, io, &.{
        "arkb",           "deploy",    tmp_payload,
        "--wallet",       arweave_key, "--tag",
        "App-Name",       "--tag",     "zev-notarize",
        "--auto-confirm",
    }) catch return error.ArkbNotFound;
    defer allocator.free(resp);

    if (std.mem.indexOf(u8, resp, "Transaction ID") != null or resp.len > 40) {
        const tx = try allocator.dupe(u8, std.mem.trim(u8, resp, " \n\r\t"));
        return .{ .tx_hash = tx, .block = try allocator.dupe(u8, "pending") };
    }
    return error.ArweaveFailed;
}

fn notarizeLocal(
    allocator: std.mem.Allocator,
    io: std.Io,
    payload: []const u8,
    timestamp: i64,
) !NotarizeResult {
    const combined = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ payload, timestamp });
    defer allocator.free(combined);

    const fingerprint_cid = cid_mod.CID.fromBytes(io, combined);
    const fingerprint = try fingerprint_cid.toString(allocator);

    const proof_path = "/tmp/zev_notarization_proof.json";
    const pf = try std.Io.Dir.cwd().createFile(io, proof_path, .{});
    defer pf.close(io);
    var pf_buffer: [512]u8 = undefined;
    var pf_writer = pf.writer(io, &pf_buffer);

    const proof = try std.fmt.allocPrint(allocator, "{{\n  \"proof\": \"{s}\",\n  \"timestamp\": {d},\n  \"payload\": {s}\n}}\n", .{ fingerprint, timestamp, payload });
    defer allocator.free(proof);
    try pf_writer.interface.writeAll(proof);
    try pf_writer.flush();

    return .{
        .tx_hash = fingerprint,
        .block = try allocator.dupe(u8, "local"),
    };
}

fn findSnapshotCid(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, name: []const u8) !?struct { cid: []u8, metrics: []u8, commit: []u8 } {
    const dir_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "snapshots" });
    defer allocator.free(dir_path);
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".name")) continue;

        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(content);

        var snap_name: []u8 = try allocator.dupe(u8, "");
        var commit_hash: []u8 = try allocator.dupe(u8, "");
        var metrics_snap: []u8 = try allocator.dupe(u8, "");
        defer allocator.free(snap_name);

        var line_iter = std.mem.splitSequence(u8, content, "\n");
        while (line_iter.next()) |line| {
            if (std.mem.startsWith(u8, line, "name=")) {
                allocator.free(snap_name);
                snap_name = try allocator.dupe(u8, line[5..]);
            } else if (std.mem.startsWith(u8, line, "commit_hash=")) {
                allocator.free(commit_hash);
                commit_hash = try allocator.dupe(u8, line[12..]);
            } else if (std.mem.startsWith(u8, line, "metrics_snapshot=")) {
                allocator.free(metrics_snap);
                metrics_snap = try allocator.dupe(u8, line[17..]);
            }
        }

        if (std.mem.eql(u8, snap_name, name)) {
            return .{
                .cid = try allocator.dupe(u8, entry.name),
                .metrics = metrics_snap,
                .commit = commit_hash,
            };
        }
        allocator.free(commit_hash);
        allocator.free(metrics_snap);
    }
    return null;
}

pub fn notarizeSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    snap_name: []const u8,
    chain: []const u8,
    dry_run: bool,
) !void {
    const snap = (try findSnapshotCid(allocator, io, repo, snap_name)) orelse {
        std.debug.print("Error: Snapshot '{s}' not found\n", .{snap_name});
        return;
    };
    defer allocator.free(snap.cid);
    defer allocator.free(snap.metrics);
    defer allocator.free(snap.commit);

    const author = try getAuthor(allocator, repo);
    defer allocator.free(author);

    const now = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);

    const payload = try buildPayload(allocator, "snapshot", snap_name, snap.cid, snap.metrics, author, now);
    defer allocator.free(payload);

    const rec_id = try computeRecordId(allocator, io, snap.cid, now);
    defer allocator.free(rec_id);

    std.debug.print("⛓️  Notarizing snapshot '{s}'\n\n", .{snap_name});
    std.debug.print("   Subject CID: {s}\n", .{snap.cid[0..@min(16, snap.cid.len)]});
    std.debug.print("   Commit:      {s}\n", .{snap.commit[0..@min(8, snap.commit.len)]});
    std.debug.print("   Metrics:     {s}\n", .{snap.metrics});
    std.debug.print("   Chain:       {s}\n", .{chain});
    std.debug.print("   Record ID:   {s}\n\n", .{rec_id[0..16]});

    if (dry_run) {
        std.debug.print("🔍 Dry run — payload that would be submitted:\n\n", .{});
        std.debug.print("{s}\n\n", .{payload});
        std.debug.print("   Record ID (local):  {s}\n", .{rec_id});
        std.debug.print("   To submit for real: remove --dry-run\n", .{});
        return;
    }

    const result = blk: {
        if (std.mem.eql(u8, chain, "ethereum")) {
            break :blk submitEthereum(allocator, io, repo, payload) catch |err| {
                if (err == error.EthNotConfigured) {
                    std.debug.print("❌ Ethereum not configured.\n", .{});
                    std.debug.print("   Set up with:\n", .{});
                    std.debug.print("   zev notarize config --chain ethereum --rpc https://mainnet.infura.io/v3/YOUR_KEY\n", .{});
                    std.debug.print("   zev notarize config --key YOUR_PRIVATE_KEY --from 0xYOUR_ADDRESS\n", .{});
                    std.debug.print("   Falling back to local notarization...\n\n", .{});
                }
                break :blk try notarizeLocal(allocator, io, payload, now);
            };
        } else if (std.mem.eql(u8, chain, "arweave")) {
            break :blk submitArweave(allocator, repo, payload) catch |err| {
                if (err == error.ArweaveNotConfigured or err == error.ArkbNotFound) {
                    std.debug.print("❌ Arweave not configured or arkb not found.\n", .{});
                    std.debug.print("   Install arkb: npm install -g arkb\n", .{});
                    std.debug.print("   Configure: zev notarize config --chain arweave --keyfile /path/to/wallet.json\n", .{});
                    std.debug.print("   Falling back to local notarization...\n\n", .{});
                }
                break :blk try notarizeLocal(allocator, io, payload, now);
            };
        } else {
            break :blk try notarizeLocal(allocator, io, payload, now);
        }
    };
    defer allocator.free(result.tx_hash);
    defer allocator.free(result.block);

    const actual_chain = if (std.mem.eql(u8, result.block, "local")) "local" else chain;
    const rec = NotarizationRecord{
        .id = rec_id,
        .subject_type = "snapshot",
        .subject_id = snap_name,
        .subject_cid = snap.cid,
        .metrics = snap.metrics,
        .author = author,
        .timestamp = now,
        .chain = actual_chain,
        .tx_hash = result.tx_hash,
        .block = result.block,
        .verified = true,
    };
    try saveRecord(allocator, io, repo, rec);

    const chain_icon: []const u8 = if (std.mem.eql(u8, actual_chain, "ethereum")) "⟠" else if (std.mem.eql(u8, actual_chain, "arweave")) "◎" else "🔒";

    std.debug.print("{s} Notarization complete!\n\n", .{chain_icon});
    if (!std.mem.eql(u8, actual_chain, "local")) {
        std.debug.print("   TX Hash: {s}\n", .{result.tx_hash});
        std.debug.print("   Block:   {s}\n", .{result.block});
    } else {
        std.debug.print("   Proof:   {s}\n", .{result.tx_hash[0..@min(16, result.tx_hash.len)]});
        std.debug.print("   Chain:   local (cryptographic fingerprint)\n", .{});
    }
    std.debug.print("   Record:  {s}\n", .{rec_id[0..16]});
    std.debug.print("\n   Verify anytime: zev notarize verify {s}\n", .{rec_id[0..16]});
}

pub fn notarizeCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    chain: []const u8,
    dry_run: bool,
) !void {
    const head = repo.getHeadCommit(io) catch {
        std.debug.print("Error: No commits yet.\n", .{});
        return;
    };
    const commit_hash = try head.toString(allocator);
    defer allocator.free(commit_hash);

    const metrics_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "metrics", commit_hash });
    defer allocator.free(metrics_path);
    var metrics_str: []u8 = try allocator.dupe(u8, "");
    defer allocator.free(metrics_str);

    const metrics_content = std.Io.Dir.cwd().readFileAlloc(io, metrics_path, allocator, .limited(64 * 1024)) catch
        try allocator.dupe(u8, "");
    defer allocator.free(metrics_content);

    if (metrics_content.len > 0) {
        var result: std.ArrayList(u8) = .empty;
        var first = true;
        var miter = std.mem.splitSequence(u8, metrics_content, "\n");
        while (miter.next()) |line| {
            if (line.len == 0) continue;
            const tab = std.mem.indexOf(u8, line, "\t") orelse line.len;
            const kv = line[0..tab];
            if (kv.len == 0) continue;
            if (!first) try result.append(allocator, ';');
            try result.appendSlice(allocator, kv);
            first = false;
        }
        allocator.free(metrics_str);
        metrics_str = try result.toOwnedSlice(allocator);
    }

    const author = try getAuthor(allocator, repo);
    defer allocator.free(author);
    const now = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);

    const payload = try buildPayload(allocator, "commit", commit_hash, commit_hash, metrics_str, author, now);
    defer allocator.free(payload);

    const rec_id = try computeRecordId(allocator, io, commit_hash, now);
    defer allocator.free(rec_id);

    std.debug.print("⛓️  Notarizing commit {s}\n\n", .{commit_hash[0..8]});
    std.debug.print("   Chain:   {s}\n", .{chain});
    if (metrics_str.len > 0)
        std.debug.print("   Metrics: {s}\n", .{metrics_str});

    if (dry_run) {
        std.debug.print("\n🔍 Dry run payload:\n\n{s}\n", .{payload});
        return;
    }

    const result = try notarizeLocal(allocator, io, payload, now);
    defer allocator.free(result.tx_hash);
    defer allocator.free(result.block);

    const rec = NotarizationRecord{
        .id = rec_id,
        .subject_type = "commit",
        .subject_id = commit_hash,
        .subject_cid = commit_hash,
        .metrics = metrics_str,
        .author = author,
        .timestamp = now,
        .chain = "local",
        .tx_hash = result.tx_hash,
        .block = result.block,
        .verified = true,
    };
    try saveRecord(allocator, io, repo, rec);

    std.debug.print("🔒 Notarized!\n", .{});
    std.debug.print("   Proof:  {s}\n", .{result.tx_hash[0..@min(16, result.tx_hash.len)]});
    std.debug.print("   Verify: zev notarize verify {s}\n", .{rec_id[0..16]});
}

pub fn notarizeVerify(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, rec_id_prefix: []const u8) !void {
    const dir = try notarizeDir(allocator, io, repo);
    defer allocator.free(dir);

    var found_rec: ?NotarizationRecord = null;
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch {
        std.debug.print("No notarizations yet.\n", .{});
        return;
    };
    defer d.close(io);

    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, rec_id_prefix)) {
            found_rec = try loadRecord(allocator, repo, entry.name);
            break;
        }
    }

    const rec = found_rec orelse {
        std.debug.print("Error: No notarization found with ID prefix '{s}'\n", .{rec_id_prefix});
        return;
    };
    defer freeRecord(allocator, rec);

    std.debug.print("\n⛓️  Notarization Record\n", .{});
    std.debug.print("   ─────────────────────────────────────────\n", .{});
    std.debug.print("   ID:          {s}\n", .{rec.id[0..@min(16, rec.id.len)]});
    std.debug.print("   Type:        {s}\n", .{rec.subject_type});
    std.debug.print("   Subject:     {s}\n", .{rec.subject_id});
    std.debug.print("   CID:         {s}\n", .{rec.subject_cid[0..@min(16, rec.subject_cid.len)]});
    std.debug.print("   Author:      {s}\n", .{rec.author});
    std.debug.print("   Timestamp:   {d}\n", .{rec.timestamp});
    std.debug.print("   Chain:       {s}\n", .{rec.chain});
    if (rec.tx_hash.len > 0)
        std.debug.print("   Proof/TX:    {s}\n", .{rec.tx_hash[0..@min(20, rec.tx_hash.len)]});
    if (rec.metrics.len > 0)
        std.debug.print("   Metrics:     {s}\n", .{rec.metrics});

    const recomputed = try computeRecordId(allocator, io, rec.subject_cid, rec.timestamp);
    defer allocator.free(recomputed);

    const id_matches = std.mem.eql(u8, recomputed, rec.id);
    std.debug.print("\n   Integrity:   {s}\n", .{if (id_matches) "✅ VALID — record ID matches CID + timestamp" else "❌ INVALID — record may have been tampered"});

    if (!std.mem.eql(u8, rec.chain, "local")) {
        std.debug.print("   On-chain:    ✅ Submitted to {s}\n", .{rec.chain});
        if (std.mem.eql(u8, rec.chain, "ethereum"))
            std.debug.print("   Explorer:    https://etherscan.io/tx/{s}\n", .{rec.tx_hash});
    }
    std.debug.print("\n", .{});
}

pub fn notarizeList(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository) !void {
    const dir = try notarizeDir(allocator, io, repo);
    defer allocator.free(dir);

    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch {
        std.debug.print("No notarizations yet.\n", .{});
        std.debug.print("Create one: zev notarize snapshot <name>\n", .{});
        return;
    };
    defer d.close(io);

    std.debug.print("⛓️  Notarizations:\n\n", .{});
    var count: usize = 0;

    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const rec = (try loadRecord(allocator, repo, entry.name)) orelse continue;
        defer freeRecord(allocator, rec);
        count += 1;

        const chain_icon: []const u8 = if (std.mem.eql(u8, rec.chain, "ethereum")) "⟠" else if (std.mem.eql(u8, rec.chain, "arweave")) "◎" else "🔒";

        std.debug.print("  {s} {s}  [{s}] {s}\n", .{ chain_icon, rec.subject_id, rec.subject_type, rec.chain });
        std.debug.print("     ID: {s}\n", .{rec.id[0..@min(16, rec.id.len)]});
        if (rec.metrics.len > 0)
            std.debug.print("     Metrics: {s}\n", .{rec.metrics});
        std.debug.print("\n", .{});
    }

    if (count == 0) {
        std.debug.print("  No notarizations yet.\n", .{});
        std.debug.print("  Create one: zev notarize snapshot <name>\n", .{});
    } else {
        std.debug.print("  Total: {d}\n", .{count});
    }
}

pub fn notarizeConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    chain: []const u8,
    rpc_url: ?[]const u8,
    private_key: ?[]const u8,
    from_addr: ?[]const u8,
    keyfile: ?[]const u8,
) !void {
    const config_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "config" });
    defer allocator.free(config_path);

    const existing = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(64 * 1024)) catch
        try allocator.dupe(u8, "");
    defer allocator.free(existing);

    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(allocator);

    var iter = std.mem.splitSequence(u8, existing, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const skip =
            (rpc_url != null and std.mem.startsWith(u8, line, "notarize.eth.rpc=")) or
            (private_key != null and std.mem.startsWith(u8, line, "notarize.eth.key=")) or
            (from_addr != null and std.mem.startsWith(u8, line, "notarize.eth.from=")) or
            (keyfile != null and std.mem.startsWith(u8, line, "notarize.arweave.keyfile="));
        if (!skip) {
            try lines.appendSlice(allocator, line);
            try lines.append(allocator, '\n');
        }
    }

    if (std.mem.eql(u8, chain, "ethereum")) {
        if (rpc_url) |u| {
            const s = try std.fmt.allocPrint(allocator, "notarize.eth.rpc={s}\n", .{u});
            defer allocator.free(s);
            try lines.appendSlice(allocator, s);
        }
        if (private_key) |k| {
            const s = try std.fmt.allocPrint(allocator, "notarize.eth.key={s}\n", .{k});
            defer allocator.free(s);
            try lines.appendSlice(allocator, s);
        }
        if (from_addr) |a| {
            const s = try std.fmt.allocPrint(allocator, "notarize.eth.from={s}\n", .{a});
            defer allocator.free(s);
            try lines.appendSlice(allocator, s);
        }
    } else if (std.mem.eql(u8, chain, "arweave")) {
        if (keyfile) |kf| {
            const s = try std.fmt.allocPrint(allocator, "notarize.arweave.keyfile={s}\n", .{kf});
            defer allocator.free(s);
            try lines.appendSlice(allocator, s);
        }
    }

    const f = try std.Io.Dir.cwd().createFile(config_path, .{});
    defer f.close(io);
    try f.writeAll(lines.items);

    std.debug.print("✅ Notarize config updated for chain: {s}\n", .{chain});
    if (rpc_url) |u| std.debug.print("   RPC URL: {s}\n", .{u});
    if (from_addr) |a| std.debug.print("   From:    {s}\n", .{a});
    if (keyfile) |kf| std.debug.print("   Keyfile: {s}\n", .{kf});
}

const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;
const Ed25519 = std.crypto.sign.Ed25519;
const b64 = std.base64;

pub fn blake3(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Blake3.hash(data, &out, .{});
    return out;
}

pub fn blake3Keyed(context: []const u8, data: []const u8) [32]u8 {
    var h = Blake3.initKdf(context, .{});
    h.update(data);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

pub const Blake3Hasher = struct {
    inner: Blake3,

    pub fn init(io: std.Io, ) Blake3Hasher {
        return .{ .inner = Blake3.init(io, .{}) };
    }

    pub fn update(self: *Blake3Hasher, data: []const u8) void {
        self.inner.update(data);
    }

    pub fn final(self: *Blake3Hasher) [32]u8 {
        var out: [32]u8 = undefined;
        self.inner.final(&out);
        return out;
    }

    pub fn reset(self: *Blake3Hasher) void {
        self.inner.reset();
    }
};

const b64url = b64.url_safe_no_pad;

pub fn b64Encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const len = b64url.Encoder.calcSize(data.len);
    const out = try allocator.alloc(u8, len);
    _ = b64url.Encoder.encode(out, data);
    return out;
}

pub fn b64Decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const max_len = try b64url.Decoder.calcSizeUpperBound(encoded.len);
    const out = try allocator.alloc(u8, max_len);
    errdefer allocator.free(out);
    const actual = try b64url.Decoder.calcSizeForSlice(encoded);
    try b64url.Decoder.decode(out[0..actual], encoded);
    return out[0..actual];
}

pub fn b64Encode32(data: [32]u8) [43]u8 {
    var out: [43]u8 = undefined;
    _ = b64url.Encoder.encode(&out, &data);
    return out;
}

pub fn b64Encode64(data: [64]u8) [86]u8 {
    var out: [86]u8 = undefined;
    _ = b64url.Encoder.encode(&out, &data);
    return out;
}

pub fn b64Decode32(encoded: []const u8) ![32]u8 {
    if (encoded.len < 43) return error.TooShort;
    var out: [32]u8 = undefined;
    try b64url.Decoder.decode(&out, encoded[0..43]);
    return out;
}

pub fn b64Decode64(encoded: []const u8) ![64]u8 {
    if (encoded.len < 86) return error.TooShort;
    var out: [64]u8 = undefined;
    try b64url.Decoder.decode(&out, encoded[0..86]);
    return out;
}

pub const Identity = struct {
    key_pair: Ed25519.KeyPair,

    pub fn generate() Identity {
        return .{ .key_pair = Ed25519.KeyPair.generate() };
    }

    pub fn loadOrCreate(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8) !Identity {
        const id_path = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "identity" });
        defer allocator.free(id_path);

        if (std.Io.Dir.cwd().readFileAlloc(io, id_path, allocator, .limited(256))) |content| {
            defer allocator.free(content);
            const trimmed = std.mem.trim(u8, content, "\n\r ");
            const seed_bytes = try b64Decode32(trimmed);
            const kp = try Ed25519.KeyPair.generateDeterministic(seed_bytes);
            return .{ .key_pair = kp };
        } else |_| {}

        const id = Identity.generate();
        try id.save(allocator, repo_path);
        return id;
    }

    pub fn save(self: Identity, allocator: std.mem.Allocator, repo_path: []const u8) !void {
        const id_path = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "identity" });
        defer allocator.free(id_path);

        const sk_bytes = self.key_pair.secret_key.toBytes();
        var seed: [32]u8 = undefined;
        @memcpy(&seed, sk_bytes[0..32]);

        const encoded = b64Encode32(seed);
        const f = try std.Io.Dir.cwd().createFile(id_path, .{ .mode = 0o600 });
        defer f.close(io);
        try f.writeAll(&encoded);
        try f.writeAll("\n");
    }

    pub fn publicKeyB64(self: Identity) [43]u8 {
        return b64Encode32(self.key_pair.public_key.toBytes());
    }

    pub fn sign(self: Identity, data: []const u8) ![86]u8 {
        const sig = try self.key_pair.sign(data, null);
        return b64Encode64(sig.toBytes());
    }

    pub fn signHash(self: Identity, data: []const u8) ![86]u8 {
        const hash = blake3(data);
        return self.sign(&hash);
    }
};

pub fn verify(io: std.Io, 
    data: []const u8,
    sig_b64: []const u8,
    pubkey_b64: []const u8,
) !void {
    const sig_bytes = try b64Decode64(sig_b64);
    const pk_bytes = try b64Decode32(pubkey_b64);

    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    const pk = try Ed25519.PublicKey.fromBytes(pk_bytes);
    try sig.verify(io, data, pk);
}

pub fn verifyHash(io: std.Io, 
    data: []const u8,
    sig_b64: []const u8,
    pubkey_b64: []const u8,
) !void {
    const hash = blake3(data);
    try verify(io, &hash, sig_b64, pubkey_b64);
}

const ipld = @import("ipld.zig");
const Repository = @import("repository.zig").Repository;

pub fn signCommitNode(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *ipld.BlockStore,
    repo: *Repository,
    commit_cid: ipld.CID,
) !ipld.CID {
    const identity = try Identity.loadOrCreate(allocator, repo.path);

    const block_data = try store.get(commit_cid);
    defer allocator.free(block_data);

    const sig_str = try identity.signHash(block_data);
    const pk_str = identity.publicKeyB64();

    const existing = try store.getNode(allocator, commit_cid);
    defer existing.deinit(allocator);
    if (existing != .map) return error.NotAMap;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var entries = std.ArrayList(ipld.Value.MapEntry){};

    for (existing.map) |entry| {
        if (std.mem.eql(u8, entry.key, "sig")) continue;
        if (std.mem.eql(u8, entry.key, "sig_pk")) continue;
        try entries.append(aa, .{
            .key = try aa.dupe(u8, entry.key),
            .value = try cloneValueArena(aa, entry.value),
        });
    }

    try entries.append(aa, .{
        .key = try aa.dupe(u8, "sig"),
        .value = .{ .string = try aa.dupe(u8, &sig_str) },
    });
    try entries.append(aa, .{
        .key = try aa.dupe(u8, "sig_pk"),
        .value = .{ .string = try aa.dupe(u8, &pk_str) },
    });

    const signed_val = ipld.Value{ .map = try entries.toOwnedSlice(aa) };
    return try store.putNode(aa, signed_val);
}

pub fn verifyCID(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *ipld.BlockStore,
    cid: ipld.CID,
) !VerifyResult {
    const node = try store.getNode(allocator, cid);
    defer node.deinit(allocator);

    if (node != .map) return error.NotAMap;

    const sig_b64 = node.getString("sig") orelse return VerifyResult{ .unsigned = .{} };
    const pk_b64 = node.getString("sig_pk") orelse return VerifyResult{ .unsigned = .{} };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var stripped = std.ArrayList(ipld.Value.MapEntry){};
    for (node.map) |entry| {
        if (std.mem.eql(u8, entry.key, "sig")) continue;
        if (std.mem.eql(u8, entry.key, "sig_pk")) continue;
        try stripped.append(aa, .{
            .key = try aa.dupe(u8, entry.key),
            .value = try cloneValueArena(aa, entry.value),
        });
    }
    const unsigned_val = ipld.Value{ .map = try stripped.toOwnedSlice(aa) };
    const unsigned_bytes = try ipld.encode(aa, unsigned_val);

    const pk_owned = try allocator.dupe(u8, pk_b64);
    errdefer allocator.free(pk_owned);

    verifyHash(io, unsigned_bytes, sig_b64, pk_b64) catch |err| {
        return VerifyResult{ .invalid = .{
            .reason = @errorName(err),
            .pk = pk_owned,
        } };
    };

    return VerifyResult{ .valid = .{ .pk = pk_owned } };
}

pub const VerifyResult = union(enum) {
    valid: struct { pk: []const u8 },
    invalid: struct { reason: []const u8, pk: []const u8 },
    unsigned: struct {},
};

pub fn cmdSign(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    cid_str: []const u8,
) !void {
    var store = try ipld.BlockStore.init(allocator, repo.path);
    defer store.deinit();

    const cid = ipld.CID.fromHex(cid_str) catch {
        std.debug.print("❌ Invalid CID: {s}\n", .{cid_str});
        return;
    };

    const signed_cid = signCommitNode(allocator, io, &store, repo, cid) catch |err| {
        std.debug.print("❌ Sign failed: {}\n", .{err});
        return;
    };

    const old_short = try cid.toShort(allocator);
    defer allocator.free(old_short);
    const new_short = try signed_cid.toShort(allocator);
    defer allocator.free(new_short);

    const identity = try Identity.loadOrCreate(allocator, repo.path);
    const pk = identity.publicKeyB64();

    std.debug.print("✍️  Signed IPLD node\n\n", .{});
    std.debug.print("   Original: {s}\n", .{old_short});
    std.debug.print("   Signed:   {s}\n", .{new_short});
    std.debug.print("   Key:      {s}\n\n", .{pk});
    std.debug.print("   Verify:   zev verify {s}\n\n", .{new_short});
}

pub fn cmdVerify(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    cid_str: []const u8,
) !void {
    var store = try ipld.BlockStore.init(allocator, repo.path);
    defer store.deinit();

    const cid = ipld.CID.fromHex(cid_str) catch {
        std.debug.print("❌ Invalid CID: {s}\n", .{cid_str});
        return;
    };

    const short = try cid.toShort(allocator);
    defer allocator.free(short);

    std.debug.print("🔍 Verifying: {s}\n\n", .{short});

    const result = verifyCID(allocator, io, &store, cid) catch |err| {
        std.debug.print("❌ Verification error: {}\n\n", .{err});
        return;
    };

    switch (result) {
        .valid => |v| {
            const pk_owned = try allocator.dupe(u8, v.pk);
            defer allocator.free(pk_owned);
            std.debug.print("   Signer: {s}\n\n", .{pk_owned});
        },
        .invalid => |v| {
            const rsn_owned = try allocator.dupe(u8, v.reason);
            defer allocator.free(rsn_owned);
            const pk_owned2 = try allocator.dupe(u8, v.pk);
            defer allocator.free(pk_owned2);
            std.debug.print("   Reason: {s}\n", .{rsn_owned});
            std.debug.print("   Key:    {s}\n\n", .{pk_owned2});
        },
        .unsigned => {
            std.debug.print("   Sign it: zev sign {s}\n\n", .{short});
        },
    }
    switch (result) {
        .valid => |v| allocator.free(v.pk),
        .invalid => |v| allocator.free(v.pk),
        .unsigned => {},
    }
}

pub fn cmdIdentity(
    allocator: std.mem.Allocator,
    repo: *Repository,
) !void {
    const identity = try Identity.loadOrCreate(allocator, repo.path);
    const pk = identity.publicKeyB64();

    std.debug.print("🔑 Zev Identity\n\n", .{});
    std.debug.print("   Public Key: {s}\n\n", .{pk});
    std.debug.print("   Stored at: .zev/identity\n", .{});
    std.debug.print("   Algorithm: Ed25519\n\n", .{});
    std.debug.print("   Share your public key so others can verify your commits.\n\n", .{});
}

fn cloneValueArena(allocator: std.mem.Allocator, v: ipld.Value) !ipld.Value {
    return switch (v) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .bytes => |b| .{ .bytes = try allocator.dupe(u8, b) },
        .int => |i| .{ .int = i },
        .uint => |u| .{ .uint = u },
        .float => |f| .{ .float = f },
        .bool => |b| .{ .bool = b },
        .link => |c| .{ .link = c },
        .null => .null,
        .map => |m| blk: {
            var entries = try allocator.alloc(ipld.Value.MapEntry, m.len);
            for (m, 0..) |e, i| {
                entries[i] = .{
                    .key = try allocator.dupe(u8, e.key),
                    .value = try cloneValueArena(allocator, e.value),
                };
            }
            break :blk .{ .map = entries };
        },
        .list => |l| blk: {
            var items = try allocator.alloc(ipld.Value, l.len);
            for (l, 0..) |item, i| items[i] = try cloneValueArena(allocator, item);
            break :blk .{ .list = items };
        },
    };
}

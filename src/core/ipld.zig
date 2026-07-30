const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

pub const Codec = enum(u64) {
    raw = 0x55,
    dag_cbor = 0x71,
    dag_json = 0x0129,
    sha2_256 = 0x12,
};

pub const Multihash = struct {
    code: u64,
    size: u8,
    digest: [32]u8,

    pub fn sha256(data: []const u8) Multihash {
        var digest: [32]u8 = undefined;
        Blake3.hash(data, &digest, .{});
        return .{ .code = 0x1e, .size = 32, .digest = digest };
    }

    pub fn encode(self: Multihash, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try writeVarint(&out, allocator, self.code);
        try writeVarint(&out, allocator, self.size);
        try out.appendSlice(allocator, &self.digest);
        return out.toOwnedSlice(allocator);
    }
};

pub const CID = struct {
    version: u8 = 1,
    codec: u64,
    hash: Multihash,

    pub fn new(codec: u64, data: []const u8) CID {
        return .{
            .version = 1,
            .codec = codec,
            .hash = Multihash.sha256(data),
        };
    }

    pub fn dagCbor(data: []const u8) CID {
        return new(@intFromEnum(Codec.dag_cbor), data);
    }

    pub fn raw(data: []const u8) CID {
        return new(@intFromEnum(Codec.raw), data);
    }

    pub fn encode(self: CID, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try writeVarint(&out, allocator, self.version);
        try writeVarint(&out, allocator, self.codec);
        const mh = try self.hash.encode(allocator);
        defer allocator.free(mh);
        try out.appendSlice(allocator, mh);
        return out.toOwnedSlice(allocator);
    }

    pub fn toString(self: CID, allocator: std.mem.Allocator) ![]u8 {
        const bytes = try self.encode(allocator);
        defer allocator.free(bytes);
        return base32Lower(allocator, bytes);
    }

    pub fn toShort(self: CID, allocator: std.mem.Allocator) ![]u8 {
        var buf: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ self.hash.digest[0], self.hash.digest[1], self.hash.digest[2], self.hash.digest[3], self.hash.digest[4], self.hash.digest[5], self.hash.digest[6], self.hash.digest[7] }) catch unreachable;
        return allocator.dupe(u8, &buf);
    }

    pub fn eql(self: CID, other: CID) bool {
        return self.codec == other.codec and
            std.mem.eql(u8, &self.hash.digest, &other.hash.digest);
    }

    pub fn fromHex(hex: []const u8) !CID {
        if (hex.len < 16) return error.InvalidCID;
        var digest: [32]u8 = std.mem.zeroes([32]u8);
        const parse_len = @min(hex.len, 64);
        var i: usize = 0;
        while (i + 1 < parse_len) : (i += 2) {
            const hi = try std.fmt.charToDigit(hex[i], 16);
            const lo = try std.fmt.charToDigit(hex[i + 1], 16);
            digest[i / 2] = (hi << 4) | lo;
        }
        return .{
            .version = 1,
            .codec = @intFromEnum(Codec.dag_cbor),
            .hash = .{ .code = 0x12, .size = 32, .digest = digest },
        };
    }
};

pub const Value = union(enum) {
    null: void,
    bool: bool,
    int: i64,
    uint: u64,
    float: f64,
    bytes: []const u8,
    string: []const u8,
    link: CID,
    list: []Value,
    map: []MapEntry,

    pub const MapEntry = struct {
        key: []const u8,
        value: Value,
    };

    pub fn deinit(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .bytes => |b| allocator.free(b),
            .string => |s| allocator.free(s),
            .list => |l| {
                for (l) |item| item.deinit(allocator);
                allocator.free(l);
            },
            .map => |m| {
                for (m) |entry| {
                    allocator.free(entry.key);
                    entry.value.deinit(allocator);
                }
                allocator.free(m);
            },
            else => {},
        }
    }

    pub fn getField(self: Value, key: []const u8) ?Value {
        if (self != .map) return null;
        for (self.map) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    pub fn getString(self: Value, key: []const u8) ?[]const u8 {
        const v = self.getField(key) orelse return null;
        return if (v == .string) v.string else null;
    }

    pub fn getInt(self: Value, key: []const u8) ?i64 {
        const v = self.getField(key) orelse return null;
        return if (v == .int) v.int else if (v == .uint) @intCast(v.uint) else null;
    }

    pub fn getLink(self: Value, key: []const u8) ?CID {
        const v = self.getField(key) orelse return null;
        return if (v == .link) v.link else null;
    }
};

pub fn encode(allocator: std.mem.Allocator, value: Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try encodeValue(&out, allocator, value);
    return out.toOwnedSlice(allocator);
}

fn encodeValue(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: Value) !void {
    switch (value) {
        .null => try out.append(allocator, 0xf6),
        .bool => |b| try out.append(allocator, if (b) 0xf5 else 0xf4),
        .uint => |u| try encodeCborHead(out, allocator, 0, u),
        .int => |i| {
            if (i >= 0) {
                try encodeCborHead(out, allocator, 0, @intCast(i));
            } else {
                try encodeCborHead(out, allocator, 1, @intCast(-(i + 1)));
            }
        },
        .float => |f| {
            try out.append(allocator, 0xfb);
            const bits: u64 = @bitCast(f);
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, bits, .big);
            try out.appendSlice(allocator, &buf);
        },
        .bytes => |b| {
            try encodeCborHead(out, allocator, 2, b.len);
            try out.appendSlice(allocator, b);
        },
        .string => |s| {
            try encodeCborHead(out, allocator, 3, s.len);
            try out.appendSlice(allocator, s);
        },
        .link => |cid| {
            try out.append(allocator, 0xd8);
            try out.append(allocator, 42);
            const cid_bytes = try cid.encode(allocator);
            defer allocator.free(cid_bytes);
            try encodeCborHead(out, allocator, 2, cid_bytes.len + 1);
            try out.append(allocator, 0x00);
            try out.appendSlice(allocator, cid_bytes);
        },
        .list => |l| {
            try encodeCborHead(out, allocator, 4, l.len);
            for (l) |item| try encodeValue(out, allocator, item);
        },
        .map => |m| {
            const sorted = try allocator.dupe(Value.MapEntry, m);
            defer allocator.free(sorted);
            std.mem.sort(Value.MapEntry, sorted, {}, struct {
                fn lt(_: void, a: Value.MapEntry, b: Value.MapEntry) bool {
                    if (a.key.len != b.key.len) return a.key.len < b.key.len;
                    return std.mem.lessThan(u8, a.key, b.key);
                }
            }.lt);
            try encodeCborHead(out, allocator, 5, sorted.len);
            for (sorted) |entry| {
                try encodeValue(out, allocator, .{ .string = entry.key });
                try encodeValue(out, allocator, entry.value);
            }
        },
    }
}

fn encodeCborHead(out: *std.ArrayList(u8), allocator: std.mem.Allocator, major: u8, n: u64) !void {
    const mt = major << 5;
    if (n <= 23) {
        try out.append(allocator, mt | @as(u8, @intCast(n)));
    } else if (n <= 0xff) {
        try out.append(allocator, mt | 24);
        try out.append(allocator, @intCast(n));
    } else if (n <= 0xffff) {
        try out.append(allocator, mt | 25);
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, @intCast(n), .big);
        try out.appendSlice(allocator, &buf);
    } else if (n <= 0xffffffff) {
        try out.append(allocator, mt | 26);
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, @intCast(n), .big);
        try out.appendSlice(allocator, &buf);
    } else {
        try out.append(allocator, mt | 27);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, n, .big);
        try out.appendSlice(allocator, &buf);
    }
}

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Value {
    var pos: usize = 0;
    return decodeValue(allocator, data, &pos);
}

fn decodeValue(allocator: std.mem.Allocator, data: []const u8, pos: *usize) !Value {
    if (pos.* >= data.len) return error.UnexpectedEnd;
    const initial = data[pos.*];
    pos.* += 1;
    const major = initial >> 5;
    const info = initial & 0x1f;

    switch (major) {
        0 => {
            const n = try decodeCborArg(data, pos, info);
            return .{ .uint = n };
        },
        1 => {
            const n = try decodeCborArg(data, pos, info);
            return .{ .int = -@as(i64, @intCast(n)) - 1 };
        },
        2 => {
            const len = try decodeCborArg(data, pos, info);
            if (pos.* + len > data.len) return error.UnexpectedEnd;
            const b = try allocator.dupe(u8, data[pos.* .. pos.* + len]);
            pos.* += len;
            return .{ .bytes = b };
        },
        3 => {
            const len = try decodeCborArg(data, pos, info);
            if (pos.* + len > data.len) return error.UnexpectedEnd;
            const s = try allocator.dupe(u8, data[pos.* .. pos.* + len]);
            pos.* += len;
            return .{ .string = s };
        },
        4 => {
            const len = try decodeCborArg(data, pos, info);
            const items = try allocator.alloc(Value, len);
            for (items) |*item| item.* = try decodeValue(allocator, data, pos);
            return .{ .list = items };
        },
        5 => {
            const len = try decodeCborArg(data, pos, info);
            const entries = try allocator.alloc(Value.MapEntry, len);
            for (entries) |*entry| {
                const kv = try decodeValue(allocator, data, pos);
                const key = if (kv == .string) kv.string else return error.InvalidMapKey;
                const val = try decodeValue(allocator, data, pos);
                entry.* = .{ .key = key, .value = val };
            }
            return .{ .map = entries };
        },
        6 => {
            const tag = try decodeCborArg(data, pos, info);
            if (tag == 42) {
                const inner = try decodeValue(allocator, data, pos);
                if (inner != .bytes or inner.bytes.len < 2) return error.InvalidLink;
                defer allocator.free(inner.bytes);
                const cid_bytes = inner.bytes[1..];
                const cid = try parseCIDBytes(cid_bytes);
                return .{ .link = cid };
            }
            return decodeValue(allocator, data, pos);
        },
        7 => {
            return switch (info) {
                20 => .{ .bool = false },
                21 => .{ .bool = true },
                22 => .null,
                27 => blk: {
                    if (pos.* + 8 > data.len) return error.UnexpectedEnd;
                    const bits = std.mem.readInt(u64, data[pos.*..][0..8], .big);
                    pos.* += 8;
                    break :blk .{ .float = @bitCast(bits) };
                },
                else => return error.UnsupportedSimple,
            };
        },
        else => return error.UnsupportedMajor,
    }
}

fn decodeCborArg(data: []const u8, pos: *usize, info: u8) !u64 {
    return switch (info) {
        0...23 => info,
        24 => blk: {
            if (pos.* >= data.len) return error.UnexpectedEnd;
            const v = data[pos.*];
            pos.* += 1;
            break :blk v;
        },
        25 => blk: {
            if (pos.* + 2 > data.len) return error.UnexpectedEnd;
            const v = std.mem.readInt(u16, data[pos.*..][0..2], .big);
            pos.* += 2;
            break :blk v;
        },
        26 => blk: {
            if (pos.* + 4 > data.len) return error.UnexpectedEnd;
            const v = std.mem.readInt(u32, data[pos.*..][0..4], .big);
            pos.* += 4;
            break :blk v;
        },
        27 => blk: {
            if (pos.* + 8 > data.len) return error.UnexpectedEnd;
            const v = std.mem.readInt(u64, data[pos.*..][0..8], .big);
            pos.* += 8;
            break :blk v;
        },
        else => error.InvalidCborInfo,
    };
}

fn parseCIDBytes(bytes: []const u8) !CID {
    if (bytes.len < 2) return error.InvalidCID;
    var pos: usize = 0;
    const version = try readVarintBytes(bytes, &pos);
    if (version != 1) return error.UnsupportedCIDVersion;
    const codec = try readVarintBytes(bytes, &pos);
    const mh_code = try readVarintBytes(bytes, &pos);
    const mh_size: u8 = @truncate(try readVarintBytes(bytes, &pos));
    if (pos + mh_size > bytes.len) return error.InvalidCID;
    var digest: [32]u8 = std.mem.zeroes([32]u8);
    const copy_len = @min(mh_size, 32);
    @memcpy(digest[0..copy_len], bytes[pos .. pos + copy_len]);
    return CID{
        .version = 1,
        .codec = codec,
        .hash = .{ .code = mh_code, .size = mh_size, .digest = digest },
    };
}

pub const CommitNode = struct {
    parent: ?CID,
    tree: CID,
    metrics: ?CID,
    experiment: ?CID,
    context: ?CID,
    notarize: ?CID,
    dataset: ?CID,
    author: []const u8,
    message: []const u8,
    timestamp: i64,
    branch: []const u8,

    pub fn toValue(self: CommitNode, allocator: std.mem.Allocator) !Value {
        var entries: std.ArrayList(Value.MapEntry) = .empty;
        defer entries.deinit(allocator);

        try entries.append(allocator, .{ .key = "zev", .value = .{ .string = try allocator.dupe(u8, "commit") } });
        try entries.append(allocator, .{ .key = "author", .value = .{ .string = try allocator.dupe(u8, self.author) } });
        try entries.append(allocator, .{ .key = "message", .value = .{ .string = try allocator.dupe(u8, self.message) } });
        try entries.append(allocator, .{ .key = "timestamp", .value = .{ .int = self.timestamp } });
        try entries.append(allocator, .{ .key = "branch", .value = .{ .string = try allocator.dupe(u8, self.branch) } });
        try entries.append(allocator, .{ .key = "tree", .value = .{ .link = self.tree } });

        if (self.parent) |p| try entries.append(allocator, .{ .key = "parent", .value = .{ .link = p } });
        if (self.metrics) |m| try entries.append(allocator, .{ .key = "metrics", .value = .{ .link = m } });
        if (self.experiment) |e| try entries.append(allocator, .{ .key = "experiment", .value = .{ .link = e } });
        if (self.context) |c| try entries.append(allocator, .{ .key = "context", .value = .{ .link = c } });
        if (self.notarize) |n| try entries.append(allocator, .{ .key = "notarize", .value = .{ .link = n } });
        if (self.dataset) |d| try entries.append(allocator, .{ .key = "dataset", .value = .{ .link = d } });

        return .{ .map = try entries.toOwnedSlice(allocator) };
    }

    pub fn toDagCbor(self: CommitNode, allocator: std.mem.Allocator) ![]u8 {
        const v = try self.toValue(allocator);
        defer v.deinit(allocator);
        return encode(allocator, v);
    }

    pub fn cid(self: CommitNode, allocator: std.mem.Allocator) !CID {
        const bytes = try self.toDagCbor(allocator);
        defer allocator.free(bytes);
        return CID.dagCbor(bytes);
    }
};

pub const MetricsNode = struct {
    commit: CID,
    entries: []const MetricEntry,
    timestamp: i64,

    pub const MetricEntry = struct { key: []const u8, value: f64 };

    pub fn toValue(self: MetricsNode, allocator: std.mem.Allocator) !Value {
        var metric_entries: std.ArrayList(Value.MapEntry) = .empty;
        defer metric_entries.deinit(allocator);
        for (self.entries) |e| {
            try metric_entries.append(allocator, .{
                .key = try allocator.dupe(u8, e.key),
                .value = .{ .float = e.value },
            });
        }
        const metrics_map = Value{ .map = try metric_entries.toOwnedSlice(allocator) };

        var entries: std.ArrayList(Value.MapEntry) = .empty;
        defer entries.deinit(allocator);
        try entries.append(allocator, .{ .key = "zev", .value = .{ .string = try allocator.dupe(u8, "metrics") } });
        try entries.append(allocator, .{ .key = "commit", .value = .{ .link = self.commit } });
        try entries.append(allocator, .{ .key = "timestamp", .value = .{ .int = self.timestamp } });
        try entries.append(allocator, .{ .key = "metrics", .value = metrics_map });
        return .{ .map = try entries.toOwnedSlice(allocator) };
    }

    pub fn toDagCbor(self: MetricsNode, allocator: std.mem.Allocator) ![]u8 {
        const v = try self.toValue(allocator);
        defer v.deinit(allocator);
        return encode(allocator, v);
    }

    pub fn cid(self: MetricsNode, allocator: std.mem.Allocator) !CID {
        const bytes = try self.toDagCbor(allocator);
        defer allocator.free(bytes);
        return CID.dagCbor(bytes);
    }
};

pub const SnapshotNode = struct {
    commit: CID,
    metrics: CID,
    name: []const u8,
    desc: []const u8,
    tags: []const []const u8,
    timestamp: i64,

    pub fn toValue(self: SnapshotNode, allocator: std.mem.Allocator) !Value {
        var tag_vals = try allocator.alloc(Value, self.tags.len);
        for (self.tags, 0..) |t, i|
            tag_vals[i] = .{ .string = try allocator.dupe(u8, t) };

        var entries: std.ArrayList(Value.MapEntry) = .empty;
        defer entries.deinit(allocator);
        try entries.append(allocator, .{ .key = "zev", .value = .{ .string = try allocator.dupe(u8, "snapshot") } });
        try entries.append(allocator, .{ .key = "name", .value = .{ .string = try allocator.dupe(u8, self.name) } });
        try entries.append(allocator, .{ .key = "desc", .value = .{ .string = try allocator.dupe(u8, self.desc) } });
        try entries.append(allocator, .{ .key = "commit", .value = .{ .link = self.commit } });
        try entries.append(allocator, .{ .key = "metrics", .value = .{ .link = self.metrics } });
        try entries.append(allocator, .{ .key = "tags", .value = .{ .list = tag_vals } });
        try entries.append(allocator, .{ .key = "timestamp", .value = .{ .int = self.timestamp } });
        return .{ .map = try entries.toOwnedSlice(allocator) };
    }

    pub fn toDagCbor(self: SnapshotNode, allocator: std.mem.Allocator) ![]u8 {
        const v = try self.toValue(allocator);
        defer v.deinit(allocator);
        return encode(allocator, v);
    }

    pub fn cid(self: SnapshotNode, allocator: std.mem.Allocator) !CID {
        const bytes = try self.toDagCbor(allocator);
        defer allocator.free(bytes);
        return CID.dagCbor(bytes);
    }
};

pub const DatasetShardNode = struct {
    source_cid: CID,
    shard_index: u64,
    total_shards: u64,
    row_start: u64,
    row_end: u64,
    strategy: []const u8,
    dataset_name: []const u8,
    timestamp: i64,

    pub fn toValue(self: DatasetShardNode, allocator: std.mem.Allocator) !Value {
        var entries: std.ArrayList(Value.MapEntry) = .empty;
        defer entries.deinit(allocator);
        try entries.append(allocator, .{ .key = "zev", .value = .{ .string = try allocator.dupe(u8, "dataset_shard") } });
        try entries.append(allocator, .{ .key = "source", .value = .{ .link = self.source_cid } });
        try entries.append(allocator, .{ .key = "dataset", .value = .{ .string = try allocator.dupe(u8, self.dataset_name) } });
        try entries.append(allocator, .{ .key = "index", .value = .{ .uint = self.shard_index } });
        try entries.append(allocator, .{ .key = "total", .value = .{ .uint = self.total_shards } });
        try entries.append(allocator, .{ .key = "row_start", .value = .{ .uint = self.row_start } });
        try entries.append(allocator, .{ .key = "row_end", .value = .{ .uint = self.row_end } });
        try entries.append(allocator, .{ .key = "strategy", .value = .{ .string = try allocator.dupe(u8, self.strategy) } });
        try entries.append(allocator, .{ .key = "timestamp", .value = .{ .int = self.timestamp } });
        return .{ .map = try entries.toOwnedSlice(allocator) };
    }

    pub fn toDagCbor(self: DatasetShardNode, allocator: std.mem.Allocator) ![]u8 {
        const v = try self.toValue(allocator);
        defer v.deinit(allocator);
        return encode(allocator, v);
    }

    pub fn cid(self: DatasetShardNode, allocator: std.mem.Allocator) !CID {
        const bytes = try self.toDagCbor(allocator);
        defer allocator.free(bytes);
        return CID.dagCbor(bytes);
    }
};

pub const ContextIPLDNode = struct {
    file_cid: CID,
    model: []const u8,
    kind: []const u8,
    prompt_cid: ?CID,
    timestamp: i64,

    pub fn toValue(self: ContextIPLDNode, allocator: std.mem.Allocator) !Value {
        var entries: std.ArrayList(Value.MapEntry) = .empty;
        defer entries.deinit(allocator);
        try entries.append(allocator, .{ .key = "zev", .value = .{ .string = try allocator.dupe(u8, "context") } });
        try entries.append(allocator, .{ .key = "file", .value = .{ .link = self.file_cid } });
        try entries.append(allocator, .{ .key = "model", .value = .{ .string = try allocator.dupe(u8, self.model) } });
        try entries.append(allocator, .{ .key = "kind", .value = .{ .string = try allocator.dupe(u8, self.kind) } });
        try entries.append(allocator, .{ .key = "timestamp", .value = .{ .int = self.timestamp } });
        if (self.prompt_cid) |pc|
            try entries.append(allocator, .{ .key = "prompt", .value = .{ .link = pc } });
        return .{ .map = try entries.toOwnedSlice(allocator) };
    }

    pub fn toDagCbor(self: ContextIPLDNode, allocator: std.mem.Allocator) ![]u8 {
        const v = try self.toValue(allocator);
        defer v.deinit(allocator);
        return encode(allocator, v);
    }

    pub fn cid(self: ContextIPLDNode, allocator: std.mem.Allocator) !CID {
        const bytes = try self.toDagCbor(allocator);
        defer allocator.free(bytes);
        return CID.dagCbor(bytes);
    }
};

pub const GraftNode = struct {
    target_cid: CID,
    alias: []const u8,
    description: []const u8,
    grafted_at: i64,
    grafted_by: []const u8,

    pub fn toValue(self: GraftNode, allocator: std.mem.Allocator) !Value {
        var entries: std.ArrayList(Value.MapEntry) = .empty;
        defer entries.deinit(allocator);
        try entries.append(allocator, .{ .key = "zev", .value = .{ .string = try allocator.dupe(u8, "graft") } });
        try entries.append(allocator, .{ .key = "target", .value = .{ .link = self.target_cid } });
        try entries.append(allocator, .{ .key = "alias", .value = .{ .string = try allocator.dupe(u8, self.alias) } });
        try entries.append(allocator, .{ .key = "description", .value = .{ .string = try allocator.dupe(u8, self.description) } });
        try entries.append(allocator, .{ .key = "grafted_at", .value = .{ .int = self.grafted_at } });
        try entries.append(allocator, .{ .key = "grafted_by", .value = .{ .string = try allocator.dupe(u8, self.grafted_by) } });
        return .{ .map = try entries.toOwnedSlice(allocator) };
    }

    pub fn toDagCbor(self: GraftNode, allocator: std.mem.Allocator) ![]u8 {
        const v = try self.toValue(allocator);
        defer v.deinit(allocator);
        return encode(allocator, v);
    }

    pub fn cid(self: GraftNode, allocator: std.mem.Allocator) !CID {
        const bytes = try self.toDagCbor(allocator);
        defer allocator.free(bytes);
        return CID.dagCbor(bytes);
    }
};

pub const BlockStore = struct {
    base_path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator,
    io: std.Io, repo_path: []const u8) !BlockStore {
        const base = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "ipld" });
        try std.Io.Dir.cwd().createDirPath(io, base);
        return .{ .base_path = base, .allocator = allocator };
    }

    pub fn deinit(self: *BlockStore) void {
        self.allocator.free(self.base_path);
    }

    fn blockPath(self: BlockStore, io: std.Io, c: CID) ![]u8 {
        const short = try c.toShort(self.allocator);
        defer self.allocator.free(short);
        const prefix = short[0..@min(2, short.len)];
        const sub_dir = try std.fs.path.join(self.allocator, &.{ self.base_path, prefix });
        try std.Io.Dir.cwd().createDirPath(io, sub_dir);
        defer self.allocator.free(sub_dir);
        return std.fs.path.join(self.allocator, &.{ sub_dir, short });
    }

    pub fn put(self: BlockStore, io: std.Io, c: CID, data: []const u8) !void {
        const path = try self.blockPath(io, c);
        defer self.allocator.free(path);
        std.Io.Dir.cwd().access(io, path, .{}) catch {
            const f = try std.Io.Dir.cwd().createFile(io, path, .{});
            var f_buffer: [512]u8 = undefined;
            var f_writer = f.writer(io, &f_buffer);
            defer f.close(io);
            try f_writer.interface.writeAll(data);
            try f_writer.flush();
            return;
        };
    }

    pub fn get(self: BlockStore, io: std.Io, c: CID) ![]u8 {
        const path = try self.blockPath(io, c);
        defer self.allocator.free(path);
        return std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(64 * 1024 * 1024)) catch error.BlockNotFound;
    }

    pub fn has(io: std.Io, self: BlockStore, c: CID) bool {
        const path = self.blockPath(io, c) catch return false;
        defer self.allocator.free(path);
        std.Io.Dir.cwd().access(path, .{}) catch return false;
        return true;
    }

    pub fn putNode(self: BlockStore, allocator: std.mem.Allocator,
    io: std.Io, value: Value) !CID {
        const data = try encode(allocator, value);
        defer allocator.free(data);
        const c = CID.dagCbor(data);
        try self.put(io, c, data);
        return c;
    }

    pub fn putNodeOwned(self: BlockStore, allocator: std.mem.Allocator,
    io: std.Io, value: Value) !CID {
        const data = try encode(allocator, value);
        defer allocator.free(data);
        const c = CID.dagCbor(data);
        try self.put(io, c, data);
        if (value == .map) {
            for (value.map) |entry| allocator.free(entry.key);
            allocator.free(value.map);
        }
        return c;
    }

    pub fn getNode(self: BlockStore, allocator: std.mem.Allocator,
    io: std.Io, c: CID) !Value {
        const data = try self.get(io, c);
        defer allocator.free(data);
        return decode(allocator, data);
    }

    pub fn count(io: std.Io, self: BlockStore) usize {
        var total: usize = 0;
        var dir = std.Io.Dir.cwd().openDir(io, self.base_path, .{ .iterate = true }) catch return 0;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind == .directory) {
                const sub_path = std.fs.path.join(self.allocator, &.{ self.base_path, entry.name }) catch continue;
                defer self.allocator.free(sub_path);
                var sub = std.Io.Dir.cwd().openDir(io, sub_path, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                var sub_it = sub.iterate();
                while (sub_it.next(io) catch null) |e| {
                    if (e.kind == .file) total += 1;
                }
            }
        }
        return total;
    }
};

pub const DagNode = struct {
    cid: CID,
    value: Value,
    children: []DagNode,

    pub fn deinit(self: *DagNode, allocator: std.mem.Allocator) void {
        self.value.deinit(allocator);
        for (self.children) |*child| child.deinit(allocator);
        allocator.free(self.children);
    }
};

pub fn walkDag(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *BlockStore,
    root_cid: CID,
    max_depth: usize,
) !DagNode {
    return walkDagInner(allocator, io, store, root_cid, max_depth, 0);
}

fn walkDagInner(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *BlockStore,
    c: CID,
    max_depth: usize,
    depth: usize,
) anyerror!DagNode {
    const value = store.getNode(allocator, io, c) catch
        return DagNode{ .cid = c, .value = .null, .children = &.{} };

    var children: std.ArrayList(DagNode) = .empty;
    if (depth < max_depth) {
        try collectLinks(allocator, io, store, value, &children, max_depth, depth + 1);
    }

    return DagNode{
        .cid = c,
        .value = value,
        .children = try children.toOwnedSlice(allocator),
    };
}

fn collectLinks(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *BlockStore,
    value: Value,
    children: *std.ArrayList(DagNode),
    max_depth: usize,
    depth: usize,
) anyerror!void {
    switch (value) {
        .link => |c| {
            const child = try walkDagInner(allocator, io, store, c, max_depth, depth);
            try children.append(allocator, child);
        },
        .map => |m| {
            for (m) |entry| {
                try collectLinks(allocator, io, store, entry.value, children, max_depth, depth);
            }
        },
        .list => |l| {
            for (l) |item| {
                try collectLinks(allocator, io, store, item, children, max_depth, depth);
            }
        },
        else => {},
    }
}

fn writeVarint(out: *std.ArrayList(u8), allocator: std.mem.Allocator, n: u64) !void {
    var v = n;
    while (v >= 0x80) {
        try out.append(allocator, @as(u8, @truncate(v)) | 0x80);
        v >>= 7;
    }
    try out.append(allocator, @truncate(v));
}

fn readVarintBytes(data: []const u8, pos: *usize) !u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (pos.* < data.len) {
        const b = data[pos.*];
        pos.* += 1;
        result |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return result;
        shift += 7;
        if (shift >= 64) return error.VarintOverflow;
    }
    return error.UnexpectedEnd;
}

const BASE32_LOWER = "abcdefghijklmnopqrstuvwxyz234567";

fn base32Lower(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const out_len = 1 + (data.len * 8 + 4) / 5;
    var out = try allocator.alloc(u8, out_len);
    out[0] = 'b';
    var bit_buf: u32 = 0;
    var bits_left: u5 = 0;
    var out_pos: usize = 1;
    for (data) |byte| {
        bit_buf = (bit_buf << 8) | byte;
        bits_left += 8;
        while (bits_left >= 5) {
            bits_left -= 5;
            out[out_pos] = BASE32_LOWER[(bit_buf >> bits_left) & 0x1f];
            out_pos += 1;
        }
    }
    if (bits_left > 0) {
        out[out_pos] = BASE32_LOWER[(bit_buf << (5 - bits_left)) & 0x1f];
        out_pos += 1;
    }
    return out[0..out_pos];
}

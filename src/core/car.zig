const std = @import("std");
const ipld = @import("ipld.zig");
const Repository = @import("repository.zig").Repository;

pub const CarWriter = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    roots: std.ArrayList(ipld.CID),
    written: std.StringHashMap(void),
    block_count: usize,
    byte_count: u64,

    pub fn init(allocator: std.mem.Allocator, file: std.fs.File) CarWriter {
        return .{
            .allocator = allocator,
            .file = file,
            .roots = std.ArrayList(ipld.CID).empty,
            .written = std.StringHashMap(void).init(allocator),
            .block_count = 0,
            .byte_count = 0,
        };
    }

    pub fn deinit(self: *CarWriter) void {
        self.roots.deinit(self.allocator);
        var it = self.written.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.written.deinit();
    }

    pub fn addRoot(self: *CarWriter, c: ipld.CID) !void {
        try self.roots.append(self.allocator, c);
    }

    pub fn writeHeader(self: *CarWriter) !void {
        var root_vals = try self.allocator.alloc(ipld.Value, self.roots.items.len);
        defer self.allocator.free(root_vals);
        for (self.roots.items, 0..) |c, i| root_vals[i] = .{ .link = c };

        var entries = try self.allocator.alloc(ipld.Value.MapEntry, 2);
        defer self.allocator.free(entries);
        entries[0] = .{ .key = "version", .value = .{ .uint = 1 } };
        entries[1] = .{ .key = "roots", .value = .{ .list = root_vals } };

        const header_val = ipld.Value{ .map = entries };
        const header_bytes = try ipld.encode(self.allocator, header_val);
        defer self.allocator.free(header_bytes);

        var vbuf: [16]u8 = undefined;
        const vlen = encodeVarint(&vbuf, header_bytes.len);
        try self.file.writeAll(vbuf[0..vlen]);
        try self.file.writeAll(header_bytes);
    }

    pub fn writeBlock(self: *CarWriter, c: ipld.CID, data: []const u8) !void {
        const short = try c.toShort(self.allocator);
        if (self.written.contains(short)) {
            self.allocator.free(short);
            return;
        }
        try self.written.put(short, {});

        const cid_bytes = try c.encode(self.allocator);
        defer self.allocator.free(cid_bytes);

        const total = cid_bytes.len + data.len;
        var vbuf: [16]u8 = undefined;
        const vlen = encodeVarint(&vbuf, total);
        try self.file.writeAll(vbuf[0..vlen]);
        try self.file.writeAll(cid_bytes);
        try self.file.writeAll(data);

        self.block_count += 1;
        self.byte_count += @intCast(vlen + total);
    }
};

pub const CarBlock = struct {
    cid: ipld.CID,
    data: []u8,

    pub fn deinit(self: CarBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub const CarReader = struct {
    allocator: std.mem.Allocator,
    roots: []ipld.CID,
    blocks: []CarBlock,

    pub fn deinit(self: *CarReader) void {
        self.allocator.free(self.roots);
        for (self.blocks) |b| b.deinit(self.allocator);
        self.allocator.free(self.blocks);
    }
};

pub fn readCar(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !CarReader {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024 * 1024)); // 512MB max
    defer allocator.free(data);

    var pos: usize = 0;

    const header_len = try readVarint(data, &pos);
    if (pos + header_len > data.len) return error.TruncatedCAR;

    const header_bytes = data[pos .. pos + header_len];
    pos += header_len;

    const header = try ipld.decode(allocator, header_bytes);
    defer header.deinit(allocator);

    var roots: std.ArrayList(ipld.CID) = .empty;
    if (header.getField("roots")) |roots_val| {
        if (roots_val == .list) {
            for (roots_val.list) |rv| {
                if (rv == .link) try roots.append(allocator, rv.link);
            }
        }
    }

    var blocks: std.ArrayList(CarBlock) = .empty;
    while (pos < data.len) {
        const block_len = readVarint(data, &pos) catch break;
        if (block_len == 0) break;
        if (pos + block_len > data.len) break;

        const block_start = pos;
        const block_end = pos + block_len;

        const c = parseCIDFromSlice(data[pos..block_end]) catch {
            pos = block_end;
            continue;
        };
        const cid_encoded_len = try cidEncodedLen(c, allocator);
        pos += cid_encoded_len;

        const block_data = try allocator.dupe(u8, data[pos..block_end]);
        pos = block_end;

        try blocks.append(allocator, CarBlock{ .cid = c, .data = block_data });
        _ = block_start;
    }

    return CarReader{
        .allocator = allocator,
        .roots = try roots.toOwnedSlice(allocator),
        .blocks = try blocks.toOwnedSlice(allocator),
    };
}

pub fn dagExport(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    root_spec: []const u8,
    output_path: []const u8,
    max_depth: usize,
    to_ipfs: bool,
) !void {
    var store = try ipld.BlockStore.init(allocator, io, repo.path);
    defer store.deinit();

    var root_cids: std.ArrayList(ipld.CID) = .empty;
    defer root_cids.deinit(allocator);

    if (std.mem.eql(u8, root_spec, "all")) {
        try collectAllCIDs(allocator, io, &store, &root_cids);
    } else if (std.mem.eql(u8, root_spec, "HEAD")) {
        const head = resolveHEAD(allocator, repo) catch {
            std.debug.print("❌ No commits yet.\n", .{});
            return;
        };
        try root_cids.append(allocator, head);
    } else {
        const c = ipld.CID.fromHex(root_spec) catch {
            std.debug.print("❌ Invalid CID: {s}\n", .{root_spec});
            return;
        };
        try root_cids.append(allocator, c);
    }

    if (root_cids.items.len == 0) {
        std.debug.print("❌ No blocks in store. Use 'zev dag put' or 'zev graft' first.\n", .{});
        return;
    }

    const f = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("❌ Cannot create {s}: {}\n", .{ output_path, err });
        return;
    };
    defer f.close(io);

    var writer = CarWriter.init(allocator, f);
    defer writer.deinit();

    for (root_cids.items) |c| try writer.addRoot(c);
    try writer.writeHeader();

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    for (root_cids.items) |root_c| {
        try walkAndWrite(allocator, io, &store, &writer, &seen, root_c, max_depth, 0);
    }

    const file_size = blk: {
        const st = std.Io.Dir.cwd().statFile(io, output_path) catch break :blk @as(u64, 0);
        break :blk @as(u64, @intCast(st.size));
    };

    std.debug.print("📦 CAR export complete\n\n", .{});
    std.debug.print("   File:    {s}\n", .{output_path});
    std.debug.print("   Blocks:  {d}\n", .{writer.block_count});
    std.debug.print("   Size:    {d} bytes\n", .{file_size});
    std.debug.print("   Roots:   {d}\n\n", .{root_cids.items.len});

    for (root_cids.items[0..@min(5, root_cids.items.len)]) |c| {
        const s = try c.toShort(allocator);
        defer allocator.free(s);
        std.debug.print("   Root: {s}\n", .{s});
    }
    std.debug.print("\n", .{});

    if (to_ipfs) {
        std.debug.print("🌐 Importing to IPFS...\n", .{});
        try importToIPFS(allocator, io, output_path);
    } else {
        std.debug.print("   Import anywhere: ipfs dag import {s}\n", .{output_path});
        std.debug.print("   Re-import here:  zev dag import {s}\n\n", .{output_path});
    }
}

fn walkAndWrite(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *ipld.BlockStore,
    writer: *CarWriter,
    seen: *std.StringHashMap(void),
    c: ipld.CID,
    max_depth: usize,
    depth: usize,
) !void {
    const short = try c.toShort(allocator);

    if (seen.contains(short)) {
        allocator.free(short);
        return;
    }
    const short_owned = try allocator.dupe(u8, short);
    allocator.free(short);
    try seen.put(short_owned, {});

    const data = store.get(c) catch return;
    defer allocator.free(data);

    try writer.writeBlock(c, data);

    if (depth >= max_depth) return;

    const value = ipld.decode(allocator, data) catch return;
    defer value.deinit(allocator);

    try followLinks(allocator, io, store, writer, seen, value, max_depth, depth + 1);
}

fn followLinks(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *ipld.BlockStore,
    writer: *CarWriter,
    seen: *std.StringHashMap(void),
    value: ipld.Value,
    max_depth: usize,
    depth: usize,
) anyerror!void {
    switch (value) {
        .link => |c| try walkAndWrite(allocator, io, store, writer, seen, c, max_depth, depth),
        .map => |m| for (m) |e| try followLinks(allocator, io, store, writer, seen, e.value, max_depth, depth),
        .list => |l| for (l) |v| try followLinks(allocator, io, store, writer, seen, v, max_depth, depth),
        else => {},
    }
}

pub fn dagImport(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    car_path: []const u8,
) !void {
    var store = try ipld.BlockStore.init(allocator, io, repo.path);
    defer store.deinit();

    std.debug.print("📥 Importing CAR: {s}\n\n", .{car_path});

    var car = readCar(allocator, car_path) catch |err| {
        std.debug.print("❌ Failed to read CAR: {}\n", .{err});
        return;
    };
    defer car.deinit();

    var imported: usize = 0;
    var skipped: usize = 0;

    for (car.blocks) |block| {
        if (store.has(io, block.cid)) {
            skipped += 1;
        } else {
            store.put(io, block.cid, block.data) catch continue;
            imported += 1;
        }
    }

    std.debug.print("   Blocks imported: {d}\n", .{imported});
    std.debug.print("   Already present: {d}\n", .{skipped});
    std.debug.print("   Total in CAR:    {d}\n\n", .{car.blocks.len});

    if (car.roots.len > 0) {
        std.debug.print("   Roots:\n", .{});
        for (car.roots) |c| {
            const s = try c.toShort(allocator);
            defer allocator.free(s);
            std.debug.print("   {s}\n", .{s});
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("   Explore: zev dag show <cid>\n", .{});
    std.debug.print("   Query:   zev dag query all:graft\n\n", .{});

    for (car.roots) |root_cid| {
        const v = store.getNode(allocator, io, root_cid) catch continue;
        defer v.deinit(allocator);
        if (v == .map) {
            if (v.getString("zev")) |t| {
                if (std.mem.eql(u8, t, "commit")) {
                    const head_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "ipld_head" });
                    defer allocator.free(head_path);
                    const cid_str = try root_cid.toShort(allocator);
                    defer allocator.free(cid_str);
                    const f2 = try std.Io.Dir.cwd().createFile(io, head_path, .{});
                    defer f2.close(io);
                    var f2_buffer: [512]u8 = undefined;
                    var f2_writer = f2.writer(io, &f2_buffer);
                    try f2_writer.interface.writeAll(cid_str);
                    try f2_writer.flush();
                    break;
                }
            }
        }
    }
}

fn collectAllCIDs(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *ipld.BlockStore,
    out: *std.ArrayList(ipld.CID),
) !void {
    var root_dir = std.Io.Dir.cwd().openDir(io, store.base_path, .{ .iterate = true }) catch return;
    defer root_dir.close(io);
    var it = root_dir.iterate();
    while (try it.next(io)) |shard| {
        if (shard.kind != .directory) continue;
        const sp = try std.fs.path.join(allocator, &.{ store.base_path, shard.name });
        defer allocator.free(sp);
        var sd = std.Io.Dir.cwd().openDir(io, sp, .{ .iterate = true }) catch continue;
        defer sd.close(io);
        var si = sd.iterate();
        while (try si.next(io)) |block| {
            if (block.kind != .file) continue;
            const c = ipld.CID.fromHex(block.name) catch continue;
            try out.append(allocator, c);
        }
    }
}

fn resolveHEAD(allocator: std.mem.Allocator, io: std.Io, repo: *Repository) !ipld.CID {
    const head_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "HEAD" });
    defer allocator.free(head_path);
    const head = try std.Io.Dir.cwd().readFileAlloc(io, head_path, allocator, .limited(256));
    defer allocator.free(head);

    if (std.mem.startsWith(u8, head, "ref: ")) {
        const ref = std.mem.trim(u8, head[5..], "\n\r ");
        const rp = try std.fs.path.join(allocator, &.{ repo.path, ".zev", ref });
        defer allocator.free(rp);
        const rc = try std.Io.Dir.cwd().readFileAlloc(io, rp, allocator, .limited(256));
        defer allocator.free(rc);
        const hash = std.mem.trim(u8, rc, "\n\r ");
        return ipld.CID.fromHex(hash);
    }
    return ipld.CID.fromHex(std.mem.trim(u8, head, "\n\r "));
}

fn importToIPFS(allocator: std.mem.Allocator,
    io: std.Io, car_path: []const u8) !void {
    _ = allocator;
    const argv = [_][]const u8{ "ipfs", "dag", "import", car_path };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch {
        std.debug.print("⚠️  ipfs not found. Install go-ipfs and run:\n", .{});
        std.debug.print("   ipfs dag import {s}\n\n", .{car_path});
        return;
    };
    const result = child.wait(io) catch return;
    _ = result;
}

fn encodeVarint(buf: []u8, n: usize) usize {
    var v = n;
    var i: usize = 0;
    while (v >= 0x80) {
        buf[i] = @as(u8, @truncate(v)) | 0x80;
        v >>= 7;
        i += 1;
    }
    buf[i] = @truncate(v);
    return i + 1;
}

fn readVarint(data: []const u8, pos: *usize) !usize {
    var result: usize = 0;
    var shift: u6 = 0;
    while (pos.* < data.len) {
        const b = data[pos.*];
        pos.* += 1;
        result |= @as(usize, b & 0x7f) << shift;
        if (b & 0x80 == 0) return result;
        shift += 7;
        if (shift >= 64) return error.VarintOverflow;
    }
    return error.UnexpectedEnd;
}

fn parseCIDFromSlice(data: []const u8) !ipld.CID {
    if (data.len < 4) return error.TooShort;
    var pos: usize = 0;
    const version = try readVarintFromSlice(data, &pos);
    if (version != 1) return error.UnsupportedVersion;
    const codec = try readVarintFromSlice(data, &pos);
    const mh_code = try readVarintFromSlice(data, &pos);
    const mh_size: u8 = @truncate(try readVarintFromSlice(data, &pos));
    if (pos + mh_size > data.len) return error.TruncatedCID;
    var digest: [32]u8 = std.mem.zeroes([32]u8);
    const copy_len = @min(@as(usize, mh_size), 32);
    @memcpy(digest[0..copy_len], data[pos .. pos + copy_len]);
    return ipld.CID{
        .version = 1,
        .codec = codec,
        .hash = .{ .code = mh_code, .size = mh_size, .digest = digest },
    };
}

fn readVarintFromSlice(data: []const u8, pos: *usize) !u64 {
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

fn cidEncodedLen(c: ipld.CID, allocator: std.mem.Allocator) !usize {
    const bytes = try c.encode(allocator);
    defer allocator.free(bytes);
    return bytes.len;
}

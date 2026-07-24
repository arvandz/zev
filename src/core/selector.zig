const std = @import("std");
const ipld = @import("ipld.zig");
const Repository = @import("repository.zig").Repository;

pub const SelectorTag = enum {
    explore_all,
    explore_fields,
    explore_recursive,
    matcher,
    explore_union,
};

pub const Selector = union(SelectorTag) {
    explore_all: *Selector,
    explore_fields: ExploreFields,
    explore_recursive: ExploreRecursive,
    matcher: MatcherOpts,
    explore_union: []*Selector,

    pub const ExploreFields = struct {
        fields: []const []const u8,
        next: *Selector,
    };

    pub const ExploreRecursive = struct {
        max_depth: usize,
        sequence: *Selector,
    };

    pub const MatcherOpts = struct {
        condition: ?Condition,
    };

    pub const Condition = struct {
        field: []const u8,
        op: CondOp,
        value: f64,

        pub const CondOp = enum { gt, lt, gte, lte, eq };

        pub fn matches(self: Condition, node: ipld.Value) bool {
            if (node != .map) return false;
            for (node.map) |entry| {
                if (!std.mem.eql(u8, entry.key, self.field)) continue;
                const v: f64 = switch (entry.value) {
                    .float => |f| f,
                    .int => |i| @floatFromInt(i),
                    .uint => |u| @floatFromInt(u),
                    else => return false,
                };
                return switch (self.op) {
                    .gt => v > self.value,
                    .lt => v < self.value,
                    .gte => v >= self.value,
                    .lte => v <= self.value,
                    .eq => @abs(v - self.value) < 0.0001,
                };
            }
            for (node.map) |entry| {
                if (!std.mem.eql(u8, entry.key, "metrics")) continue;
                if (entry.value != .map) continue;
                for (entry.value.map) |me| {
                    if (!std.mem.eql(u8, me.key, self.field)) continue;
                    const v: f64 = switch (me.value) {
                        .float => |f| f,
                        .int => |i| @floatFromInt(i),
                        .uint => |u| @floatFromInt(u),
                        else => return false,
                    };
                    return switch (self.op) {
                        .gt => v > self.value,
                        .lt => v < self.value,
                        .gte => v >= self.value,
                        .lte => v <= self.value,
                        .eq => @abs(v - self.value) < 0.0001,
                    };
                }
            }
            return false;
        }
    };

    pub fn deinit(self: *Selector, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .explore_all => |inner| {
                inner.deinit(allocator);
                allocator.destroy(inner);
            },
            .explore_fields => |ef| {
                ef.next.deinit(allocator);
                allocator.destroy(ef.next);
                allocator.free(ef.fields);
            },
            .explore_recursive => |er| {
                er.sequence.deinit(allocator);
                allocator.destroy(er.sequence);
            },
            .matcher => {},
            .explore_union => |selectors| {
                for (selectors) |s| {
                    s.deinit(allocator);
                    allocator.destroy(s);
                }
                allocator.free(selectors);
            },
        }
    }
};

pub const QueryResult = struct {
    cid: ipld.CID,
    path: []const u8,
    value: ipld.Value,
    depth: usize,

    pub fn deinit(self: QueryResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.value.deinit(allocator);
    }
};

pub const SelectorEngine = struct {
    allocator: std.mem.Allocator,
    store: *ipld.BlockStore,
    results: std.ArrayList(QueryResult),
    node_type_filter: ?[]const u8,
    max_results: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        store: *ipld.BlockStore,
        node_type: ?[]const u8,
    ) SelectorEngine {
        return .{
            .allocator = allocator,
            .store = store,
            .results = std.ArrayList(QueryResult){},
            .node_type_filter = node_type,
            .max_results = 1000,
        };
    }

    pub fn deinit(self: *SelectorEngine) void {
        for (self.results.items) |r| r.deinit(self.allocator);
        self.results.deinit(self.allocator);
    }

    pub fn execute(
        self: *SelectorEngine,
        root_cid: ipld.CID,
        sel: *const Selector,
    ) anyerror!void {
        try self.walk(root_cid, sel, "", 0);
    }

    fn walk(
        self: *SelectorEngine,
        c: ipld.CID,
        sel: *const Selector,
        path: []const u8,
        depth: usize,
    ) anyerror!void {
        if (self.results.items.len >= self.max_results) return;

        const value = self.store.getNode(self.allocator, c) catch return;
        errdefer value.deinit(self.allocator);

        switch (sel.*) {
            .matcher => |opts| {
                if (self.node_type_filter) |ntype| {
                    const actual = if (value == .map) value.getString("zev") orelse "" else "";
                    if (!std.mem.eql(u8, actual, ntype)) {
                        value.deinit(self.allocator);
                        return;
                    }
                }
                if (opts.condition) |cond| {
                    if (!cond.matches(value)) {
                        value.deinit(self.allocator);
                        return;
                    }
                }
                const path_copy = try self.allocator.dupe(u8, path);
                try self.results.append(self.allocator, QueryResult{
                    .cid = c,
                    .path = path_copy,
                    .value = value,
                    .depth = depth,
                });
            },

            .explore_all => |inner| {
                defer value.deinit(self.allocator);
                if (value != .map) return;
                for (value.map) |entry| {
                    if (entry.value == .link) {
                        const new_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.key });
                        defer self.allocator.free(new_path);
                        try self.walk(entry.value.link, inner, new_path, depth + 1);
                    }
                }
            },

            .explore_fields => |ef| {
                defer value.deinit(self.allocator);
                if (value != .map) return;
                for (value.map) |entry| {
                    var is_target = false;
                    for (ef.fields) |f| {
                        if (std.mem.eql(u8, entry.key, f)) {
                            is_target = true;
                            break;
                        }
                    }
                    if (!is_target) continue;

                    const new_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.key });
                    defer self.allocator.free(new_path);

                    if (entry.value == .link) {
                        try self.walk(entry.value.link, ef.next, new_path, depth + 1);
                    } else {
                        if (ef.next.* == .matcher) {
                            const path_copy = try self.allocator.dupe(u8, new_path);
                            const val_copy = try cloneValue(self.allocator, entry.value);
                            try self.results.append(self.allocator, QueryResult{
                                .cid = c,
                                .path = path_copy,
                                .value = val_copy,
                                .depth = depth + 1,
                            });
                        }
                    }
                }
            },

            .explore_recursive => |er| {
                defer value.deinit(self.allocator);
                if (depth >= er.max_depth) return;
                if (value != .map) return;
                for (value.map) |entry| {
                    if (entry.value != .link) continue;
                    const new_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.key });
                    defer self.allocator.free(new_path);
                    try self.walk(entry.value.link, er.sequence, new_path, depth + 1);
                }
            },

            .explore_union => |selectors| {
                for (selectors) |s| {
                    const saved_len = self.results.items.len;
                    try self.walk(c, s, path, depth);
                    if (self.results.items.len > saved_len) break;
                }
                value.deinit(self.allocator);
            },
        }
    }
};

pub const ParsedQuery = struct {
    root_cid: ipld.CID,
    selector: *Selector,
    type_filter: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParsedQuery) void {
        self.selector.deinit(self.allocator);
        self.allocator.destroy(self.selector);
    }
};

pub fn parseQuery(
    allocator: std.mem.Allocator,
    store: *ipld.BlockStore,
    repo: *Repository,
    query: []const u8,
) !ParsedQuery {
    if (std.mem.startsWith(u8, query, "all:")) {
        return parseAllQuery(allocator, store, query[4..]);
    }

    if (std.mem.startsWith(u8, query, "HEAD")) {
        return parseHeadQuery(allocator, store, repo, query);
    }

    return parseCIDQuery(allocator, query);
}

fn parseAllQuery(
    allocator: std.mem.Allocator,
    store: *ipld.BlockStore,
    rest: []const u8,
) !ParsedQuery {
    _ = store;
    var type_name: []const u8 = rest;
    var condition: ?Selector.Condition = null;

    if (std.mem.indexOf(u8, rest, " where ")) |where_pos| {
        type_name = rest[0..where_pos];
        const cond_str = rest[where_pos + 7 ..];
        condition = try parseCondition(cond_str);
    }

    const zero_cid = ipld.CID{
        .version = 0,
        .codec = 0,
        .hash = .{ .code = 0, .size = 0, .digest = std.mem.zeroes([32]u8) },
    };

    const sel = try allocator.create(Selector);
    sel.* = .{ .matcher = .{ .condition = condition } };

    return ParsedQuery{
        .root_cid = zero_cid,
        .selector = sel,
        .type_filter = type_name,
        .allocator = allocator,
    };
}

fn parseHeadQuery(
    allocator: std.mem.Allocator,
    store: *ipld.BlockStore,
    repo: *Repository,
    query: []const u8,
) !ParsedQuery {
    _ = store;
    var rest = query[4..];
    var steps_back: usize = 0;

    if (rest.len > 0 and rest[0] == '~') {
        rest = rest[1..];
        var num_end: usize = 0;
        while (num_end < rest.len and rest[num_end] >= '0' and rest[num_end] <= '9') num_end += 1;
        if (num_end > 0) {
            steps_back = std.fmt.parseInt(usize, rest[0..num_end], 10) catch 0;
            rest = rest[num_end..];
        }
    }

    const head_hash = repo.getHeadCommit() catch {
        return error.NoCommits;
    };
    var head_cid = ipld.CID{
        .version = 1,
        .codec = @intFromEnum(ipld.Codec.dag_cbor),
        .hash = .{ .code = 0x12, .size = 32, .digest = head_hash.hash },
    };

    if (steps_back > 0) {
        head_cid = try walkBackCommits(allocator, repo, head_cid, steps_back);
    }

    var path_parts: std.ArrayList([]const u8) = .empty;
    defer path_parts.deinit(allocator);

    if (rest.len > 0 and rest[0] == '/') {
        const path_str = rest[1..];
        var pit = std.mem.splitSequence(u8, path_str, "/");
        while (pit.next()) |part| {
            if (part.len > 0) try path_parts.append(allocator, part);
        }
    }

    const sel = try buildPathSelector(allocator, path_parts.items);

    return ParsedQuery{
        .root_cid = head_cid,
        .selector = sel,
        .type_filter = null,
        .allocator = allocator,
    };
}

fn parseCIDQuery(allocator: std.mem.Allocator, query: []const u8) !ParsedQuery {
    const slash = std.mem.indexOf(u8, query, "/");
    const cid_str = if (slash) |s| query[0..s] else query;
    const path_str = if (slash) |s| query[s + 1 ..] else "";

    const c = ipld.CID.fromHex(cid_str) catch return error.InvalidCID;

    var path_parts: std.ArrayList([]const u8) = .empty;
    defer path_parts.deinit(allocator);
    var pit = std.mem.splitSequence(u8, path_str, "/");
    while (pit.next()) |part| {
        if (part.len > 0) try path_parts.append(allocator, part);
    }

    const sel = try buildPathSelector(allocator, path_parts.items);

    return ParsedQuery{
        .root_cid = c,
        .selector = sel,
        .type_filter = null,
        .allocator = allocator,
    };
}

fn buildPathSelector(allocator: std.mem.Allocator, parts: []const []const u8) !*Selector {
    if (parts.len == 0) {
        const sel = try allocator.create(Selector);
        sel.* = .{ .matcher = .{ .condition = null } };
        return sel;
    }

    var inner = try allocator.create(Selector);
    inner.* = .{ .matcher = .{ .condition = null } };

    var i: usize = parts.len;
    while (i > 0) {
        i -= 1;
        const field_list = try allocator.alloc([]const u8, 1);
        field_list[0] = parts[i];
        const outer = try allocator.create(Selector);
        outer.* = .{ .explore_fields = .{ .fields = field_list, .next = inner } };
        inner = outer;
    }

    return inner;
}

fn parseCondition(expr: []const u8) !Selector.Condition {
    const trimmed = std.mem.trim(u8, expr, " ");

    const ops = [_]struct { s: []const u8, op: Selector.Condition.CondOp }{
        .{ .s = ">=", .op = .gte },
        .{ .s = "<=", .op = .lte },
        .{ .s = ">", .op = .gt },
        .{ .s = "<", .op = .lt },
        .{ .s = "=", .op = .eq },
        .{ .s = "==", .op = .eq },
    };

    for (ops) |op_entry| {
        if (std.mem.indexOf(u8, trimmed, op_entry.s)) |op_pos| {
            const field = std.mem.trim(u8, trimmed[0..op_pos], " ");
            const val_str = std.mem.trim(u8, trimmed[op_pos + op_entry.s.len ..], " ");
            const val = try std.fmt.parseFloat(f64, val_str);
            return .{ .field = field, .op = op_entry.op, .value = val };
        }
    }
    return error.InvalidCondition;
}

fn walkBackCommits(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    start: ipld.CID,
    steps: usize,
) !ipld.CID {
    _ = start;
    const head_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "HEAD" });
    defer allocator.free(head_path);
    const head_content = std.Io.Dir.cwd().readFileAlloc(io, head_path, allocator, .limited(256)) catch return error.NoCommits;
    defer allocator.free(head_content);

    var current_hash = blk: {
        if (std.mem.startsWith(u8, head_content, "ref: ")) {
            const ref = std.mem.trim(u8, head_content[5..], "\n\r ");
            const ref_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", ref });
            defer allocator.free(ref_path);
            const ref_content = std.Io.Dir.cwd().readFileAlloc(io, ref_path, allocator, .limited(256)) catch return error.NoCommits;
            defer allocator.free(ref_content);
            break :blk try allocator.dupe(u8, std.mem.trim(u8, ref_content, "\n\r "));
        }
        break :blk try allocator.dupe(u8, std.mem.trim(u8, head_content, "\n\r "));
    };
    defer allocator.free(current_hash);

    var step: usize = 0;
    while (step < steps) : (step += 1) {
        const commit_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "commits", current_hash });
        defer allocator.free(commit_path);
        const commit_data = std.Io.Dir.cwd().readFileAlloc(io, commit_path, allocator, .limited(64 * 1024)) catch break;
        defer allocator.free(commit_data);

        var found_parent = false;
        var li = std.mem.splitSequence(u8, commit_data, "\n");
        while (li.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent=")) {
                const parent = line[7..];
                if (parent.len == 64) {
                    allocator.free(current_hash);
                    current_hash = try allocator.dupe(u8, parent);
                    found_parent = true;
                    break;
                }
            }
        }
        if (!found_parent) break;
    }

    return ipld.CID.fromHex(current_hash) catch error.InvalidCID;
}

fn cloneValue(allocator: std.mem.Allocator, v: ipld.Value) !ipld.Value {
    return switch (v) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .bytes => |b| .{ .bytes = try allocator.dupe(u8, b) },
        .int => |i| .{ .int = i },
        .uint => |u| .{ .uint = u },
        .float => |f| .{ .float = f },
        .bool => |b| .{ .bool = b },
        .null => .null,
        .link => |c| .{ .link = c },
        else => .null,
    };
}

pub fn dagQuery(
    allocator: std.mem.Allocator,
    repo: *Repository,
    query_str: []const u8,
    output_format: []const u8,
) !void {
    var store = try ipld.BlockStore.init(allocator, repo.path);
    defer store.deinit();

    std.debug.print("🔍 Query: {s}\n\n", .{query_str});

    var pq = parseQuery(allocator, &store, repo, query_str) catch |err| {
        std.debug.print("❌ Parse error: {}\n", .{err});
        std.debug.print("\nQuery syntax:\n", .{});
        std.debug.print("  all:commit                        — all commit nodes\n", .{});
        std.debug.print("  all:metrics                       — all metrics nodes\n", .{});
        std.debug.print("  all:metrics where accuracy>0.9    — filtered metrics\n", .{});
        std.debug.print("  all:graft                         — all grafted links\n", .{});
        std.debug.print("  <cid>/author                      — field from node\n", .{});
        std.debug.print("  <cid>/metrics/accuracy            — nested field\n\n", .{});
        return;
    };
    defer pq.deinit();

    var engine = SelectorEngine.init(allocator, &store, pq.type_filter);
    defer engine.deinit();

    if (pq.root_cid.version == 0) {
        try scanAllBlocks(allocator, &store, &engine, pq.selector);
    } else {
        try engine.execute(pq.root_cid, pq.selector);
    }

    const results = engine.results.items;

    if (results.len == 0) {
        std.debug.print("   No results.\n\n", .{});
        return;
    }

    std.debug.print("   {d} result(s):\n\n", .{results.len});

    if (std.mem.eql(u8, output_format, "cids")) {
        for (results) |r| {
            const short = try r.cid.toShort(allocator);
            defer allocator.free(short);
            std.debug.print("{s}\n", .{short});
        }
        return;
    }

    if (std.mem.eql(u8, output_format, "json")) {
        std.debug.print("[\n", .{});
        for (results, 0..) |r, i| {
            const short = try r.cid.toShort(allocator);
            defer allocator.free(short);
            std.debug.print("  {{\"cid\":\"{s}\",\"path\":\"{s}\"", .{ short, r.path });
            if (r.value == .string) std.debug.print(",\"value\":\"{s}\"", .{r.value.string});
            if (r.value == .float) std.debug.print(",\"value\":{d:.6}", .{r.value.float});
            if (r.value == .int) std.debug.print(",\"value\":{d}", .{r.value.int});
            std.debug.print("}}{s}\n", .{if (i < results.len - 1) "," else ""});
        }
        std.debug.print("]\n\n", .{});
        return;
    }

    for (results) |r| {
        const short = try r.cid.toShort(allocator);
        defer allocator.free(short);

        const ntype = if (r.value == .map)
            r.value.getString("zev") orelse "unknown"
        else
            @tagName(r.value);

        const icon: []const u8 = if (std.mem.eql(u8, ntype, "commit")) "●" else if (std.mem.eql(u8, ntype, "metrics")) "📊" else if (std.mem.eql(u8, ntype, "snapshot")) "📸" else if (std.mem.eql(u8, ntype, "graft")) "🔗" else if (std.mem.eql(u8, ntype, "dataset_shard")) "📂" else if (std.mem.eql(u8, ntype, "context")) "🤖" else "🔷";

        std.debug.print("  {s} [{s}] {s}", .{ icon, ntype, short });
        if (r.path.len > 0) std.debug.print("  path={s}", .{r.path});
        std.debug.print("\n", .{});

        if (r.value == .map) {
            for (r.value.map) |entry| {
                if (std.mem.eql(u8, entry.key, "zev")) continue;
                switch (entry.value) {
                    .string => |s| std.debug.print("     {s}: \"{s}\"\n", .{ entry.key, s[0..@min(60, s.len)] }),
                    .int => |i| std.debug.print("     {s}: {d}\n", .{ entry.key, i }),
                    .float => |f| std.debug.print("     {s}: {d:.4}\n", .{ entry.key, f }),
                    .link => |c| {
                        const ls = try c.toShort(allocator);
                        defer allocator.free(ls);
                        std.debug.print("     → {s}: {s}\n", .{ entry.key, ls });
                    },
                    .map => |m| {
                        std.debug.print("     {s}:\n", .{entry.key});
                        for (m) |me| {
                            switch (me.value) {
                                .float => |f| std.debug.print("       {s}: {d:.4}\n", .{ me.key, f }),
                                .string => |s| std.debug.print("       {s}: \"{s}\"\n", .{ me.key, s }),
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }
        } else {
            switch (r.value) {
                .string => |s| std.debug.print("     value: \"{s}\"\n", .{s}),
                .float => |f| std.debug.print("     value: {d:.6}\n", .{f}),
                .int => |i| std.debug.print("     value: {d}\n", .{i}),
                .uint => |u| std.debug.print("     value: {d}\n", .{u}),
                else => {},
            }
        }
        std.debug.print("\n", .{});
    }
}

fn scanAllBlocks(
    allocator: std.mem.Allocator,
    store: *ipld.BlockStore,
    engine: *SelectorEngine,
    sel: *const Selector,
) !void {
    const ipld_path = store.base_path;

    var root_dir = std.Io.Dir.cwd().openDir(ipld_path, .{ .iterate = true }) catch return;
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
            const c = ipld.CID.fromHex(block_entry.name) catch continue;
            try engine.walk(c, sel, "", 0);
        }
    }
}

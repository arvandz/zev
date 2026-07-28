const std = @import("std");
const ipld = @import("ipld.zig");

pub const TreeEntry = struct {
    name: []u8,
    hash: []u8,
    size: usize,

    pub fn deinit(self: TreeEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.hash);
    }
};

pub fn readTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_path: []const u8,
    tree_hash: []const u8,
) ![]TreeEntry {
    const obj_path = try findObject(allocator, io, repo_path, tree_hash);
    defer allocator.free(obj_path);

    const content = try std.Io.Dir.cwd().readFileAlloc(io, obj_path, allocator, .limited(1024 * 1024));
    defer allocator.free(content);

    var entries = std.ArrayList(TreeEntry){};
    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitSequence(u8, line, " ");
        const name = parts.next() orelse continue;
        const hash = parts.next() orelse continue;
        const size_str = parts.next() orelse "0";
        const size = std.fmt.parseInt(usize, size_str, 10) catch 0;

        if (std.mem.eql(u8, name, "tree") or
            std.mem.eql(u8, name, "author") or
            std.mem.eql(u8, name, "parent") or
            std.mem.eql(u8, name, "timestamp")) continue;

        if (hash.len < 16) continue;
        var valid = true;
        for (hash[0..@min(16, hash.len)]) |c| {
            if (!std.ascii.isHex(c)) {
                valid = false;
                break;
            }
        }
        if (!valid) continue;

        try entries.append(allocator, TreeEntry{
            .name = try allocator.dupe(u8, name),
            .hash = try allocator.dupe(u8, hash),
            .size = size,
        });
    }
    return entries.toOwnedSlice(allocator);
}

pub fn readObject(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_path: []const u8,
    hash: []const u8,
) ![]u8 {
    const path = try findObject(allocator, io, repo_path, hash);
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024)); // 10MB max
}

fn findObject(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_path: []const u8,
    hash_prefix: []const u8,
) ![]u8 {
    const objects_dir = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "objects" });
    defer allocator.free(objects_dir);

    const exact = try std.fs.path.join(allocator, &.{ objects_dir, hash_prefix });
    if (std.Io.Dir.cwd().access(exact, .{})) |_| return exact else |_| allocator.free(exact);

    var dir = try std.Io.Dir.cwd().openDir(objects_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, hash_prefix[0..@min(hash_prefix.len, 16)])) {
            return std.fs.path.join(allocator, &.{ objects_dir, entry.name });
        }
    }
    return error.ObjectNotFound;
}

const FileType = enum {
    python,
    json,
    yaml,
    toml,
    markdown,
    text,
    binary,

    fn fromName(name: []const u8) FileType {
        if (std.mem.endsWith(u8, name, ".py")) return .python;
        if (std.mem.endsWith(u8, name, ".json")) return .json;
        if (std.mem.endsWith(u8, name, ".yaml")) return .yaml;
        if (std.mem.endsWith(u8, name, ".yml")) return .yaml;
        if (std.mem.endsWith(u8, name, ".toml")) return .toml;
        if (std.mem.endsWith(u8, name, ".md")) return .markdown;
        if (std.mem.endsWith(u8, name, ".txt")) return .text;
        if (std.mem.endsWith(u8, name, ".cfg")) return .text;
        if (std.mem.endsWith(u8, name, ".ini")) return .text;
        if (std.mem.endsWith(u8, name, ".sh")) return .text;
        return .binary;
    }
};

pub const SemanticChange = struct {
    kind: Kind,
    what: []const u8,
    detail: []const u8,

    pub const Kind = enum {
        function_added,
        function_removed,
        function_modified,
        class_added,
        class_removed,
        import_added,
        import_removed,
        config_changed,
        config_added,
        config_removed,
        line_added,
        line_removed,
        binary_changed,
    };
};

pub const FileDiff = struct {
    name: []const u8,
    hash_a: []const u8,
    hash_b: []const u8,
    size_a: usize,
    size_b: usize,
    ftype: FileType,
    change: Change,
    semantic: []SemanticChange,

    pub const Change = enum { added, removed, modified, unchanged };

    pub fn deinit(self: FileDiff, allocator: std.mem.Allocator) void {
        for (self.semantic) |sc| {
            allocator.free(sc.what);
            allocator.free(sc.detail);
        }
        allocator.free(self.semantic);
    }
};

fn diffPython(
    allocator: std.mem.Allocator,
    io: std.Io,
    content_a: []const u8,
    content_b: []const u8,
    out: *std.ArrayList(SemanticChange),
) !void {
    const defs_a = try extractPythonDefs(allocator, content_a);
    defer {
        for (defs_a) |d| allocator.free(d);
        allocator.free(defs_a);
    }
    const defs_b = try extractPythonDefs(allocator, content_b);
    defer {
        for (defs_b) |d| allocator.free(d);
        allocator.free(defs_b);
    }

    for (defs_b) |def| {
        var found = false;
        for (defs_a) |da| if (std.mem.eql(u8, da, def)) {
            found = true;
            break;
        };
        if (!found) {
            const kind: SemanticChange.Kind = if (std.mem.startsWith(u8, def, "class "))
                .class_added
            else
                .function_added;
            try out.append(allocator, .{
                .kind = kind,
                .what = try allocator.dupe(u8, def),
                .detail = try allocator.dupe(u8, "added"),
            });
        }
    }
    for (defs_a) |def| {
        var found = false;
        for (defs_b) |db| if (std.mem.eql(u8, db, def)) {
            found = true;
            break;
        };
        if (!found) {
            const kind: SemanticChange.Kind = if (std.mem.startsWith(u8, def, "class "))
                .class_removed
            else
                .function_removed;
            try out.append(allocator, .{
                .kind = kind,
                .what = try allocator.dupe(u8, def),
                .detail = try allocator.dupe(u8, "removed"),
            });
        }
    }

    const imports_a = try extractImports(allocator, content_a);
    defer {
        for (imports_a) |i| allocator.free(i);
        allocator.free(imports_a);
    }
    const imports_b = try extractImports(allocator, content_b);
    defer {
        for (imports_b) |i| allocator.free(i);
        allocator.free(imports_b);
    }

    for (imports_b) |imp| {
        var found = false;
        for (imports_a) |ia| if (std.mem.eql(u8, ia, imp)) {
            found = true;
            break;
        };
        if (!found) try out.append(allocator, .{
            .kind = .import_added,
            .what = try allocator.dupe(u8, imp),
            .detail = try allocator.dupe(u8, "added"),
        });
    }
    for (imports_a) |imp| {
        var found = false;
        for (imports_b) |ib| if (std.mem.eql(u8, ib, imp)) {
            found = true;
            break;
        };
        if (!found) try out.append(allocator, .{
            .kind = .import_removed,
            .what = try allocator.dupe(u8, imp),
            .detail = try allocator.dupe(u8, "removed"),
        });
    }

    try diffNumericAssignments(allocator, content_a, content_b, out);
}

fn extractPythonDefs(allocator: std.mem.Allocator, content: []const u8) ![][]u8 {
    var defs = std.ArrayList([]u8){};
    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "def ") or
            std.mem.startsWith(u8, trimmed, "class ") or
            std.mem.startsWith(u8, trimmed, "async def "))
        {
            const end = std.mem.indexOf(u8, trimmed, "(") orelse
                std.mem.indexOf(u8, trimmed, ":") orelse trimmed.len;
            try defs.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, trimmed[0..end], " ")));
        }
    }
    return defs.toOwnedSlice(allocator);
}

fn extractImports(allocator: std.mem.Allocator, content: []const u8) ![][]u8 {
    var imports = std.ArrayList([]u8){};
    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "import ") or
            std.mem.startsWith(u8, trimmed, "from "))
        {
            try imports.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }
    return imports.toOwnedSlice(allocator);
}

fn diffNumericAssignments(
    allocator: std.mem.Allocator,
    content_a: []const u8,
    content_b: []const u8,
    out: *std.ArrayList(SemanticChange),
) !void {
    var map_a = std.StringHashMap(f64).init(allocator);
    defer {
        var it = map_a.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        map_a.deinit();
    }
    var map_b = std.StringHashMap(f64).init(allocator);
    defer {
        var it = map_b.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        map_b.deinit();
    }

    try extractNumericAssigns(allocator, content_a, &map_a);
    try extractNumericAssigns(allocator, content_b, &map_b);

    var it = map_b.iterator();
    while (it.next()) |entry| {
        const val_b = entry.value_ptr.*;
        if (map_a.get(entry.key_ptr.*)) |val_a| {
            if (@abs(val_b - val_a) > 0.0001 * @abs(val_a + val_b + 0.001)) {
                const detail = try std.fmt.allocPrint(allocator, "{d:.6} → {d:.6}", .{ val_a, val_b });
                try out.append(allocator, .{
                    .kind = .config_changed,
                    .what = try allocator.dupe(u8, entry.key_ptr.*),
                    .detail = detail,
                });
            }
        }
    }
}

fn extractNumericAssigns(
    allocator: std.mem.Allocator,
    content: []const u8,
    map: *std.StringHashMap(f64),
) !void {
    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "#")) continue;
        const eq = std.mem.indexOf(u8, trimmed, "=") orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        if (key.len == 0 or key.len > 40) continue;
        var valid = true;
        for (key) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') {
            valid = false;
            break;
        };
        if (!valid) continue;
        const val_str = std.mem.trim(u8, trimmed[eq + 1 ..], " \t#\"'");
        const val = std.fmt.parseFloat(f64, val_str) catch continue;
        const k = try allocator.dupe(u8, key);
        try map.put(k, val);
    }
}

fn diffConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    content_a: []const u8,
    content_b: []const u8,
    out: *std.ArrayList(SemanticChange),
) !void {
    var map_a = std.StringHashMap([]u8).init(allocator);
    defer {
        var it = map_a.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        map_a.deinit();
    }
    var map_b = std.StringHashMap([]u8).init(allocator);
    defer {
        var it = map_b.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        map_b.deinit();
    }

    try extractConfigPairs(allocator, content_a, &map_a);
    try extractConfigPairs(allocator, content_b, &map_b);

    var it_a = map_a.iterator();
    while (it_a.next()) |entry| {
        if (map_b.get(entry.key_ptr.*)) |val_b| {
            if (!std.mem.eql(u8, entry.value_ptr.*, val_b)) {
                const detail = try std.fmt.allocPrint(allocator, "\"{s}\" → \"{s}\"", .{ entry.value_ptr.*[0..@min(30, entry.value_ptr.*.len)], val_b[0..@min(30, val_b.len)] });
                try out.append(allocator, .{
                    .kind = .config_changed,
                    .what = try allocator.dupe(u8, entry.key_ptr.*),
                    .detail = detail,
                });
            }
        } else {
            try out.append(allocator, .{
                .kind = .config_removed,
                .what = try allocator.dupe(u8, entry.key_ptr.*),
                .detail = try allocator.dupe(u8, "removed"),
            });
        }
    }
    var it_b = map_b.iterator();
    while (it_b.next()) |entry| {
        if (!map_a.contains(entry.key_ptr.*)) {
            try out.append(allocator, .{
                .kind = .config_added,
                .what = try allocator.dupe(u8, entry.key_ptr.*),
                .detail = try allocator.dupe(u8, entry.value_ptr.*[0..@min(40, entry.value_ptr.*.len)]),
            });
        }
    }
}

fn extractConfigPairs(
    allocator: std.mem.Allocator,
    content: []const u8,
    map: *std.StringHashMap([]u8),
) !void {
    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#' or trimmed[0] == '[' or trimmed[0] == '{' or trimmed[0] == '}') continue;

        const sep_colon = std.mem.indexOf(u8, trimmed, "\": ");
        const sep_yaml = std.mem.indexOf(u8, trimmed, ": ");
        const sep_toml = std.mem.indexOf(u8, trimmed, " = ");

        const sep_pos = sep_colon orelse sep_yaml orelse sep_toml orelse continue;
        const sep_len: usize = if (sep_colon != null) 3 else if (sep_yaml != null) 2 else 3;

        const key = std.mem.trim(u8, trimmed[0..sep_pos], " \t\"'");
        if (key.len == 0 or key.len > 60) continue;
        const val = std.mem.trim(u8, trimmed[sep_pos + sep_len ..], " \t,\"'");

        const k = try allocator.dupe(u8, key);
        const v = try allocator.dupe(u8, val[0..@min(val.len, 100)]);
        try map.put(k, v);
    }
}

fn diffText(
    allocator: std.mem.Allocator,
    content_a: []const u8,
    content_b: []const u8,
    out: *std.ArrayList(SemanticChange),
) !void {
    var lines_a = std.ArrayList([]const u8){};
    defer lines_a.deinit(allocator);
    var lines_b = std.ArrayList([]const u8){};
    defer lines_b.deinit(allocator);

    var it = std.mem.splitSequence(u8, content_a, "\n");
    while (it.next()) |l| try lines_a.append(allocator, l);
    it = std.mem.splitSequence(u8, content_b, "\n");
    while (it.next()) |l| try lines_b.append(allocator, l);

    var added: usize = 0;
    var removed: usize = 0;

    for (lines_b.items) |lb| {
        var found = false;
        for (lines_a.items) |la| if (std.mem.eql(u8, la, lb)) {
            found = true;
            break;
        };
        if (!found) added += 1;
    }
    for (lines_a.items) |la| {
        var found = false;
        for (lines_b.items) |lb| if (std.mem.eql(u8, la, lb)) {
            found = true;
            break;
        };
        if (!found) removed += 1;
    }

    if (added > 0) try out.append(allocator, .{
        .kind = .line_added,
        .what = try std.fmt.allocPrint(allocator, "{d} line(s)", .{added}),
        .detail = try allocator.dupe(u8, "added"),
    });
    if (removed > 0) try out.append(allocator, .{
        .kind = .line_removed,
        .what = try std.fmt.allocPrint(allocator, "{d} line(s)", .{removed}),
        .detail = try allocator.dupe(u8, "removed"),
    });
}

pub fn diffTrees(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_path: []const u8,
    tree_hash_a: []const u8,
    tree_hash_b: []const u8,
) ![]FileDiff {
    const entries_a = readTree(allocator, repo_path, tree_hash_a) catch &[_]TreeEntry{};
    defer {
        for (entries_a) |e| e.deinit(allocator);
        allocator.free(entries_a);
    }

    const entries_b = readTree(allocator, repo_path, tree_hash_b) catch &[_]TreeEntry{};
    defer {
        for (entries_b) |e| e.deinit(allocator);
        allocator.free(entries_b);
    }

    var diffs = std.ArrayList(FileDiff){};

    for (entries_b) |eb| {
        var found_a: ?TreeEntry = null;
        for (entries_a) |ea| {
            if (std.mem.eql(u8, ea.name, eb.name)) {
                found_a = ea;
                break;
            }
        }

        if (found_a == null) {
            try diffs.append(allocator, FileDiff{
                .name = try allocator.dupe(u8, eb.name),
                .hash_a = try allocator.dupe(u8, ""),
                .hash_b = try allocator.dupe(u8, eb.hash[0..@min(16, eb.hash.len)]),
                .size_a = 0,
                .size_b = eb.size,
                .ftype = FileType.fromName(eb.name),
                .change = .added,
                .semantic = &.{},
            });
            continue;
        }

        const ea = found_a.?;
        if (std.mem.eql(u8, ea.hash, eb.hash)) {
            try diffs.append(allocator, FileDiff{
                .name = try allocator.dupe(u8, eb.name),
                .hash_a = try allocator.dupe(u8, ea.hash[0..@min(16, ea.hash.len)]),
                .hash_b = try allocator.dupe(u8, eb.hash[0..@min(16, eb.hash.len)]),
                .size_a = ea.size,
                .size_b = eb.size,
                .ftype = FileType.fromName(eb.name),
                .change = .unchanged,
                .semantic = &.{},
            });
            continue;
        }

        const ftype = FileType.fromName(eb.name);
        var semantic = std.ArrayList(SemanticChange){};

        const content_a = readObject(allocator, repo_path, ea.hash) catch null;
        defer if (content_a) |c| allocator.free(c);
        const content_b = readObject(allocator, repo_path, eb.hash) catch null;
        defer if (content_b) |c| allocator.free(c);

        if (content_a != null and content_b != null) {
            switch (ftype) {
                .python => try diffPython(allocator, io, content_a.?, content_b.?, &semantic),
                .json, .yaml, .toml => try diffConfig(allocator, io, content_a.?, content_b.?, &semantic),
                .text, .markdown => try diffText(allocator, content_a.?, content_b.?, &semantic),
                .binary => try semantic.append(allocator, .{
                    .kind = .binary_changed,
                    .what = try allocator.dupe(u8, "binary content"),
                    .detail = try std.fmt.allocPrint(allocator, "{d} → {d} bytes", .{ ea.size, eb.size }),
                }),
            }
        }

        try diffs.append(allocator, FileDiff{
            .name = try allocator.dupe(u8, eb.name),
            .hash_a = try allocator.dupe(u8, ea.hash[0..@min(16, ea.hash.len)]),
            .hash_b = try allocator.dupe(u8, eb.hash[0..@min(16, eb.hash.len)]),
            .size_a = ea.size,
            .size_b = eb.size,
            .ftype = ftype,
            .change = .modified,
            .semantic = try semantic.toOwnedSlice(allocator),
        });
    }

    for (entries_a) |ea| {
        var found = false;
        for (entries_b) |eb| if (std.mem.eql(u8, ea.name, eb.name)) {
            found = true;
            break;
        };
        if (!found) try diffs.append(allocator, FileDiff{
            .name = try allocator.dupe(u8, ea.name),
            .hash_a = try allocator.dupe(u8, ea.hash[0..@min(16, ea.hash.len)]),
            .hash_b = try allocator.dupe(u8, ""),
            .size_a = ea.size,
            .size_b = 0,
            .ftype = FileType.fromName(ea.name),
            .change = .removed,
            .semantic = &.{},
        });
    }

    return diffs.toOwnedSlice(allocator);
}

pub fn printFileDiffs(
    allocator: std.mem.Allocator,
    diffs: []const FileDiff,
) !void {
    if (diffs.len == 0) {
        std.debug.print("🌲 Files: no changes\n\n", .{});
        return;
    }

    std.debug.print("🌲 Files:\n\n", .{});

    for (diffs) |d| {
        if (d.change == .unchanged) continue;

        const icon: []const u8 = switch (d.change) {
            .added => "🆕",
            .removed => "🗑️ ",
            .modified => "✏️ ",
            .unchanged => "➡️ ",
        };
        const ext = extIcon(d.ftype);

        std.debug.print("   {s} {s} {s}", .{ icon, ext, d.name });
        if (d.change == .modified and d.size_a != d.size_b) {
            const diff_size: i64 = @as(i64, @intCast(d.size_b)) - @as(i64, @intCast(d.size_a));
            const sign: []const u8 = if (diff_size > 0) "+" else "";
            std.debug.print("  ({s}{d} bytes)", .{ sign, diff_size });
        }
        std.debug.print("\n", .{});

        for (d.semantic) |sc| {
            const sc_icon: []const u8 = switch (sc.kind) {
                .function_added => "   ＋ fn",
                .function_removed => "   － fn",
                .function_modified => "   ≈  fn",
                .class_added => "   ＋ class",
                .class_removed => "   － class",
                .import_added => "   ＋ import",
                .import_removed => "   － import",
                .config_changed => "   ≈  config",
                .config_added => "   ＋ config",
                .config_removed => "   － config",
                .line_added => "   ＋",
                .line_removed => "   －",
                .binary_changed => "   ≈ ",
            };
            std.debug.print("      {s} {s}  {s}\n", .{ sc_icon, sc.what, sc.detail });
        }

        if (d.semantic.len > 0) std.debug.print("\n", .{});

        _ = allocator;
    }
    std.debug.print("\n", .{});
}

fn extIcon(ft: FileType) []const u8 {
    return switch (ft) {
        .python => "🐍",
        .json => "📋",
        .yaml => "📋",
        .toml => "📋",
        .markdown => "📝",
        .text => "📄",
        .binary => "📦",
    };
}

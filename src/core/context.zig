const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");

pub const AuthorKind = enum {
    human,
    llm,
    mixed,
    unknown,
};

pub const ContextRecord = struct {
    file_path: []const u8,
    file_cid: []const u8,
    commit_hash: []const u8,
    author_kind: AuthorKind,
    model: []const u8,
    prompt_hash: []const u8,
    prompt_text: []const u8,
    generation_ts: i64,
    record_id: []const u8,
    notes: []const u8,
};

fn contextDir(allocator: std.mem.Allocator, repo: *Repository) ![]u8 {
    const dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "context" });
    try std.Io.Dir.cwd().makePath(dir);
    return dir;
}

fn kindStr(k: AuthorKind) []const u8 {
    return switch (k) {
        .human => "human",
        .llm => "llm",
        .mixed => "mixed",
        .unknown => "unknown",
    };
}

fn parseKind(s: []const u8) AuthorKind {
    if (std.mem.eql(u8, s, "human")) return .human;
    if (std.mem.eql(u8, s, "llm")) return .llm;
    if (std.mem.eql(u8, s, "mixed")) return .mixed;
    return .unknown;
}

fn saveRecord(
    allocator: std.mem.Allocator,
    repo: *Repository,
    rec: ContextRecord,
) !void {
    const dir = try contextDir(allocator, repo);
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, rec.record_id });
    defer allocator.free(path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const fields = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "record_id", .v = rec.record_id },
        .{ .k = "file_path", .v = rec.file_path },
        .{ .k = "file_cid", .v = rec.file_cid },
        .{ .k = "commit_hash", .v = rec.commit_hash },
        .{ .k = "author_kind", .v = kindStr(rec.author_kind) },
        .{ .k = "model", .v = rec.model },
        .{ .k = "prompt_hash", .v = rec.prompt_hash },
        .{ .k = "notes", .v = rec.notes },
    };
    for (fields) |f| {
        const s = try std.fmt.allocPrint(allocator, "{s}={s}\n", .{ f.k, f.v });
        defer allocator.free(s);
        try out.appendSlice(allocator, s);
    }
    const ts_s = try std.fmt.allocPrint(allocator, "generation_ts={d}\n", .{rec.generation_ts});
    defer allocator.free(ts_s);
    try out.appendSlice(allocator, ts_s);

    if (rec.prompt_text.len > 0) {
        const prompt_s = try std.fmt.allocPrint(allocator, "prompt={s}\n", .{rec.prompt_text});
        defer allocator.free(prompt_s);
        try out.appendSlice(allocator, prompt_s);
    }

    const f = try std.Io.Dir.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(out.items);
}

fn loadRecord(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?ContextRecord {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(content);

    var record_id: []u8 = try allocator.dupe(u8, "");
    var file_path: []u8 = try allocator.dupe(u8, "");
    var file_cid: []u8 = try allocator.dupe(u8, "");
    var commit_hash: []u8 = try allocator.dupe(u8, "");
    var author_kind: AuthorKind = .unknown;
    var model: []u8 = try allocator.dupe(u8, "");
    var prompt_hash: []u8 = try allocator.dupe(u8, "");
    var prompt_text: []u8 = try allocator.dupe(u8, "");
    var notes: []u8 = try allocator.dupe(u8, "");
    var generation_ts: i64 = 0;

    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOf(u8, line, "=") orelse continue;
        const k = line[0..eq];
        const v = line[eq + 1 ..];
        if (std.mem.eql(u8, k, "record_id")) {
            allocator.free(record_id);
            record_id = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "file_path")) {
            allocator.free(file_path);
            file_path = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "file_cid")) {
            allocator.free(file_cid);
            file_cid = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "commit_hash")) {
            allocator.free(commit_hash);
            commit_hash = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "author_kind")) {
            author_kind = parseKind(v);
        } else if (std.mem.eql(u8, k, "model")) {
            allocator.free(model);
            model = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "prompt_hash")) {
            allocator.free(prompt_hash);
            prompt_hash = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "prompt")) {
            allocator.free(prompt_text);
            prompt_text = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "notes")) {
            allocator.free(notes);
            notes = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "generation_ts")) {
            generation_ts = std.fmt.parseInt(i64, v, 10) catch 0;
        }
    }

    if (record_id.len == 0) {
        allocator.free(record_id);
        allocator.free(file_path);
        allocator.free(file_cid);
        allocator.free(commit_hash);
        allocator.free(model);
        allocator.free(prompt_hash);
        allocator.free(prompt_text);
        allocator.free(notes);
        return null;
    }

    return ContextRecord{
        .record_id = record_id,
        .file_path = file_path,
        .file_cid = file_cid,
        .commit_hash = commit_hash,
        .author_kind = author_kind,
        .model = model,
        .prompt_hash = prompt_hash,
        .prompt_text = prompt_text,
        .generation_ts = generation_ts,
        .notes = notes,
    };
}

fn freeRecord(allocator: std.mem.Allocator, rec: ContextRecord) void {
    allocator.free(rec.record_id);
    allocator.free(rec.file_path);
    allocator.free(rec.file_cid);
    allocator.free(rec.commit_hash);
    allocator.free(rec.model);
    allocator.free(rec.prompt_hash);
    allocator.free(rec.prompt_text);
    allocator.free(rec.notes);
}

fn computeFileCid(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) ![]u8 {
    const content = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(64 * 1024 * 1024)) catch
        return try allocator.dupe(u8, "unknown");
    defer allocator.free(content);
    const c = cid_mod.CID.fromBytes(content);
    return try c.toString(allocator);
}

fn computePromptHash(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    const c = cid_mod.CID.fromBytes(prompt);
    return try c.toString(allocator);
}

fn getHeadHash(allocator: std.mem.Allocator, repo: *Repository) ![]u8 {
    const head = repo.getHeadCommit() catch
        return try allocator.dupe(u8, "none");
    return try head.toString(allocator);
}

fn makeRecordId(allocator: std.mem.Allocator, file_path: []const u8, ts: i64) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, "ctx:{s}:{d}", .{ file_path, ts });
    defer allocator.free(raw);
    const c = cid_mod.CID.fromBytes(raw);
    return try c.toString(allocator);
}

fn kindIcon(k: AuthorKind) []const u8 {
    return switch (k) {
        .human => "👤",
        .llm => "🤖",
        .mixed => "🔀",
        .unknown => "❓",
    };
}

fn modelIcon(model: []const u8) []const u8 {
    if (std.mem.indexOf(u8, model, "claude") != null) return "◆ ";
    if (std.mem.indexOf(u8, model, "gpt") != null) return "⬡ ";
    if (std.mem.indexOf(u8, model, "gemini") != null) return "✦ ";
    if (std.mem.indexOf(u8, model, "llama") != null) return "🦙";
    if (std.mem.indexOf(u8, model, "human") != null) return "👤";
    return "  ";
}

fn iterateRecords(
    allocator: std.mem.Allocator,
    repo: *Repository,
    callback: fn (allocator: std.mem.Allocator, rec: ContextRecord, ctx: *anyopaque) anyerror!bool,
    ctx: *anyopaque,
) !void {
    const dir_path = try contextDir(allocator, repo);
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);

        const rec = (try loadRecord(allocator, path)) orelse continue;
        const cont = try callback(allocator, rec, ctx);
        freeRecord(allocator, rec);
        if (!cont) break;
    }
}

pub fn contextAdd(
    allocator: std.mem.Allocator,
    repo: *Repository,
    file_path: []const u8,
    model: []const u8,
    prompt: ?[]const u8,
    notes: ?[]const u8,
    kind_str: []const u8,
) !void {
    const now = (std.time.Instant.now() catch unreachable).timestamp.sec;

    std.Io.Dir.cwd().access(file_path, .{}) catch {
        std.debug.print("Error: file '{s}' not found\n", .{file_path});
        return;
    };

    const file_cid = try computeFileCid(allocator, file_path);
    defer allocator.free(file_cid);

    const prompt_text = prompt orelse "";
    const prompt_hash = if (prompt_text.len > 0)
        try computePromptHash(allocator, prompt_text)
    else
        try allocator.dupe(u8, "none");
    defer allocator.free(prompt_hash);

    const commit_hash = try getHeadHash(allocator, repo);
    defer allocator.free(commit_hash);

    const record_id = try makeRecordId(allocator, file_path, now);
    defer allocator.free(record_id);

    const author_kind = parseKind(kind_str);

    const rec = ContextRecord{
        .record_id = record_id,
        .file_path = file_path,
        .file_cid = file_cid,
        .commit_hash = commit_hash,
        .author_kind = author_kind,
        .model = model,
        .prompt_hash = prompt_hash,
        .prompt_text = prompt orelse "",
        .generation_ts = now,
        .notes = notes orelse "",
    };

    try saveRecord(allocator, repo, rec);

    std.debug.print("{s} Context recorded for '{s}'\n", .{ kindIcon(author_kind), file_path });
    std.debug.print("   Model:   {s}{s}\n", .{ modelIcon(model), model });
    std.debug.print("   Kind:    {s}\n", .{kindStr(author_kind)});
    std.debug.print("   CID:     {s}\n", .{file_cid[0..@min(16, file_cid.len)]});
    if (prompt_text.len > 0)
        std.debug.print("   Prompt:  {s}...\n", .{prompt_text[0..@min(60, prompt_text.len)]});
    std.debug.print("   Hash:    {s}\n", .{prompt_hash[0..@min(16, prompt_hash.len)]});
    if (notes) |n| if (n.len > 0)
        std.debug.print("   Notes:   {s}\n", .{n});
    std.debug.print("   Commit:  {s}\n", .{commit_hash[0..@min(8, commit_hash.len)]});
    std.debug.print("   ID:      {s}\n\n", .{record_id[0..16]});
    std.debug.print("   Verify: zev context show {s}\n", .{file_path});
}

pub fn contextShow(
    allocator: std.mem.Allocator,
    repo: *Repository,
    file_path: []const u8,
) !void {
    const dir_path = try contextDir(allocator, repo);
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        std.debug.print("No context records yet.\n", .{});
        return;
    };
    defer dir.close();

    std.debug.print("🔍 Context for '{s}':\n\n", .{file_path});
    var found: usize = 0;

    var records: std.ArrayList(ContextRecord) = .empty;
    defer {
        for (records.items) |r| freeRecord(allocator, r);
        records.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const rec = (try loadRecord(allocator, path)) orelse continue;
        if (std.mem.eql(u8, rec.file_path, file_path)) {
            try records.append(allocator, rec);
        } else {
            freeRecord(allocator, rec);
        }
    }

    std.mem.sort(ContextRecord, records.items, {}, struct {
        fn lt(_: void, a: ContextRecord, b: ContextRecord) bool {
            return a.generation_ts < b.generation_ts;
        }
    }.lt);

    for (records.items) |rec| {
        found += 1;
        std.debug.print("  {s} [{s}] {s}{s}\n", .{ kindIcon(rec.author_kind), kindStr(rec.author_kind), modelIcon(rec.model), rec.model });
        std.debug.print("     Prompt:  {s}\n", .{rec.prompt_hash[0..@min(16, rec.prompt_hash.len)]});
        std.debug.print("     Commit:  {s}\n", .{rec.commit_hash[0..@min(8, rec.commit_hash.len)]});
        std.debug.print("     CID:     {s}\n", .{rec.file_cid[0..@min(16, rec.file_cid.len)]});
        std.debug.print("     Time:    t={d}\n", .{rec.generation_ts});
        if (rec.prompt_text.len > 0)
            std.debug.print("     Prompt:  \"{s}\"\n", .{rec.prompt_text[0..@min(80, rec.prompt_text.len)]});
        if (rec.notes.len > 0)
            std.debug.print("     Notes:   {s}\n", .{rec.notes});
        std.debug.print("\n", .{});
    }

    if (found == 0) {
        std.debug.print("  No context records for this file.\n", .{});
        std.debug.print("  Add one: zev context add {s} --model claude-3-5-sonnet\n\n", .{file_path});
    }

    if (std.Io.Dir.cwd().access(file_path, .{}) catch null == null or true) {
        const cur_cid = computeFileCid(allocator, file_path) catch null;
        if (cur_cid) |cid| {
            defer allocator.free(cid);
            if (found > 0) {
                const last = records.items[records.items.len - 1];
                if (!std.mem.eql(u8, cid, last.file_cid)) {
                    std.debug.print("  ⚠️  File has changed since last context record\n", .{});
                    std.debug.print("     Last recorded CID: {s}\n", .{last.file_cid[0..@min(16, last.file_cid.len)]});
                    std.debug.print("     Current CID:       {s}\n", .{cid[0..@min(16, cid.len)]});
                    std.debug.print("     Update with: zev context add {s} --model <model> --kind mixed\n\n", .{file_path});
                }
            }
        }
    }
}

pub fn contextBlame(
    allocator: std.mem.Allocator,
    repo: *Repository,
) !void {
    const dir_path = try contextDir(allocator, repo);
    defer allocator.free(dir_path);

    var latest = std.StringHashMap(ContextRecord).init(allocator);
    defer {
        var it = latest.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            freeRecord(allocator, e.value_ptr.*);
        }
        latest.deinit();
    }

    var dir = std.Io.Dir.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        std.debug.print("No context records yet.\n", .{});
        std.debug.print("Add context: zev context add <file> --model <model>\n", .{});
        return;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const rec = (try loadRecord(allocator, path)) orelse continue;

        if (latest.get(rec.file_path)) |existing| {
            if (rec.generation_ts > existing.generation_ts) {
                const key = try allocator.dupe(u8, rec.file_path);
                const old_key = latest.getKey(rec.file_path).?;
                const old_rec = latest.get(rec.file_path).?;
                freeRecord(allocator, old_rec);
                allocator.free(old_key);
                try latest.put(key, rec);
            } else {
                freeRecord(allocator, rec);
            }
        } else {
            const key = try allocator.dupe(u8, rec.file_path);
            try latest.put(key, rec);
        }
    }

    std.debug.print("🔍 AI Authorship Blame:\n\n", .{});
    std.debug.print("   {s:<30} {s:<20} {s:<12} {s}\n", .{ "File", "Model", "Kind", "Prompt" });
    const divider = comptime blk: {
        var s: []const u8 = "";
        for (0..78) |_| s = s ++ "─";
        break :blk s;
    };

    var mit = latest.iterator();
    while (mit.next()) |entry| {
        const rec = entry.value_ptr.*;
        std.debug.print("   {s}{s:<28} {s}{s:<18} {s:<12} {s}\n", .{
            kindIcon(rec.author_kind),
            rec.file_path[0..@min(27, rec.file_path.len)],
            modelIcon(rec.model),
            rec.model[0..@min(17, rec.model.len)],
            kindStr(rec.author_kind),
            rec.prompt_hash[0..@min(12, rec.prompt_hash.len)],
        });
    }
    std.debug.print("   {s}\n", .{divider});

    if (latest.count() == 0) {
        std.debug.print("  No files with context records.\n\n", .{});
    }
}

pub fn contextStats(
    allocator: std.mem.Allocator,
    repo: *Repository,
) !void {
    const dir_path = try contextDir(allocator, repo);
    defer allocator.free(dir_path);

    var model_counts = std.StringHashMap(usize).init(allocator);
    defer {
        var it = model_counts.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        model_counts.deinit();
    }

    var kind_counts: [4]usize = @splat(0);
    var total: usize = 0;

    var file_models = std.StringHashMap([]u8).init(allocator);
    defer {
        var it = file_models.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        file_models.deinit();
    }
    var file_kinds = std.StringHashMap(AuthorKind).init(allocator);
    defer {
        var it = file_kinds.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        file_kinds.deinit();
    }
    var file_ts = std.StringHashMap(i64).init(allocator);
    defer {
        var it = file_ts.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        file_ts.deinit();
    }

    var dir = std.Io.Dir.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        std.debug.print("No context records yet.\n", .{});
        return;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const rec = (try loadRecord(allocator, path)) orelse continue;
        defer freeRecord(allocator, rec);

        const existing_ts = file_ts.get(rec.file_path) orelse -1;
        if (rec.generation_ts > existing_ts) {
            if (file_models.getKey(rec.file_path)) |old_key| {
                allocator.free(file_models.get(rec.file_path).?);
                allocator.free(old_key);
                allocator.free(file_kinds.getKey(rec.file_path).?);
                allocator.free(file_ts.getKey(rec.file_path).?);
            }
            try file_models.put(try allocator.dupe(u8, rec.file_path), try allocator.dupe(u8, rec.model));
            try file_kinds.put(try allocator.dupe(u8, rec.file_path), rec.author_kind);
            try file_ts.put(try allocator.dupe(u8, rec.file_path), rec.generation_ts);
        }
    }

    var fmit = file_models.iterator();
    while (fmit.next()) |entry| {
        total += 1;
        const model = entry.value_ptr.*;
        const kind = file_kinds.get(entry.key_ptr.*) orelse .unknown;
        kind_counts[@intFromEnum(kind)] += 1;

        const mc = try model_counts.getOrPut(model);
        if (!mc.found_existing) {
            mc.key_ptr.* = try allocator.dupe(u8, model);
            mc.value_ptr.* = 0;
        }
        mc.value_ptr.* += 1;
    }

    std.debug.print("📊 Context Statistics ({d} files tracked):\n\n", .{total});

    std.debug.print("   Authorship:\n", .{});
    const kinds = [_]struct { k: AuthorKind, label: []const u8 }{
        .{ .k = .llm, .label = "🤖 LLM-generated" },
        .{ .k = .human, .label = "👤 Human-written" },
        .{ .k = .mixed, .label = "🔀 Mixed (LLM+human)" },
        .{ .k = .unknown, .label = "❓ Unknown" },
    };
    for (kinds) |kd| {
        const count = kind_counts[@intFromEnum(kd.k)];
        if (count == 0) continue;
        const pct: usize = if (total > 0) (count * 100) / total else 0;
        var bar: [20]u8 = undefined;
        const bar_len = (pct * 20) / 100;
        @memset(bar[0..bar_len], '#');
        @memset(bar[bar_len..], '-');
        std.debug.print("   {s:<22} {d:>3}% {s} {d}\n", .{ kd.label, pct, bar, count });
    }

    std.debug.print("\n   By Model:\n", .{});
    var mcit = model_counts.iterator();
    while (mcit.next()) |entry| {
        const pct: usize = if (total > 0) (entry.value_ptr.* * 100) / total else 0;
        std.debug.print("   {s}{s:<24} {d:>3}%  ({d} files)\n", .{ modelIcon(entry.key_ptr.*), entry.key_ptr.*, pct, entry.value_ptr.* });
    }
    std.debug.print("\n", .{});
}

pub fn contextQuery(
    allocator: std.mem.Allocator,
    repo: *Repository,
    model_filter: ?[]const u8,
    kind_filter: ?[]const u8,
    show_prompt: bool,
) !void {
    const dir_path = try contextDir(allocator, repo);
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        std.debug.print("No context records.\n", .{});
        return;
    };
    defer dir.close();

    var latest = std.StringHashMap(ContextRecord).init(allocator);
    defer {
        var it = latest.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            freeRecord(allocator, e.value_ptr.*);
        }
        latest.deinit();
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const rec = (try loadRecord(allocator, path)) orelse continue;

        const existing_ts = if (latest.get(rec.file_path)) |e| e.generation_ts else -1;
        if (rec.generation_ts > existing_ts) {
            if (latest.getKey(rec.file_path)) |old_key| {
                freeRecord(allocator, latest.get(rec.file_path).?);
                allocator.free(old_key);
            }
            try latest.put(try allocator.dupe(u8, rec.file_path), rec);
        } else {
            freeRecord(allocator, rec);
        }
    }

    const mf = model_filter orelse "";
    const kf = kind_filter orelse "";

    std.debug.print("🔍 Context Query", .{});
    if (mf.len > 0) std.debug.print(" [model={s}]", .{mf});
    if (kf.len > 0) std.debug.print(" [kind={s}]", .{kf});
    std.debug.print(":\n\n", .{});

    var found: usize = 0;
    var lit = latest.iterator();
    while (lit.next()) |entry| {
        const rec = entry.value_ptr.*;

        if (mf.len > 0 and std.mem.indexOf(u8, rec.model, mf) == null) continue;
        if (kf.len > 0 and !std.mem.eql(u8, kindStr(rec.author_kind), kf)) continue;

        found += 1;
        std.debug.print("   {s} {s}\n", .{ kindIcon(rec.author_kind), rec.file_path });
        std.debug.print("      {s}{s}  commit={s}  t={d}\n", .{ modelIcon(rec.model), rec.model, rec.commit_hash[0..@min(8, rec.commit_hash.len)], rec.generation_ts });
        if (show_prompt and rec.prompt_text.len > 0)
            std.debug.print("      prompt: \"{s}\"\n", .{rec.prompt_text[0..@min(120, rec.prompt_text.len)]});
        if (rec.notes.len > 0)
            std.debug.print("      notes:  {s}\n", .{rec.notes});
        std.debug.print("\n", .{});
    }

    if (found == 0) {
        std.debug.print("  No files match the filter.\n\n", .{});
    } else {
        std.debug.print("  {d} file(s) found.\n\n", .{found});
    }
}

pub fn contextList(allocator: std.mem.Allocator, repo: *Repository) !void {
    const dir_path = try contextDir(allocator, repo);
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        std.debug.print("No context records yet.\n", .{});
        std.debug.print("Add context: zev context add <file> --model <model>\n", .{});
        return;
    };
    defer dir.close();

    std.debug.print("📋 All context records:\n\n", .{});
    var count: usize = 0;

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const rec = (try loadRecord(allocator, path)) orelse continue;
        defer freeRecord(allocator, rec);
        count += 1;
        std.debug.print("  {s} {s:<28} {s}{s}\n", .{ kindIcon(rec.author_kind), rec.file_path, modelIcon(rec.model), rec.model });
    }

    if (count == 0) {
        std.debug.print("  No context records yet.\n", .{});
        std.debug.print("  zev context add <file> --model claude-3-5-sonnet\n\n", .{});
    } else {
        std.debug.print("\n  Total: {d} record(s)\n\n", .{count});
    }
}

pub fn contextAutoDetect(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: Repository,
    file_path: []const u8,
) !void {
    std.Io.Dir.cwd().access(io, file_path, .{}) catch {
        std.debug.print("Error: file not found: {s}\n", .{file_path});
        return;
    };

    var detected_model: []const u8 = "unknown";
    var detected_kind: []const u8 = "unknown";
    var source: []const u8 = "none";

    const env_vars = [_]struct { env: []const u8, model: []const u8 }{
        .{ .env = "CLAUDE_CODE", .model = "claude" },
        .{ .env = "CURSOR_TRACE", .model = "cursor" },
        .{ .env = "COPILOT_AGENT", .model = "github-copilot" },
        .{ .env = "CODY_AGENT", .model = "sourcegraph-cody" },
        .{ .env = "ZEV_AI_MODEL", .model = "" },
        .{ .env = "AI_MODEL", .model = "" },
        .{ .env = "OPENAI_API_KEY", .model = "openai" },
        .{ .env = "ANTHROPIC_API_KEY", .model = "anthropic" },
        .{ .env = "GEMINI_API_KEY", .model = "gemini" },
    };

    for (env_vars) |ev| {
        const val = std.process.getEnvVarOwned(allocator, ev.env) catch continue;
        defer allocator.free(val);
        if (val.len == 0) continue;
        if (ev.model.len > 0) {
            detected_model = ev.model;
        } else {
            detected_model = val;
        }
        detected_kind = "llm";
        source = ev.env;
        break;
    }

    if (std.mem.eql(u8, detected_kind, "unknown")) {
        const file_data = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(512 * 1024)) catch {
            std.debug.print("Could not read file: {s}\n", .{file_path});
            return;
        };
        defer allocator.free(file_data);

        const ai_patterns = [_][]const u8{
            "# Generated by",
            "# This code was generated",
            "# AI-generated",
            "# Created by Claude",
            "# Created by GPT",
            "// Generated by",
            "// This code was generated",
            "<!-- Generated by",
            "Generated by",
            "This function was generated",
        };

        for (ai_patterns) |pat| {
            if (std.mem.indexOf(u8, file_data, pat) != null) {
                detected_kind = "llm";
                detected_model = "unknown-ai";
                source = "file-header-pattern";
                break;
            }
        }
    }

    if (std.mem.eql(u8, detected_kind, "unknown")) {
        detected_kind = "human";
        detected_model = "none";
        source = "default";
    }

    std.debug.print("🔍 Auto-detecting context for '{s}'\n\n", .{file_path});
    std.debug.print("   Model:  {s}\n", .{detected_model});
    std.debug.print("   Kind:   {s}\n", .{detected_kind});
    std.debug.print("   Source: {s}\n\n", .{source});

    try contextAdd(allocator, repo, file_path, detected_model, null, null, detected_kind);
}

pub fn contextAutoDetectAll(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
) !void {
    const head_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "HEAD" });
    defer allocator.free(head_path);
    const head = std.Io.Dir.cwd().readFileAlloc(io, head_path, allocator, .limited(256)) catch {
        std.debug.print("No commits yet.\n", .{});
        return;
    };
    defer allocator.free(head);

    var ref_hash: []const u8 = std.mem.trim(u8, head, "\n\r ");
    var resolved: []u8 = undefined;
    var should_free = false;

    if (std.mem.startsWith(u8, ref_hash, "ref: ")) {
        const ref = ref_hash[5..];
        const ref_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", ref });
        defer allocator.free(ref_path);
        resolved = std.Io.Dir.cwd().readFileAlloc(io, ref_path, allocator, .limited(256)) catch {
            std.debug.print("Could not resolve HEAD.\n", .{});
            return;
        };
        ref_hash = std.mem.trim(u8, resolved, "\n\r ");
        should_free = true;
    }
    defer if (should_free) allocator.free(resolved);

    const obj_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "objects", ref_hash });
    defer allocator.free(obj_path);
    const obj = std.Io.Dir.cwd().readFileAlloc(io, obj_path, allocator, .limited(64 * 1024)) catch {
        std.debug.print("Could not read commit object.\n", .{});
        return;
    };
    defer allocator.free(obj);

    var tree_hash: []const u8 = "";
    var lines = std.mem.splitSequence(u8, obj, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "tree ")) {
            tree_hash = line[5..];
            break;
        }
    }
    if (tree_hash.len == 0) return;

    const tree_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "objects", tree_hash });
    defer allocator.free(tree_path);
    const tree_data = std.Io.Dir.cwd().readFileAlloc(io, tree_path, allocator, .limited(64 * 1024)) catch return;
    defer allocator.free(tree_data);

    std.debug.print("🔍 Auto-detecting context for all files in HEAD commit\n\n", .{});

    var file_lines = std.mem.splitSequence(u8, tree_data, "\n");
    var count: usize = 0;
    while (file_lines.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitSequence(u8, line, " ");
        const fname = parts.next() orelse continue;
        if (fname.len == 0) continue;
        var valid = true;
        for (fname) |c| if (c == '=' or c == ':') {
            valid = false;
            break;
        };
        if (!valid) continue;
        try contextAutoDetect(allocator, repo, fname);
        count += 1;
    }
    std.debug.print("Processed {d} file(s).\n", .{count});
}

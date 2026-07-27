const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");

pub const SplitStrategy = enum {
    sequential,
    random,
    stratified,
};

pub const ShardRecord = struct {
    id: []const u8,
    dataset_name: []const u8,
    shard_index: usize,
    total_shards: usize,
    cid: []const u8,
    row_start: usize,
    row_end: usize,
    row_count: usize,
    byte_size: u64,
    checksum: []const u8,
    strategy: []const u8,
    created: i64,
};

pub const DatasetRecord = struct {
    name: []const u8,
    source_path: []const u8,
    source_cid: []const u8,
    total_rows: usize,
    total_bytes: u64,
    total_shards: usize,
    strategy: []const u8,
    created: i64,
    description: []const u8,
    format: []const u8,
};

pub const AssignmentRecord = struct {
    commit_hash: []const u8,
    dataset_name: []const u8,
    shard_ids: []const []const u8,
    assigned_at: i64,
    notes: []const u8,
};

fn datasetDir(allocator: std.mem.Allocator, repo: *Repository) ![]u8 {
    const dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "datasets" });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn shardsDir(allocator: std.mem.Allocator, repo: *Repository, dataset_name: []const u8) ![]u8 {
    const dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "datasets", dataset_name, "shards" });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn assignDir(allocator: std.mem.Allocator, repo: *Repository, dataset_name: []const u8) ![]u8 {
    const dir = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "datasets", dataset_name, "assignments" });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn saveDatasetRecord(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    ds: DatasetRecord,
) !void {
    const dir = try datasetDir(allocator, repo);
    defer allocator.free(dir);
    const ds_dir = try std.fs.path.join(allocator, &.{ dir, ds.name });
    try std.Io.Dir.cwd().createDirPath(io, ds_dir);
    defer allocator.free(ds_dir);
    const path = try std.fs.path.join(allocator, &.{ ds_dir, "dataset.meta" });
    defer allocator.free(path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const s = try std.fmt.allocPrint(allocator, "name={s}\nsource_path={s}\nsource_cid={s}\ntotal_rows={d}\n" ++
        "total_bytes={d}\ntotal_shards={d}\nstrategy={s}\ncreated={d}\n" ++
        "description={s}\nformat={s}\n", .{ ds.name, ds.source_path, ds.source_cid, ds.total_rows, ds.total_bytes, ds.total_shards, ds.strategy, ds.created, ds.description, ds.format });
    defer allocator.free(s);
    try out.appendSlice(allocator, s);

    const f = try std.Io.Dir.cwd().createFile(path, .{});
    defer f.close(io);
    try f.writeAll(out.items);
}

fn loadDatasetRecord(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?DatasetRecord {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch return null;
    defer allocator.free(content);

    var name: []u8 = try allocator.dupe(u8, "");
    var source_path: []u8 = try allocator.dupe(u8, "");
    var source_cid: []u8 = try allocator.dupe(u8, "");
    var strategy: []u8 = try allocator.dupe(u8, "sequential");
    var description: []u8 = try allocator.dupe(u8, "");
    var format: []u8 = try allocator.dupe(u8, "");
    var total_rows: usize = 0;
    var total_bytes: u64 = 0;
    var total_shards: usize = 0;
    var created: i64 = 0;

    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOf(u8, line, "=") orelse continue;
        const k = line[0..eq];
        const v = line[eq + 1 ..];
        if (std.mem.eql(u8, k, "name")) {
            allocator.free(name);
            name = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "source_path")) {
            allocator.free(source_path);
            source_path = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "source_cid")) {
            allocator.free(source_cid);
            source_cid = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "strategy")) {
            allocator.free(strategy);
            strategy = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "description")) {
            allocator.free(description);
            description = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "format")) {
            allocator.free(format);
            format = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, k, "total_rows")) total_rows = std.fmt.parseInt(usize, v, 10) catch 0 else if (std.mem.eql(u8, k, "total_bytes")) total_bytes = std.fmt.parseInt(u64, v, 10) catch 0 else if (std.mem.eql(u8, k, "total_shards")) total_shards = std.fmt.parseInt(usize, v, 10) catch 0 else if (std.mem.eql(u8, k, "created")) created = std.fmt.parseInt(i64, v, 10) catch 0;
    }

    if (name.len == 0) {
        allocator.free(name);
        allocator.free(source_path);
        allocator.free(source_cid);
        allocator.free(strategy);
        allocator.free(description);
        allocator.free(format);
        return null;
    }
    return DatasetRecord{ .name = name, .source_path = source_path, .source_cid = source_cid, .total_rows = total_rows, .total_bytes = total_bytes, .total_shards = total_shards, .strategy = strategy, .created = created, .description = description, .format = format };
}

fn freeDatasetRecord(allocator: std.mem.Allocator, ds: DatasetRecord) void {
    allocator.free(ds.name);
    allocator.free(ds.source_path);
    allocator.free(ds.source_cid);
    allocator.free(ds.strategy);
    allocator.free(ds.description);
    allocator.free(ds.format);
}

fn saveShardRecord(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    shard: ShardRecord,
) !void {
    const dir = try shardsDir(allocator, repo, shard.dataset_name);
    defer allocator.free(dir);
    const fname = try std.fmt.allocPrint(allocator, "shard_{d:0>4}", .{shard.shard_index});
    defer allocator.free(fname);
    const path = try std.fs.path.join(allocator, &.{ dir, fname });
    defer allocator.free(path);

    const s = try std.fmt.allocPrint(allocator, "id={s}\ndataset={s}\nindex={d}\ntotal={d}\ncid={s}\n" ++
        "row_start={d}\nrow_end={d}\nrow_count={d}\nbyte_size={d}\n" ++
        "checksum={s}\nstrategy={s}\ncreated={d}\n", .{ shard.id, shard.dataset_name, shard.shard_index, shard.total_shards, shard.cid, shard.row_start, shard.row_end, shard.row_count, shard.byte_size, shard.checksum, shard.strategy, shard.created });
    defer allocator.free(s);

    const f = try std.Io.Dir.cwd().createFile(path, .{});
    defer f.close(io);
    try f.writeAll(s);
}

fn saveAssignment(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    assignment: AssignmentRecord,
) !void {
    const dir = try assignDir(allocator, repo, assignment.dataset_name);
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, assignment.commit_hash[0..@min(16, assignment.commit_hash.len)] });
    defer allocator.free(path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const hdr = try std.fmt.allocPrint(allocator, "commit={s}\ndataset={s}\nassigned_at={d}\nnotes={s}\n", .{ assignment.commit_hash, assignment.dataset_name, assignment.assigned_at, assignment.notes });
    defer allocator.free(hdr);
    try out.appendSlice(allocator, hdr);

    for (assignment.shard_ids) |sid| {
        const sl = try std.fmt.allocPrint(allocator, "shard={s}\n", .{sid});
        defer allocator.free(sl);
        try out.appendSlice(allocator, sl);
    }

    const f = try std.Io.Dir.cwd().createFile(path, .{});
    defer f.close(io);
    try f.writeAll(out.items);
}

fn detectFormat(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".csv")) return "csv";
    if (std.mem.endsWith(u8, path, ".tsv")) return "csv";
    if (std.mem.endsWith(u8, path, ".jsonl")) return "jsonl";
    if (std.mem.endsWith(u8, path, ".json")) return "jsonl";
    if (std.mem.endsWith(u8, path, ".txt")) return "text";
    if (std.mem.endsWith(u8, path, ".bin")) return "binary";
    if (std.mem.endsWith(u8, path, ".parquet")) return "parquet";
    const stat = std.Io.Dir.cwd().statFile(path) catch return "unknown";
    if (stat.kind == .directory) return "directory";
    return "binary";
}

fn countLines(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !usize {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024 * 1024)) catch return 0;
    defer allocator.free(content);
    var count: usize = 0;
    for (content) |c| {
        if (c == '\n') count += 1;
    }
    if (content.len > 0 and content[content.len - 1] != '\n') count += 1;
    return count;
}

fn getFileSize(path: []const u8) u64 {
    const stat = std.Io.Dir.cwd().statFile(path) catch return 0;
    return @intCast(stat.size);
}

pub fn datasetRegister(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    source_path: []const u8,
    name: []const u8,
    description: []const u8,
) !void {
    std.Io.Dir.cwd().access(io, source_path, .{}) catch {
        std.debug.print("❌ Source not found: {s}\n", .{source_path});
        return;
    };

    const now = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);
    const format = detectFormat(source_path);
    const byte_size = getFileSize(source_path);

    const src_content = std.Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(64 * 1024 * 1024)) catch blk: {
        const fake = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ source_path, byte_size });
        defer allocator.free(fake);
        break :blk try allocator.dupe(u8, fake);
    };
    defer allocator.free(src_content);
    const src_cid_obj = cid_mod.CID.fromBytes(src_content);
    const src_cid = try src_cid_obj.toString(allocator);
    defer allocator.free(src_cid);

    const total_rows = if (std.mem.eql(u8, format, "csv") or
        std.mem.eql(u8, format, "jsonl") or
        std.mem.eql(u8, format, "text"))
        try countLines(allocator, source_path)
    else
        0;

    const ds = DatasetRecord{
        .name = name,
        .source_path = source_path,
        .source_cid = src_cid,
        .total_rows = total_rows,
        .total_bytes = byte_size,
        .total_shards = 0,
        .strategy = "none",
        .created = now,
        .description = description,
        .format = format,
    };

    try saveDatasetRecord(allocator, io, repo, ds);

    std.debug.print("📂 Dataset registered: {s}\n\n", .{name});
    std.debug.print("   Source:  {s}\n", .{source_path});
    std.debug.print("   Format:  {s}\n", .{format});
    std.debug.print("   Size:    {d} KB\n", .{byte_size / 1024});
    if (total_rows > 0)
        std.debug.print("   Rows:    {d}\n", .{total_rows});
    std.debug.print("   CID:     {s}\n", .{src_cid[0..@min(16, src_cid.len)]});
    if (description.len > 0)
        std.debug.print("   Desc:    {s}\n", .{description});
    std.debug.print("\n   Next: zev dataset split {s} --shards 8\n\n", .{name});
}

pub fn datasetSplit(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    dataset_name: []const u8,
    num_shards: usize,
    strategy_str: []const u8,
    seed: u64,
) !void {
    const now = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);

    const dir = try datasetDir(allocator, repo);
    defer allocator.free(dir);
    const meta_path = try std.fs.path.join(allocator, &.{ dir, dataset_name, "dataset.meta" });
    defer allocator.free(meta_path);

    var ds = (try loadDatasetRecord(allocator, meta_path)) orelse {
        std.debug.print("❌ Dataset '{s}' not found.\n", .{dataset_name});
        std.debug.print("   Register first: zev dataset register <path> --name {s}\n", .{dataset_name});
        return;
    };

    if (num_shards == 0 or num_shards > 10000) {
        std.debug.print("❌ Invalid shard count: {d}\n", .{num_shards});
        return;
    }

    std.debug.print("✂️  Splitting dataset '{s}' into {d} shards\n\n", .{ dataset_name, num_shards });
    std.debug.print("   Strategy: {s}\n", .{strategy_str});
    std.debug.print("   Format:   {s}\n", .{ds.format});
    std.debug.print("   Source:   {s}\n\n", .{ds.source_path});

    const is_line_based = std.mem.eql(u8, ds.format, "csv") or
        std.mem.eql(u8, ds.format, "jsonl") or
        std.mem.eql(u8, ds.format, "text");

    if (is_line_based and ds.total_rows > 0) {
        try splitLinesBased(allocator, io, repo, ds, num_shards, strategy_str, seed, now);
    } else {
        try splitBytesBased(allocator, io, repo, ds, num_shards, strategy_str, now);
    }

    ds.total_shards = num_shards;
    ds.strategy = strategy_str;
    const ds_updated = DatasetRecord{
        .name = ds.name,
        .source_path = ds.source_path,
        .source_cid = ds.source_cid,
        .total_rows = ds.total_rows,
        .total_bytes = ds.total_bytes,
        .total_shards = num_shards,
        .strategy = strategy_str,
        .created = ds.created,
        .description = ds.description,
        .format = ds.format,
    };
    try saveDatasetRecord(allocator, io, repo, ds_updated);

    std.debug.print("\n✅ Split complete!\n\n", .{});
    std.debug.print("   Dataset:  {s}\n", .{dataset_name});
    std.debug.print("   Shards:   {d}\n", .{num_shards});
    std.debug.print("   Strategy: {s}\n\n", .{strategy_str});
    std.debug.print("   Assign shards to a training commit:\n", .{});
    std.debug.print("   zev dataset assign {s} --shards 0,1,2,3\n\n", .{dataset_name});
    std.debug.print("   View lineage:\n", .{});
    std.debug.print("   zev dataset lineage {s}\n\n", .{dataset_name});
}

fn splitLinesBased(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    ds: DatasetRecord,
    num_shards: usize,
    strategy_str: []const u8,
    seed: u64,
    now: i64,
) !void {
    const total_rows = ds.total_rows;
    const rows_per_shard = total_rows / num_shards;
    const remainder = total_rows % num_shards;

    var indices = try allocator.alloc(usize, total_rows);
    defer allocator.free(indices);
    for (0..total_rows) |i| indices[i] = i;

    if (std.mem.eql(u8, strategy_str, "random")) {
        var rng = seed;
        var i: usize = total_rows - 1;
        while (i > 0) : (i -= 1) {
            rng = rng *% 6364136223846793005 +% 1442695040888963407; // LCG
            const j = rng % (i + 1);
            const tmp = indices[i];
            indices[i] = indices[j];
            indices[j] = tmp;
        }
    }

    std.debug.print("   {s:<8} {s:<12} {s:<12} {s:<12} {s}\n", .{ "Shard", "Rows", "Start", "End", "CID" });
    const divider60 = comptime blk: {
        var s: []const u8 = "";
        for (0..60) |_| s = s ++ "─";
        break :blk s;
    };
    std.debug.print("   {s}\n", .{divider60});

    var row_cursor: usize = 0;
    for (0..num_shards) |si| {
        const extra: usize = if (si < remainder) 1 else 0;
        const shard_rows = rows_per_shard + extra;
        const row_start = row_cursor;
        const row_end = row_cursor + shard_rows;
        row_cursor = row_end;

        const shard_raw = try std.fmt.allocPrint(allocator, "shard:{s}:{d}:{d}:{d}:{d}", .{ ds.source_cid, si, row_start, row_end, seed });
        defer allocator.free(shard_raw);
        const shard_cid_obj = cid_mod.CID.fromBytes(shard_raw);
        const shard_cid = try shard_cid_obj.toString(allocator);
        defer allocator.free(shard_cid);

        const shard_id = try std.fmt.allocPrint(allocator, "{s}:shard_{d}", .{ ds.name, si });
        defer allocator.free(shard_id);

        const shard_bytes = if (ds.total_bytes > 0 and total_rows > 0)
            (ds.total_bytes * shard_rows) / total_rows
        else
            0;

        const shard = ShardRecord{
            .id = shard_id,
            .dataset_name = ds.name,
            .shard_index = si,
            .total_shards = num_shards,
            .cid = shard_cid,
            .row_start = row_start,
            .row_end = row_end,
            .row_count = shard_rows,
            .byte_size = shard_bytes,
            .checksum = shard_cid,
            .strategy = strategy_str,
            .created = now,
        };
        try saveShardRecord(allocator, io, repo, shard);

        std.debug.print("   {d:<8} {d:<12} {d:<12} {d:<12} {s}\n", .{ si, shard_rows, row_start, row_end, shard_cid[0..@min(16, shard_cid.len)] });
    }
}

fn splitBytesBased(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    ds: DatasetRecord,
    num_shards: usize,
    strategy_str: []const u8,
    now: i64,
) !void {
    const bytes_per_shard = if (ds.total_bytes > 0) ds.total_bytes / num_shards else 0;

    std.debug.print("   {s:<8} {s:<16} {s:<14} {s}\n", .{ "Shard", "Bytes", "Offset", "CID" });
    const divider60 = comptime blk: {
        var s: []const u8 = "";
        for (0..60) |_| s = s ++ "─";
        break :blk s;
    };
    std.debug.print("   {s}\n", .{divider60});

    for (0..num_shards) |si| {
        const byte_start = si * bytes_per_shard;
        const byte_end = if (si == num_shards - 1) ds.total_bytes else (si + 1) * bytes_per_shard;
        const shard_bytes = byte_end - byte_start;

        const shard_raw = try std.fmt.allocPrint(allocator, "shard:{s}:{d}:{d}:{d}", .{ ds.source_cid, si, byte_start, byte_end });
        defer allocator.free(shard_raw);
        const shard_cid_obj = cid_mod.CID.fromBytes(shard_raw);
        const shard_cid = try shard_cid_obj.toString(allocator);
        defer allocator.free(shard_cid);

        const shard_id = try std.fmt.allocPrint(allocator, "{s}:shard_{d}", .{ ds.name, si });
        defer allocator.free(shard_id);

        const shard = ShardRecord{
            .id = shard_id,
            .dataset_name = ds.name,
            .shard_index = si,
            .total_shards = num_shards,
            .cid = shard_cid,
            .row_start = byte_start,
            .row_end = byte_end,
            .row_count = 0,
            .byte_size = shard_bytes,
            .checksum = shard_cid,
            .strategy = strategy_str,
            .created = now,
        };
        try saveShardRecord(allocator, io, repo, shard);

        std.debug.print("   {d:<8} {d:<16} {d:<14} {s}\n", .{ si, shard_bytes, byte_start, shard_cid[0..@min(16, shard_cid.len)] });
    }
}

pub fn datasetAssign(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    dataset_name: []const u8,
    shard_indices: []const usize,
    notes: []const u8,
) !void {
    const now = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);

    const head = repo.getHeadCommit() catch {
        std.debug.print("❌ No commits yet. Commit first.\n", .{});
        return;
    };
    const commit_hash = try head.toString(allocator);
    defer allocator.free(commit_hash);

    var shard_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (shard_ids.items) |s| allocator.free(s);
        shard_ids.deinit(allocator);
    }
    for (shard_indices) |idx| {
        const sid = try std.fmt.allocPrint(allocator, "{s}:shard_{d}", .{ dataset_name, idx });
        try shard_ids.append(allocator, sid);
    }

    const assignment = AssignmentRecord{
        .commit_hash = commit_hash,
        .dataset_name = dataset_name,
        .shard_ids = shard_ids.items,
        .assigned_at = now,
        .notes = notes,
    };
    try saveAssignment(allocator, io, repo, assignment);

    std.debug.print("🔗 Shards assigned to commit {s}\n\n", .{commit_hash[0..8]});
    std.debug.print("   Dataset: {s}\n", .{dataset_name});
    std.debug.print("   Shards:  ", .{});
    for (shard_indices, 0..) |idx, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{d}", .{idx});
    }
    std.debug.print("\n", .{});
    if (notes.len > 0) std.debug.print("   Notes:   {s}\n", .{notes});
    std.debug.print("\n   View impact: zev dataset impact {s} --shard <N>\n\n", .{dataset_name});
}

pub fn datasetLineage(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    dataset_name: []const u8,
) !void {
    const assign_dir_path = try assignDir(allocator, repo, dataset_name);
    defer allocator.free(assign_dir_path);

    std.debug.print("🔗 Dataset Lineage: {s}\n\n", .{dataset_name});

    var dir = std.Io.Dir.cwd().openDir(io, assign_dir_path, .{ .iterate = true }) catch {
        std.debug.print("   No assignments yet.\n", .{});
        std.debug.print("   Assign shards: zev dataset assign {s} --shards 0,1,2\n\n", .{dataset_name});
        return;
    };
    defer dir.close(io);

    std.debug.print("   {s:<12} {s:<30} {s}\n", .{ "Commit", "Shards", "Notes" });
    const divider60 = comptime blk: {
        var s: []const u8 = "";
        for (0..60) |_| s = s ++ "─";
        break :blk s;
    };
    std.debug.print("   {s}\n", .{divider60});

    var total: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ assign_dir_path, entry.name });
        defer allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(content);

        var commit: []u8 = try allocator.dupe(u8, "");
        var notes: []u8 = try allocator.dupe(u8, "");
        var shard_list: std.ArrayList([]u8) = .empty;
        defer allocator.free(commit);
        defer allocator.free(notes);
        defer {
            for (shard_list.items) |s| allocator.free(s);
            shard_list.deinit(allocator);
        }

        var li = std.mem.splitSequence(u8, content, "\n");
        while (li.next()) |line| {
            if (std.mem.startsWith(u8, line, "commit=")) {
                allocator.free(commit);
                commit = try allocator.dupe(u8, line[7..]);
            } else if (std.mem.startsWith(u8, line, "notes=")) {
                allocator.free(notes);
                notes = try allocator.dupe(u8, line[6..]);
            } else if (std.mem.startsWith(u8, line, "shard=")) {
                try shard_list.append(allocator, try allocator.dupe(u8, line[6..]));
            }
        }

        var shards_str: std.ArrayList(u8) = .empty;
        defer shards_str.deinit(allocator);
        for (shard_list.items, 0..) |s, i| {
            if (i > 0) try shards_str.appendSlice(allocator, ", ");
            const colon = std.mem.lastIndexOf(u8, s, "_") orelse 0;
            try shards_str.appendSlice(allocator, s[colon + 1 ..]);
        }

        std.debug.print("   {s:<12} [{s}]{s}{s}\n", .{ commit[0..@min(8, commit.len)], shards_str.items, if (notes.len > 0) "  " else "", if (notes.len > 0) notes else "" });
        total += 1;
    }

    if (total == 0) {
        std.debug.print("   No assignments recorded.\n\n", .{});
    } else {
        std.debug.print("\n   {d} training run(s) tracked\n\n", .{total});
    }
}

pub fn datasetImpact(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    dataset_name: []const u8,
    shard_index: usize,
) !void {
    const assign_dir_path = try assignDir(allocator, repo, dataset_name);
    defer allocator.free(assign_dir_path);

    const target_shard = try std.fmt.allocPrint(allocator, "{s}:shard_{d}", .{ dataset_name, shard_index });
    defer allocator.free(target_shard);

    std.debug.print("💥 Impact Analysis: shard {d} of '{s}'\n\n", .{ shard_index, dataset_name });
    std.debug.print("   Question: if shard_{d} is corrupt/poisoned, which models are affected?\n\n", .{shard_index});

    var dir = std.Io.Dir.cwd().openDir(io, assign_dir_path, .{ .iterate = true }) catch {
        std.debug.print("   No assignments found for dataset '{s}'.\n\n", .{dataset_name});
        return;
    };
    defer dir.close(io);

    var affected: usize = 0;
    var total: usize = 0;

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        total += 1;
        const path = try std.fs.path.join(allocator, &.{ assign_dir_path, entry.name });
        defer allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(content);

        var commit: []u8 = try allocator.dupe(u8, "");
        var found_shard = false;
        defer allocator.free(commit);

        var li = std.mem.splitSequence(u8, content, "\n");
        while (li.next()) |line| {
            if (std.mem.startsWith(u8, line, "commit=")) {
                allocator.free(commit);
                commit = try allocator.dupe(u8, line[7..]);
            } else if (std.mem.startsWith(u8, line, "shard=") and
                std.mem.eql(u8, line[6..], target_shard))
            {
                found_shard = true;
            }
        }

        if (found_shard) {
            affected += 1;
            std.debug.print("   ❌ AFFECTED  commit {s}\n", .{commit[0..@min(8, commit.len)]});
        } else {
            std.debug.print("   ✅ CLEAN     commit {s}\n", .{commit[0..@min(8, commit.len)]});
        }
    }

    std.debug.print("\n   {d}/{d} training runs are affected by shard_{d}\n\n", .{ affected, total, shard_index });

    if (affected > 0) {
        std.debug.print("   ⚠️  Recommended actions:\n", .{});
        std.debug.print("   1. Inspect shard_{d} for corruption or data poisoning\n", .{shard_index});
        std.debug.print("   2. Retrain affected models without shard_{d}\n", .{shard_index});
        std.debug.print("   3. Use 'zev reproduce <commit>' to reproduce clean runs\n\n", .{});
    }
}

pub fn datasetList(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository) !void {
    const dir_path = try datasetDir(allocator, repo);
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        std.debug.print("No datasets registered yet.\n", .{});
        std.debug.print("Register: zev dataset register <path> --name <name>\n", .{});
        return;
    };
    defer dir.close(io);

    std.debug.print("📂 Registered Datasets:\n\n", .{});
    var count: usize = 0;

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const meta_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name, "dataset.meta" });
        defer allocator.free(meta_path);
        const ds = (try loadDatasetRecord(allocator, meta_path)) orelse continue;
        count += 1;

        std.debug.print("  📂 {s}\n", .{ds.name});
        std.debug.print("     Source:  {s}\n", .{ds.source_path});
        std.debug.print("     Format:  {s}   Size: {d} KB\n", .{ ds.format, ds.total_bytes / 1024 });
        if (ds.total_rows > 0)
            std.debug.print("     Rows:    {d}\n", .{ds.total_rows});
        if (ds.total_shards > 0)
            std.debug.print("     Shards:  {d} ({s})\n", .{ ds.total_shards, ds.strategy });
        std.debug.print("     CID:     {s}\n\n", .{ds.source_cid[0..@min(16, ds.source_cid.len)]});
    }

    if (count == 0) {
        std.debug.print("  No datasets yet.\n\n", .{});
        std.debug.print("  zev dataset register ./data.csv --name mydata\n\n", .{});
    } else {
        std.debug.print("  Total: {d} dataset(s)\n\n", .{count});
    }
}

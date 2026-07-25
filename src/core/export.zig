const std = @import("std");
const Repository = @import("repository.zig").Repository;
const cid_mod = @import("cid.zig");
const commit_mod = @import("commit.zig");

pub const FileEntry = struct { abs: []u8, rel: []u8 };

const MAGIC = "ZEV-ARCHIVE-V1";

const ManifestEntry = struct {
    path: []const u8,
    size: u64,
    checksum: []const u8,
};

fn readFileSafe(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound or err == error.IsDir) return null;
        return err;
    };
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

fn computeChecksum(allocator: std.mem.Allocator,
    io: std.Io, data: []const u8) ![]u8 {
    const c = cid_mod.CID.fromBytes(io, data);
    return try c.toString(allocator);
}

fn collectDir(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    rel_prefix: []const u8,
    files: *std.ArrayList(FileEntry),
) !void {
    var dir = std.Io.Dir.cwd().openDir(base_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        const abs = try std.fs.path.join(allocator, &.{ base_path, entry.name });
        const rel = if (rel_prefix.len > 0)
            try std.fs.path.join(allocator, &.{ rel_prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        if (entry.kind == .directory) {
            try collectDir(allocator, abs, rel, files);
            allocator.free(abs);
            allocator.free(rel);
        } else if (entry.kind == .file) {
            try files.append(allocator, FileEntry{ .abs = abs, .rel = rel });
        } else {
            allocator.free(abs);
            allocator.free(rel);
        }
    }
}

pub fn exportRepo(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: *Repository,
    output_path: []const u8,
    snapshot_filter: ?[]const u8,
    since_hash: ?[]const u8,
    include_objects: bool,
) !void {
    const now = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);

    std.debug.print("📦 Exporting repository...\n\n", .{});

    var files: std.ArrayList(FileEntry) = .empty;
    defer {
        for (files.items) |f| {
            allocator.free(f.abs);
            allocator.free(f.rel);
        }
        files.deinit(allocator);
    }

    const zev_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev" });
    defer allocator.free(zev_path);

    const meta_dirs = [_][]const u8{
        "metrics",       "experiments", "lineage", "snapshots",
        "notarizations", "reproduce",   "capture", "refs",
        "drift_history",
    };

    for (meta_dirs) |d| {
        const dir_path = try std.fs.path.join(allocator, &.{ zev_path, d });
        defer allocator.free(dir_path);
        try collectDir(allocator, dir_path, d, &files);
    }

    const config_files = [_][]const u8{
        "config", "HEAD", "run_command", "drift_config", "peer_state", "peers",
    };
    for (config_files) |cf| {
        const abs = try std.fs.path.join(allocator, &.{ zev_path, cf });
        if (std.Io.Dir.cwd().access(abs, .{}) catch null == null or
            std.Io.Dir.cwd().access(abs, .{}) catch unreachable == {})
        {
            _ = std.Io.Dir.cwd().statFile(abs) catch {
                allocator.free(abs);
                continue;
            };
        }
        const rel = try allocator.dupe(u8, cf);
        try files.append(allocator, FileEntry{ .abs = abs, .rel = rel });
    }

    if (include_objects) {
        const obj_path = try std.fs.path.join(allocator, &.{ zev_path, "objects" });
        defer allocator.free(obj_path);

        if (since_hash) |_| {
            std.debug.print("   ℹ️  --since filter: including all objects (full graph walk)\n", .{});
            try collectDir(allocator, obj_path, "objects", &files);
        } else {
            try collectDir(allocator, obj_path, "objects", &files);
        }
    }

    var filtered_files: std.ArrayList(FileEntry) = .empty;
    defer filtered_files.deinit(allocator);

    if (snapshot_filter) |snap_name| {
        std.debug.print("   Filter: snapshot '{s}'\n", .{snap_name});
        var snap_cid: ?[]u8 = null;
        defer if (snap_cid) |s| allocator.free(s);

        const snap_dir = try std.fs.path.join(allocator, &.{ zev_path, "snapshots" });
        defer allocator.free(snap_dir);
        var sd = std.Io.Dir.cwd().openDir(snap_dir, .{ .iterate = true }) catch {
            std.debug.print("   No snapshots found\n", .{});
            return;
        };
        defer sd.close();
        var sit = sd.iterate();
        while (try sit.next()) |entry| {
            if (entry.kind != .file or std.mem.endsWith(u8, entry.name, ".name")) continue;
            const sp = try std.fs.path.join(allocator, &.{ snap_dir, entry.name });
            defer allocator.free(sp);
            const sc = std.Io.Dir.cwd().readFileAlloc(io, sp, allocator, .limited(64 * 1024)) catch continue;
            defer allocator.free(sc);
            var li = std.mem.splitSequence(u8, sc, "\n");
            while (li.next()) |line| {
                if (std.mem.startsWith(u8, line, "name=") and std.mem.eql(u8, line[5..], snap_name)) {
                    snap_cid = try allocator.dupe(u8, entry.name);
                    break;
                }
            }
            if (snap_cid != null) break;
        }

        for (files.items) |fi| {
            const include = snap_cid != null and ((std.mem.startsWith(u8, fi.rel, "snapshots") and
                std.mem.indexOf(u8, fi.rel, snap_cid.?) != null) or
                std.mem.startsWith(u8, fi.rel, "refs") or
                std.mem.eql(u8, fi.rel, "config") or
                std.mem.eql(u8, fi.rel, "HEAD"));
            if (include) try filtered_files.append(allocator, fi);
        }
        std.debug.print("   Included {d} snapshot-specific files\n", .{filtered_files.items.len});
    }

    const export_files: []FileEntry = if (snapshot_filter != null) filtered_files.items else files.items;

    std.debug.print("   Writing {d} file(s) to {s}\n\n", .{ export_files.len, output_path });

    const out_f = try std.Io.Dir.cwd().createFile(output_path, .{});
    defer out_f.close();

    var manifest_hash: std.ArrayList(u8) = .empty;
    defer manifest_hash.deinit(allocator);

    {
        const header = try std.fmt.allocPrint(allocator, "{s}\ncreated={d}\nrepo={s}\nfiles={d}\n---\n", .{ MAGIC, now, repo.path, export_files.len });
        defer allocator.free(header);
        try out_f.writeAll(header);
    }

    var total_bytes: u64 = 0;
    var written_files: usize = 0;

    for (export_files) |fi| {
        const content = (try readFileSafe(allocator, fi.abs)) orelse continue;
        defer allocator.free(content);

        const checksum = try computeChecksum(allocator, io, content);
        defer allocator.free(checksum);

        const file_hdr = try std.fmt.allocPrint(allocator, "FILE {s} {d} {s}\n", .{ fi.rel, content.len, checksum });
        defer allocator.free(file_hdr);
        try out_f.writeAll(file_hdr);
        try out_f.writeAll(content);
        try out_f.writeAll("\n");

        try manifest_hash.appendSlice(allocator, checksum);
        try manifest_hash.append(allocator, '\n');

        total_bytes += content.len;
        written_files += 1;
    }

    const manifest_cid = cid_mod.CID.fromBytes(io, manifest_hash.items);
    const manifest_str = try manifest_cid.toString(allocator);
    defer allocator.free(manifest_str);

    const footer = try std.fmt.allocPrint(allocator, "MANIFEST\n{s}\nEND\n", .{manifest_str});
    defer allocator.free(footer);
    try out_f.writeAll(footer);

    const kb = total_bytes / 1024;
    std.debug.print("✅ Export complete!\n\n", .{});
    std.debug.print("   Archive:  {s}\n", .{output_path});
    std.debug.print("   Files:    {d}\n", .{written_files});
    std.debug.print("   Size:     {d} KB\n", .{kb});
    std.debug.print("   Manifest: {s}\n\n", .{manifest_str[0..16]});
    std.debug.print("   Restore on any machine:\n", .{});
    std.debug.print("   zev import {s}\n\n", .{output_path});
}

pub fn importArchive(
    allocator: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,
    target_dir: []const u8,
    dry_run: bool,
) !void {
    std.debug.print("📥 Importing archive: {s}\n\n", .{archive_path});

    const content = std.Io.Dir.cwd().readFileAlloc(io, archive_path, allocator, .limited(512 * 1024 * 1024)) catch |err| {
        std.debug.print("❌ Cannot read archive: {}\n", .{err});
        return;
    };
    defer allocator.free(content);

    if (!std.mem.startsWith(u8, content, MAGIC)) {
        std.debug.print("❌ Not a valid zev archive (bad magic)\n", .{});
        return;
    }

    var pos: usize = 0;
    var file_count: usize = 0;
    var created: i64 = 0;
    var src_repo: []const u8 = "";

    while (pos < content.len) {
        const nl = std.mem.indexOf(u8, content[pos..], "\n") orelse break;
        const line = content[pos .. pos + nl];
        pos += nl + 1;
        if (std.mem.eql(u8, line, "---")) break;
        if (std.mem.startsWith(u8, line, "files="))
            file_count = std.fmt.parseInt(usize, line[6..], 10) catch 0;
        if (std.mem.startsWith(u8, line, "created="))
            created = std.fmt.parseInt(i64, line[8..], 10) catch 0;
        if (std.mem.startsWith(u8, line, "repo="))
            src_repo = line[5..];
    }

    std.debug.print("   Archive info:\n", .{});
    std.debug.print("   Created:   t={d}\n", .{created});
    std.debug.print("   Source:    {s}\n", .{src_repo});
    std.debug.print("   Files:     {d}\n\n", .{file_count});

    if (dry_run) {
        std.debug.print("   🔍 Dry run — files that would be restored:\n\n", .{});
    }

    const zev_target = try std.fs.path.join(allocator, &.{ target_dir, ".zev" });
    defer allocator.free(zev_target);

    if (!dry_run) {
        const subdirs = [_][]const u8{
            "objects",   "refs/heads",    "metrics",   "experiments", "lineage",
            "snapshots", "notarizations", "reproduce", "capture",     "drift_history",
        };
        for (subdirs) |sub| {
            const p = try std.fs.path.join(allocator, &.{ zev_target, sub });
            defer allocator.free(p);
            try std.Io.Dir.cwd().makePath(p);
        }
    }

    var restored: usize = 0;
    var skipped: usize = 0;
    var manifest_acc: std.ArrayList(u8) = .empty;
    defer manifest_acc.deinit(allocator);

    while (pos < content.len) {
        const nl = std.mem.indexOf(u8, content[pos..], "\n") orelse break;
        const line = content[pos .. pos + nl];
        pos += nl + 1;

        if (std.mem.eql(u8, line, "MANIFEST")) {
            const mnl = std.mem.indexOf(u8, content[pos..], "\n") orelse break;
            const stored_manifest = content[pos .. pos + mnl];
            pos += mnl + 1;

            const computed = cid_mod.CID.fromBytes(io, manifest_acc.items);
            const computed_str = try computed.toString(allocator);
            defer allocator.free(computed_str);

            if (std.mem.eql(u8, stored_manifest, computed_str)) {
                std.debug.print("\n   ✅ Manifest verified — archive integrity confirmed\n", .{});
            } else {
                std.debug.print("\n   ⚠️  Manifest mismatch — archive may be corrupted\n", .{});
                std.debug.print("   Expected: {s}\n", .{stored_manifest[0..@min(16, stored_manifest.len)]});
                std.debug.print("   Got:      {s}\n", .{computed_str[0..@min(16, computed_str.len)]});
            }
            break;
        }

        if (!std.mem.startsWith(u8, line, "FILE ")) continue;

        var parts = std.mem.splitSequence(u8, line[5..], " ");
        const rel_path = parts.next() orelse continue;
        const size_str = parts.next() orelse continue;
        const checksum = parts.next() orelse continue;
        const size = std.fmt.parseInt(usize, size_str, 10) catch continue;

        if (pos + size > content.len) {
            std.debug.print("   ❌ Truncated archive at {s}\n", .{rel_path});
            break;
        }
        const file_content = content[pos .. pos + size];
        pos += size + 1;

        try manifest_acc.appendSlice(allocator, checksum);
        try manifest_acc.append(allocator, '\n');

        const actual_checksum = try computeChecksum(allocator, io, file_content);
        defer allocator.free(actual_checksum);
        const valid = std.mem.eql(u8, actual_checksum, checksum);

        if (dry_run) {
            const valid_str: []const u8 = if (valid) "✅" else "❌";
            std.debug.print("   {s} {s} ({d}B)\n", .{ valid_str, rel_path, size });
            restored += 1;
            continue;
        }

        if (!valid) {
            std.debug.print("   ⚠️  Checksum mismatch: {s} — skipping\n", .{rel_path});
            skipped += 1;
            continue;
        }

        const out_path = try std.fs.path.join(allocator, &.{ zev_target, rel_path });
        defer allocator.free(out_path);

        const parent = std.fs.path.dirname(out_path) orelse out_path;
        std.Io.Dir.cwd().makePath(parent) catch {};

        const existing = readFileSafe(allocator, out_path) catch null;
        if (existing) |ex| {
            defer allocator.free(ex);
            if (std.mem.eql(u8, ex, file_content)) {
                skipped += 1;
                continue;
            }
        }

        const wf = std.Io.Dir.cwd().createFile(out_path, .{}) catch |err| {
            std.debug.print("   ⚠️  Cannot write {s}: {}\n", .{ rel_path, err });
            skipped += 1;
            continue;
        };
        defer wf.close();
        try wf.writeAll(file_content);
        std.debug.print("   ✅ {s}\n", .{rel_path});
        restored += 1;
    }

    if (!dry_run) {
        const head_path = try std.fs.path.join(allocator, &.{ zev_target, "HEAD" });
        defer allocator.free(head_path);
        std.Io.Dir.cwd().access(head_path, .{}) catch {
            const hf = try std.Io.Dir.cwd().createFile(head_path, .{});
            defer hf.close();
            try hf.writeAll("ref: refs/heads/main\n");
        };

        std.debug.print("\n✅ Import complete!\n\n", .{});
        std.debug.print("   Restored: {d} file(s)\n", .{restored});
        std.debug.print("   Skipped:  {d} (already present or invalid)\n\n", .{skipped});
        std.debug.print("   Next steps:\n", .{});
        std.debug.print("   cd {s}\n", .{target_dir});
        std.debug.print("   zev log\n", .{});
        std.debug.print("   zev snapshot list\n", .{});
        std.debug.print("   zev lineage list\n\n", .{});
    } else {
        std.debug.print("\n   Would restore {d} file(s)\n", .{restored});
        std.debug.print("   Run without --dry-run to restore\n\n", .{});
    }
}

pub fn archiveInfo(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8) !void {
    const content = std.Io.Dir.cwd().readFileAlloc(io, archive_path, allocator, .limited(512 * 1024 * 1024)) catch |err| {
        std.debug.print("❌ Cannot read archive: {}\n", .{err});
        return;
    };
    defer allocator.free(content);

    if (!std.mem.startsWith(u8, content, MAGIC)) {
        std.debug.print("❌ Not a valid zev archive\n", .{});
        return;
    }

    std.debug.print("🗂️  Archive: {s}\n\n", .{archive_path});

    var pos: usize = 0;
    var file_count: usize = 0;
    var created: i64 = 0;
    var src_repo: []const u8 = "";

    while (pos < content.len) {
        const nl = std.mem.indexOf(u8, content[pos..], "\n") orelse break;
        const line = content[pos .. pos + nl];
        pos += nl + 1;
        if (std.mem.eql(u8, line, "---")) break;
        if (std.mem.startsWith(u8, line, "files="))
            file_count = std.fmt.parseInt(usize, line[6..], 10) catch 0;
        if (std.mem.startsWith(u8, line, "created="))
            created = std.fmt.parseInt(i64, line[8..], 10) catch 0;
        if (std.mem.startsWith(u8, line, "repo="))
            src_repo = line[5..];
    }

    std.debug.print("   Created:  t={d}\n", .{created});
    std.debug.print("   Source:   {s}\n", .{src_repo});
    std.debug.print("   Files:    {d}\n\n", .{file_count});

    var counts = std.StringHashMap(usize).init(allocator);
    defer counts.deinit();
    var total_size: u64 = 0;

    while (pos < content.len) {
        const nl = std.mem.indexOf(u8, content[pos..], "\n") orelse break;
        const line = content[pos .. pos + nl];
        pos += nl + 1;
        if (std.mem.eql(u8, line, "MANIFEST")) break;
        if (!std.mem.startsWith(u8, line, "FILE ")) continue;

        var parts = std.mem.splitSequence(u8, line[5..], " ");
        const rel_path = parts.next() orelse continue;
        const size_str = parts.next() orelse continue;
        const size = std.fmt.parseInt(u64, size_str, 10) catch 0;
        total_size += size;
        pos += @intCast(size + 1);

        const category: []const u8 = if (std.mem.startsWith(u8, rel_path, "objects")) "objects" else if (std.mem.startsWith(u8, rel_path, "snapshots")) "snapshots" else if (std.mem.startsWith(u8, rel_path, "metrics")) "metrics" else if (std.mem.startsWith(u8, rel_path, "experiments")) "experiments" else if (std.mem.startsWith(u8, rel_path, "lineage")) "lineage" else if (std.mem.startsWith(u8, rel_path, "notarizations")) "notarizations" else if (std.mem.startsWith(u8, rel_path, "reproduce")) "reproduce" else "other";

        const entry = try counts.getOrPut(category);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    std.debug.print("   Contents:\n", .{});
    var cit = counts.iterator();
    while (cit.next()) |e| {
        std.debug.print("   {s:<20} {d} file(s)\n", .{ e.key_ptr.*, e.value_ptr.* });
    }
    std.debug.print("\n   Total size: {d} KB\n\n", .{total_size / 1024});
}

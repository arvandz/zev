const std = @import("std");
const repository = @import("repository.zig");
const cid = @import("cid.zig");
const commit = @import("commit.zig");
const IPFSClient = @import("ipfs.zig").IPFSClient;
const Repository = repository.Repository;
const shallow_mod = @import("shallow.zig");

pub const RemoteProtocol = enum {
    file,
    http,
    https,
    ssh,
    ipfs,

    pub fn fromUri(uri: []const u8) !RemoteProtocol {
        if (std.mem.startsWith(u8, uri, "file://")) return .file;
        if (std.mem.startsWith(u8, uri, "http://")) return .http;
        if (std.mem.startsWith(u8, uri, "https://")) return .https;
        if (std.mem.startsWith(u8, uri, "ssh://")) return .ssh;
        if (std.mem.startsWith(u8, uri, "ipfs://")) return .ipfs;

        if (std.mem.indexOf(u8, uri, "@") != null and std.mem.indexOf(u8, uri, ":") != null) {
            return .ssh;
        }

        if (std.mem.startsWith(u8, uri, "/")) return .file;

        return error.UnsupportedProtocol;
    }
};

pub const Remote = struct {
    name: []const u8,
    url: []const u8,
    protocol: RemoteProtocol,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, url: []const u8) !Remote {
        const protocol = try RemoteProtocol.fromUri(url);

        return Remote{
            .name = try allocator.dupe(u8, name),
            .url = try allocator.dupe(u8, url),
            .protocol = protocol,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Remote) void {
        self.allocator.free(self.name);
        self.allocator.free(self.url);
    }
};

pub fn addRemote(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, name: []const u8, url: []const u8) !void {
    const zev_path = try std.fs.path.join(allocator, &[_][]const u8{ repo.path, ".zev" });
    defer allocator.free(zev_path);

    const remotes_dir = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "remotes" });
    defer allocator.free(remotes_dir);

    try std.Io.Dir.cwd().createDirPath(io, remotes_dir);

    const remote_file_path = try std.fs.path.join(allocator, &[_][]const u8{ remotes_dir, name });
    defer allocator.free(remote_file_path);

    const remote_file = try std.Io.Dir.cwd().createFile(io, remote_file_path, .{});
    defer remote_file.close(io);
    var buffer: [512]u8 = undefined;
    var writer = remote_file.writer(io, &buffer);
    try writer.interface.writeAll(url);
    try writer.flush();
}

pub fn getRemote(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, name: []const u8) ![]const u8 {
    const zev_path = try std.fs.path.join(allocator, &[_][]const u8{ repo.path, ".zev" });
    defer allocator.free(zev_path);
    const remote_file_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "remotes", name });
    defer allocator.free(remote_file_path);
    const remote_file = try std.Io.Dir.cwd().openFile(io, remote_file_path, .{});
    defer remote_file.close(io);
    var read_buffer: [1024]u8 = undefined;
    var reader = remote_file.reader(io, &read_buffer);
    const bytes_read = try reader.interface.readSliceShort(&read_buffer);
    const url = std.mem.trim(u8, read_buffer[0..bytes_read], " \n\r\t");

    return try allocator.dupe(u8, url);
}

pub fn removeRemote(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, name: []const u8) !void {
    const zev_path = try std.fs.path.join(allocator, &[_][]const u8{ repo.path, ".zev" });
    defer allocator.free(zev_path);

    const remote_file_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "remotes", name });
    defer allocator.free(remote_file_path);

    try std.Io.Dir.cwd().deleteFile(io, remote_file_path);
}

pub fn listRemotes(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository) !void {
    const zev_path = try std.fs.path.join(allocator, &[_][]const u8{ repo.path, ".zev" });
    defer allocator.free(zev_path);

    const remotes_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "remotes" });
    defer allocator.free(remotes_dir_path);

    var remotes_dir = std.Io.Dir.cwd().openDir(io, remotes_dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("No remotes configured\n", .{});
            return;
        }
        return err;
    };
    defer remotes_dir.close(io);

    var iterator = remotes_dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;

        const url = try getRemote(allocator, io, repo, entry.name);
        defer allocator.free(url);

        const protocol = RemoteProtocol.fromUri(url) catch .file;
        const protocol_icon = switch (protocol) {
            .file => "📁",
            .http, .https => "🌐",
            .ssh => "🔐",
            .ipfs => "🌐",
        };

        std.debug.print("{s} {s: <15} {s}\n", .{ protocol_icon, entry.name, url });
    }
}

pub fn push(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, remote_name: []const u8, branch_name: []const u8) !void {
    const remote_url = try getRemote(allocator, io, repo, remote_name);
    defer allocator.free(remote_url);

    const protocol = try RemoteProtocol.fromUri(remote_url);

    std.debug.print("📤 Pushing to {s} ({s})\n", .{ remote_name, remote_url });

    switch (protocol) {
        .file => try pushFile(allocator, io, repo, remote_url, branch_name),
        .http, .https => try pushHTTP(allocator, remote_url, branch_name),
        .ssh => try pushSSH(allocator, remote_url, branch_name),
        .ipfs => try pushIPFS(allocator, repo, remote_name, branch_name),
    }
}

pub fn pull(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, remote_name: []const u8, branch_name: []const u8) !void {
    const remote_url = try getRemote(allocator, io, repo, remote_name);
    defer allocator.free(remote_url);

    const protocol = try RemoteProtocol.fromUri(remote_url);

    std.debug.print("📥 Pulling from {s} ({s})\n", .{ remote_name, remote_url });

    switch (protocol) {
        .file => try pullFile(allocator, io, repo, remote_url, branch_name),
        .http, .https => try pullHTTP(allocator, repo, remote_url, branch_name),
        .ssh => try pullSSH(allocator, repo, remote_url, branch_name),
        .ipfs => try pullIPFS(allocator, repo, remote_url, branch_name),
    }
}

pub fn cloneWithDepth(allocator: std.mem.Allocator, io: std.Io, url: []const u8, dest_path: []const u8, depth: usize) !void {
    const protocol = try RemoteProtocol.fromUri(url);
    std.debug.print("📦 Cloning from {s} into {s} (depth={})\n", .{ url, dest_path, depth });
    switch (protocol) {
        .file => try cloneFileShallow(allocator, io, url, dest_path, depth),
        .http, .https => try cloneHTTP(allocator, url, dest_path),
        .ssh => try cloneSSH(allocator, url, dest_path),
        .ipfs => try cloneIPFS(allocator, io, url, dest_path),
    }
}

pub fn clone(allocator: std.mem.Allocator, io: std.Io, url: []const u8, dest_path: []const u8) !void {
    const protocol = try RemoteProtocol.fromUri(url);
    std.debug.print("📦 Cloning from {s} into {s}\n", .{ url, dest_path });
    switch (protocol) {
        .file => try cloneFile(allocator, io, url, dest_path),
        .http, .https => try cloneHTTP(allocator, url, dest_path),
        .ssh => try cloneSSH(allocator, url, dest_path),
        .ipfs => try cloneIPFS(allocator, io, url, dest_path),
    }
}

fn pushFile(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, remote_url: []const u8, branch_name: []const u8) !void {
    const remote_path = if (std.mem.startsWith(u8, remote_url, "file://"))
        remote_url[7..]
    else
        remote_url;

    if (!Repository.exists(allocator, remote_path)) {
        return error.RemoteNotFound;
    }

    var remote_repo = try Repository.open(allocator, remote_path);
    defer remote_repo.deinit();

    const zev_path = try std.fs.path.join(allocator, &[_][]const u8{ repo.path, ".zev" });
    defer allocator.free(zev_path);

    const branch_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "refs", "heads", branch_name });
    defer allocator.free(branch_path);

    const branch_file = try std.Io.Dir.cwd().openFile(branch_path, .{});
    defer branch_file.close(io);

    var buffer: [256]u8 = undefined;
    var branch_file_scratch: [4096]u8 = undefined;
    var branch_file_reader = branch_file.reader(io, &branch_file_scratch);
    const bytes_read = try branch_file_reader.interface.readSliceShort(&buffer);
    const commit_hash = std.mem.trim(u8, buffer[0..bytes_read], " \n\r\t");

    var hash: [32]u8 = undefined;
    for (0..32) |i| {
        const high = try std.fmt.charToDigit(commit_hash[i * 2], 16);
        const low = try std.fmt.charToDigit(commit_hash[i * 2 + 1], 16);
        hash[i] = (high << 4) | low;
    }
    const head_cid = cid.CID{ .hash = hash };

    try copyCommitHistory(allocator, repo, &remote_repo, head_cid);

    const remote_branch_path = try std.fs.path.join(allocator, &[_][]const u8{ remote_path, ".zev", "refs", "heads", branch_name });
    defer allocator.free(remote_branch_path);

    const remote_branch_file = try std.Io.Dir.cwd().createFile(remote_branch_path, .{});
    defer remote_branch_file.close(io);

    try remote_branch_file.writeAll(commit_hash);

    std.debug.print("✅ Pushed {s} to {s}\n", .{ branch_name, remote_path });
}

fn pullFile(allocator: std.mem.Allocator,
    io: std.Io, repo: *Repository, remote_url: []const u8, branch_name: []const u8) !void {
    const remote_path = if (std.mem.startsWith(u8, remote_url, "file://"))
        remote_url[7..]
    else
        remote_url;

    if (!Repository.exists(allocator, remote_path)) {
        return error.RemoteNotFound;
    }

    var remote_repo = try Repository.open(allocator, remote_path);
    defer remote_repo.deinit();

    const remote_branch_path = try std.fs.path.join(allocator, &[_][]const u8{ remote_path, ".zev", "refs", "heads", branch_name });
    defer allocator.free(remote_branch_path);

    const remote_branch_file = try std.Io.Dir.cwd().openFile(remote_branch_path, .{});
    defer remote_branch_file.close(io);

    var buffer: [256]u8 = undefined;
    var remote_branch_file_scratch: [4096]u8 = undefined;
    var remote_branch_file_reader = remote_branch_file.reader(io, &remote_branch_file_scratch);
    const bytes_read = try remote_branch_file_reader.interface.readSliceShort(&buffer);
    const commit_hash = std.mem.trim(u8, buffer[0..bytes_read], " \n\r\t");

    var hash: [32]u8 = undefined;
    for (0..32) |i| {
        const high = try std.fmt.charToDigit(commit_hash[i * 2], 16);
        const low = try std.fmt.charToDigit(commit_hash[i * 2 + 1], 16);
        hash[i] = (high << 4) | low;
    }
    const remote_head = cid.CID{ .hash = hash };

    try copyCommitHistory(allocator, &remote_repo, repo, remote_head);

    const zev_path = try std.fs.path.join(allocator, &[_][]const u8{ repo.path, ".zev" });
    defer allocator.free(zev_path);

    const local_branch_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "refs", "heads", branch_name });
    defer allocator.free(local_branch_path);

    const local_branch_file = try std.Io.Dir.cwd().createFile(local_branch_path, .{});
    defer local_branch_file.close(io);

    try local_branch_file.writeAll(commit_hash);

    std.debug.print("✅ Pulled {s} successfully\n", .{branch_name});
}

fn cloneFileShallow(allocator: std.mem.Allocator, io: std.Io, url: []const u8, dest_path: []const u8, depth: usize) !void {
    const source_path = if (std.mem.startsWith(u8, url, "file://")) url[7..] else url;
    if (!Repository.exists(allocator, io, source_path)) return error.RemoteNotFound;
    var dest_repo = try Repository.init(allocator, io, dest_path, false);
    defer dest_repo.deinit();
    try addRemote(allocator, io, &dest_repo, "origin", url);
    var source_repo = try Repository.open(allocator, io, source_path);
    defer source_repo.deinit();

    const source_head = source_repo.getHeadCommit(io) catch {
        std.debug.print("⚠️  Remote has no commits\n", .{});
        return;
    };

    std.debug.print("📥 Copying last {} commit(s)...\n", .{depth});
    try shallow_mod.shallowCopy(allocator, io, &source_repo, &dest_repo, source_head, depth);

    const zev_path = try std.fs.path.join(allocator, &.{ dest_path, ".zev" });
    defer allocator.free(zev_path);
    const main_path = try std.fs.path.join(allocator, &.{ zev_path, "refs", "heads", "main" });
    defer allocator.free(main_path);
    const heads_dir = try std.fs.path.join(allocator, &.{ zev_path, "refs", "heads" });
    defer allocator.free(heads_dir);
    try std.Io.Dir.cwd().createDirPath(io, heads_dir);
    const main_file = try std.Io.Dir.cwd().createFile(io, main_path, .{});
    defer main_file.close(io);
    const head_str = try source_head.toString(allocator);
    defer allocator.free(head_str);
    var main_buffer: [128]u8 = undefined;
    var main_writer = main_file.writer(io, &main_buffer);
    try main_writer.interface.writeAll(head_str);
    try main_writer.flush();
    const checkout_mod = @import("checkout.zig");
    checkout_mod.checkoutCommit(allocator, io, &dest_repo, source_head) catch |err| {
        std.debug.print("⚠️  Warning: Could not checkout files: {}\n", .{err});
    };

    std.debug.print("✅ Shallow clone complete (depth={})\n", .{depth});
    if (shallow_mod.isShallow(io, allocator, dest_path)) {
        std.debug.print("⚠️  This is a shallow clone - history is limited\n", .{});
    }
}

fn cloneFile(allocator: std.mem.Allocator, io: std.Io, url: []const u8, dest_path: []const u8) !void {
    const source_path = if (std.mem.startsWith(u8, url, "file://"))
        url[7..]
    else
        url;

    if (!Repository.exists(allocator, io, source_path)) {
        return error.RemoteNotFound;
    }

    var dest_repo = try Repository.init(allocator, io, dest_path, false);
    defer dest_repo.deinit();

    try addRemote(allocator, io, &dest_repo, "origin", url);

    var source_repo = try Repository.open(allocator, io, source_path);
    defer source_repo.deinit();

    const source_head = source_repo.getHeadCommit(io) catch {
        std.debug.print("⚠️  Remote repository has no commits\n", .{});
        return;
    };
    try copyCommitHistory(allocator, io, &source_repo, &dest_repo, source_head);
    const zev_path = try std.fs.path.join(allocator, &[_][]const u8{ dest_path, ".zev" });
    defer allocator.free(zev_path);
    const heads_dir = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "refs", "heads" });
    defer allocator.free(heads_dir);
    try std.Io.Dir.cwd().createDirPath(io, heads_dir);
    const main_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "refs", "heads", "main" });
    defer allocator.free(main_path);
    const main_file = try std.Io.Dir.cwd().createFile(io, main_path, .{});
    defer main_file.close(io);
    const head_str = try source_head.toString(allocator);
    defer allocator.free(head_str);
    var buffer: [128]u8 = undefined;
    var writer = main_file.writer(io, &buffer);
    try writer.interface.writeAll(head_str);
    try writer.flush();
    const checkout_mod = @import("checkout.zig");
    std.debug.print("📂 Checking out files...\n", .{});
    checkout_mod.checkoutCommit(allocator, io, &dest_repo, source_head) catch |err| {
        std.debug.print("⚠️  Warning: Could not checkout files: {}\n", .{err});
    };
    std.debug.print("✅ Cloned successfully\n", .{});
}

fn pushHTTP(allocator: std.mem.Allocator, remote_url: []const u8, branch_name: []const u8) !void {
    _ = allocator;
    _ = branch_name;

    std.debug.print("❌ HTTP/HTTPS push not yet implemented\n", .{});
    std.debug.print("💡 Remote URL: {s}\n", .{remote_url});
    return error.NotImplemented;
}

fn pullHTTP(allocator: std.mem.Allocator, repo: *Repository, remote_url: []const u8, branch_name: []const u8) !void {
    _ = allocator;
    _ = repo;
    _ = branch_name;

    std.debug.print("❌ HTTP/HTTPS pull not yet implemented\n", .{});
    std.debug.print("💡 Remote URL: {s}\n", .{remote_url});
    return error.NotImplemented;
}

fn cloneHTTP(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    _ = allocator;
    _ = dest_path;

    std.debug.print("❌ HTTP/HTTPS cloning not yet implemented\n", .{});
    std.debug.print("💡 URL: {s}\n", .{url});
    std.debug.print("💡 For now, use file:// for local repos or ipfs:// for IPFS\n", .{});
    return error.NotImplemented;
}

fn pushSSH(allocator: std.mem.Allocator, remote_url: []const u8, branch_name: []const u8) !void {
    _ = allocator;
    _ = branch_name;

    std.debug.print("❌ SSH push not yet implemented\n", .{});
    std.debug.print("💡 Remote URL: {s}\n", .{remote_url});
    return error.NotImplemented;
}

fn pullSSH(allocator: std.mem.Allocator, repo: *Repository, remote_url: []const u8, branch_name: []const u8) !void {
    _ = allocator;
    _ = repo;
    _ = branch_name;

    std.debug.print("❌ SSH pull not yet implemented\n", .{});
    std.debug.print("💡 Remote URL: {s}\n", .{remote_url});
    return error.NotImplemented;
}

fn cloneSSH(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    _ = allocator;
    _ = dest_path;

    std.debug.print("❌ SSH cloning not yet implemented\n", .{});
    std.debug.print("💡 URL: {s}\n", .{url});
    std.debug.print("💡 For now, use file:// for local repos or ipfs:// for IPFS\n", .{});
    return error.NotImplemented;
}

fn pushIPFS(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, remote_name: []const u8, branch_name: []const u8) !void {
    _ = remote_name;
    _ = branch_name;

    std.debug.print("📦 Pushing to IPFS with full object history...\n", .{});

    const ipfs_repo = @import("ipfs_repo.zig");

    const metadata_json = try ipfs_repo.IPFSRepo.packWithObjects(allocator, io, repo);
    defer allocator.free(metadata_json);

    std.debug.print("📄 Packed repository metadata and objects ({} bytes)\n", .{metadata_json.len});

    var ipfs_client = IPFSClient.init(allocator, "http://127.0.0.1:5001");
    const metadata_cid = try ipfs_client.add(io, metadata_json);
    defer allocator.free(metadata_cid);

    std.debug.print("✅ Repository pushed to IPFS!\n", .{});
    std.debug.print("🔗 Repository CID: {s}\n", .{metadata_cid});
    std.debug.print("\n💡 To clone this repository:\n", .{});
    std.debug.print("   zev clone ipfs://{s} <directory>\n", .{metadata_cid});
    std.debug.print("\n🌐 View on IPFS gateway:\n", .{});
    std.debug.print("   https://ipfs.io/ipfs/{s}\n", .{metadata_cid});
}

fn pullIPFS(allocator: std.mem.Allocator, io: std.Io, repo: *Repository, remote_url: []const u8, branch_name: []const u8) !void {
    _ = branch_name;

    const ipfs_cid = if (std.mem.startsWith(u8, remote_url, "ipfs://"))
        remote_url[7..]
    else
        remote_url;

    std.debug.print("📥 Pulling from IPFS: {s}\n", .{ipfs_cid});

    const ipfs_repo = @import("ipfs_repo.zig");

    var ipfs_client = IPFSClient.init(allocator, "http://127.0.0.1:5001");
    const metadata_json = try ipfs_client.cat(io, ipfs_cid);
    defer allocator.free(metadata_json);

    std.debug.print("📄 Retrieved repository metadata\n", .{});

    var metadata = try ipfs_repo.IPFSRepo.Metadata.fromJson(allocator, metadata_json);
    defer metadata.deinit();

    var it = metadata.refs.iterator();
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "refs/heads/")) {
            const ref_branch_name = entry.key_ptr.*[11..];
            const ref_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "heads", ref_branch_name });
            defer allocator.free(ref_path);

            if (std.fs.path.dirname(ref_path)) |parent_dir| {
                try std.Io.Dir.cwd().createDirPath(io, parent_dir);
            }

            const ref_file = try std.Io.Dir.cwd().createFile(io, ref_path, .{});
            defer ref_file.close(io);
            var ref_file_buffer: [512]u8 = undefined;
            var ref_file_writer = ref_file.writer(io, &ref_file_buffer);
            try ref_file_writer.interface.writeAll(entry.value_ptr.*);
            try ref_file_writer.flush();

            std.debug.print("✅ Updated ref: {s} -> {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    std.debug.print("✅ Pull completed successfully!\n", .{});
}

fn cloneIPFS(allocator: std.mem.Allocator, io: std.Io, url: []const u8, dest_path: []const u8) !void {
    const ipfs_cid = if (std.mem.startsWith(u8, url, "ipfs://"))
        url[7..]
    else
        url;

    std.debug.print("📥 Cloning from IPFS: {s}\n", .{ipfs_cid});
    std.debug.print("📂 Destination: {s}\n", .{dest_path});

    const ipfs_repo = @import("ipfs_repo.zig");

    try std.Io.Dir.cwd().createDirPath(io, dest_path);

    var ipfs_client = IPFSClient.init(allocator, "http://127.0.0.1:5001");
    const metadata_json = try ipfs_client.cat(io, ipfs_cid);
    defer allocator.free(metadata_json);

    std.debug.print("📄 Retrieved repository metadata ({} bytes)\n", .{metadata_json.len});

    try ipfs_repo.IPFSRepo.unpack(allocator, io, dest_path, metadata_json);

    var repo = try Repository.init(allocator, io, dest_path, false);
    defer repo.deinit();

    const checkout_mod = @import("checkout.zig");
    if (repo.getHeadCommit(io)) |commit_cid| {
        std.debug.print("\xf0\x9f\x93\x82 Checking out files...\n", .{});
        checkout_mod.checkoutCommit(allocator, io, &repo, commit_cid) catch |err| {
            std.debug.print("Warning: Could not checkout files: {}\n", .{err});
        };
    } else |_| {}

    std.debug.print("✅ Repository cloned successfully!\n", .{});
    std.debug.print("📂 Location: {s}\n", .{dest_path});

    const origin_url = try std.fmt.allocPrint(allocator, "ipfs://{s}", .{ipfs_cid});
    defer allocator.free(origin_url);
    try addRemote(allocator, io, &repo, "origin", origin_url);
}

fn copyCommitHistory(allocator: std.mem.Allocator, io: std.Io, from_repo: *Repository, to_repo: *Repository, head: cid.CID) !void {
    var visited = std.AutoHashMap([32]u8, void).init(allocator);
    defer visited.deinit();

    var to_process: std.ArrayList(cid.CID) = .empty;
    defer to_process.deinit(allocator);

    try to_process.append(allocator, head);

    while (to_process.items.len > 0) {
        const current = to_process.pop() orelse break;

        if (visited.contains(current.hash)) continue;
        try visited.put(current.hash, {});

        if (try to_repo.store.has(io, current)) continue;

        const data = try from_repo.store.get(io, current);
        defer allocator.free(data);

        _ = try to_repo.store.put(io, data);

        const commit_obj = commit.Commit.deserialize(allocator, data) catch continue;
        defer allocator.free(commit_obj.author);
        defer allocator.free(commit_obj.message);

        if (commit_obj.parent_cid) |parent| {
            try to_process.append(allocator, parent);
        }

        try to_process.append(allocator, commit_obj.tree_cid);
    }
}

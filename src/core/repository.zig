const std = @import("std");
const blob = @import("blob.zig");
const tree = @import("tree.zig");
const commit = @import("commit.zig");
const cid = @import("cid.zig");
const index = @import("index.zig");
const config_mod = @import("config.zig");
const storage_mod = @import("storage.zig");

pub const Repository = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    store: blob.BlobStore,
    index: index.Index,
    config: ?config_mod.Config,
    storage: ?storage_mod.StorageManager,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8, use_ipfs: bool) !Repository {
        const zev_path = try std.fs.path.join(allocator, &[_][]const u8{ path, ".zev" });
        defer allocator.free(zev_path);
        try std.Io.Dir.cwd().createDirPath(io, zev_path);
        const objects_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "objects" });
        defer allocator.free(objects_path);
        const refs_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "refs" });
        defer allocator.free(refs_path);
        const heads_path = try std.fs.path.join(allocator, &[_][]const u8{ refs_path, "heads" });
        defer allocator.free(heads_path);
        try std.Io.Dir.cwd().createDirPath(io, heads_path);
        const head_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "HEAD" });
        defer allocator.free(head_path);
        const head_file = try std.Io.Dir.cwd().createFile(io, head_path, .{});
        defer head_file.close(io);
        var head_buffer: [64]u8 = undefined;
        var head_writer = head_file.writer(io, &head_buffer);
        try head_writer.interface.writeAll("ref: refs/heads/main\n");
        try head_writer.flush();

        var repo_config = config_mod.Config.init(allocator);
        if (use_ipfs) {
            repo_config.storage_backend = .hybrid;
            repo_config.ipfs_enabled = true;
        }
        try repo_config.save(io, path);

        var storage_manager: ?storage_mod.StorageManager = null;
        if (use_ipfs) {
            const storage_config = storage_mod.StorageConfig{
                .backend = repo_config.storage_backend,
                .ipfs_enabled = repo_config.ipfs_enabled,
                .ipfs_url = repo_config.ipfs_url,
                .auto_pin = repo_config.ipfs_auto_pin,
            };
            storage_manager = try storage_mod.StorageManager.init(allocator, storage_config);
        }

        const store_path = try allocator.dupe(u8, objects_path);
        const index_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "index" });

        return Repository{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .store = try blob.BlobStore.init(allocator, io, store_path),
            .index = index.Index.init(allocator, index_path),
            .config = repo_config,
            .storage = storage_manager,
        };
    }

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Repository {
        const zev_path = try std.fs.path.join(allocator, &[_][]const u8{ path, ".zev" });
        defer allocator.free(zev_path);
        const objects_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "objects" });
        const index_path = try std.fs.path.join(allocator, &[_][]const u8{ zev_path, "index" });
        const repo_config = try config_mod.Config.load(allocator, io, path);

        var storage_manager: ?storage_mod.StorageManager = null;
        if (repo_config.ipfs_enabled) {
            const storage_config = storage_mod.StorageConfig{
                .backend = repo_config.storage_backend,
                .ipfs_enabled = repo_config.ipfs_enabled,
                .ipfs_url = repo_config.ipfs_url,
                .auto_pin = repo_config.ipfs_auto_pin,
            };
            storage_manager = try storage_mod.StorageManager.init(allocator, storage_config);
        }

        var repo = Repository{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .store = try blob.BlobStore.init(allocator, io, objects_path),
            .index = index.Index.init(allocator, index_path),
            .config = repo_config,
            .storage = storage_manager,
        };

        try repo.index.read(io);

        return repo;
    }

    pub fn exists(allocator: std.mem.Allocator, io: std.Io, path: []const u8) bool {
        const zev_path = std.fs.path.join(allocator, &[_][]const u8{ path, ".zev" }) catch return false;
        defer allocator.free(zev_path);
        std.Io.Dir.cwd().access(io, zev_path, .{}) catch return false;
        return true;
    }

    pub fn deinit(self: *Repository) void {
        self.allocator.free(self.path);
        self.allocator.free(self.store.store_path);
        self.allocator.free(self.index.index_path);
        self.index.deinit();
        if (self.config) |*cfg| cfg.deinit();
    }

    pub fn createCommit(self: *Repository, io: std.Io, author: []const u8, message: []const u8, file_tree: *tree.Tree) !cid.CID {
        var commit_tree = tree.Tree.init(self.allocator);
        defer commit_tree.deinit();

        for (self.index.entries.items) |entry| {
            const tree_entry = tree.FileEntry{
                .name = try self.allocator.dupe(u8, entry.path),
                .cid = entry.cid,
                .size = entry.size,
                .mode = entry.mode,
            };
            try commit_tree.entries.append(self.allocator, tree_entry);
        }

        const tree_data = try commit_tree.serialize();
        defer self.allocator.free(tree_data);

        const tree_cid = try self.store.put(io, tree_data);

        if (self.storage) |*storage| {
            const ipfs_tree_cid = try storage.storeObject(io, tree_data);
            defer self.allocator.free(ipfs_tree_cid);
            std.debug.print("🌲 Tree stored in IPFS: {s}\n", .{ipfs_tree_cid});
        }

        const parent_cid = self.getHeadCommit(io) catch null;

        const new_commit = commit.Commit.init(io, tree_cid, parent_cid, author, message);
        const commit_data = try new_commit.serialize(self.allocator);
        defer self.allocator.free(commit_data);

        const commit_cid = try self.store.put(io, commit_data);

        if (self.storage) |*storage| {
            const ipfs_commit_cid = try storage.storeObject(io, commit_data);
            defer self.allocator.free(ipfs_commit_cid);
            std.debug.print("📦 Commit stored in IPFS: {s}\n", .{ipfs_commit_cid});
        }

        try self.updateHead(io, commit_cid);

        _ = file_tree;
        return commit_cid;
    }

    pub fn getHeadCommit(self: *Repository, io: std.Io) !cid.CID {
        const zev_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.path, ".zev" });
        defer self.allocator.free(zev_path);
        const head_path = try std.fs.path.join(self.allocator, &[_][]const u8{ zev_path, "HEAD" });
        defer self.allocator.free(head_path);
        const head_file = try std.Io.Dir.cwd().openFile(io, head_path, .{});
        defer head_file.close(io);
        var read_buf: [256]u8 = undefined;
        var head_reader = head_file.reader(io, &read_buf);
        var buffer: [256]u8 = undefined;
        const bytes_read = try head_reader.interface.readSliceShort(&buffer);
        const head_content = std.mem.trim(u8, buffer[0..bytes_read], " \n\r\t");
        if (std.mem.startsWith(u8, head_content, "ref: ")) {
            const ref_path = head_content[5..];
            const full_ref_path = try std.fs.path.join(self.allocator, &[_][]const u8{ zev_path, ref_path });
            defer self.allocator.free(full_ref_path);
            const ref_file = try std.Io.Dir.cwd().openFile(io, full_ref_path, .{});
            defer ref_file.close(io);
            var ref_read_buf: [256]u8 = undefined;
            var ref_reader = ref_file.reader(io, &ref_read_buf);
            const ref_bytes = try ref_reader.interface.readSliceShort(&buffer);
            const commit_hash = std.mem.trim(u8, buffer[0..ref_bytes], " \n\r\t");

            var hash: [32]u8 = undefined;
            for (0..32) |i| {
                const high = try std.fmt.charToDigit(commit_hash[i * 2], 16);
                const low = try std.fmt.charToDigit(commit_hash[i * 2 + 1], 16);
                hash[i] = (high << 4) | low;
            }

            return cid.CID{ .hash = hash };
        }

        return error.InvalidHead;
    }

    fn updateHead(self: *Repository, io: std.Io, commit_cid: cid.CID) !void {
        const zev_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.path, ".zev" });
        defer self.allocator.free(zev_path);

        const head_path = try std.fs.path.join(self.allocator, &[_][]const u8{ zev_path, "HEAD" });
        defer self.allocator.free(head_path);

        const head_file = try std.Io.Dir.cwd().openFile(io, head_path, .{});
        defer head_file.close(io);

        var head_scratch: [256]u8 = undefined;
        var head_reader = head_file.reader(io, &head_scratch);
        const bytes_read = try head_reader.interface.readSliceShort(&buffer);
        const head_content = std.mem.trim(u8, buffer[0..bytes_read], " \n\r\t");

        if (std.mem.startsWith(u8, head_content, "ref: ")) {
            const ref_path = head_content[5..];
            const full_ref_path = try std.fs.path.join(self.allocator, &[_][]const u8{ zev_path, ref_path });
            defer self.allocator.free(full_ref_path);

            const ref_file = try std.Io.Dir.cwd().createFile(full_ref_path, .{});
            defer ref_file.close(io);

            const commit_hash = try commit_cid.toString(self.allocator);
            defer self.allocator.free(commit_hash);

            try ref_file.writeAll(commit_hash);
        }
    }

    pub fn getConfig(self: *Repository) ?*config_mod.Config {
        if (self.config) |*cfg| return cfg;
        return null;
    }

    pub fn saveConfig(self: *Repository) !void {
        if (self.config) |*cfg| {
            try cfg.save(self.path);
        }
    }
};

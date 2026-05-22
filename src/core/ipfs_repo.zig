const std = @import("std");
const commit_mod = @import("commit.zig");
const tree_mod = @import("tree.zig");
const IPFSClient = @import("ipfs.zig").IPFSClient;
const cid_mod = @import("cid.zig");
const Repository = @import("repository.zig").Repository;

pub const IPFSRepo = struct {
    pub const Metadata = struct {
        version: []const u8,
        head_ref: []const u8,
        refs: std.StringHashMap([]const u8),
        objects: std.StringHashMap([]const u8),

        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Metadata {
            return .{
                .version = "1.0",
                .head_ref = "refs/heads/main",
                .refs = std.StringHashMap([]const u8).init(allocator),
                .objects = std.StringHashMap([]const u8).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Metadata) void {
            var refs_it = self.refs.iterator();
            while (refs_it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.refs.deinit();

            var obj_it = self.objects.iterator();
            while (obj_it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.objects.deinit();
        }

        pub fn toJson(self: *const Metadata, allocator: std.mem.Allocator) ![]const u8 {
            var json: std.ArrayList(u8) = .{};
            errdefer json.deinit(allocator);

            try json.appendSlice(allocator, "{");
            try json.appendSlice(allocator, "\"version\":\"");
            try json.appendSlice(allocator, self.version);
            try json.appendSlice(allocator, "\",");

            try json.appendSlice(allocator, "\"head_ref\":\"");
            try json.appendSlice(allocator, self.head_ref);
            try json.appendSlice(allocator, "\",");

            try json.appendSlice(allocator, "\"refs\":{");
            var refs_it = self.refs.iterator();
            var first = true;
            while (refs_it.next()) |entry| {
                if (!first) try json.appendSlice(allocator, ",");
                first = false;

                try json.appendSlice(allocator, "\"");
                try json.appendSlice(allocator, entry.key_ptr.*);
                try json.appendSlice(allocator, "\":\"");
                try json.appendSlice(allocator, entry.value_ptr.*);
                try json.appendSlice(allocator, "\"");
            }
            try json.appendSlice(allocator, "},");

            try json.appendSlice(allocator, "\"objects\":{");
            var obj_it = self.objects.iterator();
            first = true;
            while (obj_it.next()) |entry| {
                if (!first) try json.appendSlice(allocator, ",");
                first = false;

                try json.appendSlice(allocator, "\"");
                try json.appendSlice(allocator, entry.key_ptr.*);
                try json.appendSlice(allocator, "\":\"");
                try json.appendSlice(allocator, entry.value_ptr.*);
                try json.appendSlice(allocator, "\"");
            }
            try json.appendSlice(allocator, "}}");

            return json.toOwnedSlice(allocator);
        }

        pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !Metadata {
            var metadata = Metadata.init(allocator);
            errdefer metadata.deinit();

            if (std.mem.indexOf(u8, json_str, "\"head_ref\":\"")) |start| {
                const value_start = start + 12;
                if (std.mem.indexOfPos(u8, json_str, value_start, "\"")) |end| {
                    metadata.head_ref = try allocator.dupe(u8, json_str[value_start..end]);
                }
            }

            if (std.mem.indexOf(u8, json_str, "\"refs\":{")) |refs_start| {
                const refs_content_start = refs_start + 8;
                if (std.mem.indexOfPos(u8, json_str, refs_content_start, "}")) |refs_end| {
                    const refs_content = json_str[refs_content_start..refs_end];
                    try parseJsonMap(allocator, refs_content, &metadata.refs);
                }
            }

            if (std.mem.indexOf(u8, json_str, "\"objects\":{")) |obj_start| {
                const obj_content_start = obj_start + 11;
                if (std.mem.indexOfPos(u8, json_str, obj_content_start, "}")) |obj_end| {
                    const obj_content = json_str[obj_content_start..obj_end];
                    try parseJsonMap(allocator, obj_content, &metadata.objects);
                }
            }

            return metadata;
        }

        fn parseJsonMap(allocator: std.mem.Allocator, content: []const u8, map: *std.StringHashMap([]const u8)) !void {
            var pos: usize = 0;
            while (pos < content.len) {
                const key_start = std.mem.indexOfPos(u8, content, pos, "\"") orelse break;
                const key_value_start = key_start + 1;
                const key_end = std.mem.indexOfPos(u8, content, key_value_start, "\"") orelse break;

                const key = try allocator.dupe(u8, content[key_value_start..key_end]);
                errdefer allocator.free(key);

                const sep = std.mem.indexOfPos(u8, content, key_end, ":\"") orelse break;
                const val_start = sep + 2;
                const val_end = std.mem.indexOfPos(u8, content, val_start, "\"") orelse break;

                const value = try allocator.dupe(u8, content[val_start..val_end]);
                errdefer allocator.free(value);

                try map.put(key, value);

                pos = val_end + 1;
            }
        }
    };

    pub fn packWithObjects(allocator: std.mem.Allocator, repo: *Repository) ![]const u8 {
        var metadata = Metadata.init(allocator);
        defer metadata.deinit();

        const head_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "HEAD" });
        defer allocator.free(head_path);

        const head_file = std.fs.cwd().openFile(head_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print("Warning: HEAD file not found\n", .{});
            }
            return err;
        };
        defer head_file.close();

        var head_buf: [256]u8 = undefined;
        const head_bytes = try head_file.read(&head_buf);
        metadata.head_ref = try allocator.dupe(u8, std.mem.trim(u8, head_buf[0..head_bytes], " \n\r\t"));

        const refs_path = try std.fs.path.join(allocator, &.{ repo.path, ".zev", "refs", "heads" });
        defer allocator.free(refs_path);

        var refs_dir = std.fs.cwd().openDir(refs_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print("Warning: refs directory not found\n", .{});
                return metadata.toJson(allocator);
            }
            return err;
        };
        defer refs_dir.close();

        var it = refs_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .file) {
                const ref_file = try refs_dir.openFile(entry.name, .{});
                defer ref_file.close();

                var ref_buf: [65]u8 = undefined;
                const ref_bytes = try ref_file.read(&ref_buf);
                const ref_hash = std.mem.trim(u8, ref_buf[0..ref_bytes], " \n\r\t");

                const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{entry.name});
                const ref_value = try allocator.dupe(u8, ref_hash);

                try metadata.refs.put(ref_name, ref_value);
            }
        }

        std.debug.print("📦 Uploading objects to IPFS...\n", .{});
        var ipfs_client = IPFSClient.init(allocator, "http://127.0.0.1:5001");

        var visited = std.AutoHashMap([32]u8, void).init(allocator);
        defer visited.deinit();

        var refs_iter = metadata.refs.iterator();
        while (refs_iter.next()) |ref_entry| {
            if (std.mem.startsWith(u8, ref_entry.key_ptr.*, "refs/heads/")) {
                var hash: [32]u8 = undefined;
                for (0..32) |i| {
                    const high = try std.fmt.charToDigit(ref_entry.value_ptr.*[i * 2], 16);
                    const low = try std.fmt.charToDigit(ref_entry.value_ptr.*[i * 2 + 1], 16);
                    hash[i] = (high << 4) | low;
                }
                const commit_cid = cid_mod.CID{ .hash = hash };

                try uploadObjectTree(allocator, repo, &ipfs_client, commit_cid, &metadata.objects, &visited);
            }
        }

        std.debug.print("✅ Uploaded {} objects to IPFS\n", .{metadata.objects.count()});

        return metadata.toJson(allocator);
    }

    fn uploadObjectTree(
        allocator: std.mem.Allocator,
        repo: *Repository,
        ipfs_client: *IPFSClient,
        obj_cid: cid_mod.CID,
        objects_map: *std.StringHashMap([]const u8),
        visited: *std.AutoHashMap([32]u8, void),
    ) !void {
        if (visited.contains(obj_cid.hash)) return;
        try visited.put(obj_cid.hash, {});

        const obj_data = try repo.store.get(obj_cid);
        defer allocator.free(obj_data);

        const ipfs_cid = try ipfs_client.add(obj_data);

        const local_cid_str = try obj_cid.toString(allocator);
        try objects_map.put(local_cid_str, ipfs_cid);

        if (commit_mod.Commit.deserialize(allocator, obj_data)) |commit_obj| {
            defer allocator.free(commit_obj.author);
            defer allocator.free(commit_obj.message);

            if (commit_obj.parent_cid) |parent_cid| {
                try uploadObjectTree(allocator, repo, ipfs_client, parent_cid, objects_map, visited);
            }

            try uploadObjectTree(allocator, repo, ipfs_client, commit_obj.tree_cid, objects_map, visited);
            return;
        } else |_| {}

        if (tree_mod.Tree.deserialize(allocator, obj_data)) |tree_obj| {
            var tree = tree_obj;
            defer tree.deinit();

            for (tree.entries.items) |entry| {
                try uploadObjectTree(allocator, repo, ipfs_client, entry.cid, objects_map, visited);
            }
            return;
        } else |_| {}
    }

    pub fn pack(allocator: std.mem.Allocator, repo_path: []const u8) ![]const u8 {
        var metadata = Metadata.init(allocator);
        defer metadata.deinit();

        const head_path = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "HEAD" });
        defer allocator.free(head_path);

        const head_file = std.fs.cwd().openFile(head_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print("Warning: HEAD file not found\n", .{});
            }
            return err;
        };
        defer head_file.close();

        var head_buf: [256]u8 = undefined;
        const head_bytes = try head_file.read(&head_buf);
        metadata.head_ref = try allocator.dupe(u8, std.mem.trim(u8, head_buf[0..head_bytes], " \n\r\t"));

        const refs_path = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "refs", "heads" });
        defer allocator.free(refs_path);

        var refs_dir = std.fs.cwd().openDir(refs_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print("Warning: refs directory not found\n", .{});
                return metadata.toJson(allocator);
            }
            return err;
        };
        defer refs_dir.close();

        var it = refs_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .file) {
                const ref_file = try refs_dir.openFile(entry.name, .{});
                defer ref_file.close();

                var ref_buf: [65]u8 = undefined;
                const ref_bytes = try ref_file.read(&ref_buf);
                const ref_hash = std.mem.trim(u8, ref_buf[0..ref_bytes], " \n\r\t");

                const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{entry.name});
                const ref_value = try allocator.dupe(u8, ref_hash);

                try metadata.refs.put(ref_name, ref_value);
            }
        }

        return metadata.toJson(allocator);
    }

    pub fn unpack(allocator: std.mem.Allocator, repo_path: []const u8, json_data: []const u8) !void {
        var metadata = try Metadata.fromJson(allocator, json_data);
        defer metadata.deinit();

        const zev_path = try std.fs.path.join(allocator, &.{ repo_path, ".zev" });
        defer allocator.free(zev_path);

        try std.fs.cwd().makePath(zev_path);

        const head_path = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "HEAD" });
        defer allocator.free(head_path);

        const head_file = try std.fs.cwd().createFile(head_path, .{});
        defer head_file.close();
        try head_file.writeAll(metadata.head_ref);

        var refs_it = metadata.refs.iterator();
        while (refs_it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, "refs/heads/")) {
                const branch_name = entry.key_ptr.*[11..];

                const ref_path = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "refs", "heads", branch_name });
                defer allocator.free(ref_path);

                if (std.fs.path.dirname(ref_path)) |parent_dir| {
                    try std.fs.cwd().makePath(parent_dir);
                }

                const ref_file = try std.fs.cwd().createFile(ref_path, .{});
                defer ref_file.close();

                try ref_file.writeAll(entry.value_ptr.*);
                try ref_file.writeAll("\n");
            }
        }

        if (metadata.objects.count() > 0) {
            std.debug.print("📥 Downloading {} objects from IPFS...\n", .{metadata.objects.count()});

            var ipfs_client = IPFSClient.init(allocator, "http://127.0.0.1:5001");
            const objects_path = try std.fs.path.join(allocator, &.{ repo_path, ".zev", "objects" });
            defer allocator.free(objects_path);

            try std.fs.cwd().makePath(objects_path);

            var obj_it = metadata.objects.iterator();
            while (obj_it.next()) |entry| {
                const local_cid = entry.key_ptr.*;
                const ipfs_cid = entry.value_ptr.*;

                const obj_data = try ipfs_client.cat(ipfs_cid);
                defer allocator.free(obj_data);

                const obj_file_path = try std.fs.path.join(allocator, &.{ objects_path, local_cid });
                defer allocator.free(obj_file_path);

                const obj_file = try std.fs.cwd().createFile(obj_file_path, .{});
                defer obj_file.close();
                try obj_file.writeAll(obj_data);
            }

            std.debug.print("✅ Downloaded all objects\n", .{});
        }
    }
};

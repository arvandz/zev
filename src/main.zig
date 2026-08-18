const std = @import("std");
const cid = @import("core/cid.zig");
const blob = @import("core/blob.zig");
const repository = @import("core/repository.zig");
const tree = @import("core/tree.zig");
const log = @import("core/log.zig");
const status = @import("core/status.zig");
const branch = @import("core/branch.zig");
const merge = @import("core/merge.zig");
const diff = @import("core/diff.zig");
const remote = @import("core/remote.zig");
const ipfs = @import("core/ipfs.zig");
const config_mod = @import("core/config.zig");
const checkout = @import("core/checkout.zig");
const tag_mod = @import("core/tag.zig");
const hooks_mod = @import("core/hooks.zig");
const gc_mod = @import("core/gc.zig");
const stash_mod = @import("core/stash.zig");
const rebase_mod = @import("core/rebase.zig");
const blame_mod = @import("core/blame.zig");
const cherrypick_mod = @import("core/cherrypick.zig");
const bisect_mod = @import("core/bisect.zig");
const metrics_mod = @import("core/metrics.zig");
const experiment_mod = @import("core/experiment.zig");
const lineage_mod = @import("core/lineage.zig");
const snapshot_mod = @import("core/snapshot.zig");
const publish_mod = @import("core/publish.zig");
const search_mod = @import("core/search.zig");
const compare_mod = @import("core/compare.zig");
const peer_mod = @import("core/peer.zig");
const notarize_mod = @import("core/notarize.zig");
const drift_mod = @import("core/drift.zig");
const reproduce_mod = @import("core/reproduce.zig");
const export_mod = @import("core/export.zig");
const audit_mod = @import("core/audit.zig");
const context_mod = @import("core/context.zig");
const dataset_mod = @import("core/dataset.zig");
const ipld = @import("core/ipld.zig");
const dag_mod = @import("core/dag.zig");
const selector_mod = @import("core/selector.zig");
const car_mod = @import("core/car.zig");
const ipld_commit = @import("core/ipld_commit.zig");
const crypto_mod = @import("core/crypto.zig");
const merge_mod = @import("core/fedmerge.zig");
const sdiff = @import("core/semantic_diff.zig");
const regression = @import("core/regression.zig");
const weight_diff = @import("core/weight_diff.zig");
const weight_merge = @import("core/weight_merge.zig");
const remote_http = @import("core/remote_http.zig");
const weight_diff_api_cli = @import("core/weight_diff_api_cli.zig");
const repo_dashboard_cli = @import("core/repo_dashboard_cli.zig");
const dependency_graph_cli = @import("core/dependency_graph_cli.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const env_map = init.environ_map;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try printUsage();
        return;
    }
    const command = args[1];

    if (std.mem.eql(u8, command, "init")) {
        const path = if (args.len >= 3 and !std.mem.eql(u8, args[2], "--ipfs")) args[2] else ".";

        var use_ipfs = false;
        if (args.len >= 4 and std.mem.eql(u8, args[3], "--ipfs")) {
            use_ipfs = true;
        } else if (args.len >= 3 and std.mem.eql(u8, args[2], "--ipfs")) {
            use_ipfs = true;
        }

        var repo = try repository.Repository.init(allocator, io, path, use_ipfs);

        defer repo.deinit();

        std.debug.print("Initialized empty Zev repository in {s}/.zev/\n", .{path});
        if (use_ipfs) {
            std.debug.print("🌐 IPFS hybrid storage enabled\n", .{});
            std.debug.print("💡 Commits and objects will be automatically stored in IPFS\n", .{});
        }
    } else if (std.mem.eql(u8, command, "clone")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev clone <url> [directory]\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev clone file:///path/to/repo\n", .{});
            std.debug.print("  zev clone https://example.com/repo.git myrepo\n", .{});
            std.debug.print("  zev clone user@host:/path/to/repo\n", .{});
            std.debug.print("  zev clone ipfs://QmXXXXX...\n", .{});
            return;
        }
        var depth: usize = 0;
        var url: []const u8 = "";
        var dest: []const u8 = "zev-clone";
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.startsWith(u8, args[i], "--depth=")) {
                depth = try std.fmt.parseInt(usize, args[i][8..], 10);
            } else if (std.mem.eql(u8, args[i], "--depth") and i + 1 < args.len) {
                i += 1;
                depth = try std.fmt.parseInt(usize, args[i], 10);
            } else if (url.len == 0) {
                url = args[i];
            } else {
                dest = args[i];
            }
        }

        if (url.len == 0) {
            std.debug.print("Usage: zev clone [--depth=N] <url> [directory]\n", .{});
            return;
        }

        if (depth > 0) {
            try remote.cloneWithDepth(allocator, io, url, dest, depth);
        } else {
            try remote.clone(allocator, io, url, dest);
        }
    } else if (std.mem.eql(u8, command, "config")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }

        var config = try config_mod.Config.load(allocator, io, ".");
        defer config.deinit();

        if (args.len < 3) {
            std.debug.print("Usage: zev config <get|set|list> [key] [value]\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev config list\n", .{});
            std.debug.print("  zev config get user.name\n", .{});
            std.debug.print("  zev config set user.name \"Your Name\"\n", .{});
            std.debug.print("  zev config set storage.backend hybrid\n", .{});
            return;
        }

        const subcommand = args[2];

        if (std.mem.eql(u8, subcommand, "list")) {
            std.debug.print("📋 Configuration:\n", .{});
            try config.listDirect();
        } else if (std.mem.eql(u8, subcommand, "get")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev config get <key>\n", .{});
                return;
            }
            const key = args[3];
            const value = config.get(key) catch |err| {
                if (err == error.UnknownConfigKey) {
                    std.debug.print("❌ Unknown config key: {s}\n", .{key});
                    return;
                }
                return err;
            };
            std.debug.print("{s}={s}\n", .{ key, value });
        } else if (std.mem.eql(u8, subcommand, "set")) {
            if (args.len < 5) {
                std.debug.print("Usage: zev config set <key> <value>\n", .{});
                std.debug.print("\nAvailable keys:\n", .{});
                std.debug.print("  user.name              Your name\n", .{});
                std.debug.print("  user.email             Your email\n", .{});
                std.debug.print("  storage.backend        local|ipfs|hybrid\n", .{});
                std.debug.print("  ipfs.url               IPFS API URL\n", .{});
                std.debug.print("  ipfs.auto_pin          true|false\n", .{});
                std.debug.print("  core.default_branch    Default branch name\n", .{});
                return;
            }
            const key = args[3];
            const value = args[4];

            config.set(key, value) catch |err| {
                const validation_mod = @import("core/config_validation.zig");
                const friendly_msg = validation_mod.getErrorMessage(err);
                std.debug.print("❌ Error: {s}\n", .{friendly_msg});
                std.debug.print("💡 Failed to set {s} = {s}\n", .{ key, value });
                return;
            };
            try config.save(io, ".");

            std.debug.print("✅ Set {s} = {s}\n", .{ key, value });

            if (std.mem.eql(u8, key, "storage.backend")) {
                std.debug.print("💡 Storage backend changed to: {s}\n", .{value});
                if (std.mem.eql(u8, value, "hybrid") or std.mem.eql(u8, value, "ipfs")) {
                    std.debug.print("📦 IPFS storage enabled - commits will be stored in IPFS\n", .{});
                }
            }
        } else {
            std.debug.print("Unknown config subcommand: {s}\n", .{subcommand});
            std.debug.print("Use: get, set, or list\n", .{});
        }
    } else if (std.mem.eql(u8, command, "version")) {
        std.debug.print("Zev version 0.1.0 (with IPFS integration)\n", .{});
    } else if (std.mem.eql(u8, command, "hash")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev hash <data>\n", .{});
            return;
        }
        const data = args[2];
        const content_id = cid.CID.fromBytes(data);
        const hash_str = try content_id.toString(allocator);
        defer allocator.free(hash_str);
        std.debug.print("CID: {s}\n", .{hash_str});
    } else if (std.mem.eql(u8, command, "add")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev add <file>\n", .{});
            return;
        }

        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository. Run 'zev init' first.\n", .{});
            return;
        }

        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        const ignore_mod = @import("core/ignore.zig");
        var ignore_list = try ignore_mod.IgnoreList.loadFromFile(allocator, io, ".");
        defer ignore_list.deinit();

        var arg_i: usize = 2;
        while (arg_i < args.len) : (arg_i += 1) {
            const filename = args[arg_i];

            if (ignore_list.isIgnored(filename)) {
                std.debug.print("Ignored '{s}' (matches .zevignore pattern)\n", .{filename});
                continue;
            }

            const file_data = try std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .unlimited);
            defer allocator.free(file_data);

            const file = try std.Io.Dir.cwd().openFile(io, filename, .{});
            defer file.close(io);
            const file_stat = try file.stat(io);

            const content_id = try repo.store.put(io, file_data);

            if (repo.storage) |*storage| {
                const ipfs_cid = try storage.storeObject(io, file_data);
                defer allocator.free(ipfs_cid);
                std.debug.print("📦 Blob stored in IPFS: {s}\n", .{ipfs_cid});
            }

            try repo.index.addEntry(filename, content_id, file_data.len, @intCast(file_stat.permissions.toMode()));
            std.debug.print("Added '{s}' to staging area\n", .{filename});
        }
        try repo.index.write(io);
    } else if (std.mem.eql(u8, command, "commit")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev commit <message>\n", .{});
            return;
        }

        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }

        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (repo.index.entries.items.len == 0) {
            std.debug.print("Nothing to commit (staging area is empty)\n", .{});
            return;
        }

        const message = args[2];

        const author = if (repo.config) |*cfg|
            try std.fmt.allocPrint(allocator, "{s} <{s}>", .{ cfg.user_name, cfg.user_email })
        else
            try allocator.dupe(u8, "Zev User <user@example.com>");
        defer allocator.free(author);

        const staged_count = repo.index.entries.items.len;

        const pre_result = try hooks_mod.runHook(allocator, io, ".", .pre_commit, &.{});
        if (pre_result == .failure) {
            std.debug.print("Commit aborted by pre-commit hook\n", .{});
            return;
        }

        var file_tree = tree.Tree.init(allocator);
        defer file_tree.deinit();

        const commit_cid = try repo.createCommit(io, author, message, &file_tree);
        const cid_str = try commit_cid.toString(allocator);
        defer allocator.free(cid_str);

        repo.index.clear();
        try repo.index.write(io);

        std.debug.print("Created commit: {s}\n", .{cid_str});
        std.debug.print("Committed {} file(s)\n", .{staged_count});
        ipld_commit.onNewCommit(allocator, io, &repo, cid_str) catch {};

        _ = try hooks_mod.runHook(allocator, io, ".", .post_commit, &.{});
    } else if (std.mem.eql(u8, command, "remote")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }

        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            try remote.listRemotes(allocator, io, &repo);
        } else if (std.mem.eql(u8, args[2], "list")) {
            try remote.listRemotes(allocator, io, &repo);
        } else if (std.mem.eql(u8, args[2], "add")) {
            if (args.len < 5) {
                std.debug.print("Usage: zev remote add <name> <url>\n", .{});
                std.debug.print("\nExamples:\n", .{});
                std.debug.print("  zev remote add origin file:///path/to/repo\n", .{});
                std.debug.print("  zev remote add github https://github.com/user/repo\n", .{});
                std.debug.print("  zev remote add server ssh://user@host:/path/repo\n", .{});
                std.debug.print("  zev remote add ipfs ipfs://QmXXXXX...\n", .{});
                return;
            }
            const name = args[3];
            const url = args[4];
            try remote.addRemote(allocator, io, &repo, name, url);
            std.debug.print("✅ Added remote '{s}' -> {s}\n", .{ name, url });
        } else if (std.mem.eql(u8, args[2], "remove") or std.mem.eql(u8, args[2], "rm")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev remote remove <name>\n", .{});
                return;
            }
            const name = args[3];
            try remote.removeRemote(allocator, io, &repo, name);
            std.debug.print("✅ Removed remote '{s}'\n", .{name});
        } else if (std.mem.eql(u8, args[2], "show")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev remote show <name>\n", .{});
                return;
            }
            const name = args[3];
            const url = try remote.getRemote(allocator, io, &repo, name);
            defer allocator.free(url);

            const protocol = remote.RemoteProtocol.fromUri(url) catch .file;
            std.debug.print("📡 Remote: {s}\n", .{name});
            std.debug.print("🔗 URL: {s}\n", .{url});
            std.debug.print("📋 Protocol: {s}\n", .{@tagName(protocol)});
        } else {
            std.debug.print("Unknown remote command: {s}\n", .{args[2]});
            std.debug.print("Usage: zev remote [add|remove|show|list]\n", .{});
        }
    } else if (std.mem.eql(u8, command, "push")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev push <remote> [branch]\n", .{});
            return;
        }

        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }

        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        const remote_name = args[2];
        const branch_name = if (args.len >= 4) args[3] else "main";

        const push_result = try hooks_mod.runHook(allocator, io, ".", .pre_push, &.{});
        if (push_result == .failure) {
            std.debug.print("Push aborted by pre-push hook\n", .{});
            return;
        }
        try remote.push(allocator, io, &repo, remote_name, branch_name);
    } else if (std.mem.eql(u8, command, "pull")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev pull <remote> [branch]\n", .{});
            return;
        }

        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }

        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        const remote_name = args[2];
        const branch_name = if (args.len >= 4) args[3] else "main";

        try remote.pull(allocator, io, &repo, remote_name, branch_name);
    } else if (std.mem.eql(u8, command, "sdiff")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        var ref_a: []const u8 = "HEAD~1";
        var ref_b: []const u8 = "HEAD";
        var metric_filter: ?[]const u8 = null;
        var fmt: []const u8 = "text";
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--metric") and i + 1 < args.len) {
                i += 1;
                metric_filter = args[i];
            } else if (std.mem.eql(u8, args[i], "--format") and i + 1 < args.len) {
                i += 1;
                fmt = args[i];
            } else if (i == 2 and !std.mem.startsWith(u8, args[i], "--")) {
                ref_a = args[i];
            } else if (i == 3 and !std.mem.startsWith(u8, args[i], "--")) {
                ref_b = args[i];
            }
        }
        try sdiff.cmdSemanticDiff(allocator, io, &repo, ref_a, ref_b, metric_filter, fmt);
    } else if (std.mem.eql(u8, command, "diff")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }

        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len >= 3) {
            const option = args[2];

            if (std.mem.eql(u8, option, "--staged") or std.mem.eql(u8, option, "--cached")) {
                try diff.diffStaged(allocator, io, &repo);
            } else {
                try diff.diffWorkingToStaging(allocator, io, &repo, option);
            }
        } else {
            try diff.diffUnstaged(allocator, io, &repo);
        }
    } else if (std.mem.eql(u8, command, "branch")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }

        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            try branch.listBranches(allocator, io, &repo);
        } else {
            const branch_name = args[2];

            if (std.mem.eql(u8, branch_name, "-d")) {
                if (args.len < 4) {
                    std.debug.print("Usage: zev branch -d <branch-name>\n", .{});
                    return;
                }
                const delete_name = args[3];
                branch.deleteBranch(allocator, io, &repo, delete_name) catch |err| {
                    if (err == error.CannotDeleteCurrentBranch) {
                        std.debug.print("Error: Cannot delete the current branch\n", .{});
                    } else {
                        return err;
                    }
                    return;
                };
                std.debug.print("Deleted branch '{s}'\n", .{delete_name});
            } else {
                branch.createBranch(allocator, io, &repo, branch_name) catch |err| {
                    if (err == error.BranchAlreadyExists) {
                        std.debug.print("Error: Branch '{s}' already exists\n", .{branch_name});
                    } else {
                        return err;
                    }
                    return;
                };
                std.debug.print("Created branch '{s}'\n", .{branch_name});
            }
        }
    } else if (std.mem.eql(u8, command, "checkout")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev checkout <branch-name>\n", .{});
            return;
        }

        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }

        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        const branch_name = args[2];
        branch.checkoutBranch(allocator, io, &repo, branch_name) catch |err| {
            if (err == error.BranchNotFound) {
                std.debug.print("Error: Branch '{s}' not found\n", .{branch_name});
            } else {
                return err;
            }
            return;
        };
        const head_commit = repo.getHeadCommit(io) catch null;
        if (head_commit) |commit_cid| {
            const checkout_mod = @import("core/checkout.zig");
            checkout_mod.checkoutCommit(allocator, io, &repo, commit_cid) catch |err| {
                std.debug.print("Warning: Could not checkout files: {}\n", .{err});
            };
        }
        std.debug.print("Switched to branch '{s}'\n", .{branch_name});
    } else if (std.mem.eql(u8, command, "merge")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev merge <branch-name>\n", .{});
            return;
        }

        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }

        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        const source_branch = args[2];
        const result = try merge.merge(allocator, io, &repo, source_branch);

        switch (result) {
            .FastForward => {
                std.debug.print("Fast-forward merge completed\n", .{});
            },
            .AlreadyUpToDate => {
                std.debug.print("Already up to date\n", .{});
            },
            .ThreeWaySuccess => {
                std.debug.print("Three-way merge completed successfully\n", .{});
            },
            .ConflictDetected => {
                std.debug.print("Automatic merge failed; fix conflicts and commit the result\n", .{});
            },
        }
    } else if (std.mem.eql(u8, command, "ipfs")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev ipfs <subcommand>\n", .{});
            std.debug.print("\nSubcommands:\n", .{});
            std.debug.print("  status              Check IPFS daemon connection\n", .{});
            std.debug.print("  id                  Show IPFS node information\n", .{});
            std.debug.print("  add <file>          Add file to IPFS\n", .{});
            std.debug.print("  cat <cid>           Retrieve content from IPFS\n", .{});
            std.debug.print("  block-put <file>    Store file as IPFS block\n", .{});
            std.debug.print("  block-get <cid>     Get raw IPFS block\n", .{});
            std.debug.print("  block-stat <cid>    Get block statistics\n", .{});
            std.debug.print("  pin <cid>           Pin content to local storage\n", .{});
            std.debug.print("  unpin <cid>         Unpin content from local storage\n", .{});
            return;
        }

        const subcommand = args[2];
        var ipfs_client = ipfs.IPFSClient.init(allocator, "http://127.0.0.1:5001");

        if (std.mem.eql(u8, subcommand, "status")) {
            const version_str = ipfs_client.version(
                io,
            ) catch |err| {
                std.debug.print("❌ IPFS daemon not running or unreachable: {}\n", .{err});
                std.debug.print("💡 Start IPFS with: ipfs daemon\n", .{});
                return;
            };
            defer allocator.free(version_str);
            std.debug.print("✅ IPFS daemon connected\n", .{});
            std.debug.print("📦 Version: {s}\n", .{version_str});
        } else if (std.mem.eql(u8, subcommand, "id")) {
            var node_id = ipfs_client.id(
                io,
            ) catch |err| {
                std.debug.print("❌ Failed to get node ID: {}\n", .{err});
                return;
            };
            defer node_id.deinit(allocator);

            std.debug.print("🆔 Node ID: {s}\n", .{node_id.id});
            std.debug.print("🤖 Agent: {s}\n", .{node_id.agent_version});
        } else if (std.mem.eql(u8, subcommand, "add")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev ipfs add <file>\n", .{});
                return;
            }

            const filename = args[3];
            const file_data = try std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .limited(100 * 1024 * 1024));
            defer allocator.free(file_data);

            std.debug.print("📤 Adding {s} to IPFS...\n", .{filename});
            const ipfs_cid = try ipfs_client.add(io, file_data);
            defer allocator.free(ipfs_cid);

            std.debug.print("✅ Added to IPFS!\n", .{});
            std.debug.print("🔗 CID: {s}\n", .{ipfs_cid});
            std.debug.print("📊 Size: {} bytes\n", .{file_data.len});
            std.debug.print("\n💡 View on gateway: https://ipfs.io/ipfs/{s}\n", .{ipfs_cid});
        } else if (std.mem.eql(u8, subcommand, "cat")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev ipfs cat <cid>\n", .{});
                return;
            }

            const ipfs_cid = args[3];
            std.debug.print("📥 Retrieving {s} from IPFS...\n", .{ipfs_cid});

            const data = try ipfs_client.cat(io, ipfs_cid);
            defer allocator.free(data);

            std.debug.print("\n--- Content ---\n", .{});
            std.debug.print("{s}\n", .{data});
            std.debug.print("--- End ({} bytes) ---\n", .{data.len});
        } else if (std.mem.eql(u8, subcommand, "block-put")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev ipfs block-put <file> [--pin]\n", .{});
                return;
            }

            const filename = args[3];
            const should_pin = if (args.len >= 5) std.mem.eql(u8, args[4], "--pin") else false;

            const file_data = try std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .limited(100 * 1024 * 1024));
            defer allocator.free(file_data);

            std.debug.print("📦 Storing {s} as IPFS block...\n", .{filename});
            const block_cid = try ipfs_client.blockPut(io, file_data, should_pin);
            defer allocator.free(block_cid);

            std.debug.print("✅ Block stored!\n", .{});
            std.debug.print("🔗 CID: {s}\n", .{block_cid});
            std.debug.print("📊 Size: {} bytes\n", .{file_data.len});
            if (should_pin) {
                std.debug.print("📌 Pinned: yes\n", .{});
            }
        } else if (std.mem.eql(u8, subcommand, "block-get")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev ipfs block-get <cid>\n", .{});
                return;
            }

            const block_cid = args[3];
            std.debug.print("📥 Getting block {s}...\n", .{block_cid});

            const data = try ipfs_client.blockGet(io, block_cid);
            defer allocator.free(data);

            std.debug.print("\n--- Block Data ---\n", .{});
            std.debug.print("{s}\n", .{data});
            std.debug.print("--- End ({} bytes) ---\n", .{data.len});
        } else if (std.mem.eql(u8, subcommand, "block-stat")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev ipfs block-stat <cid>\n", .{});
                return;
            }

            const block_cid = args[3];
            var stat = try ipfs_client.blockStat(io, block_cid);
            defer stat.deinit(allocator);

            std.debug.print("📊 Block Statistics:\n", .{});
            std.debug.print("  CID:  {s}\n", .{stat.key});
            std.debug.print("  Size: {} bytes\n", .{stat.size});
        } else if (std.mem.eql(u8, subcommand, "pin")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev ipfs pin <cid>\n", .{});
                return;
            }

            const pin_cid = args[3];
            std.debug.print("📌 Pinning {s}...\n", .{pin_cid});
            try ipfs_client.pin(io, pin_cid);
            std.debug.print("✅ Pinned successfully!\n", .{});
        } else if (std.mem.eql(u8, subcommand, "unpin")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev ipfs unpin <cid>\n", .{});
                return;
            }

            const unpin_cid = args[3];
            std.debug.print("📌 Unpinning {s}...\n", .{unpin_cid});
            try ipfs_client.unpin(io, unpin_cid);
            std.debug.print("✅ Unpinned successfully!\n", .{});
        } else {
            std.debug.print("❌ Unknown ipfs subcommand: {s}\n", .{subcommand});
            std.debug.print("Run 'zev ipfs' for usage\n", .{});
        }
    } else if (std.mem.eql(u8, command, "log")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }

        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        const head_cid = repo.getHeadCommit(io) catch {
            std.debug.print("No commits yet.\n", .{});
            return;
        };

        const max_count = if (args.len >= 3) try std.fmt.parseInt(usize, args[2], 10) else 10;

        try log.printLog(io, allocator, &repo.store, head_cid, max_count);
    } else if (std.mem.eql(u8, command, "status")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }

        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        try status.showStatus(allocator, io, &repo);
    } else if (std.mem.eql(u8, command, "cat")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev cat <cid>\n", .{});
            return;
        }

        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }

        const hash_str = args[2];
        if (hash_str.len != 64) {
            std.debug.print("Invalid CID length\n", .{});
            return;
        }

        var hash: [32]u8 = undefined;
        for (0..32) |i| {
            const high = try std.fmt.charToDigit(hash_str[i * 2], 16);
            const low = try std.fmt.charToDigit(hash_str[i * 2 + 1], 16);
            hash[i] = (high << 4) | low;
        }

        const content_id = cid.CID{ .hash = hash };
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        const data = try repo.store.get(io, content_id);
        defer allocator.free(data);
        std.debug.print("{s}\n", .{data});
    } else if (std.mem.eql(u8, command, "hook")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            std.debug.print("Usage: zev hook <list|add|remove>\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev hook list\n", .{});
            std.debug.print("  zev hook add pre-commit <script>\n", .{});
            std.debug.print("  zev hook remove pre-commit\n", .{});
            std.debug.print("\nHook types: pre-commit, post-commit, pre-push, post-merge, commit-msg\n", .{});
            return;
        }

        if (std.mem.eql(u8, args[2], "list")) {
            try hooks_mod.listHooks(allocator, io, ".");
        } else if (std.mem.eql(u8, args[2], "add")) {
            if (args.len < 5) {
                std.debug.print("Usage: zev hook add <type> <script-file>\n", .{});
                return;
            }
            const hook_type = hooks_mod.HookType.fromString(args[3]) orelse {
                std.debug.print("Unknown hook type: {s}\n", .{args[3]});
                std.debug.print("Valid types: pre-commit, post-commit, pre-push, post-merge, commit-msg\n", .{});
                return;
            };
            const script = try std.Io.Dir.cwd().readFileAlloc(io, args[4], allocator, .limited(1024 * 1024));
            defer allocator.free(script);
            try hooks_mod.installHook(allocator, io, ".", hook_type, script);
        } else if (std.mem.eql(u8, args[2], "remove")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev hook remove <type>\n", .{});
                return;
            }
            const hook_type = hooks_mod.HookType.fromString(args[3]) orelse {
                std.debug.print("Unknown hook type: {s}\n", .{args[3]});
                return;
            };
            hooks_mod.removeHook(allocator, io, ".", hook_type) catch |err| {
                if (err == error.HookNotFound) {
                    std.debug.print("Hook {s} not found\n", .{args[3]});
                } else return err;
            };
            std.debug.print("Removed {s} hook\n", .{args[3]});
        } else {
            std.debug.print("Unknown hook subcommand: {s}\n", .{args[2]});
        }
    } else if (std.mem.eql(u8, command, "tag")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }

        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            try tag_mod.listTags(allocator, io, &repo);
        } else if (std.mem.eql(u8, args[2], "-d") or std.mem.eql(u8, args[2], "--delete")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev tag -d <tag-name>\n", .{});
                return;
            }
            tag_mod.deleteTag(allocator, io, &repo, args[3]) catch |err| {
                if (err == error.TagNotFound) {
                    std.debug.print("Error: Tag '{s}' not found\n", .{args[3]});
                } else return err;
            };
            std.debug.print("Deleted tag '{s}'\n", .{args[3]});
        } else if (std.mem.eql(u8, args[2], "-a") or std.mem.eql(u8, args[2], "--annotate")) {
            if (args.len < 5) {
                std.debug.print("Usage: zev tag -a <tag-name> -m <message>\n", .{});
                return;
            }
            const tag_name = args[3];
            var msg: []const u8 = "Tagged version";
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "-m") and i + 1 < args.len) {
                    msg = args[i + 1];
                    break;
                }
            }
            const author = if (repo.config) |*cfg|
                try std.fmt.allocPrint(allocator, "{s} <{s}>", .{ cfg.user_name, cfg.user_email })
            else
                try allocator.dupe(u8, "Zev User <user@example.com>");
            defer allocator.free(author);
            try tag_mod.createAnnotatedTag(allocator, io, &repo, tag_name, msg, author);
            std.debug.print("Created annotated tag '{s}'\n", .{tag_name});
        } else {
            const tag_name = args[2];
            try tag_mod.createTag(allocator, io, &repo, tag_name);
            std.debug.print("Created tag '{s}'\n", .{tag_name});
        }
    } else if (std.mem.eql(u8, command, "stash")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3 or std.mem.eql(u8, args[2], "save")) {
            const msg = if (args.len >= 4) args[3] else null;
            try stash_mod.stashSave(allocator, io, &repo, msg);
        } else if (std.mem.eql(u8, args[2], "list")) {
            try stash_mod.stashList(allocator, io, &repo);
        } else if (std.mem.eql(u8, args[2], "apply")) {
            const id = if (args.len >= 4) try std.fmt.parseInt(usize, args[3], 10) else 0;
            stash_mod.stashApply(allocator, io, &repo, id) catch |err| {
                if (err == error.StashNotFound) {
                    std.debug.print("Stash@{{{}}} not found\n", .{id});
                } else return err;
            };
        } else if (std.mem.eql(u8, args[2], "pop")) {
            const id = if (args.len >= 4) try std.fmt.parseInt(usize, args[3], 10) else 0;
            stash_mod.stashApply(allocator, io, &repo, id) catch |err| {
                if (err == error.StashNotFound) {
                    std.debug.print("Stash@{{{}}} not found\n", .{id});
                    return;
                } else return err;
            };
            stash_mod.stashDrop(allocator, io, &repo, id) catch {};
        } else if (std.mem.eql(u8, args[2], "drop")) {
            const id = if (args.len >= 4) try std.fmt.parseInt(usize, args[3], 10) else 0;
            stash_mod.stashDrop(allocator, io, &repo, id) catch |err| {
                if (err == error.StashNotFound) {
                    std.debug.print("Stash@{{{}}} not found\n", .{id});
                } else return err;
            };
        } else {
            std.debug.print("Usage: zev stash [save|list|apply|pop|drop] [id]\n", .{});
        }
    } else if (std.mem.eql(u8, command, "bisect")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev bisect <start|good|bad|reset>\n", .{});
            std.debug.print("\nBinary search through commits to find a bug\n", .{});
            std.debug.print("  zev bisect start              Start bisect session\n", .{});
            std.debug.print("  zev bisect good [hash]        Mark commit as good\n", .{});
            std.debug.print("  zev bisect bad [hash]         Mark commit as bad\n", .{});
            std.debug.print("  zev bisect reset              End bisect session\n", .{});
            return;
        }
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (std.mem.eql(u8, args[2], "start")) {
            try bisect_mod.bisectStart(allocator, io, &repo);
        } else if (std.mem.eql(u8, args[2], "good")) {
            const hash = if (args.len >= 4) args[3] else null;
            try bisect_mod.bisectGood(allocator, io, &repo, hash);
        } else if (std.mem.eql(u8, args[2], "bad")) {
            const hash = if (args.len >= 4) args[3] else null;
            try bisect_mod.bisectBad(allocator, io, &repo, hash);
        } else if (std.mem.eql(u8, args[2], "reset")) {
            try bisect_mod.bisectReset(allocator, io, &repo);
        } else {
            std.debug.print("Unknown bisect subcommand: {s}\n", .{args[2]});
        }
    } else if (std.mem.eql(u8, command, "cherry-pick")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev cherry-pick <commit-hash>\n", .{});
            return;
        }
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        const hash_str = args[2];
        if (hash_str.len != 64) {
            std.debug.print("Error: Invalid commit hash (must be 64 hex chars)\n", .{});
            return;
        }
        var hash: [32]u8 = undefined;
        for (0..32) |idx| {
            const high = try std.fmt.charToDigit(hash_str[idx * 2], 16);
            const low = try std.fmt.charToDigit(hash_str[idx * 2 + 1], 16);
            hash[idx] = (high << 4) | low;
        }
        const pick_cid = cid.CID{ .hash = hash };
        const result = try cherrypick_mod.cherryPick(allocator, io, &repo, pick_cid);
        switch (result) {
            .success => {},
            .conflict => std.debug.print("❌ Cherry-pick failed\n", .{}),
            .already_applied => std.debug.print("ℹ️  Already applied\n", .{}),
        }
    } else if (std.mem.eql(u8, command, "blame")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev blame <file>\n", .{});
            std.debug.print("\nShows who last modified each line of a file\n", .{});
            return;
        }
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();
        try blame_mod.blame(allocator, io, &repo, args[2]);
    } else if (std.mem.eql(u8, command, "rebase")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev rebase <branch>\n", .{});
            std.debug.print("\nReplays commits from current branch on top of <branch>\n", .{});
            return;
        }
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        const onto = args[2];
        const result = try rebase_mod.rebase(allocator, io, &repo, onto);
        switch (result) {
            .success => {},
            .conflict => std.debug.print("❌ Rebase stopped due to conflicts\n", .{}),
            .nothing_to_rebase => {},
        }
    } else if (std.mem.eql(u8, command, "gc")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        const dry_run = args.len >= 3 and std.mem.eql(u8, args[2], "--dry-run");
        if (dry_run) std.debug.print("🔍 Dry run mode - no files will be deleted\n", .{});

        const result = try gc_mod.runGC(allocator, io, &repo, dry_run);

        std.debug.print("\n📊 Garbage Collection Results:\n", .{});
        std.debug.print("  Objects checked: {}\n", .{result.objects_checked});
        std.debug.print("  Objects removed: {}\n", .{result.objects_removed});
        std.debug.print("  Space freed: {} bytes\n", .{result.bytes_freed});
        if (result.objects_removed == 0) {
            std.debug.print("✅ Repository is clean, nothing to collect\n", .{});
        } else if (dry_run) {
            std.debug.print("💡 Run \'zev gc\' without --dry-run to actually remove objects\n", .{});
        } else {
            std.debug.print("✅ Garbage collection complete\n", .{});
        }
    } else if (std.mem.eql(u8, command, "ipld")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            std.debug.print("Usage: zev ipld <migrate|log>\n\n", .{});
            std.debug.print("Commands:\n", .{});
            std.debug.print("  zev ipld migrate   — convert all existing commits to IPLD nodes\n", .{});
            std.debug.print("  zev ipld log       — show commit history via IPLD DAG\n\n", .{});
            return;
        }
        const sub = args[2];
        if (std.mem.eql(u8, sub, "migrate")) {
            try ipld_commit.migrateCommitsToIPLD(allocator, io, &repo);
        } else if (std.mem.eql(u8, sub, "log")) {
            const max: usize = if (args.len > 3)
                std.fmt.parseInt(usize, args[3], 10) catch 20
            else
                20;
            try ipld_commit.ipldLog(allocator, io, &repo, max);
        } else {
            std.debug.print("Unknown ipld subcommand: {s}\n", .{sub});
        }
    } else if (std.mem.eql(u8, command, "dag")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            std.debug.print("Usage: zev dag <show|walk|put|stat>\n\n", .{});
            std.debug.print("Examples:\n", .{});
            std.debug.print("  zev dag show <cid>\n", .{});
            std.debug.print("  zev dag walk <cid> [--depth 3]\n", .{});
            std.debug.print("  zev dag put <file>\n", .{});
            std.debug.print("  zev dag stat\n\n", .{});
            return;
        }
        const sub = args[2];
        if (std.mem.eql(u8, sub, "show")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev dag show <cid>\n", .{});
                return;
            }
            try dag_mod.dagShow(allocator, io, &repo, args[3]);
        } else if (std.mem.eql(u8, sub, "walk")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev dag walk <cid> [--depth N]\n", .{});
                return;
            }
            var depth: usize = 3;
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--depth") and i + 1 < args.len) {
                    i += 1;
                    depth = std.fmt.parseInt(usize, args[i], 10) catch 3;
                }
            }
            try dag_mod.dagWalk(allocator, io, &repo, args[3], depth);
        } else if (std.mem.eql(u8, sub, "put")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev dag put <file>\n", .{});
                return;
            }
            try dag_mod.dagPut(allocator, io, &repo, args[3]);
        } else if (std.mem.eql(u8, sub, "stat")) {
            try dag_mod.dagStat(allocator, io, &repo);
        } else if (std.mem.eql(u8, sub, "auto")) {
            if (args.len >= 4) {
                try context_mod.contextAutoDetect(allocator, io, env_map, &repo, args[3]);
            } else {
                try context_mod.contextAutoDetectAll(allocator, io, env_map, &repo);
            }
        } else if (std.mem.eql(u8, sub, "export")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev dag export <HEAD|all|cid> --output <file.car> [--depth N] [--to-ipfs]\n", .{});
                return;
            }
            var output: []const u8 = "export.car";
            var depth: usize = 64;
            var to_ipfs = false;
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
                    i += 1;
                    output = args[i];
                } else if (std.mem.eql(u8, args[i], "--depth") and i + 1 < args.len) {
                    i += 1;
                    depth = std.fmt.parseInt(usize, args[i], 10) catch 64;
                } else if (std.mem.eql(u8, args[i], "--to-ipfs")) {
                    to_ipfs = true;
                }
            }
            try car_mod.dagExport(allocator, io, &repo, args[3], output, depth, to_ipfs);
        } else if (std.mem.eql(u8, sub, "import")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev dag import <file.car>\n", .{});
                return;
            }
            try car_mod.dagImport(allocator, io, &repo, args[3]);
        } else if (std.mem.eql(u8, sub, "get")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev dag get <cid> --output <path>\n\n", .{});
                return;
            }
            var out_path: ?[]const u8 = null;
            var gi: usize = 4;
            while (gi < args.len) : (gi += 1) {
                if (std.mem.eql(u8, args[gi], "--output") and gi + 1 < args.len) {
                    gi += 1;
                    out_path = args[gi];
                }
            }
            const op = out_path orelse {
                std.debug.print("Usage: zev dag get <cid> --output <path>\n\n", .{});
                return;
            };
            var ipld_store = try ipld.BlockStore.init(allocator, io, repo.path);
            defer ipld_store.deinit();
            const get_cid = ipld.CID.fromHex(args[3]) catch {
                std.debug.print("❌ Invalid CID: {s}\n\n", .{args[3]});
                return;
            };
            const block_data = ipld_store.get(io, get_cid) catch {
                std.debug.print("❌ Block not found: {s}\n\n", .{args[3]});
                return;
            };
            defer allocator.free(block_data);
            const out_file = try std.Io.Dir.cwd().createFile(io, op, .{});
            defer out_file.close(io);
            var out_buffer: [65536]u8 = undefined;
            var out_writer = out_file.writer(io, &out_buffer);
            try out_writer.interface.writeAll(block_data);
            try out_writer.flush();
            std.debug.print("✅ Extracted {d} bytes to {s}\n\n", .{ block_data.len, op });
        } else if (std.mem.eql(u8, sub, "query")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev dag query <query> [--format text|json|cids]\n\n", .{});
                std.debug.print("Examples:\n", .{});
                std.debug.print("  zev dag query all:graft\n", .{});
                std.debug.print("  zev dag query all:commit\n", .{});
                std.debug.print("  zev dag query all:metrics\n", .{});
                std.debug.print("  zev dag query all:metrics where accuracy>0.9\n", .{});
                std.debug.print("  zev dag query <cid>/author\n", .{});
                std.debug.print("  zev dag query all:graft --format json\n\n", .{});
                return;
            }
            var format: []const u8 = "text";
            var query_end: usize = args.len;
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--format") and i + 1 < args.len) {
                    query_end = i;
                    format = args[i + 1];
                    break;
                }
            }
            var qbuf: [512]u8 = undefined;
            var qlen: usize = 0;
            for (args[3..query_end], 0..) |arg, qi| {
                if (qi > 0) {
                    qbuf[qlen] = ' ';
                    qlen += 1;
                }
                @memcpy(qbuf[qlen .. qlen + arg.len], arg);
                qlen += arg.len;
            }
            try selector_mod.dagQuery(allocator, io, &repo, qbuf[0..qlen], format);
        } else {
            std.debug.print("Unknown dag subcommand: {s}\n", .{sub});
        }
    } else if (std.mem.eql(u8, command, "graft")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            std.debug.print("Usage: zev graft <cid> --as <alias> [--desc <desc>] [--fetch]\n", .{});
            std.debug.print("       zev graft list\n", .{});
            std.debug.print("       zev graft resolve <alias>\n\n", .{});
            std.debug.print("Examples:\n", .{});
            std.debug.print("  zev graft bafyreib3x7... --as dataset/imagenet-v2\n", .{});
            std.debug.print("  zev graft <cid> --as model/bert-base --fetch\n", .{});
            std.debug.print("  zev graft list\n", .{});
            std.debug.print("  zev graft resolve dataset/imagenet-v2\n\n", .{});
            return;
        }

        const sub = args[2];
        if (std.mem.eql(u8, sub, "list")) {
            try dag_mod.graftList(allocator, io, &repo);
        } else if (std.mem.eql(u8, sub, "resolve")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev graft resolve <alias>\n", .{});
                return;
            }
            try dag_mod.graftResolve(allocator, io, &repo, args[3]);
        } else {
            var alias: []const u8 = "unnamed";
            var desc: []const u8 = "";
            var fetch = false;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--as") and i + 1 < args.len) {
                    i += 1;
                    alias = args[i];
                } else if (std.mem.eql(u8, args[i], "--desc") and i + 1 < args.len) {
                    i += 1;
                    desc = args[i];
                } else if (std.mem.eql(u8, args[i], "--fetch")) {
                    fetch = true;
                }
            }
            try dag_mod.graftAdd(allocator, io, &repo, sub, alias, desc, fetch);
        }
    } else if (std.mem.eql(u8, command, "dataset")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            std.debug.print("Usage: zev dataset <register|split|assign|lineage|impact|list>\n\n", .{});
            std.debug.print("Examples:\n", .{});
            std.debug.print("  zev dataset register ./data.csv --name imagenet\n", .{});
            std.debug.print("  zev dataset split imagenet --shards 8 --strategy random\n", .{});
            std.debug.print("  zev dataset assign imagenet --shards 0,1,2,3\n", .{});
            std.debug.print("  zev dataset lineage imagenet\n", .{});
            std.debug.print("  zev dataset impact imagenet --shard 3\n", .{});
            std.debug.print("  zev dataset list\n\n", .{});
            return;
        }

        const sub = args[2];
        if (std.mem.eql(u8, sub, "register")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev dataset register <path> --name <name> [--desc <desc>]\n", .{});
                return;
            }
            var name: []const u8 = args[3];
            var desc: []const u8 = "";
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--name") and i + 1 < args.len) {
                    i += 1;
                    name = args[i];
                } else if (std.mem.eql(u8, args[i], "--desc") and i + 1 < args.len) {
                    i += 1;
                    desc = args[i];
                }
            }
            try dataset_mod.datasetRegister(allocator, io, &repo, args[3], name, desc);
        } else if (std.mem.eql(u8, sub, "split")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev dataset split <name> --shards <N> [--strategy sequential|random|stratified] [--seed <N>]\n", .{});
                return;
            }
            var num_shards: usize = 4;
            var strategy: []const u8 = "sequential";
            var seed: u64 = 42;
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--shards") and i + 1 < args.len) {
                    i += 1;
                    num_shards = std.fmt.parseInt(usize, args[i], 10) catch 4;
                } else if (std.mem.eql(u8, args[i], "--strategy") and i + 1 < args.len) {
                    i += 1;
                    strategy = args[i];
                } else if (std.mem.eql(u8, args[i], "--seed") and i + 1 < args.len) {
                    i += 1;
                    seed = std.fmt.parseInt(u64, args[i], 10) catch 42;
                }
            }
            try dataset_mod.datasetSplit(allocator, io, &repo, args[3], num_shards, strategy, seed);
        } else if (std.mem.eql(u8, sub, "assign")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev dataset assign <name> --shards <0,1,2,...> [--notes <notes>]\n", .{});
                return;
            }
            var shards_str: []const u8 = "";
            var notes: []const u8 = "";
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--shards") and i + 1 < args.len) {
                    i += 1;
                    shards_str = args[i];
                } else if (std.mem.eql(u8, args[i], "--notes") and i + 1 < args.len) {
                    i += 1;
                    notes = args[i];
                }
            }
            var shard_indices: std.ArrayList(usize) = .empty;
            defer shard_indices.deinit(allocator);
            var sit = std.mem.splitSequence(u8, shards_str, ",");
            while (sit.next()) |tok| {
                const idx = std.fmt.parseInt(usize, std.mem.trim(u8, tok, " "), 10) catch continue;
                try shard_indices.append(allocator, idx);
            }
            try dataset_mod.datasetAssign(allocator, io, &repo, args[3], shard_indices.items, notes);
        } else if (std.mem.eql(u8, sub, "lineage")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev dataset lineage <name>\n", .{});
                return;
            }
            try dataset_mod.datasetLineage(allocator, io, &repo, args[3]);
        } else if (std.mem.eql(u8, sub, "impact")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev dataset impact <name> --shard <N>\n", .{});
                return;
            }
            var shard_idx: usize = 0;
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--shard") and i + 1 < args.len) {
                    i += 1;
                    shard_idx = std.fmt.parseInt(usize, args[i], 10) catch 0;
                }
            }
            try dataset_mod.datasetImpact(allocator, io, &repo, args[3], shard_idx);
        } else if (std.mem.eql(u8, sub, "list")) {
            try dataset_mod.datasetList(allocator, io, &repo);
        } else {
            std.debug.print("Unknown dataset subcommand: {s}\n", .{sub});
        }
    } else if (std.mem.eql(u8, command, "context")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            std.debug.print("Usage: zev context <add|show|blame|stats|query|list>\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev context add model.py --model claude-3-5-sonnet\n", .{});
            std.debug.print("  zev context add train.py --model gpt-4o --prompt \"Write a training loop\"\n", .{});
            std.debug.print("  zev context add utils.py --model human --kind human\n", .{});
            std.debug.print("  zev context add model.py --model claude-3-5-sonnet --kind mixed --notes \"edited scheduler\"\n", .{});
            std.debug.print("  zev context show model.py\n", .{});
            std.debug.print("  zev context blame\n", .{});
            std.debug.print("  zev context stats\n", .{});
            std.debug.print("  zev context query --model claude\n", .{});
            std.debug.print("  zev context query --kind llm --prompt\n", .{});
            return;
        }

        const sub = args[2];
        if (std.mem.eql(u8, sub, "add")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev context add <file> --model <model> [--kind llm|human|mixed] [--prompt \"...\"" ++ "] [--notes \"...\"]\n", .{});
                return;
            }
            var model: []const u8 = "unknown";
            var prompt: ?[]const u8 = null;
            var notes: ?[]const u8 = null;
            var kind: []const u8 = "llm";
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--model") and i + 1 < args.len) {
                    i += 1;
                    model = args[i];
                } else if (std.mem.eql(u8, args[i], "--prompt") and i + 1 < args.len) {
                    i += 1;
                    prompt = args[i];
                } else if (std.mem.eql(u8, args[i], "--notes") and i + 1 < args.len) {
                    i += 1;
                    notes = args[i];
                } else if (std.mem.eql(u8, args[i], "--kind") and i + 1 < args.len) {
                    i += 1;
                    kind = args[i];
                } else if (std.mem.eql(u8, args[i], "--human")) {
                    kind = "human";
                    model = "human";
                } else if (std.mem.eql(u8, args[i], "--mixed")) {
                    kind = "mixed";
                }
            }
            try context_mod.contextAdd(allocator, io, &repo, args[3], model, prompt, notes, kind);
        } else if (std.mem.eql(u8, sub, "show")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev context show <file>\n", .{});
                return;
            }
            try context_mod.contextShow(allocator, io, &repo, args[3]);
        } else if (std.mem.eql(u8, sub, "blame")) {
            try context_mod.contextBlame(allocator, io, &repo);
        } else if (std.mem.eql(u8, sub, "stats")) {
            try context_mod.contextStats(allocator, io, &repo);
        } else if (std.mem.eql(u8, sub, "list")) {
            try context_mod.contextList(allocator, io, &repo);
        } else if (std.mem.eql(u8, sub, "auto")) {
            if (args.len >= 4) {
                try context_mod.contextAutoDetect(allocator, io, env_map, &repo, args[3]);
            } else {
                try context_mod.contextAutoDetectAll(allocator, io, env_map, &repo);
            }
        } else if (std.mem.eql(u8, sub, "export")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev dag export <HEAD|all|cid> --output <file.car> [--depth N] [--to-ipfs]\n", .{});
                return;
            }
            var output: []const u8 = "export.car";
            var depth: usize = 64;
            var to_ipfs = false;
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
                    i += 1;
                    output = args[i];
                } else if (std.mem.eql(u8, args[i], "--depth") and i + 1 < args.len) {
                    i += 1;
                    depth = std.fmt.parseInt(usize, args[i], 10) catch 64;
                } else if (std.mem.eql(u8, args[i], "--to-ipfs")) {
                    to_ipfs = true;
                }
            }
            try car_mod.dagExport(allocator, io, &repo, args[3], output, depth, to_ipfs);
        } else if (std.mem.eql(u8, sub, "import")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev dag import <file.car>\n", .{});
                return;
            }
            try car_mod.dagImport(allocator, io, &repo, args[3]);
        } else if (std.mem.eql(u8, sub, "get")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev dag get <cid> --output <path>\n\n", .{});
                return;
            }
            var out_path: ?[]const u8 = null;
            var gi: usize = 4;
            while (gi < args.len) : (gi += 1) {
                if (std.mem.eql(u8, args[gi], "--output") and gi + 1 < args.len) {
                    gi += 1;
                    out_path = args[gi];
                }
            }
            const op = out_path orelse {
                std.debug.print("Usage: zev dag get <cid> --output <path>\n\n", .{});
                return;
            };
            var ipld_store = try ipld.BlockStore.init(allocator, io, repo.path);
            defer ipld_store.deinit();
            const get_cid = ipld.CID.fromHex(args[3]) catch {
                std.debug.print("❌ Invalid CID: {s}\n\n", .{args[3]});
                return;
            };
            const block_data = ipld_store.get(io, get_cid) catch {
                std.debug.print("❌ Block not found: {s}\n\n", .{args[3]});
                return;
            };
            defer allocator.free(block_data);
            const out_file = try std.Io.Dir.cwd().createFile(io, op, .{});
            defer out_file.close(io);
            var out_buffer: [65536]u8 = undefined;
            var out_writer = out_file.writer(io, &out_buffer);
            try out_writer.interface.writeAll(block_data);
            try out_writer.flush();
            std.debug.print("✅ Extracted {d} bytes to {s}\n\n", .{ block_data.len, op });
        } else if (std.mem.eql(u8, sub, "query")) {
            var model_filter: ?[]const u8 = null;
            var kind_filter: ?[]const u8 = null;
            var show_prompt = false;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--model") and i + 1 < args.len) {
                    i += 1;
                    model_filter = args[i];
                } else if (std.mem.eql(u8, args[i], "--kind") and i + 1 < args.len) {
                    i += 1;
                    kind_filter = args[i];
                } else if (std.mem.eql(u8, args[i], "--prompt")) {
                    show_prompt = true;
                }
            }
            try context_mod.contextQuery(allocator, io, &repo, model_filter, kind_filter, show_prompt);
        } else {
            std.debug.print("Unknown context subcommand: {s}\n", .{sub});
        }
    } else if (std.mem.eql(u8, command, "audit")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();
        var filter_snapshot: ?[]const u8 = null;
        var format: []const u8 = "terminal";
        var output_path: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--snapshot") and i + 1 < args.len) {
                i += 1;
                filter_snapshot = args[i];
            } else if (std.mem.eql(u8, args[i], "--format") and i + 1 < args.len) {
                i += 1;
                format = args[i];
            } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
                i += 1;
                output_path = args[i];
            } else if (std.mem.eql(u8, args[i], "--md")) {
                format = "md";
            } else if (std.mem.eql(u8, args[i], "--json")) {
                format = "json";
            }
        }
        try audit_mod.runAudit(allocator, io, &repo, filter_snapshot, format, output_path);
    } else if (std.mem.eql(u8, command, "export")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev export <output.zev-archive> [options]\n", .{});
            std.debug.print("\nOptions:\n", .{});
            std.debug.print("  --snapshot <name>   export only that snapshot\n", .{});
            std.debug.print("  --since <hash>      incremental export from commit\n", .{});
            std.debug.print("  --no-objects        skip blob objects (metadata only)\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev export repo.zev-archive\n", .{});
            std.debug.print("  zev export snap.zev-archive --snapshot v1.0\n", .{});
            std.debug.print("  zev export meta.zev-archive --no-objects\n", .{});
            return;
        }
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();
        var snapshot_filter: ?[]const u8 = null;
        var since_hash: ?[]const u8 = null;
        var include_objects = true;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--snapshot") and i + 1 < args.len) {
                i += 1;
                snapshot_filter = args[i];
            } else if (std.mem.eql(u8, args[i], "--since") and i + 1 < args.len) {
                i += 1;
                since_hash = args[i];
            } else if (std.mem.eql(u8, args[i], "--no-objects")) {
                include_objects = false;
            }
        }
        try export_mod.exportRepo(allocator, io, &repo, args[2], snapshot_filter, since_hash, include_objects);
    } else if (std.mem.eql(u8, command, "import")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev import <archive.zev-archive> [target-dir] [--dry-run]\n", .{});
            return;
        }
        var target_dir: []const u8 = ".";
        var dry_run = false;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--dry-run")) {
                dry_run = true;
            } else if (args[i][0] != '-') {
                target_dir = args[i];
            }
        }
        try export_mod.importArchive(allocator, io, args[2], target_dir, dry_run);
    } else if (std.mem.eql(u8, command, "archive-info")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev archive-info <archive.zev-archive>\n", .{});
            return;
        }
        try export_mod.archiveInfo(allocator, io, args[2]);
    } else if (std.mem.eql(u8, command, "reproduce")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            std.debug.print("Usage: zev reproduce <snapshot|commit|HEAD|status|capture>\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev reproduce capture \"python train.py\"\n", .{});
            std.debug.print("  zev reproduce v1.0\n", .{});
            std.debug.print("  zev reproduce HEAD --cmd \"python train.py\"\n", .{});
            std.debug.print("  zev reproduce v1.0 --tolerance 0.02 --dry-run\n", .{});
            std.debug.print("  zev reproduce status\n", .{});
            return;
        }

        const sub = args[2];
        if (std.mem.eql(u8, sub, "status")) {
            var limit: usize = 20;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--limit") and i + 1 < args.len) {
                    i += 1;
                    limit = std.fmt.parseInt(usize, args[i], 10) catch 20;
                }
            }
            try reproduce_mod.reproduceStatus(allocator, io, &repo, limit);
        } else if (std.mem.eql(u8, sub, "capture")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev reproduce capture \"<command>\"\n", .{});
                return;
            }
            var env_file: ?[]const u8 = null;
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--env") and i + 1 < args.len) {
                    i += 1;
                    env_file = args[i];
                }
            }
            try reproduce_mod.capturePub(io, allocator, &repo, args[3], env_file);
        } else {
            var tolerance: f64 = 0.01;
            var run_cmd: ?[]const u8 = null;
            var dry_run = false;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--tolerance") and i + 1 < args.len) {
                    i += 1;
                    tolerance = std.fmt.parseFloat(f64, args[i]) catch 0.01;
                } else if (std.mem.eql(u8, args[i], "--cmd") and i + 1 < args.len) {
                    i += 1;
                    run_cmd = args[i];
                } else if (std.mem.eql(u8, args[i], "--dry-run")) {
                    dry_run = true;
                }
            }
            if (std.mem.eql(u8, sub, "HEAD") or sub.len == 64) {
                try reproduce_mod.reproduceCommit(allocator, io, &repo, sub, tolerance, run_cmd, dry_run);
            } else {
                try reproduce_mod.reproduceSnapshot(io, allocator, &repo, sub, tolerance, run_cmd, dry_run);
            }
        }
    } else if (std.mem.eql(u8, command, "drift")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            std.debug.print("Usage: zev drift <baseline|check|config|show|history|watch>\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev drift baseline v1.0\n", .{});
            std.debug.print("  zev drift config --metric accuracy --delta 0.05 --direction hib\n", .{});
            std.debug.print("  zev drift config --metric loss --delta 0.1 --direction lib\n", .{});
            std.debug.print("  zev drift check\n", .{});
            std.debug.print("  zev drift show\n", .{});
            std.debug.print("  zev drift history\n", .{});
            std.debug.print("  zev drift watch --interval 60\n", .{});
            return;
        }

        const sub = args[2];
        if (std.mem.eql(u8, sub, "baseline")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev drift baseline <snapshot-name-or-commit-hash>\n", .{});
                return;
            }
            try drift_mod.driftBaseline(allocator, io, &repo, args[3]);
        } else if (std.mem.eql(u8, sub, "config")) {
            var metric: []const u8 = "";
            var max_delta: f64 = 0.05;
            var max_pct: f64 = 0;
            var direction: []const u8 = "any";
            var webhook: ?[]const u8 = null;
            var watch_interval: ?u32 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--metric") and i + 1 < args.len) {
                    i += 1;
                    metric = args[i];
                } else if (std.mem.eql(u8, args[i], "--delta") and i + 1 < args.len) {
                    i += 1;
                    max_delta = std.fmt.parseFloat(f64, args[i]) catch 0.05;
                } else if (std.mem.eql(u8, args[i], "--pct") and i + 1 < args.len) {
                    i += 1;
                    max_pct = std.fmt.parseFloat(f64, args[i]) catch 0;
                } else if (std.mem.eql(u8, args[i], "--direction") and i + 1 < args.len) {
                    i += 1;
                    direction = args[i];
                } else if (std.mem.eql(u8, args[i], "--webhook") and i + 1 < args.len) {
                    i += 1;
                    webhook = args[i];
                } else if (std.mem.eql(u8, args[i], "--interval") and i + 1 < args.len) {
                    i += 1;
                    watch_interval = std.fmt.parseInt(u32, args[i], 10) catch 300;
                }
            }
            if (metric.len == 0) {
                std.debug.print("Usage: zev drift config --metric <name> --delta <value> --direction <hib|lib|any>\n", .{});
                return;
            }
            try drift_mod.driftConfig(allocator, io, &repo, metric, max_delta, max_pct, direction, webhook, watch_interval);
        } else if (std.mem.eql(u8, sub, "check")) {
            var baseline_override: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--baseline") and i + 1 < args.len) {
                    i += 1;
                    baseline_override = args[i];
                }
            }
            try drift_mod.driftCheck(allocator, io, &repo, baseline_override);
        } else if (std.mem.eql(u8, sub, "show")) {
            try drift_mod.driftShow(io, allocator, &repo);
        } else if (std.mem.eql(u8, sub, "history")) {
            var limit: usize = 20;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--limit") and i + 1 < args.len) {
                    i += 1;
                    limit = std.fmt.parseInt(usize, args[i], 10) catch 20;
                }
            }
            try drift_mod.driftHistory(allocator, io, &repo, limit);
        } else if (std.mem.eql(u8, sub, "watch")) {
            var interval: u32 = 0;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--interval") and i + 1 < args.len) {
                    i += 1;
                    interval = std.fmt.parseInt(u32, args[i], 10) catch 0;
                }
            }
            try drift_mod.driftWatch(allocator, io, &repo, interval);
        } else {
            std.debug.print("Unknown drift subcommand: {s}\n", .{sub});
        }
    } else if (std.mem.eql(u8, command, "notarize")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            std.debug.print("Usage: zev notarize <snapshot|commit|verify|list|config>\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev notarize snapshot v1.0\n", .{});
            std.debug.print("  zev notarize snapshot v1.0 --chain ethereum\n", .{});
            std.debug.print("  zev notarize snapshot v1.0 --dry-run\n", .{});
            std.debug.print("  zev notarize commit\n", .{});
            std.debug.print("  zev notarize list\n", .{});
            std.debug.print("  zev notarize verify <record-id-prefix>\n", .{});
            std.debug.print("  zev notarize config --chain ethereum --rpc https://mainnet.infura.io/v3/KEY\n", .{});
            return;
        }

        const sub = args[2];
        if (std.mem.eql(u8, sub, "snapshot")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev notarize snapshot <name> [--chain local|ethereum|arweave] [--dry-run]\n", .{});
                return;
            }
            var chain: []const u8 = "local";
            var dry_run = false;
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--chain") and i + 1 < args.len) {
                    i += 1;
                    chain = args[i];
                } else if (std.mem.eql(u8, args[i], "--dry-run")) {
                    dry_run = true;
                }
            }
            try notarize_mod.notarizeSnapshot(allocator, io, &repo, args[3], chain, dry_run);
        } else if (std.mem.eql(u8, sub, "commit")) {
            var chain: []const u8 = "local";
            var dry_run = false;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--chain") and i + 1 < args.len) {
                    i += 1;
                    chain = args[i];
                } else if (std.mem.eql(u8, args[i], "--dry-run")) {
                    dry_run = true;
                }
            }
            try notarize_mod.notarizeCommit(allocator, io, &repo, chain, dry_run);
        } else if (std.mem.eql(u8, sub, "verify")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev notarize verify <record-id-prefix>\n", .{});
                return;
            }
            try notarize_mod.notarizeVerify(allocator, io, &repo, args[3]);
        } else if (std.mem.eql(u8, sub, "list")) {
            try notarize_mod.notarizeList(allocator, io, &repo);
        } else if (std.mem.eql(u8, sub, "config")) {
            var chain: []const u8 = "ethereum";
            var rpc_url: ?[]const u8 = null;
            var private_key: ?[]const u8 = null;
            var from_addr: ?[]const u8 = null;
            var keyfile: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--chain") and i + 1 < args.len) {
                    i += 1;
                    chain = args[i];
                } else if (std.mem.eql(u8, args[i], "--rpc") and i + 1 < args.len) {
                    i += 1;
                    rpc_url = args[i];
                } else if (std.mem.eql(u8, args[i], "--key") and i + 1 < args.len) {
                    i += 1;
                    private_key = args[i];
                } else if (std.mem.eql(u8, args[i], "--from") and i + 1 < args.len) {
                    i += 1;
                    from_addr = args[i];
                } else if (std.mem.eql(u8, args[i], "--keyfile") and i + 1 < args.len) {
                    i += 1;
                    keyfile = args[i];
                }
            }
            try notarize_mod.notarizeConfig(allocator, io, &repo, chain, rpc_url, private_key, from_addr, keyfile);
        } else {
            std.debug.print("Unknown notarize subcommand: {s}\n", .{sub});
        }
    } else if (std.mem.eql(u8, command, "peer")) {
        if (args.len < 3) {
            std.debug.print("Usage: zev peer <announce|listen|sync|connect|status>\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev peer status\n", .{});
            std.debug.print("  zev peer announce\n", .{});
            std.debug.print("  zev peer announce --topic my-project\n", .{});
            std.debug.print("  zev peer listen --topic my-project\n", .{});
            std.debug.print("  zev peer connect /ip4/1.2.3.4/tcp/4001/p2p/<peerID>\n", .{});
            std.debug.print("  zev peer sync <meta-cid>\n", .{});
            return;
        }
        const sub = args[2];
        if (std.mem.eql(u8, sub, "status")) {
            if (!repository.Repository.exists(allocator, io, ".")) {
                std.debug.print("Not a zev repository.\n", .{});
                return;
            }
            var repo = try repository.Repository.open(allocator, io, ".");
            defer repo.deinit();
            try peer_mod.peerStatus(allocator, io, &repo);
        } else if (std.mem.eql(u8, sub, "announce")) {
            if (!repository.Repository.exists(allocator, io, ".")) {
                std.debug.print("Not a zev repository.\n", .{});
                return;
            }
            var repo = try repository.Repository.open(allocator, io, ".");
            defer repo.deinit();
            var topic: []const u8 = "zev-repos";
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--topic") and i + 1 < args.len) {
                    i += 1;
                    topic = args[i];
                }
            }
            try peer_mod.peerAnnounce(allocator, io, &repo, topic);
        } else if (std.mem.eql(u8, sub, "listen")) {
            if (!repository.Repository.exists(allocator, io, ".")) {
                std.debug.print("Not a zev repository.\n", .{});
                return;
            }
            var repo = try repository.Repository.open(allocator, io, ".");
            defer repo.deinit();
            var topic: []const u8 = "zev-repos";
            var timeout: u32 = 30;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--topic") and i + 1 < args.len) {
                    i += 1;
                    topic = args[i];
                } else if (std.mem.eql(u8, args[i], "--timeout") and i + 1 < args.len) {
                    i += 1;
                    timeout = std.fmt.parseInt(u32, args[i], 10) catch 30;
                }
            }
            try peer_mod.peerListen(allocator, io, &repo, topic, timeout);
        } else if (std.mem.eql(u8, sub, "connect")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev peer connect <multiaddr>\n", .{});
                return;
            }
            try peer_mod.peerConnect(allocator, io, args[3]);
        } else if (std.mem.eql(u8, sub, "sync")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev peer sync <meta-cid>\n", .{});
                return;
            }
            if (!repository.Repository.exists(allocator, io, ".")) {
                std.debug.print("Not a zev repository.\n", .{});
                return;
            }
            var repo = try repository.Repository.open(allocator, io, ".");
            defer repo.deinit();
            try peer_mod.peerSync(allocator, io, &repo, args[3]);
        } else {
            std.debug.print("Unknown peer subcommand: {s}\n", .{sub});
        }
    } else if (std.mem.eql(u8, command, "fork")) {
        if (args.len < 4) {
            std.debug.print("Usage: zev fork <meta-cid> <target-directory>\n", .{});
            std.debug.print("\nExample:\n", .{});
            std.debug.print("  zev fork QmXxx... my-forked-repo\n", .{});
            return;
        }
        try peer_mod.forkRepo(allocator, io, args[2], args[3]);
    } else if (std.mem.eql(u8, command, "compare")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 5) {
            std.debug.print("Usage: zev compare <commits|experiments|snapshots|branches> <a> <b>\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev compare commits <hash-a> <hash-b>\n", .{});
            std.debug.print("  zev compare experiments resnet50 vgg16\n", .{});
            std.debug.print("  zev compare snapshots v1.0 v2.0\n", .{});
            std.debug.print("  zev compare branches main exp/resnet50\n", .{});
            return;
        }

        const sub = args[2];
        if (std.mem.eql(u8, sub, "commits")) {
            try compare_mod.compareCommits(allocator, io, &repo, args[3], args[4]);
        } else if (std.mem.eql(u8, sub, "experiments")) {
            try compare_mod.compareExperiments(allocator, io, &repo, args[3], args[4]);
        } else if (std.mem.eql(u8, sub, "snapshots")) {
            try compare_mod.compareSnapshots(allocator, io, &repo, args[3], args[4]);
        } else if (std.mem.eql(u8, sub, "branches")) {
            try compare_mod.compareBranches(allocator, io, &repo, args[3], args[4]);
        } else {
            std.debug.print("Unknown compare subcommand: {s}\n", .{sub});
        }
    } else if (std.mem.eql(u8, command, "search")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            std.debug.print("Usage: zev search <commits|experiments|metrics|lineage|snapshots|all> [query]\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev search commits \"resnet\"\n", .{});
            std.debug.print("  zev search experiments \"resnet\" --status completed\n", .{});
            std.debug.print("  zev search metrics \"accuracy>0.9\"\n", .{});
            std.debug.print("  zev search metrics \"loss<0.3\"\n", .{});
            std.debug.print("  zev search lineage \"imagenet\" --type dataset\n", .{});
            std.debug.print("  zev search snapshots \"v1\" --permanent\n", .{});
            std.debug.print("  zev search all \"resnet\"\n", .{});
            return;
        }

        const sub = args[2];
        if (std.mem.eql(u8, sub, "commits")) {
            const query = if (args.len >= 4) args[3] else "";
            var limit: usize = 20;
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--limit") and i + 1 < args.len) {
                    i += 1;
                    limit = std.fmt.parseInt(usize, args[i], 10) catch 20;
                }
            }
            try search_mod.searchCommits(allocator, io, &repo, query, limit);
        } else if (std.mem.eql(u8, sub, "experiments")) {
            const query = if (args.len >= 4) args[3] else "";
            var status_filter: []const u8 = "";
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--status") and i + 1 < args.len) {
                    i += 1;
                    status_filter = args[i];
                }
            }
            try search_mod.searchExperiments(allocator, io, &repo, query, status_filter);
        } else if (std.mem.eql(u8, sub, "metrics")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev search metrics <filter>\n", .{});
                std.debug.print("Examples: accuracy>0.9   loss<0.3   epochs>=50\n", .{});
                return;
            }
            try search_mod.searchMetrics(allocator, io, &repo, args[3]);
        } else if (std.mem.eql(u8, sub, "lineage")) {
            const query = if (args.len >= 4) args[3] else "";
            var type_filter: []const u8 = "";
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--type") and i + 1 < args.len) {
                    i += 1;
                    type_filter = args[i];
                }
            }
            try search_mod.searchLineage(allocator, io, &repo, query, type_filter);
        } else if (std.mem.eql(u8, sub, "snapshots")) {
            const query = if (args.len >= 4) args[3] else "";
            var permanent_only = false;
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--permanent")) permanent_only = true;
            }
            try search_mod.searchSnapshots(allocator, io, &repo, query, permanent_only);
        } else if (std.mem.eql(u8, sub, "all")) {
            const query = if (args.len >= 4) args[3] else "";
            try search_mod.searchAll(io, allocator, &repo, query);
        } else {
            std.debug.print("Unknown search subcommand: {s}\n", .{sub});
        }
    } else if (std.mem.eql(u8, command, "publish")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            std.debug.print("Usage: zev publish <commit|experiment|snapshot|config>\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev publish config --endpoint https://yourplatform.com/api/zev\n", .{});
            std.debug.print("  zev publish config --token YOUR_TOKEN --username yourname\n", .{});
            std.debug.print("  zev publish commit --tags \"cv,resnet\" --note \"First public run\"\n", .{});
            std.debug.print("  zev publish commit --dry-run\n", .{});
            std.debug.print("  zev publish experiment resnet50\n", .{});
            std.debug.print("  zev publish snapshot v2.0\n", .{});
            return;
        }

        const sub = args[2];
        if (std.mem.eql(u8, sub, "config")) {
            var endpoint: ?[]const u8 = null;
            var token: ?[]const u8 = null;
            var username: ?[]const u8 = null;
            var show_config = true;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--endpoint") and i + 1 < args.len) {
                    i += 1;
                    endpoint = args[i];
                    show_config = false;
                } else if (std.mem.eql(u8, args[i], "--token") and i + 1 < args.len) {
                    i += 1;
                    token = args[i];
                    show_config = false;
                } else if (std.mem.eql(u8, args[i], "--username") and i + 1 < args.len) {
                    i += 1;
                    username = args[i];
                    show_config = false;
                }
            }
            if (show_config) {
                try publish_mod.publishConfigShow(allocator, io, &repo);
            } else {
                try publish_mod.publishConfig(allocator, io, &repo, endpoint, token, username);
            }
        } else if (std.mem.eql(u8, sub, "commit")) {
            var tags: []const u8 = "";
            var note: []const u8 = "";
            var dry_run = false;
            var repo_name: []const u8 = "my-repo";
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--tags") and i + 1 < args.len) {
                    i += 1;
                    tags = args[i];
                } else if (std.mem.eql(u8, args[i], "--note") and i + 1 < args.len) {
                    i += 1;
                    note = args[i];
                } else if (std.mem.eql(u8, args[i], "--repo") and i + 1 < args.len) {
                    i += 1;
                    repo_name = args[i];
                } else if (std.mem.eql(u8, args[i], "--dry-run")) {
                    dry_run = true;
                }
            }
            try publish_mod.publishCommit(allocator, io, &repo, tags, note, dry_run, repo_name);
        } else if (std.mem.eql(u8, sub, "experiment")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev publish experiment <name> [--dry-run] [--repo name]\n", .{});
                return;
            }
            var dry_run = false;
            var repo_name: []const u8 = "my-repo";
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--dry-run")) {
                    dry_run = true;
                } else if (std.mem.eql(u8, args[i], "--repo") and i + 1 < args.len) {
                    i += 1;
                    repo_name = args[i];
                }
            }
            try publish_mod.publishExperiment(allocator, io, &repo, args[3], dry_run, repo_name);
        } else if (std.mem.eql(u8, sub, "snapshot")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev publish snapshot <name> [--dry-run] [--repo name]\n", .{});
                return;
            }
            var dry_run = false;
            var repo_name: []const u8 = "my-repo";
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--dry-run")) {
                    dry_run = true;
                } else if (std.mem.eql(u8, args[i], "--repo") and i + 1 < args.len) {
                    i += 1;
                    repo_name = args[i];
                }
            }
            try publish_mod.publishSnapshot(allocator, io, &repo, args[3], dry_run, repo_name);
        } else {
            std.debug.print("Unknown publish subcommand: {s}\n", .{sub});
        }
    } else if (std.mem.eql(u8, command, "snapshot")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            std.debug.print("Usage: zev snapshot <create|list|show|restore|diff>\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev snapshot create v1.0 \"First stable model\"\n", .{});
            std.debug.print("  zev snapshot create v1.0 \"Release\" --permanent\n", .{});
            std.debug.print("  zev snapshot list\n", .{});
            std.debug.print("  zev snapshot show v1.0\n", .{});
            std.debug.print("  zev snapshot restore v1.0\n", .{});
            std.debug.print("  zev snapshot diff v1.0 v2.0\n", .{});
            return;
        }

        const sub = args[2];
        if (std.mem.eql(u8, sub, "create")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev snapshot create <name> [description] [--tags t] [--experiment e] [--lineage l] [--permanent]\n", .{});
                return;
            }
            const snap_name = args[3];
            var desc: []const u8 = "";
            var tags: []const u8 = "";
            var experiment_ref: []const u8 = "";
            var lineage_refs: []const u8 = "";
            var permanent = false;
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--tags") and i + 1 < args.len) {
                    i += 1;
                    tags = args[i];
                } else if (std.mem.eql(u8, args[i], "--experiment") and i + 1 < args.len) {
                    i += 1;
                    experiment_ref = args[i];
                } else if (std.mem.eql(u8, args[i], "--lineage") and i + 1 < args.len) {
                    i += 1;
                    lineage_refs = args[i];
                } else if (std.mem.eql(u8, args[i], "--permanent")) {
                    permanent = true;
                } else if (desc.len == 0 and !std.mem.startsWith(u8, args[i], "--")) {
                    desc = args[i];
                }
            }
            try snapshot_mod.snapshotCreate(allocator, io, &repo, snap_name, desc, tags, experiment_ref, lineage_refs, permanent);
        } else if (std.mem.eql(u8, sub, "list")) {
            try snapshot_mod.snapshotList(allocator, io, &repo);
        } else if (std.mem.eql(u8, sub, "show")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev snapshot show <name>\n", .{});
                return;
            }
            try snapshot_mod.snapshotShow(io, allocator, &repo, args[3]);
        } else if (std.mem.eql(u8, sub, "restore")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev snapshot restore <name>\n", .{});
                return;
            }
            try snapshot_mod.snapshotRestore(io, allocator, &repo, args[3]);
        } else if (std.mem.eql(u8, sub, "diff")) {
            if (args.len < 5) {
                std.debug.print("Usage: zev snapshot diff <name-a> <name-b>\n", .{});
                return;
            }
            try snapshot_mod.snapshotDiff(io, allocator, &repo, args[3], args[4]);
        } else {
            std.debug.print("Unknown snapshot subcommand: {s}\n", .{sub});
        }
    } else if (std.mem.eql(u8, command, "lineage")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            std.debug.print("Usage: zev lineage <add|link|show|list|graph|provenance>\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev lineage add raw_data dataset \"ImageNet 50k subset\"\n", .{});
            std.debug.print("  zev lineage add clean_data dataset \"Cleaned dataset\" --file data.csv\n", .{});
            std.debug.print("  zev lineage add train_script script \"Training pipeline\" --file train.py\n", .{});
            std.debug.print("  zev lineage add resnet50_v1 model \"First ResNet50 run\"\n", .{});
            std.debug.print("  zev lineage link clean_data raw_data\n", .{});
            std.debug.print("  zev lineage link resnet50_v1 clean_data\n", .{});
            std.debug.print("  zev lineage link resnet50_v1 train_script\n", .{});
            std.debug.print("  zev lineage show resnet50_v1\n", .{});
            std.debug.print("  zev lineage graph\n", .{});
            return;
        }

        const sub = args[2];
        if (std.mem.eql(u8, sub, "add")) {
            if (args.len < 6) {
                std.debug.print("Usage: zev lineage add <id> <type> <description> [--file <path>] [--tags <tags>] [--version <v>]\n", .{});
                std.debug.print("Types: dataset, script, model, experiment, artifact\n", .{});
                return;
            }
            const id = args[3];
            const node_type = args[4];
            const desc = args[5];
            var file_path: ?[]const u8 = null;
            var tags: []const u8 = "";
            var version: []const u8 = "1.0";
            var i: usize = 6;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--file") and i + 1 < args.len) {
                    i += 1;
                    file_path = args[i];
                } else if (std.mem.eql(u8, args[i], "--tags") and i + 1 < args.len) {
                    i += 1;
                    tags = args[i];
                } else if (std.mem.eql(u8, args[i], "--version") and i + 1 < args.len) {
                    i += 1;
                    version = args[i];
                }
            }
            try lineage_mod.lineageAdd(allocator, io, &repo, id, node_type, desc, file_path, tags, version);
        } else if (std.mem.eql(u8, sub, "link")) {
            if (args.len < 5) {
                std.debug.print("Usage: zev lineage link <child> <parent>\n", .{});
                std.debug.print("  Means: <child> was derived from <parent>\n", .{});
                return;
            }
            try lineage_mod.lineageLink(allocator, io, &repo, args[3], args[4]);
        } else if (std.mem.eql(u8, sub, "show")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev lineage show <id>\n", .{});
                return;
            }
            try lineage_mod.lineageShow(io, allocator, &repo, args[3]);
        } else if (std.mem.eql(u8, sub, "list")) {
            try lineage_mod.lineageList(allocator, io, &repo);
        } else if (std.mem.eql(u8, sub, "graph")) {
            try lineage_mod.lineageGraph(allocator, io, &repo);
        } else if (std.mem.eql(u8, sub, "provenance")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev lineage provenance <cid-prefix>\n", .{});
                return;
            }
            try lineage_mod.lineageProvenance(allocator, io, &repo, args[3]);
        } else {
            std.debug.print("Unknown lineage subcommand: {s}\n", .{sub});
        }
    } else if (std.mem.eql(u8, command, "experiment")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            std.debug.print("Usage: zev experiment <start|list|show|complete|abandon|compare>\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev experiment start resnet50 \"Test ResNet50 architecture\"\n", .{});
            std.debug.print("  zev experiment list\n", .{});
            std.debug.print("  zev experiment show resnet50\n", .{});
            std.debug.print("  zev experiment complete resnet50 \"Achieved 94%% accuracy\"\n", .{});
            std.debug.print("  zev experiment abandon resnet50 \"Overfitting too severe\"\n", .{});
            std.debug.print("  zev experiment compare resnet50 vgg16\n", .{});
            return;
        }

        const sub = args[2];
        if (std.mem.eql(u8, sub, "start")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev experiment start <name> [description] [hypothesis] [tags]\n", .{});
                return;
            }
            const name = args[3];
            const description = if (args.len >= 5) args[4] else "";
            const hypothesis = if (args.len >= 6) args[5] else "";
            const tags = if (args.len >= 7) args[6] else "";
            try experiment_mod.experimentStart(allocator, io, &repo, name, description, hypothesis, tags);
        } else if (std.mem.eql(u8, sub, "list")) {
            try experiment_mod.experimentList(allocator, io, &repo);
        } else if (std.mem.eql(u8, sub, "show")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev experiment show <name>\n", .{});
                return;
            }
            try experiment_mod.experimentShow(allocator, io, &repo, args[3]);
        } else if (std.mem.eql(u8, sub, "complete")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev experiment complete <name> [notes]\n", .{});
                return;
            }
            const notes = if (args.len >= 5) args[4] else "";
            try experiment_mod.experimentComplete(allocator, io, &repo, args[3], notes);
        } else if (std.mem.eql(u8, sub, "abandon")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev experiment abandon <name> [reason]\n", .{});
                return;
            }
            const reason = if (args.len >= 5) args[4] else "";
            try experiment_mod.experimentAbandon(allocator, io, &repo, args[3], reason);
        } else if (std.mem.eql(u8, sub, "compare")) {
            if (args.len < 5) {
                std.debug.print("Usage: zev experiment compare <name-a> <name-b>\n", .{});
                return;
            }
            try experiment_mod.experimentCompare(allocator, io, &repo, args[3], args[4]);
        } else {
            std.debug.print("Unknown experiment subcommand: {s}\n", .{sub});
        }
    } else if (std.mem.eql(u8, command, "metrics")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 3) {
            std.debug.print("Usage: zev metrics <set|show|list|compare>\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev metrics set accuracy 0.9842\n", .{});
            std.debug.print("  zev metrics set loss 0.0341\n", .{});
            std.debug.print("  zev metrics set dataset_size 50000\n", .{});
            std.debug.print("  zev metrics show\n", .{});
            std.debug.print("  zev metrics show <commit-hash>\n", .{});
            std.debug.print("  zev metrics list\n", .{});
            std.debug.print("  zev metrics compare <hash-a> <hash-b>\n", .{});
            return;
        }

        const sub = args[2];
        if (std.mem.eql(u8, sub, "set")) {
            if (args.len < 5) {
                std.debug.print("Usage: zev metrics set <key> <value>\n", .{});
                return;
            }
            try metrics_mod.setMetric(allocator, io, &repo, args[3], args[4]);
            {
                const mval = std.fmt.parseFloat(f64, args[4]) catch 0.0;
                const head_h = resolveCurrentHEAD(allocator, io, &repo) catch "";
                defer if (head_h.len > 0) allocator.free(head_h);
                if (head_h.len > 0)
                    ipld_commit.onMetricsSet(allocator, io, &repo, head_h, args[3], mval) catch {};
            }
        } else if (std.mem.eql(u8, sub, "show")) {
            const hash_opt = if (args.len >= 4) args[3] else null;
            try metrics_mod.showMetrics(allocator, io, &repo, hash_opt);
        } else if (std.mem.eql(u8, sub, "list")) {
            try metrics_mod.listMetrics(allocator, io, &repo);
        } else if (std.mem.eql(u8, sub, "compare")) {
            if (args.len < 5) {
                std.debug.print("Usage: zev metrics compare <hash-a> <hash-b>\n", .{});
                return;
            }
            try metrics_mod.compareMetrics(allocator, io, &repo, args[3], args[4]);
        } else {
            std.debug.print("Unknown metrics subcommand: {s}\n", .{sub});
        }
    } else if (std.mem.eql(u8, command, "fedmerge")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        var from_path: []const u8 = "";
        var strategy_str: []const u8 = "metrics-max";
        var dry_run = false;
        var sign_result = false;
        var weight_file: ?[]const u8 = null;
        var weight_strategy_str: []const u8 = "average";
        var weight_alpha: f64 = 0.5;
        var weight_base: ?[]const u8 = null;
        var weight_density: f64 = 0.2;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--from") and i + 1 < args.len) {
                i += 1;
                from_path = args[i];
            } else if (std.mem.eql(u8, args[i], "--strategy") and i + 1 < args.len) {
                i += 1;
                strategy_str = args[i];
            } else if (std.mem.eql(u8, args[i], "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, args[i], "--sign")) {
                sign_result = true;
            } else if (std.mem.eql(u8, args[i], "--merge-weights") and i + 1 < args.len) {
                i += 1;
                weight_file = args[i];
            } else if (std.mem.eql(u8, args[i], "--weight-strategy") and i + 1 < args.len) {
                i += 1;
                weight_strategy_str = args[i];
            } else if (std.mem.eql(u8, args[i], "--weight-alpha") and i + 1 < args.len) {
                i += 1;
                weight_alpha = std.fmt.parseFloat(f64, args[i]) catch 0.5;
            } else if (std.mem.eql(u8, args[i], "--weight-base") and i + 1 < args.len) {
                i += 1;
                weight_base = args[i];
            } else if (std.mem.eql(u8, args[i], "--weight-density") and i + 1 < args.len) {
                i += 1;
                weight_density = std.fmt.parseFloat(f64, args[i]) catch 0.2;
            }
        }
        if (from_path.len == 0) {
            std.debug.print("Usage: zev merge --from <file.car> [--strategy metrics-max|metrics-min|metrics-avg|commit-union] [--dry-run] [--sign]\n\n", .{});
            std.debug.print("Strategies:\n", .{});
            std.debug.print("  metrics-max    Take higher value per metric (default)\n", .{});
            std.debug.print("  metrics-min    Take lower value per metric\n", .{});
            std.debug.print("  metrics-avg    Average the values\n", .{});
            std.debug.print("  commit-union   Merge histories only\n\n", .{});
            std.debug.print("Weight merging (operates directly on IPLD, no working directory needed):\n", .{});
            std.debug.print("  --merge-weights <filename>       merge this file's weight tensors from both sides\n", .{});
            std.debug.print("  --weight-strategy average|weighted|slerp\n", .{});
            std.debug.print("  --weight-alpha <X>                mix ratio for weighted/slerp\n\n", .{});
            return;
        }
        const strategy = merge_mod.MergeStrategy.fromStr(strategy_str);
        const weight_strategy: weight_merge.MergeStrategy = if (std.mem.eql(u8, weight_strategy_str, "weighted"))
            .weighted
        else if (std.mem.eql(u8, weight_strategy_str, "slerp"))
            .slerp
        else if (std.mem.eql(u8, weight_strategy_str, "ties"))
            .ties
        else
            .average;
        try merge_mod.mergeFromCar(allocator, io, &repo, from_path, strategy, dry_run, sign_result, weight_file, weight_strategy, weight_alpha, weight_base, weight_density);
    } else if (std.mem.eql(u8, command, "sign")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();
        if (args.len < 3) {
            std.debug.print("Usage: zev sign <cid>\n", .{});
            return;
        }
        try crypto_mod.cmdSign(allocator, io, &repo, args[2]);
    } else if (std.mem.eql(u8, command, "verify")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();
        if (args.len < 3) {
            std.debug.print("Usage: zev verify <cid>\n", .{});
            return;
        }
        try crypto_mod.cmdVerify(allocator, io, &repo, args[2]);
    } else if (std.mem.eql(u8, command, "identity")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();
        try crypto_mod.cmdIdentity(io, allocator, &repo);
    } else if (std.mem.eql(u8, command, "wdiff")) {
        if (args.len < 4) {
            std.debug.print("Usage: zev wdiff <file_a> <file_b> [--all] [--format json]\n", .{});
            std.debug.print("\nSupported formats:\n", .{});
            std.debug.print("  .safetensors  (HuggingFace — fastest, no Python needed)\n", .{});
            std.debug.print("  .pt .pth .bin (PyTorch — requires python3 + torch)\n", .{});
            std.debug.print("  .npy          (NumPy — no extra deps)\n", .{});
            std.debug.print("  .npz          (NumPy archive — requires numpy)\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev wdiff model_v1.safetensors model_v2.safetensors\n", .{});
            std.debug.print("  zev wdiff weights.pt weights_ft.pt --all\n", .{});
            std.debug.print("  zev wdiff layer.npy layer_v2.npy --format json\n\n", .{});
            return;
        }
        var show_unchanged = false;
        var fmt: []const u8 = "text";
        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--all"))   show_unchanged = true;
            if (std.mem.eql(u8, args[i], "--format") and i + 1 < args.len) {
                i += 1; fmt = args[i];
            }
        }
        try weight_diff.cmdWeightDiff(io, allocator, args[2], args[3], show_unchanged, fmt);
    } else if (std.mem.eql(u8, command, "merge-weights")) {
        if (args.len < 4) {
            std.debug.print("Usage: zev merge-weights <model_a> <model_b> --output <out> [--strategy average|weighted|slerp] [--alpha X]\n", .{});
            std.debug.print("\nStrategies:\n", .{});
            std.debug.print("  average   (a+b)/2, the classic 'model soup' technique\n", .{});
            std.debug.print("  weighted  alpha*a + (1-alpha)*b\n", .{});
            std.debug.print("  slerp     spherical interpolation, preserves relative magnitude\n", .{});
            std.debug.print("\nExamples:\n", .{});
            std.debug.print("  zev merge-weights model_a.safetensors model_b.safetensors --output merged.safetensors\n", .{});
            std.debug.print("  zev merge-weights a.safetensors b.safetensors --output m.safetensors --strategy weighted --alpha 0.7\n\n", .{});
            return;
        }
        var output_path: ?[]const u8 = null;
        var strategy: weight_merge.MergeStrategy = .average;
        var alpha: f64 = 0.5;
        var base_path: ?[]const u8 = null;
        var density: f64 = 0.2;
        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
                i += 1; output_path = args[i];
            } else if (std.mem.eql(u8, args[i], "--strategy") and i + 1 < args.len) {
                i += 1;
                if (std.mem.eql(u8, args[i], "average")) strategy = .average
                else if (std.mem.eql(u8, args[i], "weighted")) strategy = .weighted
                else if (std.mem.eql(u8, args[i], "slerp")) strategy = .slerp
                else if (std.mem.eql(u8, args[i], "ties")) strategy = .ties;
            } else if (std.mem.eql(u8, args[i], "--alpha") and i + 1 < args.len) {
                i += 1; alpha = std.fmt.parseFloat(f64, args[i]) catch 0.5;
            } else if (std.mem.eql(u8, args[i], "--base") and i + 1 < args.len) {
                i += 1; base_path = args[i];
            } else if (std.mem.eql(u8, args[i], "--density") and i + 1 < args.len) {
                i += 1; density = std.fmt.parseFloat(f64, args[i]) catch 0.2;
            }
        }
        const out = output_path orelse {
            std.debug.print("Error: --output <path> is required\n", .{});
            return;
        };

        if (strategy == .ties) {
            const base = base_path orelse {
                std.debug.print("Error: --strategy ties requires --base <path-to-base-model>\n\n", .{});
                std.debug.print("TIES-Merging needs the common base model both fine-tunes started from,\n", .{});
                std.debug.print("to compute each model's task vector (finetuned - base) and detect\n", .{});
                std.debug.print("sign conflicts between them.\n\n", .{});
                return;
            };
            std.debug.print("🧬 TIES-Merging {s} + {s} (base: {s})...\n", .{ args[2], args[3], base });
            const data_base = std.Io.Dir.cwd().readFileAlloc(io, base, allocator, .unlimited) catch {
                std.debug.print("❌ Could not read base model: {s}\n\n", .{base});
                return;
            };
            defer allocator.free(data_base);
            const data_a = std.Io.Dir.cwd().readFileAlloc(io, args[2], allocator, .unlimited) catch {
                std.debug.print("❌ Could not read: {s}\n\n", .{args[2]});
                return;
            };
            defer allocator.free(data_a);
            const data_b = std.Io.Dir.cwd().readFileAlloc(io, args[3], allocator, .unlimited) catch {
                std.debug.print("❌ Could not read: {s}\n\n", .{args[3]});
                return;
            };
            defer allocator.free(data_b);

            var result = weight_merge.mergeSafetensorsBytesTies(allocator, data_base, data_a, data_b, density, alpha * 2.0) catch |err| {
                std.debug.print("❌ TIES merge failed: {}\n\n", .{err});
                return;
            };
            defer result.report.deinit(allocator);
            defer allocator.free(result.bytes);

            const out_file = try std.Io.Dir.cwd().createFile(io, out, .{});
            defer out_file.close(io);
            var out_buffer: [65536]u8 = undefined;
            var out_writer = out_file.writer(io, &out_buffer);
            try out_writer.interface.writeAll(result.bytes);
            try out_writer.flush();

            weight_merge.printMergeReport(&result.report, out);
        } else {
            std.debug.print("🧬 Merging {s} + {s} ({s})...\n", .{ args[2], args[3], @tagName(strategy) });
            var report = weight_merge.mergeSafetensors(allocator, io, args[2], args[3], out, strategy, alpha) catch |err| {
                std.debug.print("❌ Merge failed: {}\n", .{err});
                std.debug.print("   Only .safetensors files are currently supported for merging.\n\n", .{});
                return;
            };
            defer report.deinit(allocator);
            weight_merge.printMergeReport(&report, out);
        }
    } else if (std.mem.eql(u8, command, "push-api")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();

        if (args.len < 4) {
            std.debug.print("Usage: zev push-api <zevapi://host:port/owner/repo> <branch> --token <pat>\n\n", .{});
            std.debug.print("Example:\n", .{});
            std.debug.print("  zev push-api zevapi://localhost:8080/arvand/my-model main --token zev_pat_...\n\n", .{});
            return;
        }

        const remote_url: []const u8 = args[2];
        const branch_name: []const u8 = args[3];
        var token: []const u8 = "";
        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--token") and i + 1 < args.len) {
                i += 1;
                token = args[i];
            }
        }

        if (token.len == 0) {
            std.debug.print("Error: --token <pat> is required\n\n", .{});
            return;
        }

        try remote_http.pushToApi(allocator, io, &repo, remote_url, branch_name, token);
    } else if (std.mem.eql(u8, command, "pull-api")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository. Run 'zev init' first, or use 'zev clone-api'.\n", .{});
            return;
        }
        if (args.len < 4) {
            std.debug.print("Usage: zev pull-api <zevapi://host:port/owner/repo> <branch> [--token <pat>]\n\n", .{});
            return;
        }
        const remote_url_p: []const u8 = args[2];
        const branch_p: []const u8 = args[3];
        var token_p: ?[]const u8 = null;
        var pi: usize = 4;
        while (pi < args.len) : (pi += 1) {
            if (std.mem.eql(u8, args[pi], "--token") and pi + 1 < args.len) {
                pi += 1;
                token_p = args[pi];
            }
        }
        try remote_http.pullFromApi(allocator, io, ".", remote_url_p, branch_p, token_p);
    } else if (std.mem.eql(u8, command, "clone-api")) {
        if (args.len < 4) {
            std.debug.print("Usage: zev clone-api <zevapi://host:port/owner/repo> <dir> [--branch <name>] [--token <pat>]\n\n", .{});
            return;
        }
        const remote_url_c: []const u8 = args[2];
        const dest_dir: []const u8 = args[3];
        var branch_c: []const u8 = "main";
        var token_c: ?[]const u8 = null;
        var ci: usize = 4;
        while (ci < args.len) : (ci += 1) {
            if (std.mem.eql(u8, args[ci], "--branch") and ci + 1 < args.len) {
                ci += 1;
                branch_c = args[ci];
            } else if (std.mem.eql(u8, args[ci], "--token") and ci + 1 < args.len) {
                ci += 1;
                token_c = args[ci];
            }
        }

        try std.Io.Dir.cwd().createDirPath(io, dest_dir);
        var new_repo = try repository.Repository.init(allocator, io, dest_dir, false);
        defer new_repo.deinit();

        try remote_http.pullFromApi(allocator, io, dest_dir, remote_url_c, branch_c, token_c);

        std.debug.print("Cloned into '{s}'. Run 'cd {s} && zev checkout {s}' to materialize files.\n\n", .{ dest_dir, dest_dir, branch_c });
    } else if (std.mem.eql(u8, command, "verify-release")) {
        if (args.len < 4) {
            std.debug.print("Usage: zev verify-release <base_url> <cid>\n\n", .{});
            std.debug.print("Example:\n", .{});
            std.debug.print("  zev verify-release http://localhost:8090 QmSomeArtifactCID\n\n", .{});
            return;
        }
        const vr_base_url = args[2];
        const vr_cid = args[3];
        try remote_http.verifyRelease(allocator, io, vr_base_url, vr_cid);
    } else if (std.mem.eql(u8, command, "weight-diff-api")) {
        if (args.len < 8) {
            std.debug.print("Usage: zev weight-diff-api <base_url> <owner> <repo> <branch> <hash_a> <hash_b> <filename> [--token <pat>]\n\n", .{});
            std.debug.print("Example:\n", .{});
            std.debug.print("  zev weight-diff-api http://localhost:8090 arvand my-model main abc123 HEAD model.safetensors --token zev_pat_...\n\n", .{});
            return;
        }
        const wd_base_url = args[2];
        const wd_owner = args[3];
        const wd_repo = args[4];
        const wd_branch = args[5];
        const wd_hash_a = args[6];
        const wd_hash_b = args[7];
        const wd_filename = args[8];
        var wd_token: ?[]const u8 = null;
        var wi: usize = 9;
        while (wi < args.len) : (wi += 1) {
            if (std.mem.eql(u8, args[wi], "--token") and wi + 1 < args.len) {
                wi += 1;
                wd_token = args[wi];
            }
        }
        try weight_diff_api_cli.cmdWeightDiffApi(allocator, io, wd_base_url, wd_owner, wd_repo, wd_branch, wd_hash_a, wd_hash_b, wd_filename, wd_token);
    } else if (std.mem.eql(u8, command, "repo-dashboard")) {
        if (args.len < 5) {
            std.debug.print("Usage: zev repo-dashboard <base_url> <owner> <repo> [--token <pat>]\n\n", .{});
            std.debug.print("Example:\n", .{});
            std.debug.print("  zev repo-dashboard http://localhost:8090 arvand my-model --token zev_pat_...\n\n", .{});
            return;
        }
        const rd_base_url = args[2];
        const rd_owner = args[3];
        const rd_repo = args[4];
        var rd_token: ?[]const u8 = null;
        var ri: usize = 5;
        while (ri < args.len) : (ri += 1) {
            if (std.mem.eql(u8, args[ri], "--token") and ri + 1 < args.len) {
                ri += 1;
                rd_token = args[ri];
            }
        }
        try repo_dashboard_cli.cmdRepoDashboard(allocator, io, rd_base_url, rd_owner, rd_repo, rd_token);
    } else if (std.mem.eql(u8, command, "dependency-graph")) {
        if (args.len < 6) {
            std.debug.print("Usage: zev dependency-graph <base_url> <owner> <repo> <commit_hash> [--token <pat>]\n\n", .{});
            std.debug.print("Example:\n", .{});
            std.debug.print("  zev dependency-graph http://localhost:8090 arvand chat-agent abc123... --token zev_pat_...\n\n", .{});
            return;
        }
        const dg_base_url = args[2];
        const dg_owner = args[3];
        const dg_repo = args[4];
        const dg_commit = args[5];
        var dg_token: ?[]const u8 = null;
        var dgi: usize = 6;
        while (dgi < args.len) : (dgi += 1) {
            if (std.mem.eql(u8, args[dgi], "--token") and dgi + 1 < args.len) {
                dgi += 1;
                dg_token = args[dgi];
            }
        }
        try dependency_graph_cli.cmdDependencyGraph(allocator, io, dg_base_url, dg_owner, dg_repo, dg_commit, dg_token);
    } else if (std.mem.eql(u8, command, "threshold")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();
        if (args.len < 3) {
            std.debug.print("Usage: zev threshold <set|list>\n", .{});
            std.debug.print("  zev threshold set accuracy --min 0.90 --warn-delta 0.02\n", .{});
            std.debug.print("  zev threshold set loss --max 0.5 --warn-pct 20\n", .{});
            std.debug.print("  zev threshold list\n\n", .{});
            return;
        }
        if (std.mem.eql(u8, args[2], "list")) {
            try regression.cmdThresholdList(io, allocator, &repo);
        } else if (std.mem.eql(u8, args[2], "set")) {
            if (args.len < 4) {
                std.debug.print("Usage: zev threshold set <metric> [--min X] [--max X] [--warn-delta X] [--warn-pct X]\n", .{});
                return;
            }
            try regression.cmdThresholdSet(io, allocator, &repo, args[3], args[4..]);
        }
    } else if (std.mem.eql(u8, command, "check")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();
        const ref = if (args.len >= 3) args[2] else "HEAD";
        const exit_code = try regression.cmdCheck(allocator, io, &repo, ref);
        if (exit_code != 0) std.process.exit(exit_code);
    } else if (std.mem.eql(u8, command, "history")) {
        if (!repository.Repository.exists(allocator, io, ".")) {
            std.debug.print("Not a zev repository.\n", .{});
            return;
        }
        var repo = try repository.Repository.open(allocator, io, ".");
        defer repo.deinit();
        if (args.len < 3) {
            std.debug.print("Usage: zev history <metric>\n", .{});
            std.debug.print("Example: zev history accuracy\n\n", .{});
            return;
        }
        try regression.cmdHistory(io, allocator, &repo, args[2]);
    } else if (std.mem.eql(u8, command, "help")) {
        try printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try printUsage();
    }
}

fn resolveCurrentHEAD(allocator: std.mem.Allocator, io: std.Io, repo: *repository.Repository) ![]u8 {
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
        return allocator.dupe(u8, std.mem.trim(u8, rc, "\n\r "));
    }
    return allocator.dupe(u8, std.mem.trim(u8, head, "\n\r "));
}
fn printUsage() !void {
    std.debug.print(
        \\Zev - Next Generation Version Control
        \\
        \\Usage: zev <command> [options]
        \\
        \\Commands:
        \\  init [path] [--ipfs]    Initialize a new Zev repository
        \\  clone <url> [dir]       Clone a repository (file://, http://, ssh://, ipfs://)
        \\  config <get|set|list>   Manage repository configuration
        \\  version                 Show Zev version
        \\  hash <data>             Generate CID for data
        \\  add <file>              Stage file for commit
        \\  commit <msg>            Commit staged changes
        \\  diff [--staged]         Show changes
        \\  diff <file>             Show changes in file
        \\  branch [name]           List or create branches
        \\  branch -d <name>        Delete a branch
        \\  checkout <branch>       Switch to a branch
        \\  merge <branch>          Merge branch into current branch
        \\  remote [add|rm|show]    Manage remotes
        \\  push <remote> [branch]  Push to remote (supports file://, http://, ssh://, ipfs://)
        \\  pull <remote> [branch]  Pull from remote
        \\  ipfs <subcmd>           IPFS operations (status, add, cat, pin, etc.)
        \\  log [n]                 Show commit history (default: 10)
        \\  status                  Show working tree status
        \\  cat <cid>               Retrieve data by CID
        \\  help                    Show this help message
        \\
        \\ML & IPLD Commands:
        \\  metrics <set|show|list> Track ML metrics
        \\  sdiff [a] [b]           Semantic diff (metrics + files)
        \\  check [ref]             Regression gate (exit 1 on failure)
        \\  threshold <set|list>    Configure regression thresholds
        \\  history <metric>        Show metric trend + sparkline
        \\  ipld <migrate|log>      IPLD commit management
        \\  dag <show|walk|query|export|import|stat>  DAG operations
        \\  graft <cid> --as <name> Link external CID
        \\  fedmerge --from <f.car>  Federated merge without server
        \\  sign <cid>              Sign node with Ed25519
        \\  verify <cid>            Verify signature
        \\  identity                Show/create signing identity
        \\  audit                   Full provenance report
        \\
        \\Remote Protocols:
        \\  file://path             Local filesystem
        \\  http://url              HTTP/HTTPS
        \\  ssh://user@host:path    SSH
        \\  user@host:path          SSH (Git style)
        \\  ipfs://CID              IPFS
        \\
        \\Configuration:
        \\  zev config set user.name "Your Name"
        \\  zev config set user.email "you@example.com"
        \\  zev config set storage.backend hybrid
        \\  zev config list
        \\
    , .{});
}

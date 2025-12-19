const std = @import("std");
const c = @cImport(@cInclude("git2.h"));
const git = @import("git.zig");

pub const help =
    \\usage: zagi commit -m <message> [-a] [--amend]
    \\
    \\Create a commit from staged changes.
    \\
    \\Options:
    \\  -m <msg>   Commit message (required unless --amend)
    \\  -a         Stage all modified tracked files before commit
    \\  --amend    Amend the previous commit
    \\
;

pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) git.Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Parse arguments
    var message: ?[]const u8 = null;
    var amend = false;
    var all = false;

    var i: usize = 2; // Skip "zagi" and "commit"
    while (i < args.len) : (i += 1) {
        const arg = std.mem.sliceTo(args[i], 0);

        if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            i += 1;
            if (i >= args.len) {
                return git.Error.UsageError;
            }
            message = std.mem.sliceTo(args[i], 0);
        } else if (std.mem.startsWith(u8, arg, "-m")) {
            // Handle -m"message" format (no space)
            message = arg[2..];
        } else if (std.mem.startsWith(u8, arg, "--message=")) {
            message = arg[10..];
        } else if (std.mem.eql(u8, arg, "--amend")) {
            amend = true;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            all = true;
        }
    }

    // Message is required (unless amending)
    if (message == null and !amend) {
        return git.Error.UsageError;
    }

    // Initialize libgit2
    if (c.git_libgit2_init() < 0) {
        return git.Error.InitFailed;
    }
    defer _ = c.git_libgit2_shutdown();

    // Open repository
    var repo: ?*c.git_repository = null;
    if (c.git_repository_open_ext(&repo, ".", 0, null) < 0) {
        return git.Error.NotARepository;
    }
    defer c.git_repository_free(repo);

    // Get index
    var index: ?*c.git_index = null;
    if (c.git_repository_index(&index, repo) < 0) {
        return git.Error.IndexOpenFailed;
    }
    defer c.git_index_free(index);

    // If -a flag, stage all tracked modified files
    if (all) {
        if (c.git_index_update_all(index, null, null, null) < 0) {
            return git.Error.AddFailed;
        }
        if (c.git_index_write(index) < 0) {
            return git.Error.IndexWriteFailed;
        }
    }

    // Check if there's anything to commit
    var head_commit: ?*c.git_commit = null;
    var has_head = false;

    var head_ref: ?*c.git_reference = null;
    if (c.git_repository_head(&head_ref, repo) == 0) {
        has_head = true;
        const head_oid = c.git_reference_target(head_ref);
        if (head_oid != null) {
            _ = c.git_commit_lookup(&head_commit, repo, head_oid);
        }
        c.git_reference_free(head_ref);
    }
    defer if (head_commit) |hc| c.git_commit_free(hc);

    // Write the index as a tree
    var tree_oid: c.git_oid = undefined;
    if (c.git_index_write_tree(&tree_oid, index) < 0) {
        return git.Error.IndexWriteFailed;
    }

    // Check if tree is same as HEAD (nothing to commit)
    if (has_head and head_commit != null and !amend) {
        const head_tree_oid = c.git_commit_tree_id(head_commit);
        if (head_tree_oid != null and c.git_oid_equal(&tree_oid, head_tree_oid) != 0) {
            return git.Error.NothingToCommit;
        }
    }

    // Get the tree object
    var tree: ?*c.git_tree = null;
    if (c.git_tree_lookup(&tree, repo, &tree_oid) < 0) {
        return git.Error.CommitFailed;
    }
    defer c.git_tree_free(tree);

    // Get signature
    var signature: ?*c.git_signature = null;
    if (c.git_signature_default(&signature, repo) < 0) {
        // Try to create a signature from config
        return git.Error.CommitFailed;
    }
    defer c.git_signature_free(signature);

    // Determine the commit message
    var final_message: []const u8 = undefined;
    var message_buf: [4096]u8 = undefined;

    if (amend and message == null) {
        // Use the original commit message
        if (head_commit) |hc| {
            const orig_msg = c.git_commit_message(hc);
            if (orig_msg != null) {
                final_message = std.mem.sliceTo(orig_msg, 0);
            } else {
                return git.Error.UsageError;
            }
        } else {
            return git.Error.UsageError;
        }
    } else if (message) |msg| {
        final_message = msg;
    } else {
        return git.Error.UsageError;
    }

    // Copy message to null-terminated buffer
    if (final_message.len >= message_buf.len) {
        return git.Error.CommitFailed;
    }
    @memcpy(message_buf[0..final_message.len], final_message);
    message_buf[final_message.len] = 0;

    // Create the commit
    var commit_oid: c.git_oid = undefined;

    if (amend and head_commit != null) {
        // Amend the HEAD commit
        if (c.git_commit_amend(
            &commit_oid,
            head_commit,
            "HEAD",
            null, // use original author
            signature,
            null, // use original encoding
            &message_buf,
            tree,
        ) < 0) {
            return git.Error.CommitFailed;
        }
    } else {
        // Create new commit
        var parents: [1]?*const c.git_commit = .{head_commit};
        const parent_count: usize = if (has_head) 1 else 0;

        if (c.git_commit_create(
            &commit_oid,
            repo,
            "HEAD",
            signature,
            signature,
            null, // UTF-8 encoding
            &message_buf,
            tree,
            parent_count,
            if (parent_count > 0) @ptrCast(&parents) else null,
        ) < 0) {
            return git.Error.CommitFailed;
        }
    }

    // Format output
    var hash_buf: [8]u8 = undefined;
    _ = c.git_oid_tostr(&hash_buf, hash_buf.len, &commit_oid);

    // Get diff stats
    const stats = getDiffStats(allocator, repo, head_commit, tree) catch .{ .files = 0, .insertions = 0, .deletions = 0 };

    // Output
    stdout.print("committed: {s} \"{s}\"\n", .{ hash_buf[0..7], final_message }) catch return git.Error.WriteFailed;
    if (stats.files > 0) {
        stdout.print("  {d} file{s}, +{d} -{d}\n", .{
            stats.files,
            if (stats.files == 1) "" else "s",
            stats.insertions,
            stats.deletions,
        }) catch return git.Error.WriteFailed;
    }
}

const DiffStats = struct {
    files: usize,
    insertions: usize,
    deletions: usize,
};

fn getDiffStats(allocator: std.mem.Allocator, repo: ?*c.git_repository, old_commit: ?*c.git_commit, new_tree: ?*c.git_tree) !DiffStats {
    _ = allocator;

    var old_tree: ?*c.git_tree = null;
    if (old_commit) |oc| {
        if (c.git_commit_tree(&old_tree, oc) < 0) {
            return DiffStats{ .files = 0, .insertions = 0, .deletions = 0 };
        }
    }
    defer if (old_tree) |ot| c.git_tree_free(ot);

    var diff: ?*c.git_diff = null;
    if (c.git_diff_tree_to_tree(&diff, repo, old_tree, new_tree, null) < 0) {
        return DiffStats{ .files = 0, .insertions = 0, .deletions = 0 };
    }
    defer c.git_diff_free(diff);

    var stats: ?*c.git_diff_stats = null;
    if (c.git_diff_get_stats(&stats, diff) < 0) {
        return DiffStats{ .files = 0, .insertions = 0, .deletions = 0 };
    }
    defer c.git_diff_stats_free(stats);

    return DiffStats{
        .files = c.git_diff_stats_files_changed(stats),
        .insertions = c.git_diff_stats_insertions(stats),
        .deletions = c.git_diff_stats_deletions(stats),
    };
}

// Output formatting functions (testable)

pub fn formatCommitOutput(writer: anytype, hash: []const u8, message: []const u8, files: usize, insertions: usize, deletions: usize) !void {
    try writer.print("committed: {s} \"{s}\"\n", .{ hash, message });
    if (files > 0) {
        try writer.print("  {d} file{s}, +{d} -{d}\n", .{
            files,
            if (files == 1) "" else "s",
            insertions,
            deletions,
        });
    }
}

// Tests
const testing = std.testing;

test "formatCommitOutput with one file" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try formatCommitOutput(output.writer(), "abc1234", "Test message", 1, 10, 5);

    const expected = "committed: abc1234 \"Test message\"\n  1 file, +10 -5\n";
    try testing.expectEqualStrings(expected, output.items);
}

test "formatCommitOutput with multiple files" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try formatCommitOutput(output.writer(), "def5678", "Another commit", 3, 25, 10);

    const expected = "committed: def5678 \"Another commit\"\n  3 files, +25 -10\n";
    try testing.expectEqualStrings(expected, output.items);
}

test "formatCommitOutput with no file changes" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try formatCommitOutput(output.writer(), "ghi9012", "Empty commit", 0, 0, 0);

    const expected = "committed: ghi9012 \"Empty commit\"\n";
    try testing.expectEqualStrings(expected, output.items);
}

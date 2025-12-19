const std = @import("std");
const c = @cImport(@cInclude("git2.h"));

pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    _ = args;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Initialize libgit2
    if (c.git_libgit2_init() < 0) {
        try stderr.print("Failed to initialize libgit2\n", .{});
        std.process.exit(1);
    }
    defer _ = c.git_libgit2_shutdown();

    // Open repository
    var repo: ?*c.git_repository = null;
    if (c.git_repository_open_ext(&repo, ".", 0, null) < 0) {
        try stderr.print("fatal: not a git repository (or any of the parent directories): .git\n", .{});
        std.process.exit(128);
    }
    defer c.git_repository_free(repo);

    // Get current branch
    var head: ?*c.git_reference = null;
    const head_err = c.git_repository_head(&head, repo);
    defer if (head != null) c.git_reference_free(head);

    if (head_err == 0 and head != null) {
        const branch_name = c.git_reference_shorthand(head);
        if (branch_name) |name| {
            const branch = std.mem.sliceTo(name, 0);
            try stdout.print("branch: {s}", .{branch});

            // Check upstream status
            var upstream: ?*c.git_reference = null;
            if (c.git_branch_upstream(&upstream, head) == 0 and upstream != null) {
                defer c.git_reference_free(upstream);

                var ahead: usize = 0;
                var behind: usize = 0;
                const local_oid = c.git_reference_target(head);
                const upstream_oid = c.git_reference_target(upstream);

                if (local_oid != null and upstream_oid != null) {
                    _ = c.git_graph_ahead_behind(&ahead, &behind, repo, local_oid, upstream_oid);

                    if (ahead == 0 and behind == 0) {
                        try stdout.print(" (up to date)", .{});
                    } else if (ahead > 0 and behind == 0) {
                        try stdout.print(" (ahead {d})", .{ahead});
                    } else if (behind > 0 and ahead == 0) {
                        try stdout.print(" (behind {d})", .{behind});
                    } else {
                        try stdout.print(" (ahead {d}, behind {d})", .{ ahead, behind });
                    }
                }
            }
            try stdout.print("\n", .{});
        }
    } else if (head_err == c.GIT_EUNBORNBRANCH) {
        try stdout.print("branch: (no commits yet)\n", .{});
    } else {
        try stdout.print("branch: HEAD detached\n", .{});
    }

    // Get status
    var status_list: ?*c.git_status_list = null;
    var opts: c.git_status_options = undefined;
    _ = c.git_status_options_init(&opts, c.GIT_STATUS_OPTIONS_VERSION);
    opts.show = c.GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
    opts.flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED |
        c.GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX |
        c.GIT_STATUS_OPT_SORT_CASE_SENSITIVELY;

    if (c.git_status_list_new(&status_list, repo, &opts) < 0) {
        try stderr.print("Failed to get status\n", .{});
        std.process.exit(1);
    }
    defer c.git_status_list_free(status_list);

    const count = c.git_status_list_entrycount(status_list);

    if (count == 0) {
        try stdout.print("\nnothing to commit, working tree clean\n", .{});
        return;
    }

    // Collect files by category
    var staged = std.array_list.Managed(FileStatus).init(allocator);
    defer staged.deinit();
    var modified = std.array_list.Managed(FileStatus).init(allocator);
    defer modified.deinit();
    var untracked = std.array_list.Managed(FileStatus).init(allocator);
    defer untracked.deinit();

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entry = c.git_status_byindex(status_list, i);
        if (entry == null) continue;

        const status = entry.*.status;
        const diff_delta = entry.*.head_to_index;
        const wt_delta = entry.*.index_to_workdir;

        // Staged changes (index)
        if (status & (c.GIT_STATUS_INDEX_NEW | c.GIT_STATUS_INDEX_MODIFIED | c.GIT_STATUS_INDEX_DELETED | c.GIT_STATUS_INDEX_RENAMED | c.GIT_STATUS_INDEX_TYPECHANGE) != 0) {
            if (diff_delta) |delta| {
                const path = if (delta.*.new_file.path) |p| std.mem.sliceTo(p, 0) else "";
                const marker = getIndexMarker(status);
                try staged.append(.{ .marker = marker, .path = path });
            }
        }

        // Workdir changes (modified but not staged)
        if (status & (c.GIT_STATUS_WT_MODIFIED | c.GIT_STATUS_WT_DELETED | c.GIT_STATUS_WT_TYPECHANGE | c.GIT_STATUS_WT_RENAMED) != 0) {
            if (wt_delta) |delta| {
                const path = if (delta.*.new_file.path) |p| std.mem.sliceTo(p, 0) else "";
                const marker = getWtMarker(status);
                try modified.append(.{ .marker = marker, .path = path });
            }
        }

        // Untracked
        if (status & c.GIT_STATUS_WT_NEW != 0) {
            if (wt_delta) |delta| {
                const path = if (delta.*.new_file.path) |p| std.mem.sliceTo(p, 0) else "";
                try untracked.append(.{ .marker = "??", .path = path });
            }
        }
    }

    // Print staged
    if (staged.items.len > 0) {
        try stdout.print("\nstaged: {d} files\n", .{staged.items.len});
        for (staged.items) |file| {
            try stdout.print("  {s} {s}\n", .{ file.marker, file.path });
        }
    }

    // Print modified
    if (modified.items.len > 0) {
        try stdout.print("\nmodified: {d} files\n", .{modified.items.len});
        for (modified.items) |file| {
            try stdout.print("  {s} {s}\n", .{ file.marker, file.path });
        }
    }

    // Print untracked
    if (untracked.items.len > 0) {
        try stdout.print("\nuntracked: {d} files\n", .{untracked.items.len});
        const max_show: usize = 5;
        for (untracked.items, 0..) |file, idx| {
            if (idx >= max_show) {
                try stdout.print("  + {d} more\n", .{untracked.items.len - max_show});
                break;
            }
            try stdout.print("  {s} {s}\n", .{ file.marker, file.path });
        }
    }
}

const FileStatus = struct {
    marker: []const u8,
    path: []const u8,
};

fn getIndexMarker(status: c_uint) []const u8 {
    if (status & c.GIT_STATUS_INDEX_NEW != 0) return "A ";
    if (status & c.GIT_STATUS_INDEX_MODIFIED != 0) return "M ";
    if (status & c.GIT_STATUS_INDEX_DELETED != 0) return "D ";
    if (status & c.GIT_STATUS_INDEX_RENAMED != 0) return "R ";
    if (status & c.GIT_STATUS_INDEX_TYPECHANGE != 0) return "T ";
    return "  ";
}

fn getWtMarker(status: c_uint) []const u8 {
    if (status & c.GIT_STATUS_WT_MODIFIED != 0) return " M";
    if (status & c.GIT_STATUS_WT_DELETED != 0) return " D";
    if (status & c.GIT_STATUS_WT_RENAMED != 0) return " R";
    if (status & c.GIT_STATUS_WT_TYPECHANGE != 0) return " T";
    return "  ";
}

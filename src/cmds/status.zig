const std = @import("std");
const git = @import("git.zig");
const c = git.c;

pub const help =
    \\usage: git status [<path>...]
    \\
    \\Show working tree status.
    \\
    \\Examples:
    \\  git status              Show all changes
    \\  git status src/         Show changes in src/ directory
    \\  git status *.ts         Show changes to TypeScript files
    \\
;

const MAX_PATHSPECS = 16;

pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) (git.Error || error{OutOfMemory})!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Parse arguments
    var pathspecs: [MAX_PATHSPECS][*c]u8 = undefined;
    var pathspec_count: usize = 0;

    for (args[2..]) |arg| {
        const a = std.mem.sliceTo(arg, 0);
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            stdout.print("{s}", .{help}) catch {};
            return;
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--short")) {
            // Already short format by default, ignore
        } else if (std.mem.eql(u8, a, "-b") or std.mem.eql(u8, a, "--branch")) {
            // Already show branch by default, ignore
        } else if (std.mem.startsWith(u8, a, "-")) {
            // Other flags unsupported (--porcelain, etc.)
            return git.Error.UnsupportedFlag;
        } else {
            // Path argument
            if (pathspec_count < MAX_PATHSPECS) {
                pathspecs[pathspec_count] = @constCast(arg.ptr);
                pathspec_count += 1;
            }
        }
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

    // Get current branch
    var head: ?*c.git_reference = null;
    const head_err = c.git_repository_head(&head, repo);
    defer if (head != null) c.git_reference_free(head);

    if (head_err == 0 and head != null) {
        const branch_name = c.git_reference_shorthand(head);
        if (branch_name) |name| {
            const branch = std.mem.sliceTo(name, 0);
            stdout.print("branch: {s}", .{branch}) catch return git.Error.WriteFailed;

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
                        stdout.print(" (up to date)", .{}) catch return git.Error.WriteFailed;
                    } else if (ahead > 0 and behind == 0) {
                        stdout.print(" (ahead {d})", .{ahead}) catch return git.Error.WriteFailed;
                    } else if (behind > 0 and ahead == 0) {
                        stdout.print(" (behind {d})", .{behind}) catch return git.Error.WriteFailed;
                    } else {
                        stdout.print(" (ahead {d}, behind {d})", .{ ahead, behind }) catch return git.Error.WriteFailed;
                    }
                }
            }
            stdout.print("\n", .{}) catch return git.Error.WriteFailed;
        }
    } else if (head_err == c.GIT_EUNBORNBRANCH) {
        stdout.print("branch: (no commits yet)\n", .{}) catch return git.Error.WriteFailed;
    } else {
        stdout.print("branch: HEAD detached\n", .{}) catch return git.Error.WriteFailed;
    }

    // Get status
    var status_list: ?*c.git_status_list = null;
    var opts: c.git_status_options = undefined;
    _ = c.git_status_options_init(&opts, c.GIT_STATUS_OPTIONS_VERSION);
    opts.show = c.GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
    opts.flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED |
        c.GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX |
        c.GIT_STATUS_OPT_SORT_CASE_SENSITIVELY;

    // Set up pathspec filtering if paths were provided
    if (pathspec_count > 0) {
        opts.pathspec.strings = &pathspecs;
        opts.pathspec.count = pathspec_count;
    }

    if (c.git_status_list_new(&status_list, repo, &opts) < 0) {
        return git.Error.StatusFailed;
    }
    defer c.git_status_list_free(status_list);

    const count = c.git_status_list_entrycount(status_list);

    if (count == 0) {
        stdout.print("\nnothing to commit, working tree clean\n", .{}) catch return git.Error.WriteFailed;
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
                const marker = git.indexMarker(status);
                try staged.append(.{ .marker = marker, .path = path });
            }
        }

        // Workdir changes (modified but not staged)
        if (status & (c.GIT_STATUS_WT_MODIFIED | c.GIT_STATUS_WT_DELETED | c.GIT_STATUS_WT_TYPECHANGE | c.GIT_STATUS_WT_RENAMED) != 0) {
            if (wt_delta) |delta| {
                const path = if (delta.*.new_file.path) |p| std.mem.sliceTo(p, 0) else "";
                const marker = git.workdirMarker(status);
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
        stdout.print("\nstaged: {d} files\n", .{staged.items.len}) catch return git.Error.WriteFailed;
        for (staged.items) |file| {
            stdout.print("  {s} {s}\n", .{ file.marker, file.path }) catch return git.Error.WriteFailed;
        }
    }

    // Print modified
    if (modified.items.len > 0) {
        stdout.print("\nmodified: {d} files\n", .{modified.items.len}) catch return git.Error.WriteFailed;
        for (modified.items) |file| {
            stdout.print("  {s} {s}\n", .{ file.marker, file.path }) catch return git.Error.WriteFailed;
        }
    }

    // Print untracked
    if (untracked.items.len > 0) {
        stdout.print("\nuntracked: {d} files\n", .{untracked.items.len}) catch return git.Error.WriteFailed;
        const max_show: usize = 5;
        for (untracked.items, 0..) |file, idx| {
            if (idx >= max_show) {
                stdout.print("  + {d} more\n", .{untracked.items.len - max_show}) catch return git.Error.WriteFailed;
                break;
            }
            stdout.print("  {s} {s}\n", .{ file.marker, file.path }) catch return git.Error.WriteFailed;
        }
    }
}

const FileStatus = struct {
    marker: []const u8,
    path: []const u8,
};

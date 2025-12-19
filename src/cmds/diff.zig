const std = @import("std");
const c = @cImport(@cInclude("git2.h"));
const git = @import("git.zig");

pub const help =
    \\usage: git diff [--staged] [--stat] [--name-only] [<commit>] [-- <path>...]
    \\
    \\Show changes in working tree, staging area, or between commits.
    \\
    \\Options:
    \\  --staged      Show staged changes (what will be committed)
    \\  --stat        Show diffstat (files changed, insertions, deletions)
    \\  --name-only   Show only names of changed files
    \\
    \\Examples:
    \\  git diff                    Show unstaged changes
    \\  git diff --staged           Show staged changes
    \\  git diff --stat             Show summary of changes
    \\  git diff --name-only        List changed files
    \\  git diff HEAD~2..HEAD       Show changes between commits
    \\
;

const DiffError = git.Error || error{OutOfMemory};

pub const OutputMode = enum {
    patch,
    stat,
    name_only,
};

fn resolveTree(repo: ?*c.git_repository, spec: []const u8) ?*c.git_tree {
    // Create null-terminated string for libgit2
    var buf: [256]u8 = undefined;
    if (spec.len >= buf.len) return null;
    @memcpy(buf[0..spec.len], spec);
    buf[spec.len] = 0;

    var obj: ?*c.git_object = null;
    if (c.git_revparse_single(&obj, repo, &buf) < 0) {
        return null;
    }

    // Peel to tree
    var tree: ?*c.git_tree = null;
    if (c.git_object_peel(@ptrCast(&tree), obj, c.GIT_OBJECT_TREE) < 0) {
        c.git_object_free(obj);
        return null;
    }
    c.git_object_free(obj);
    return tree;
}

fn resolveCommit(repo: ?*c.git_repository, spec: []const u8) ?*c.git_commit {
    // Create null-terminated string for libgit2
    var buf: [256]u8 = undefined;
    if (spec.len >= buf.len) return null;
    @memcpy(buf[0..spec.len], spec);
    buf[spec.len] = 0;

    var obj: ?*c.git_object = null;
    if (c.git_revparse_single(&obj, repo, &buf) < 0) {
        return null;
    }

    // Peel to commit
    var commit: ?*c.git_commit = null;
    if (c.git_object_peel(@ptrCast(&commit), obj, c.GIT_OBJECT_COMMIT) < 0) {
        c.git_object_free(obj);
        return null;
    }
    c.git_object_free(obj);
    return commit;
}

fn getMergeBaseTree(repo: ?*c.git_repository, spec1: []const u8, spec2: []const u8) ?*c.git_tree {
    const commit1 = resolveCommit(repo, spec1) orelse return null;
    defer c.git_commit_free(commit1);

    const commit2 = resolveCommit(repo, spec2) orelse return null;
    defer c.git_commit_free(commit2);

    var merge_base_oid: c.git_oid = undefined;
    if (c.git_merge_base(&merge_base_oid, repo, c.git_commit_id(commit1), c.git_commit_id(commit2)) < 0) {
        return null;
    }

    var merge_base_commit: ?*c.git_commit = null;
    if (c.git_commit_lookup(&merge_base_commit, repo, &merge_base_oid) < 0) {
        return null;
    }
    defer c.git_commit_free(merge_base_commit);

    var tree: ?*c.git_tree = null;
    if (c.git_commit_tree(&tree, merge_base_commit) < 0) {
        return null;
    }
    return tree;
}

const MAX_PATHSPECS = 16;

pub fn run(_: std.mem.Allocator, args: [][:0]u8) DiffError!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Parse args
    var staged = false;
    var output_mode: OutputMode = .patch;
    var rev_spec: ?[]const u8 = null;
    var pathspecs: [MAX_PATHSPECS][*c]u8 = undefined;
    var pathspec_count: usize = 0;
    var after_double_dash = false;

    for (args[2..]) |arg| {
        const a = std.mem.sliceTo(arg, 0);

        if (after_double_dash) {
            // Everything after -- is a path
            if (pathspec_count < MAX_PATHSPECS) {
                pathspecs[pathspec_count] = @constCast(arg.ptr);
                pathspec_count += 1;
            }
            continue;
        }

        if (std.mem.eql(u8, a, "--")) {
            after_double_dash = true;
        } else if (std.mem.eql(u8, a, "--staged") or std.mem.eql(u8, a, "--cached")) {
            staged = true;
        } else if (std.mem.eql(u8, a, "--stat")) {
            output_mode = .stat;
        } else if (std.mem.eql(u8, a, "--name-only")) {
            output_mode = .name_only;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            stdout.print("{s}", .{help}) catch {};
            return;
        } else if (std.mem.startsWith(u8, a, "-")) {
            // Unknown flag - passthrough to git
            return git.Error.UnsupportedFlag;
        } else if (!std.mem.startsWith(u8, a, "-")) {
            // Non-flag argument is a revision spec
            rev_spec = a;
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

    // Set up diff options
    var diff_opts: c.git_diff_options = undefined;
    _ = c.git_diff_options_init(&diff_opts, c.GIT_DIFF_OPTIONS_VERSION);
    diff_opts.context_lines = 0; // No context lines - agent knows the file

    // Set up pathspec filtering if paths were provided
    if (pathspec_count > 0) {
        diff_opts.pathspec.strings = &pathspecs;
        diff_opts.pathspec.count = pathspec_count;
    }

    var diff: ?*c.git_diff = null;

    if (rev_spec) |spec| {
        // Diff between commits (e.g., HEAD~2..HEAD, HEAD~2, or main...feature)
        var old_tree: ?*c.git_tree = null;
        var new_tree: ?*c.git_tree = null;
        defer if (old_tree != null) c.git_tree_free(old_tree);
        defer if (new_tree != null) c.git_tree_free(new_tree);

        const parsed = parseRevSpec(spec);
        const new_spec = parsed.new orelse "HEAD";

        if (parsed.triple_dot) {
            // Triple dot: diff from merge-base to new
            old_tree = getMergeBaseTree(repo, parsed.old, new_spec) orelse return git.Error.RevwalkFailed;
            new_tree = resolveTree(repo, new_spec) orelse return git.Error.RevwalkFailed;
        } else {
            // Double dot or single revision
            old_tree = resolveTree(repo, parsed.old) orelse return git.Error.RevwalkFailed;
            new_tree = resolveTree(repo, new_spec) orelse return git.Error.RevwalkFailed;
        }

        if (c.git_diff_tree_to_tree(&diff, repo, old_tree, new_tree, &diff_opts) < 0) {
            return git.Error.StatusFailed;
        }
    } else if (staged) {
        // Diff HEAD to index (staged changes)
        var head_commit: ?*c.git_commit = null;
        var head_tree: ?*c.git_tree = null;

        var head_ref: ?*c.git_reference = null;
        if (c.git_repository_head(&head_ref, repo) == 0 and head_ref != null) {
            defer c.git_reference_free(head_ref);
            const head_oid = c.git_reference_target(head_ref);
            if (head_oid != null) {
                if (c.git_commit_lookup(&head_commit, repo, head_oid) == 0) {
                    defer c.git_commit_free(head_commit);
                    _ = c.git_commit_tree(&head_tree, head_commit);
                }
            }
        }
        defer if (head_tree != null) c.git_tree_free(head_tree);

        if (c.git_diff_tree_to_index(&diff, repo, head_tree, null, &diff_opts) < 0) {
            return git.Error.StatusFailed;
        }
    } else {
        // Diff index to workdir (unstaged changes)
        if (c.git_diff_index_to_workdir(&diff, repo, null, &diff_opts) < 0) {
            return git.Error.StatusFailed;
        }
    }
    defer c.git_diff_free(diff);

    // Output based on mode
    switch (output_mode) {
        .stat => {
            printStat(diff, stdout);
        },
        .name_only => {
            printNameOnly(diff, stdout);
        },
        .patch => {
            // Track state for printing
            var print_state = PrintState{
                .stdout = stdout,
                .current_file = null,
                .current_hunk_start = 0,
                .current_hunk_end = 0,
                .had_output = false,
            };

            // Print the diff
            _ = c.git_diff_print(diff, c.GIT_DIFF_FORMAT_PATCH, printCallback, &print_state);

            if (!print_state.had_output) {
                stdout.print("no changes\n", .{}) catch {};
            }
        },
    }
}

const PrintState = struct {
    stdout: std.fs.File.DeprecatedWriter,
    current_file: ?[]const u8,
    current_hunk_start: u32,
    current_hunk_end: u32,
    had_output: bool,
};

fn printStat(diff: ?*c.git_diff, stdout: std.fs.File.DeprecatedWriter) void {
    const num_deltas = c.git_diff_num_deltas(diff);
    if (num_deltas == 0) {
        stdout.print("no changes\n", .{}) catch {};
        return;
    }

    var total_insertions: usize = 0;
    var total_deletions: usize = 0;

    var i: usize = 0;
    while (i < num_deltas) : (i += 1) {
        const delta = c.git_diff_get_delta(diff, i);
        if (delta == null) continue;

        const path = if (delta.*.new_file.path) |p| std.mem.sliceTo(p, 0) else continue;

        // Get stats for this file
        var patch: ?*c.git_patch = null;
        if (c.git_patch_from_diff(&patch, diff, i) < 0) continue;
        defer c.git_patch_free(patch);

        var adds: usize = 0;
        var dels: usize = 0;
        _ = c.git_patch_line_stats(null, &adds, &dels, patch);

        total_insertions += adds;
        total_deletions += dels;

        // Format: filename | changes +++ ---
        const changes = adds + dels;
        stdout.print(" {s} | {d} ", .{ path, changes }) catch {};

        // Print +/- bar (max 20 chars)
        const max_bar: usize = 20;
        const total = if (changes > max_bar) max_bar else changes;
        const plus_count = if (changes > 0) (adds * total) / changes else 0;
        const minus_count = total - plus_count;

        var j: usize = 0;
        while (j < plus_count) : (j += 1) {
            stdout.print("+", .{}) catch {};
        }
        j = 0;
        while (j < minus_count) : (j += 1) {
            stdout.print("-", .{}) catch {};
        }
        stdout.print("\n", .{}) catch {};
    }

    // Summary line
    stdout.print(" {d} files changed", .{num_deltas}) catch {};
    if (total_insertions > 0) {
        stdout.print(", {d} insertions(+)", .{total_insertions}) catch {};
    }
    if (total_deletions > 0) {
        stdout.print(", {d} deletions(-)", .{total_deletions}) catch {};
    }
    stdout.print("\n", .{}) catch {};
}

fn printNameOnly(diff: ?*c.git_diff, stdout: std.fs.File.DeprecatedWriter) void {
    const num_deltas = c.git_diff_num_deltas(diff);
    if (num_deltas == 0) {
        stdout.print("no changes\n", .{}) catch {};
        return;
    }

    var i: usize = 0;
    while (i < num_deltas) : (i += 1) {
        const delta = c.git_diff_get_delta(diff, i);
        if (delta == null) continue;

        const path = if (delta.*.new_file.path) |p| std.mem.sliceTo(p, 0) else continue;
        stdout.print("{s}\n", .{path}) catch {};
    }
}

fn printCallback(
    delta: ?*const c.git_diff_delta,
    hunk: ?*const c.git_diff_hunk,
    line: ?*const c.git_diff_line,
    payload: ?*anyopaque,
) callconv(.c) c_int {
    const state: *PrintState = @ptrCast(@alignCast(payload));
    const stdout = state.stdout;

    if (line) |l| {
        const origin = l.origin;

        // File header
        if (origin == c.GIT_DIFF_LINE_FILE_HDR) {
            // New file starting
            if (delta) |d| {
                const new_path = if (d.new_file.path) |p| std.mem.sliceTo(p, 0) else null;
                if (new_path) |path| {
                    if (state.current_file == null or !std.mem.eql(u8, state.current_file.?, path)) {
                        if (state.had_output) {
                            stdout.print("\n", .{}) catch {};
                        }
                        state.current_file = path;
                        state.current_hunk_start = 0;
                        state.current_hunk_end = 0;
                    }
                }
            }
            return 0;
        }

        // Hunk header - track line numbers
        if (origin == c.GIT_DIFF_LINE_HUNK_HDR) {
            if (hunk) |h| {
                // Print file:line header
                if (state.current_file) |file| {
                    const start = if (h.old_start > 0) h.old_start else h.new_start;
                    const lines = @max(h.old_lines, h.new_lines);
                    if (lines > 1) {
                        stdout.print("{s}:{d}-{d}\n", .{ file, start, start + lines - 1 }) catch {};
                    } else {
                        stdout.print("{s}:{d}\n", .{ file, start }) catch {};
                    }
                    state.had_output = true;
                }
            }
            return 0;
        }

        // Actual diff lines
        if (origin == c.GIT_DIFF_LINE_ADDITION or origin == c.GIT_DIFF_LINE_DELETION) {
            const prefix: u8 = if (origin == c.GIT_DIFF_LINE_ADDITION) '+' else '-';
            const content = if (l.content) |cont| cont[0..@intCast(l.content_len)] else "";

            // Trim trailing newline if present
            const trimmed = std.mem.trimRight(u8, content, "\n\r");
            stdout.print("{c} {s}\n", .{ prefix, trimmed }) catch {};
            state.had_output = true;
        }
    }

    return 0;
}

pub fn formatHunkHeader(writer: anytype, file: []const u8, start: u32, lines: u32) !void {
    if (lines > 1) {
        try writer.print("{s}:{d}-{d}\n", .{ file, start, start + lines - 1 });
    } else {
        try writer.print("{s}:{d}\n", .{ file, start });
    }
}

pub fn formatDiffLine(writer: anytype, is_addition: bool, content: []const u8) !void {
    const prefix: u8 = if (is_addition) '+' else '-';
    const trimmed = std.mem.trimRight(u8, content, "\n\r");
    try writer.print("{c} {s}\n", .{ prefix, trimmed });
}

pub fn formatNoChanges(writer: anytype) !void {
    try writer.print("no changes\n", .{});
}

/// Parse a revision spec like "HEAD~2..HEAD" or "main...feature" into parts.
/// Returns null for new if it's a single revision (diff to HEAD).
/// triple_dot indicates merge-base semantics (changes since diverged).
pub fn parseRevSpec(spec: []const u8) struct { old: []const u8, new: ?[]const u8, triple_dot: bool } {
    // Check for triple dot first (must check before double dot)
    if (std.mem.indexOf(u8, spec, "...")) |dot_pos| {
        return .{
            .old = spec[0..dot_pos],
            .new = spec[dot_pos + 3 ..],
            .triple_dot = true,
        };
    } else if (std.mem.indexOf(u8, spec, "..")) |dot_pos| {
        return .{
            .old = spec[0..dot_pos],
            .new = spec[dot_pos + 2 ..],
            .triple_dot = false,
        };
    } else {
        return .{
            .old = spec,
            .new = null,
            .triple_dot = false,
        };
    }
}

// Tests
const testing = std.testing;

test "formatHunkHeader single line" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try formatHunkHeader(output.writer(), "src/main.zig", 42, 1);

    try testing.expectEqualStrings("src/main.zig:42\n", output.items);
}

test "formatHunkHeader multiple lines" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try formatHunkHeader(output.writer(), "src/main.zig", 10, 5);

    try testing.expectEqualStrings("src/main.zig:10-14\n", output.items);
}

test "formatHunkHeader line range at line 1" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try formatHunkHeader(output.writer(), "README.md", 1, 3);

    try testing.expectEqualStrings("README.md:1-3\n", output.items);
}

test "formatDiffLine addition" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try formatDiffLine(output.writer(), true, "const x = 42;");

    try testing.expectEqualStrings("+ const x = 42;\n", output.items);
}

test "formatDiffLine deletion" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try formatDiffLine(output.writer(), false, "const x = 0;");

    try testing.expectEqualStrings("- const x = 0;\n", output.items);
}

test "formatDiffLine trims trailing newline" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try formatDiffLine(output.writer(), true, "hello world\n");

    try testing.expectEqualStrings("+ hello world\n", output.items);
}

test "formatDiffLine trims trailing CRLF" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try formatDiffLine(output.writer(), false, "windows line\r\n");

    try testing.expectEqualStrings("- windows line\n", output.items);
}

test "formatNoChanges" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try formatNoChanges(output.writer());

    try testing.expectEqualStrings("no changes\n", output.items);
}

test "parseRevSpec with range HEAD~2..HEAD" {
    const result = parseRevSpec("HEAD~2..HEAD");
    try testing.expectEqualStrings("HEAD~2", result.old);
    try testing.expectEqualStrings("HEAD", result.new.?);
    try testing.expect(!result.triple_dot);
}

test "parseRevSpec with range main..feature" {
    const result = parseRevSpec("main..feature");
    try testing.expectEqualStrings("main", result.old);
    try testing.expectEqualStrings("feature", result.new.?);
    try testing.expect(!result.triple_dot);
}

test "parseRevSpec single revision" {
    const result = parseRevSpec("HEAD~5");
    try testing.expectEqualStrings("HEAD~5", result.old);
    try testing.expect(result.new == null);
    try testing.expect(!result.triple_dot);
}

test "parseRevSpec with commit hash" {
    const result = parseRevSpec("abc123");
    try testing.expectEqualStrings("abc123", result.old);
    try testing.expect(result.new == null);
    try testing.expect(!result.triple_dot);
}

test "parseRevSpec with hash range" {
    const result = parseRevSpec("abc123..def456");
    try testing.expectEqualStrings("abc123", result.old);
    try testing.expectEqualStrings("def456", result.new.?);
    try testing.expect(!result.triple_dot);
}

test "parseRevSpec with triple dot main...feature" {
    const result = parseRevSpec("main...feature");
    try testing.expectEqualStrings("main", result.old);
    try testing.expectEqualStrings("feature", result.new.?);
    try testing.expect(result.triple_dot);
}

test "parseRevSpec with triple dot HEAD~5...HEAD" {
    const result = parseRevSpec("HEAD~5...HEAD");
    try testing.expectEqualStrings("HEAD~5", result.old);
    try testing.expectEqualStrings("HEAD", result.new.?);
    try testing.expect(result.triple_dot);
}

test "parseRevSpec distinguishes double and triple dots" {
    const double = parseRevSpec("a..b");
    const triple = parseRevSpec("a...b");
    try testing.expect(!double.triple_dot);
    try testing.expect(triple.triple_dot);
    try testing.expectEqualStrings("b", double.new.?);
    try testing.expectEqualStrings("b", triple.new.?);
}

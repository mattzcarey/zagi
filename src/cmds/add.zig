const std = @import("std");
const c = @cImport(@cInclude("git2.h"));
const git = @import("git.zig");

pub const help =
    \\usage: zagi add <path>...
    \\
    \\Stage files for commit.
    \\
    \\Arguments:
    \\  <path>  File or directory to stage (use . for all)
    \\
;

pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) (git.Error || error{WriteError})!void {
    _ = allocator;
    const stdout = std.fs.File.stdout().deprecatedWriter();

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

    // Collect paths to add (skip "zagi" and "add")
    if (args.len < 3) {
        return git.Error.UsageError;
    }

    for (args[2..]) |path| {
        const path_slice = std.mem.sliceTo(path, 0);

        if (std.mem.eql(u8, path_slice, ".")) {
            // Add all files
            if (c.git_index_add_all(index, null, c.GIT_INDEX_ADD_DEFAULT, null, null) < 0) {
                return git.Error.AddFailed;
            }
        } else {
            // Add specific file
            const result = c.git_index_add_bypath(index, path);
            if (result < 0) {
                return git.Error.FileNotFound;
            }
        }
    }

    // Write index to disk
    if (c.git_index_write(index) < 0) {
        return git.Error.IndexWriteFailed;
    }

    // Show what was staged by getting status
    var status_list: ?*c.git_status_list = null;
    var opts: c.git_status_options = undefined;
    _ = c.git_status_options_init(&opts, c.GIT_STATUS_OPTIONS_VERSION);
    opts.show = c.GIT_STATUS_SHOW_INDEX_ONLY;
    opts.flags = c.GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX;

    if (c.git_status_list_new(&status_list, repo, &opts) < 0) {
        return git.Error.StatusFailed;
    }
    defer c.git_status_list_free(status_list);

    const count = c.git_status_list_entrycount(status_list);
    if (count == 0) {
        stdout.print("nothing to add\n", .{}) catch return error.WriteError;
        return;
    }

    stdout.print("staged: {d} file{s}\n", .{ count, if (count == 1) "" else "s" }) catch return error.WriteError;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entry = c.git_status_byindex(status_list, i);
        if (entry == null) continue;

        const status = entry.*.status;
        const delta = entry.*.head_to_index;

        if (delta) |d| {
            const path = if (d.*.new_file.path) |p| std.mem.sliceTo(p, 0) else "";
            const marker = git.indexMarker(status);
            stdout.print("  {s} {s}\n", .{ marker, path }) catch return error.WriteError;
        }
    }
}

// Output formatting functions (testable without libgit2)

pub fn formatStagedHeader(writer: anytype, count: usize) !void {
    if (count == 0) {
        try writer.print("nothing to add\n", .{});
    } else {
        try writer.print("staged: {d} file{s}\n", .{ count, if (count == 1) "" else "s" });
    }
}

pub fn formatStagedFile(writer: anytype, marker: []const u8, path: []const u8) !void {
    try writer.print("  {s} {s}\n", .{ marker, path });
}

// Tests
const testing = std.testing;

test "formatStagedHeader with zero files" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try formatStagedHeader(output.writer(), 0);

    try testing.expectEqualStrings("nothing to add\n", output.items);
}

test "formatStagedHeader with one file" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try formatStagedHeader(output.writer(), 1);

    try testing.expectEqualStrings("staged: 1 file\n", output.items);
}

test "formatStagedHeader with multiple files" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try formatStagedHeader(output.writer(), 5);

    try testing.expectEqualStrings("staged: 5 files\n", output.items);
}

test "formatStagedFile formats correctly" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try formatStagedFile(output.writer(), "A ", "src/main.zig");

    try testing.expectEqualStrings("  A  src/main.zig\n", output.items);
}

test "formatStagedFile with modified marker" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try formatStagedFile(output.writer(), "M ", "README.md");

    try testing.expectEqualStrings("  M  README.md\n", output.items);
}

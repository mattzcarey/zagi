const std = @import("std");
const guardrails = @import("guardrails.zig");
const edit = @import("cmds/edit.zig");
const git = @import("cmds/git.zig");
const c = git.c;
const detect = @import("cmds/detect.zig");

/// Pass through a command to git CLI
pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Check guardrails in agent mode
    if (detect.isAgentMode()) {
        // Cast to const for checkBlocked
        const const_args: []const [:0]const u8 = @ptrCast(args);
        if (guardrails.checkBlocked(const_args)) |reason| {
            stderr.print("error: destructive command blocked\n", .{}) catch {};
            stderr.print("reason: {s}\n", .{reason}) catch {};
            stderr.print("hint: ask the user to run this command themselves, then confirm with you when done\n", .{}) catch {};
            std.process.exit(1);
        }
    }

    // Check edit-mode guardrail: block 'push' during edit session
    if (isPushCommand(args)) {
        if (isEditSessionActive()) {
            stderr.print("error: git push blocked during edit session\n", .{}) catch {};
            stderr.print("hint: complete with --back or --abort first\n", .{}) catch {};
            std.process.exit(1);
        }
    }

    var git_args = std.array_list.Managed([]const u8).init(allocator);
    defer git_args.deinit();

    try git_args.append("git");
    for (args[1..]) |arg| {
        try git_args.append(arg);
    }

    var child = std.process.Child.init(git_args.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        stderr.print("Error executing git: {s}\n", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };

    switch (term) {
        .Exited => |code| std.process.exit(code),
        .Signal => |sig| {
            stderr.print("Git terminated by signal {d}\n", .{sig}) catch {};
            std.process.exit(1);
        },
        .Stopped => |sig| {
            stderr.print("Git stopped by signal {d}\n", .{sig}) catch {};
            std.process.exit(1);
        },
        .Unknown => |code| {
            stderr.print("Git exited with unknown status {d}\n", .{code}) catch {};
            std.process.exit(1);
        },
    }
}

/// Check if the command is 'push'
fn isPushCommand(args: [][:0]u8) bool {
    // Need at least: zagi push
    if (args.len < 2) return false;

    // Check if arg[1] (the git subcommand) is "push"
    const cmd = std.mem.sliceTo(args[1], 0);
    return std.mem.eql(u8, cmd, "push");
}

/// Check if an edit session is currently active by looking for refs/edit/origin
fn isEditSessionActive() bool {
    // Initialize libgit2
    if (c.git_libgit2_init() < 0) {
        return false;
    }
    defer _ = c.git_libgit2_shutdown();

    // Open repository
    var repo: ?*c.git_repository = null;
    if (c.git_repository_open_ext(&repo, ".", 0, null) < 0) {
        return false;
    }
    defer c.git_repository_free(repo);

    return edit.isEditActive(repo);
}

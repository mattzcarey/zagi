const std = @import("std");
const build_options = @import("build_options");
const passthrough = @import("passthrough.zig");
const log = @import("cmds/log.zig");
const status = @import("cmds/status.zig");
const add = @import("cmds/add.zig");
const alias = @import("cmds/alias.zig");
const commit = @import("cmds/commit.zig");
const diff = @import("cmds/diff.zig");
const fork = @import("cmds/fork.zig");
const git = @import("cmds/git.zig");

const version = build_options.version;

const Command = enum {
    log_cmd,
    status_cmd,
    add_cmd,
    alias_cmd,
    commit_cmd,
    diff_cmd,
    fork_cmd,
    other,
};

var current_command: Command = .other;

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = std.process.argsAlloc(allocator) catch {
        std.process.exit(1);
    };
    defer std.process.argsFree(allocator, args);

    run(allocator, args) catch |err| {
        // UnsupportedFlag: pass through to git
        if (err == git.Error.UnsupportedFlag) {
            passthrough.run(allocator, args) catch {};
            return;
        }
        handleError(err, current_command);
    };
}

fn run(allocator: std.mem.Allocator, args: [][:0]u8) !void {

    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (args.len < 2) {
        printHelp(stdout) catch {};
        return;
    }

    const cmd = args[1];

    // Handle global flags
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        printHelp(stdout) catch {};
        return;
    }

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        stdout.print("zagi {s}\n", .{version}) catch {};
        return;
    }

    // Passthrough mode: -g/--git passes remaining args directly to git
    if (std.mem.eql(u8, cmd, "-g") or std.mem.eql(u8, cmd, "--git")) {
        try passthrough.run(allocator, args[1..]);
        return;
    }

    // Zagi commands
    if (std.mem.eql(u8, cmd, "log")) {
        current_command = .log_cmd;
        try log.run(allocator, args);
    } else if (std.mem.eql(u8, cmd, "status")) {
        current_command = .status_cmd;
        try status.run(allocator, args);
    } else if (std.mem.eql(u8, cmd, "add")) {
        current_command = .add_cmd;
        try add.run(allocator, args);
    } else if (std.mem.eql(u8, cmd, "alias")) {
        current_command = .alias_cmd;
        try alias.run(allocator, args);
    } else if (std.mem.eql(u8, cmd, "commit")) {
        current_command = .commit_cmd;
        try commit.run(allocator, args);
    } else if (std.mem.eql(u8, cmd, "diff")) {
        current_command = .diff_cmd;
        try diff.run(allocator, args);
    } else if (std.mem.eql(u8, cmd, "fork")) {
        current_command = .fork_cmd;
        try fork.run(allocator, args);
    } else {
        // Unknown command: pass through to git
        current_command = .other;
        try passthrough.run(allocator, args);
    }
}

fn printHelp(stdout: anytype) !void {
    try stdout.print(
        \\zagi - git for agents
        \\
        \\usage: zagi <command> [args...]
        \\usage: git <command> [args...] (when aliased)
        \\
        \\commands:
        \\  status    Show working tree status
        \\  log       Show commit history
        \\  diff      Show changes
        \\  add       Stage files for commit
        \\  commit    Create a commit
        \\  fork      Manage parallel worktrees
        \\  alias     Create an alias to git
        \\
        \\options:
        \\  -h, --help     Show this help
        \\  -v, --version  Show version
        \\  -g, --git      Git passthrough mode (e.g. git -g log)
        \\
        \\Unrecognized commands are passed through to git.
        \\
        \\
    , .{});
}

fn handleError(err: anyerror, cmd: Command) void {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    const exit_code: u8 = switch (err) {
        git.Error.NotARepository => blk: {
            stderr.print("fatal: not a git repository\n", .{}) catch {};
            break :blk 128;
        },
        git.Error.InitFailed => blk: {
            stderr.print("fatal: failed to initialize libgit2\n", .{}) catch {};
            break :blk 1;
        },
        git.Error.IndexOpenFailed => blk: {
            stderr.print("fatal: failed to open index\n", .{}) catch {};
            break :blk 1;
        },
        git.Error.IndexWriteFailed => blk: {
            stderr.print("fatal: failed to write index\n", .{}) catch {};
            break :blk 1;
        },
        git.Error.StatusFailed => blk: {
            stderr.print("fatal: failed to get status\n", .{}) catch {};
            break :blk 1;
        },
        git.Error.FileNotFound => blk: {
            stderr.print("error: file not found\n", .{}) catch {};
            break :blk 128;
        },
        git.Error.AddFailed => blk: {
            stderr.print("error: failed to add files\n", .{}) catch {};
            break :blk 1;
        },
        git.Error.RevwalkFailed => blk: {
            stderr.print("fatal: failed to walk commits\n", .{}) catch {};
            break :blk 1;
        },
        git.Error.UsageError => blk: {
            printUsageHelp(stderr, cmd);
            break :blk 1;
        },
        git.Error.WriteFailed => blk: {
            stderr.print("fatal: write failed\n", .{}) catch {};
            break :blk 1;
        },
        git.Error.NothingToCommit => blk: {
            stderr.print("error: nothing to commit\n", .{}) catch {};
            break :blk 1;
        },
        git.Error.CommitFailed => blk: {
            stderr.print("error: commit failed\n", .{}) catch {};
            break :blk 1;
        },
        error.OutOfMemory => blk: {
            stderr.print("fatal: out of memory\n", .{}) catch {};
            break :blk 1;
        },
        else => blk: {
            stderr.print("error: {}\n", .{err}) catch {};
            break :blk 1;
        },
    };

    std.process.exit(exit_code);
}

fn printUsageHelp(stderr: anytype, cmd: Command) void {
    const help_text = switch (cmd) {
        .add_cmd => add.help,
        .commit_cmd => commit.help,
        .status_cmd => status.help,
        .log_cmd => log.help,
        .alias_cmd => alias.help,
        .diff_cmd => diff.help,
        .fork_cmd => fork.help,
        .other => "usage: git <command> [args...]\n",
    };

    stderr.print("{s}", .{help_text}) catch {};
}

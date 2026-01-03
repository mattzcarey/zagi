const std = @import("std");

/// Guardrails for agent mode (ZAGI_AGENT).
/// Blocks commands that can cause actual data loss.
///
/// Philosophy: Only block commands where data is UNRECOVERABLE.
/// - Discarding uncommitted work = data loss (no way to get it back)
/// - Deleting untracked files = data loss
/// - Force pushing = remote data loss
/// - Rewriting shared history = data loss for collaborators
///
/// NOT blocked (recoverable via reflog/remote):
/// - git reset (soft) - commits still in reflog
/// - git branch -d - only deletes if merged
/// - git checkout <branch> - just switches, doesn't discard

pub const BlockedCommand = struct {
    pattern: Pattern,
    reason: []const u8,
};

pub const Pattern = union(enum) {
    /// Command + specific flag combination (e.g., "reset" + "--hard")
    cmd_with_flag: struct {
        cmd: []const u8,
        flag: []const u8,
    },
    /// Command + any of these flags
    cmd_with_any_flag: struct {
        cmd: []const u8,
        flags: []const []const u8,
    },
    /// Command + argument pattern (e.g., "checkout" + ".")
    cmd_with_arg: struct {
        cmd: []const u8,
        arg: []const u8,
    },
    /// Command + flag + argument pattern (e.g., "checkout" + "--" + any path)
    cmd_flag_then_arg: struct {
        cmd: []const u8,
        flag: []const u8,
    },
    /// Subcommand (e.g., "stash drop")
    subcommand: struct {
        cmd: []const u8,
        sub: []const u8,
    },
    /// Command + argument starting with prefix (e.g., "push" + ":" for refspec delete)
    cmd_with_arg_prefix: struct {
        cmd: []const u8,
        prefix: []const u8,
    },
};

/// Commands that cause unrecoverable data loss.
pub const blocked_commands = [_]BlockedCommand{
    // Working tree destroyers
    .{
        .pattern = .{ .cmd_with_flag = .{ .cmd = "reset", .flag = "--hard" } },
        .reason = "discards all uncommitted changes (unrecoverable)",
    },
    .{
        .pattern = .{ .cmd_with_arg = .{ .cmd = "checkout", .arg = "." } },
        .reason = "discards all working tree changes (unrecoverable)",
    },
    .{
        .pattern = .{ .cmd_with_any_flag = .{ .cmd = "clean", .flags = &.{ "-f", "--force", "-fd", "-fx", "-fxd", "-d", "-x" } } },
        .reason = "permanently deletes untracked files",
    },
    .{
        .pattern = .{ .cmd_with_arg = .{ .cmd = "restore", .arg = "." } },
        .reason = "discards all working tree changes (unrecoverable)",
    },
    .{
        .pattern = .{ .cmd_with_flag = .{ .cmd = "restore", .flag = "--worktree" } },
        .reason = "discards working tree changes (unrecoverable)",
    },

    // Remote history destroyers
    .{
        .pattern = .{ .cmd_with_any_flag = .{ .cmd = "push", .flags = &.{ "-f", "--force", "--force-with-lease", "--force-if-includes" } } },
        .reason = "overwrites remote history (may cause data loss for collaborators)",
    },

    // Remote branch deleters
    .{
        .pattern = .{ .cmd_with_any_flag = .{ .cmd = "push", .flags = &.{ "--delete", "-d" } } },
        .reason = "deletes remote branch",
    },
    .{
        .pattern = .{ .cmd_with_arg_prefix = .{ .cmd = "push", .prefix = ":" } },
        .reason = "deletes remote branch (refspec syntax)",
    },

    // Stash destroyers
    .{
        .pattern = .{ .subcommand = .{ .cmd = "stash", .sub = "drop" } },
        .reason = "permanently deletes stashed changes",
    },
    .{
        .pattern = .{ .subcommand = .{ .cmd = "stash", .sub = "clear" } },
        .reason = "permanently deletes all stashed changes",
    },

    // Branch force delete
    .{
        .pattern = .{ .cmd_with_flag = .{ .cmd = "branch", .flag = "-D" } },
        .reason = "force deletes branch even if not merged (potential data loss)",
    },
};

/// Check if a command should be blocked in agent mode.
/// Returns the reason if blocked, null if allowed.
pub fn checkBlocked(args: []const [:0]const u8) ?[]const u8 {
    // Need at least: zagi <cmd>
    if (args.len < 2) return null;

    // Skip the executable name (could be "zagi", "git", or full path like "/usr/bin/zagi")
    // Check if args[0] ends with "zagi" or "git" or is exactly one of them
    const arg0 = std.mem.sliceTo(args[0], 0);
    const is_wrapper = std.mem.eql(u8, arg0, "zagi") or
        std.mem.eql(u8, arg0, "git") or
        std.mem.endsWith(u8, arg0, "/zagi") or
        std.mem.endsWith(u8, arg0, "/git");
    const cmd_start: usize = if (is_wrapper) 1 else 0;

    if (args.len <= cmd_start) return null;

    const cmd = std.mem.sliceTo(args[cmd_start], 0);
    const rest = args[cmd_start + 1 ..];

    for (blocked_commands) |blocked| {
        if (matchesPattern(cmd, rest, blocked.pattern)) {
            return blocked.reason;
        }
    }

    return null;
}

fn matchesPattern(cmd: []const u8, rest: []const [:0]const u8, pattern: Pattern) bool {
    switch (pattern) {
        .cmd_with_flag => |p| {
            if (!std.mem.eql(u8, cmd, p.cmd)) return false;
            return hasFlag(rest, p.flag);
        },
        .cmd_with_any_flag => |p| {
            if (!std.mem.eql(u8, cmd, p.cmd)) return false;
            for (p.flags) |flag| {
                if (hasFlag(rest, flag)) return true;
            }
            return false;
        },
        .cmd_with_arg => |p| {
            if (!std.mem.eql(u8, cmd, p.cmd)) return false;
            return hasArg(rest, p.arg);
        },
        .cmd_flag_then_arg => |p| {
            if (!std.mem.eql(u8, cmd, p.cmd)) return false;
            // Check for "--" followed by any argument
            for (rest, 0..) |arg_ptr, i| {
                const arg = std.mem.sliceTo(arg_ptr, 0);
                if (std.mem.eql(u8, arg, p.flag) and i + 1 < rest.len) {
                    return true;
                }
            }
            return false;
        },
        .subcommand => |p| {
            if (!std.mem.eql(u8, cmd, p.cmd)) return false;
            if (rest.len == 0) return false;
            return std.mem.eql(u8, std.mem.sliceTo(rest[0], 0), p.sub);
        },
        .cmd_with_arg_prefix => |p| {
            if (!std.mem.eql(u8, cmd, p.cmd)) return false;
            return hasArgWithPrefix(rest, p.prefix);
        },
    }
}

fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |arg_ptr| {
        const arg = std.mem.sliceTo(arg_ptr, 0);
        if (std.mem.eql(u8, arg, flag)) return true;
        // Handle combined short flags like -fd
        if (flag.len == 2 and flag[0] == '-' and flag[1] != '-') {
            if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
                // Check if the flag char is in the combined flags
                if (std.mem.indexOfScalar(u8, arg[1..], flag[1]) != null) {
                    return true;
                }
            }
        }
    }
    return false;
}

fn hasArg(args: []const [:0]const u8, target: []const u8) bool {
    for (args) |arg_ptr| {
        const arg = std.mem.sliceTo(arg_ptr, 0);
        if (std.mem.eql(u8, arg, target)) return true;
    }
    return false;
}

fn hasArgWithPrefix(args: []const [:0]const u8, prefix: []const u8) bool {
    for (args) |arg_ptr| {
        const arg = std.mem.sliceTo(arg_ptr, 0);
        if (arg.len > prefix.len and std.mem.startsWith(u8, arg, prefix)) return true;
    }
    return false;
}

/// Check if guardrails should be enforced.
pub fn isAgentMode() bool {
    return std.posix.getenv("ZAGI_AGENT") != null;
}

// Tests
const testing = std.testing;

fn toArgs(comptime strings: []const []const u8) [strings.len][:0]const u8 {
    var result: [strings.len][:0]const u8 = undefined;
    inline for (strings, 0..) |s, i| {
        result[i] = s ++ "";
    }
    return result;
}

test "blocks reset --hard" {
    const args = toArgs(&.{ "git", "reset", "--hard" });
    try testing.expect(checkBlocked(&args) != null);
}

test "blocks reset --hard HEAD~1" {
    const args = toArgs(&.{ "git", "reset", "--hard", "HEAD~1" });
    try testing.expect(checkBlocked(&args) != null);
}

test "allows reset --soft" {
    const args = toArgs(&.{ "git", "reset", "--soft", "HEAD~1" });
    try testing.expect(checkBlocked(&args) == null);
}

test "allows reset without flags" {
    const args = toArgs(&.{ "git", "reset", "HEAD~1" });
    try testing.expect(checkBlocked(&args) == null);
}

test "blocks checkout ." {
    const args = toArgs(&.{ "git", "checkout", "." });
    try testing.expect(checkBlocked(&args) != null);
}

test "allows checkout -- file (targeted revert is ok)" {
    const args = toArgs(&.{ "git", "checkout", "--", "file.txt" });
    try testing.expect(checkBlocked(&args) == null);
}

test "allows checkout branch" {
    const args = toArgs(&.{ "git", "checkout", "main" });
    try testing.expect(checkBlocked(&args) == null);
}

test "allows checkout -b newbranch" {
    const args = toArgs(&.{ "git", "checkout", "-b", "feature" });
    try testing.expect(checkBlocked(&args) == null);
}

test "blocks clean -f" {
    const args = toArgs(&.{ "git", "clean", "-f" });
    try testing.expect(checkBlocked(&args) != null);
}

test "blocks clean -fd" {
    const args = toArgs(&.{ "git", "clean", "-fd" });
    try testing.expect(checkBlocked(&args) != null);
}

test "blocks clean -d (combined flags)" {
    const args = toArgs(&.{ "git", "clean", "-d" });
    try testing.expect(checkBlocked(&args) != null);
}

test "allows clean -n (dry run)" {
    const args = toArgs(&.{ "git", "clean", "-n" });
    try testing.expect(checkBlocked(&args) == null);
}

test "blocks push --force" {
    const args = toArgs(&.{ "git", "push", "--force" });
    try testing.expect(checkBlocked(&args) != null);
}

test "blocks push -f" {
    const args = toArgs(&.{ "git", "push", "-f" });
    try testing.expect(checkBlocked(&args) != null);
}

test "allows push" {
    const args = toArgs(&.{ "git", "push", "origin", "main" });
    try testing.expect(checkBlocked(&args) == null);
}

test "blocks push --delete" {
    const args = toArgs(&.{ "git", "push", "origin", "--delete", "feature" });
    try testing.expect(checkBlocked(&args) != null);
}

test "blocks push -d (delete)" {
    const args = toArgs(&.{ "git", "push", "origin", "-d", "feature" });
    try testing.expect(checkBlocked(&args) != null);
}

test "blocks push refspec delete syntax" {
    const args = toArgs(&.{ "git", "push", "origin", ":feature" });
    try testing.expect(checkBlocked(&args) != null);
}

test "allows push with normal refspec" {
    const args = toArgs(&.{ "git", "push", "origin", "feature:feature" });
    try testing.expect(checkBlocked(&args) == null);
}

test "blocks stash drop" {
    const args = toArgs(&.{ "git", "stash", "drop" });
    try testing.expect(checkBlocked(&args) != null);
}

test "blocks stash clear" {
    const args = toArgs(&.{ "git", "stash", "clear" });
    try testing.expect(checkBlocked(&args) != null);
}

test "allows stash" {
    const args = toArgs(&.{ "git", "stash" });
    try testing.expect(checkBlocked(&args) == null);
}

test "allows stash pop" {
    const args = toArgs(&.{ "git", "stash", "pop" });
    try testing.expect(checkBlocked(&args) == null);
}

test "blocks branch -D" {
    const args = toArgs(&.{ "git", "branch", "-D", "feature" });
    try testing.expect(checkBlocked(&args) != null);
}

test "allows branch -d" {
    const args = toArgs(&.{ "git", "branch", "-d", "feature" });
    try testing.expect(checkBlocked(&args) == null);
}

test "blocks restore ." {
    const args = toArgs(&.{ "git", "restore", "." });
    try testing.expect(checkBlocked(&args) != null);
}

test "blocks restore --worktree" {
    const args = toArgs(&.{ "git", "restore", "--worktree", "file.txt" });
    try testing.expect(checkBlocked(&args) != null);
}

test "allows restore --staged" {
    const args = toArgs(&.{ "git", "restore", "--staged", "file.txt" });
    try testing.expect(checkBlocked(&args) == null);
}

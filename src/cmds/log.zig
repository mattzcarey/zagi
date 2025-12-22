const std = @import("std");
const git = @import("git.zig");
const c = git.c;

pub const help =
    \\usage: git log [-n <count>] [--author=<pattern>] [--grep=<pattern>]
    \\               [--since=<date>] [--until=<date>] [--prompts] [-- <path>...]
    \\
    \\Show commit history.
    \\
    \\Options:
    \\  -n <count>       Limit to n commits (default: 10)
    \\  --author=<pat>   Filter by author name or email
    \\  --grep=<pat>     Filter by commit message
    \\  --since=<date>   Show commits after date (e.g. 2025-01-01, "1 week ago")
    \\  --until=<date>   Show commits before date
    \\  --prompts        Show AI prompts attached to commits
    \\  -- <path>...     Show commits affecting paths
    \\
;

const MAX_PATHSPECS = 16;

const Options = struct {
    max_count: usize = 10,
    author: ?[]const u8 = null,
    grep: ?[]const u8 = null,
    since: ?i64 = null,
    until: ?i64 = null,
    pathspecs: [MAX_PATHSPECS][*c]u8 = undefined,
    pathspec_count: usize = 0,
    show_prompts: bool = false,
};

pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) (git.Error || error{OutOfMemory})!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Parse options
    var opts = Options{};
    var after_double_dash = false;
    var i: usize = 2; // skip "zagi" and "log"
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (after_double_dash) {
            // Everything after -- is a path
            if (opts.pathspec_count < MAX_PATHSPECS) {
                opts.pathspecs[opts.pathspec_count] = @constCast(arg.ptr);
                opts.pathspec_count += 1;
            }
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            after_double_dash = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--max-count")) {
            i += 1;
            if (i < args.len) {
                opts.max_count = std.fmt.parseInt(usize, args[i], 10) catch 10;
            }
        } else if (std.mem.startsWith(u8, arg, "-n")) {
            opts.max_count = std.fmt.parseInt(usize, arg[2..], 10) catch 10;
        } else if (std.mem.startsWith(u8, arg, "--max-count=")) {
            opts.max_count = std.fmt.parseInt(usize, arg[12..], 10) catch 10;
        } else if (std.mem.startsWith(u8, arg, "--author=")) {
            opts.author = arg[9..];
        } else if (std.mem.eql(u8, arg, "--author")) {
            i += 1;
            if (i < args.len) {
                opts.author = std.mem.sliceTo(args[i], 0);
            }
        } else if (std.mem.startsWith(u8, arg, "--grep=")) {
            opts.grep = arg[7..];
        } else if (std.mem.eql(u8, arg, "--grep")) {
            i += 1;
            if (i < args.len) {
                opts.grep = std.mem.sliceTo(args[i], 0);
            }
        } else if (std.mem.startsWith(u8, arg, "--since=") or std.mem.startsWith(u8, arg, "--after=")) {
            const date_str = if (std.mem.startsWith(u8, arg, "--since=")) arg[8..] else arg[8..];
            opts.since = parseDate(date_str);
        } else if (std.mem.startsWith(u8, arg, "--until=") or std.mem.startsWith(u8, arg, "--before=")) {
            const date_str = if (std.mem.startsWith(u8, arg, "--until=")) arg[8..] else arg[9..];
            opts.until = parseDate(date_str);
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            stdout.print("{s}", .{help}) catch {};
            return;
        } else if (std.mem.eql(u8, arg, "--oneline")) {
            // Already one-line format by default, ignore
        } else if (std.mem.eql(u8, arg, "--prompts")) {
            opts.show_prompts = true;
        } else if (std.mem.startsWith(u8, arg, "-") or std.mem.startsWith(u8, arg, "--")) {
            // Unknown flag - passthrough to git
            return git.Error.UnsupportedFlag;
        }
        // Non-flag arguments (revision specs) - passthrough for now
        else if (!std.mem.startsWith(u8, arg, "-")) {
            return git.Error.UnsupportedFlag;
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

    // Create revwalk
    var walk: ?*c.git_revwalk = null;
    if (c.git_revwalk_new(&walk, repo) < 0) {
        return git.Error.RevwalkFailed;
    }
    defer c.git_revwalk_free(walk);

    _ = c.git_revwalk_sorting(walk, c.GIT_SORT_TIME);

    if (c.git_revwalk_push_head(walk) < 0) {
        return git.Error.RevwalkFailed;
    }

    // Walk commits
    var oid: c.git_oid = undefined;
    var count: usize = 0;
    var total_matching: usize = 0;

    while (c.git_revwalk_next(&oid, walk) == 0) {
        var commit: ?*c.git_commit = null;
        if (c.git_commit_lookup(&commit, repo, &oid) < 0) {
            continue;
        }
        defer c.git_commit_free(commit);

        // Apply filters
        if (!commitMatchesFilters(repo, commit.?, opts)) {
            continue;
        }

        total_matching += 1;

        if (count >= opts.max_count) {
            // Keep counting for truncation message but don't print
            continue;
        }

        printCommit(allocator, stdout, commit.?, &oid, opts) catch return git.Error.WriteFailed;
        count += 1;
    }

    // Show truncation message
    if (total_matching > opts.max_count) {
        const remaining = total_matching - opts.max_count;
        stdout.print("\n[{d} more commits, use -n to see more]\n", .{remaining}) catch return git.Error.WriteFailed;
    }
}

fn printCommit(
    allocator: std.mem.Allocator,
    writer: anytype,
    commit: *c.git_commit,
    oid: *const c.git_oid,
    opts: Options,
) !void {
    var sha_buf: [41]u8 = undefined;
    _ = c.git_oid_tostr(&sha_buf, sha_buf.len, oid);
    const sha = std.mem.sliceTo(&sha_buf, 0);

    const message_ptr = c.git_commit_message(commit);
    const message = if (message_ptr) |ptr| std.mem.sliceTo(ptr, 0) else "";
    const subject = if (std.mem.indexOf(u8, message, "\n")) |idx|
        message[0..idx]
    else
        message;

    const author = c.git_commit_author(commit);

    // Concise format: abc123f (2025-01-15) Alice: Add user authentication
    if (author) |a| {
        const full_name = if (a.*.name) |n| std.mem.sliceTo(n, 0) else "Unknown";
        const first_name = if (std.mem.indexOf(u8, full_name, " ")) |idx|
            full_name[0..idx]
        else
            full_name;

        const date_str = try formatDate(allocator, a.*.when.time);
        defer allocator.free(date_str);

        try writer.print("{s} ({s}) {s}: {s}\n", .{ sha[0..7], date_str, first_name, subject });
    } else {
        try writer.print("{s} {s}\n", .{ sha[0..7], subject });
    }

    // Show prompt note if requested
    if (opts.show_prompts) {
        const repo = c.git_commit_owner(commit);
        var note: ?*c.git_note = null;
        if (c.git_note_read(&note, repo, "refs/notes/prompts", oid) == 0) {
            defer c.git_note_free(note);
            const note_msg = c.git_note_message(note);
            if (note_msg) |msg| {
                const prompt_text = std.mem.sliceTo(msg, 0);
                // Truncate long prompts for display
                const max_len: usize = 200;
                if (prompt_text.len > max_len) {
                    try writer.print("  prompt: {s}...\n", .{prompt_text[0..max_len]});
                } else {
                    try writer.print("  prompt: {s}\n", .{prompt_text});
                }
            }
        }
    }
}

fn formatDate(allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
    const SECONDS_PER_DAY: i64 = 86400;
    const days = @divFloor(timestamp, SECONDS_PER_DAY) + 719468;

    const era: i64 = @divFloor(if (days >= 0) days else days - 146096, 146097);
    const doe: u32 = @intCast(days - era * 146097);
    const yoe: u32 = @intCast(@divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365));
    const y: i64 = @as(i64, yoe) + era * 400;
    const doy: u32 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: u32 = @divFloor(5 * doy + 2, 153);
    const d: u32 = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: u32 = if (mp < 10) mp + 3 else mp - 9;

    const year: i64 = if (m <= 2) y + 1 else y;

    return std.fmt.allocPrint(allocator, "{d}-{d:0>2}-{d:0>2}", .{ year, m, d });
}

/// Check if a commit matches all specified filters
fn commitMatchesFilters(repo: ?*c.git_repository, commit: *c.git_commit, opts: Options) bool {
    // Author filter
    if (opts.author) |author_pattern| {
        const author = c.git_commit_author(commit);
        if (author) |a| {
            const name = if (a.*.name) |n| std.mem.sliceTo(n, 0) else "";
            const email = if (a.*.email) |e| std.mem.sliceTo(e, 0) else "";
            if (!containsIgnoreCase(name, author_pattern) and !containsIgnoreCase(email, author_pattern)) {
                return false;
            }
        } else {
            return false;
        }
    }

    // Grep filter (message)
    if (opts.grep) |grep_pattern| {
        const message_ptr = c.git_commit_message(commit);
        if (message_ptr) |ptr| {
            const message = std.mem.sliceTo(ptr, 0);
            if (!containsIgnoreCase(message, grep_pattern)) {
                return false;
            }
        } else {
            return false;
        }
    }

    // Date filters
    const author = c.git_commit_author(commit);
    if (author) |a| {
        const commit_time = a.*.when.time;
        if (opts.since) |since| {
            if (commit_time < since) {
                return false;
            }
        }
        if (opts.until) |until| {
            if (commit_time > until) {
                return false;
            }
        }
    }

    // Path filter
    if (opts.pathspec_count > 0) {
        if (!commitTouchesPath(repo, commit, opts)) {
            return false;
        }
    }

    return true;
}

/// Check if commit touches any of the specified paths
fn commitTouchesPath(repo: ?*c.git_repository, commit: *c.git_commit, opts: Options) bool {
    // Get commit tree
    var commit_tree: ?*c.git_tree = null;
    if (c.git_commit_tree(&commit_tree, commit) < 0) {
        return false;
    }
    defer c.git_tree_free(commit_tree);

    // Get parent tree (or null for root commit)
    var parent_tree: ?*c.git_tree = null;
    if (c.git_commit_parentcount(commit) > 0) {
        var parent: ?*c.git_commit = null;
        if (c.git_commit_parent(&parent, commit, 0) == 0) {
            defer c.git_commit_free(parent);
            _ = c.git_commit_tree(&parent_tree, parent);
        }
    }
    defer if (parent_tree != null) c.git_tree_free(parent_tree);

    // Set up diff options with pathspec
    var diff_opts: c.git_diff_options = undefined;
    _ = c.git_diff_options_init(&diff_opts, c.GIT_DIFF_OPTIONS_VERSION);
    diff_opts.pathspec.strings = @constCast(&opts.pathspecs);
    diff_opts.pathspec.count = opts.pathspec_count;

    // Get diff
    var diff: ?*c.git_diff = null;
    if (c.git_diff_tree_to_tree(&diff, repo, parent_tree, commit_tree, &diff_opts) < 0) {
        return false;
    }
    defer c.git_diff_free(diff);

    // If there are any deltas, the commit touches the path
    return c.git_diff_num_deltas(diff) > 0;
}

/// Case-insensitive substring search (pure function, testable)
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var matches = true;
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            if (toLower(hc) != toLower(nc)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn toLower(char: u8) u8 {
    if (char >= 'A' and char <= 'Z') {
        return char + 32;
    }
    return char;
}

/// Parse a date string into unix timestamp (pure function, testable)
/// Supports: YYYY-MM-DD, "N days ago", "N weeks ago", "N months ago"
pub fn parseDate(date_str: []const u8) ?i64 {
    // Try YYYY-MM-DD format
    if (date_str.len == 10 and date_str[4] == '-' and date_str[7] == '-') {
        const year = std.fmt.parseInt(i32, date_str[0..4], 10) catch return null;
        const month = std.fmt.parseInt(u32, date_str[5..7], 10) catch return null;
        const day = std.fmt.parseInt(u32, date_str[8..10], 10) catch return null;

        return dateToTimestamp(year, month, day);
    }

    // Try relative dates: "N days ago", "N weeks ago", etc.
    // Get current time (approximate - we use a fixed "now" for reproducibility)
    const now = std.time.timestamp();

    if (std.mem.endsWith(u8, date_str, " days ago") or std.mem.endsWith(u8, date_str, " day ago")) {
        const num_end = if (std.mem.indexOf(u8, date_str, " day")) |idx| idx else return null;
        const days = std.fmt.parseInt(i64, date_str[0..num_end], 10) catch return null;
        return now - (days * 86400);
    }

    if (std.mem.endsWith(u8, date_str, " weeks ago") or std.mem.endsWith(u8, date_str, " week ago")) {
        const num_end = if (std.mem.indexOf(u8, date_str, " week")) |idx| idx else return null;
        const weeks = std.fmt.parseInt(i64, date_str[0..num_end], 10) catch return null;
        return now - (weeks * 7 * 86400);
    }

    if (std.mem.endsWith(u8, date_str, " months ago") or std.mem.endsWith(u8, date_str, " month ago")) {
        const num_end = if (std.mem.indexOf(u8, date_str, " month")) |idx| idx else return null;
        const months = std.fmt.parseInt(i64, date_str[0..num_end], 10) catch return null;
        return now - (months * 30 * 86400); // Approximate
    }

    return null;
}

/// Convert year/month/day to unix timestamp (pure function, testable)
pub fn dateToTimestamp(year: i32, month: u32, day: u32) i64 {
    // Convert to days since epoch using inverse of formatDate algorithm
    const y: i64 = @as(i64, year) - @as(i64, if (month <= 2) @as(i64, 1) else @as(i64, 0));
    const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: u32 = @intCast(y - era * 400);
    const mp: u32 = if (month > 2) month - 3 else month + 9;
    const doy: u32 = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe: u32 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days: i64 = era * 146097 + @as(i64, doe) - 719468;

    return days * 86400;
}

// Tests
const testing = std.testing;

test "formatDate - unix epoch" {
    const allocator = testing.allocator;
    const result = try formatDate(allocator, 0);
    defer allocator.free(result);
    try testing.expectEqualStrings("1970-01-01", result);
}

test "formatDate - known date 2025-01-15" {
    const allocator = testing.allocator;
    // 2025-01-15 00:00:00 UTC = 1736899200
    const result = try formatDate(allocator, 1736899200);
    defer allocator.free(result);
    try testing.expectEqualStrings("2025-01-15", result);
}

test "formatDate - leap year 2024-02-29" {
    const allocator = testing.allocator;
    // 2024-02-29 00:00:00 UTC = 1709164800
    const result = try formatDate(allocator, 1709164800);
    defer allocator.free(result);
    try testing.expectEqualStrings("2024-02-29", result);
}

test "formatDate - end of year 2023-12-31" {
    const allocator = testing.allocator;
    // 2023-12-31 00:00:00 UTC = 1703980800
    const result = try formatDate(allocator, 1703980800);
    defer allocator.free(result);
    try testing.expectEqualStrings("2023-12-31", result);
}

test "formatDate - year 2000" {
    const allocator = testing.allocator;
    // 2000-01-01 00:00:00 UTC = 946684800
    const result = try formatDate(allocator, 946684800);
    defer allocator.free(result);
    try testing.expectEqualStrings("2000-01-01", result);
}

// containsIgnoreCase tests
test "containsIgnoreCase - exact match" {
    try testing.expect(containsIgnoreCase("hello", "hello"));
}

test "containsIgnoreCase - case insensitive" {
    try testing.expect(containsIgnoreCase("Hello World", "hello"));
    try testing.expect(containsIgnoreCase("hello world", "HELLO"));
    try testing.expect(containsIgnoreCase("HELLO WORLD", "world"));
}

test "containsIgnoreCase - substring" {
    try testing.expect(containsIgnoreCase("alice@example.com", "alice"));
    try testing.expect(containsIgnoreCase("Alice Smith", "smith"));
}

test "containsIgnoreCase - no match" {
    try testing.expect(!containsIgnoreCase("hello", "world"));
    try testing.expect(!containsIgnoreCase("abc", "abcd"));
}

test "containsIgnoreCase - empty needle" {
    try testing.expect(containsIgnoreCase("anything", ""));
}

test "containsIgnoreCase - needle longer than haystack" {
    try testing.expect(!containsIgnoreCase("hi", "hello"));
}

// parseDate tests
test "parseDate - YYYY-MM-DD format" {
    const ts = parseDate("2025-01-15");
    try testing.expect(ts != null);
    // 2025-01-15 00:00:00 UTC = 1736899200
    try testing.expectEqual(@as(i64, 1736899200), ts.?);
}

test "parseDate - year 2000" {
    const ts = parseDate("2000-01-01");
    try testing.expect(ts != null);
    // 2000-01-01 00:00:00 UTC = 946684800
    try testing.expectEqual(@as(i64, 946684800), ts.?);
}

test "parseDate - invalid format returns null" {
    try testing.expect(parseDate("not-a-date") == null);
    try testing.expect(parseDate("2025/01/15") == null);
    try testing.expect(parseDate("") == null);
}

// dateToTimestamp tests
test "dateToTimestamp - epoch" {
    try testing.expectEqual(@as(i64, 0), dateToTimestamp(1970, 1, 1));
}

test "dateToTimestamp - known date" {
    // 2025-01-15 00:00:00 UTC = 1736899200
    try testing.expectEqual(@as(i64, 1736899200), dateToTimestamp(2025, 1, 15));
}

test "dateToTimestamp - leap year" {
    // 2024-02-29 00:00:00 UTC = 1709164800
    try testing.expectEqual(@as(i64, 1709164800), dateToTimestamp(2024, 2, 29));
}

test "dateToTimestamp - roundtrip with formatDate" {
    const allocator = testing.allocator;
    const ts: i64 = 1703980800; // 2023-12-31
    const formatted = try formatDate(allocator, ts);
    defer allocator.free(formatted);
    const parsed = parseDate(formatted);
    try testing.expectEqual(ts, parsed.?);
}

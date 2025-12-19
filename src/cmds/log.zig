const std = @import("std");
const c = @cImport(@cInclude("git2.h"));
const git = @import("git.zig");

pub const help =
    \\usage: zagi log [-n <count>] [--full]
    \\
    \\Show commit history.
    \\
    \\Options:
    \\  -n <count>  Limit to n commits (default: 10)
    \\  --full      Show full commit details
    \\
;

const Options = struct {
    max_count: usize = 10,
    full: bool = false,
};

pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) (git.Error || error{OutOfMemory})!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Parse options
    var opts = Options{};
    var i: usize = 2; // skip "zagi" and "log"
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--full")) {
            opts.full = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--max-count")) {
            i += 1;
            if (i < args.len) {
                opts.max_count = std.fmt.parseInt(usize, args[i], 10) catch 10;
            }
        } else if (std.mem.startsWith(u8, arg, "-n")) {
            opts.max_count = std.fmt.parseInt(usize, arg[2..], 10) catch 10;
        } else if (std.mem.startsWith(u8, arg, "--max-count=")) {
            opts.max_count = std.fmt.parseInt(usize, arg[12..], 10) catch 10;
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
    var total: usize = 0;

    // Count total commits for truncation message
    var count_walk: ?*c.git_revwalk = null;
    if (c.git_revwalk_new(&count_walk, repo) == 0) {
        defer c.git_revwalk_free(count_walk);
        _ = c.git_revwalk_sorting(count_walk, c.GIT_SORT_TIME);
        if (c.git_revwalk_push_head(count_walk) == 0) {
            var count_oid: c.git_oid = undefined;
            while (c.git_revwalk_next(&count_oid, count_walk) == 0) {
                total += 1;
                if (total > 1000) break;
            }
        }
    }

    while (c.git_revwalk_next(&oid, walk) == 0) {
        if (count >= opts.max_count) break;

        var commit: ?*c.git_commit = null;
        if (c.git_commit_lookup(&commit, repo, &oid) < 0) {
            continue;
        }
        defer c.git_commit_free(commit);

        printCommit(allocator, stdout, commit.?, &oid, opts) catch return git.Error.WriteFailed;
        count += 1;
    }

    // Show truncation message
    if (!opts.full and total > opts.max_count) {
        const remaining = total - opts.max_count;
        stdout.print("\n[{d} more commits, use -n to see more or --full for details]\n", .{remaining}) catch return git.Error.WriteFailed;
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

    if (opts.full) {
        try writer.print("commit {s}\n", .{sha});

        if (author) |a| {
            const name = if (a.*.name) |n| std.mem.sliceTo(n, 0) else "Unknown";
            const email = if (a.*.email) |e| std.mem.sliceTo(e, 0) else "";
            try writer.print("Author: {s} <{s}>\n", .{ name, email });
            try printFormattedDate(writer, a.*.when.time, a.*.when.offset);
        }

        try writer.print("\n", .{});
        var lines = std.mem.splitScalar(u8, message, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) {
                try writer.print("    {s}\n", .{line});
            }
        }
        try writer.print("\n", .{});
    } else {
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

fn printFormattedDate(writer: anytype, timestamp: i64, offset: c_int) !void {
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

    const dow: usize = @intCast(@mod(@divFloor(timestamp, SECONDS_PER_DAY) + 4, 7));
    const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    const secs_in_day: u64 = @intCast(@mod(timestamp, SECONDS_PER_DAY));
    const hours: u64 = secs_in_day / 3600;
    const mins: u64 = (secs_in_day % 3600) / 60;
    const secs: u64 = secs_in_day % 60;

    const offset_hours = @divTrunc(offset, 60);
    const offset_mins: u32 = @intCast(@abs(@mod(offset, 60)));
    const sign: u8 = if (offset >= 0) '+' else '-';

    try writer.print("Date:   {s} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} {d} {c}{d:0>2}{d:0>2}\n", .{
        day_names[dow],
        month_names[m - 1],
        d,
        hours,
        mins,
        secs,
        year,
        sign,
        @as(u32, @intCast(@abs(offset_hours))),
        offset_mins,
    });
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

test "printFormattedDate - basic format" {
    var buf: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    // 2025-01-15 14:30:45 UTC
    try printFormattedDate(writer, 1736951445, 0);
    const result = fbs.getWritten();
    try testing.expectEqualStrings("Date:   Wed Jan 15 14:30:45 2025 +0000\n", result);
}

test "printFormattedDate - negative timezone" {
    var buf: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    // 2025-01-15 14:30:45 UTC, -0800 offset
    try printFormattedDate(writer, 1736951445, -480);
    const result = fbs.getWritten();
    try testing.expectEqualStrings("Date:   Wed Jan 15 14:30:45 2025 -0800\n", result);
}

test "printFormattedDate - positive timezone" {
    var buf: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    // 2025-01-15 14:30:45 UTC, +0530 offset
    try printFormattedDate(writer, 1736951445, 330);
    const result = fbs.getWritten();
    try testing.expectEqualStrings("Date:   Wed Jan 15 14:30:45 2025 +0530\n", result);
}

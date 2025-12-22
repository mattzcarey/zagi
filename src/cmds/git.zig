const std = @import("std");
pub const c = @cImport(@cInclude("git2.h"));

pub const Error = error{
    InitFailed,
    NotARepository,
    IndexOpenFailed,
    IndexWriteFailed,
    StatusFailed,
    FileNotFound,
    RevwalkFailed,
    UsageError,
    WriteFailed,
    AddFailed,
    NothingToCommit,
    CommitFailed,
    UnsupportedFlag,
};

pub fn indexMarker(status: c_uint) []const u8 {
    if (status & c.GIT_STATUS_INDEX_NEW != 0) return "A ";
    if (status & c.GIT_STATUS_INDEX_MODIFIED != 0) return "M ";
    if (status & c.GIT_STATUS_INDEX_DELETED != 0) return "D ";
    if (status & c.GIT_STATUS_INDEX_RENAMED != 0) return "R ";
    if (status & c.GIT_STATUS_INDEX_TYPECHANGE != 0) return "T ";
    return "  ";
}

pub fn workdirMarker(status: c_uint) []const u8 {
    if (status & c.GIT_STATUS_WT_MODIFIED != 0) return " M";
    if (status & c.GIT_STATUS_WT_DELETED != 0) return " D";
    if (status & c.GIT_STATUS_WT_RENAMED != 0) return " R";
    if (status & c.GIT_STATUS_WT_TYPECHANGE != 0) return " T";
    return "  ";
}

/// Counts uncommitted changes in a repository
pub const UncommittedCounts = struct {
    staged: usize,
    unstaged: usize,
    untracked: usize,

    pub fn total(self: UncommittedCounts) usize {
        return self.staged + self.unstaged + self.untracked;
    }

    pub fn workdirTotal(self: UncommittedCounts) usize {
        return self.unstaged + self.untracked;
    }
};

pub fn countUncommitted(repo: ?*c.git_repository) ?UncommittedCounts {
    var status_list: ?*c.git_status_list = null;
    var opts = std.mem.zeroes(c.git_status_options);
    opts.version = c.GIT_STATUS_OPTIONS_VERSION;
    opts.show = c.GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
    opts.flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED;

    if (c.git_status_list_new(&status_list, repo, &opts) < 0) {
        return null;
    }
    defer c.git_status_list_free(status_list);

    var counts = UncommittedCounts{ .staged = 0, .unstaged = 0, .untracked = 0 };
    const count = c.git_status_list_entrycount(status_list);

    for (0..count) |idx| {
        const entry = c.git_status_byindex(status_list, idx);
        if (entry == null) continue;

        const s = entry.*.status;

        // Staged (index) changes
        if (s & (c.GIT_STATUS_INDEX_NEW | c.GIT_STATUS_INDEX_MODIFIED | c.GIT_STATUS_INDEX_DELETED | c.GIT_STATUS_INDEX_RENAMED) != 0) {
            counts.staged += 1;
        }
        // Unstaged workdir changes (modified/deleted tracked files)
        if (s & (c.GIT_STATUS_WT_MODIFIED | c.GIT_STATUS_WT_DELETED | c.GIT_STATUS_WT_RENAMED) != 0) {
            counts.unstaged += 1;
        }
        // Untracked files
        if (s & c.GIT_STATUS_WT_NEW != 0) {
            counts.untracked += 1;
        }
    }

    return counts;
}

const testing = std.testing;

test "indexMarker - new file" {
    try testing.expectEqualStrings("A ", indexMarker(c.GIT_STATUS_INDEX_NEW));
}

test "indexMarker - modified file" {
    try testing.expectEqualStrings("M ", indexMarker(c.GIT_STATUS_INDEX_MODIFIED));
}

test "indexMarker - deleted file" {
    try testing.expectEqualStrings("D ", indexMarker(c.GIT_STATUS_INDEX_DELETED));
}

test "indexMarker - renamed file" {
    try testing.expectEqualStrings("R ", indexMarker(c.GIT_STATUS_INDEX_RENAMED));
}

test "indexMarker - typechange" {
    try testing.expectEqualStrings("T ", indexMarker(c.GIT_STATUS_INDEX_TYPECHANGE));
}

test "indexMarker - unknown status returns spaces" {
    try testing.expectEqualStrings("  ", indexMarker(0));
}

test "workdirMarker - modified file" {
    try testing.expectEqualStrings(" M", workdirMarker(c.GIT_STATUS_WT_MODIFIED));
}

test "workdirMarker - deleted file" {
    try testing.expectEqualStrings(" D", workdirMarker(c.GIT_STATUS_WT_DELETED));
}

test "workdirMarker - renamed file" {
    try testing.expectEqualStrings(" R", workdirMarker(c.GIT_STATUS_WT_RENAMED));
}

test "workdirMarker - typechange" {
    try testing.expectEqualStrings(" T", workdirMarker(c.GIT_STATUS_WT_TYPECHANGE));
}

test "workdirMarker - unknown status returns spaces" {
    try testing.expectEqualStrings("  ", workdirMarker(0));
}

test "indexMarker - combined status picks first match" {
    // When multiple flags are set, should return first match (NEW)
    const combined = c.GIT_STATUS_INDEX_NEW | c.GIT_STATUS_INDEX_MODIFIED;
    try testing.expectEqualStrings("A ", indexMarker(combined));
}

test "UncommittedCounts.total sums all categories" {
    const counts = UncommittedCounts{ .staged = 2, .unstaged = 3, .untracked = 5 };
    try testing.expectEqual(@as(usize, 10), counts.total());
}

test "UncommittedCounts.total returns zero when empty" {
    const counts = UncommittedCounts{ .staged = 0, .unstaged = 0, .untracked = 0 };
    try testing.expectEqual(@as(usize, 0), counts.total());
}

test "UncommittedCounts.workdirTotal excludes staged" {
    const counts = UncommittedCounts{ .staged = 10, .unstaged = 3, .untracked = 5 };
    try testing.expectEqual(@as(usize, 8), counts.workdirTotal());
}

test "UncommittedCounts.workdirTotal with only staged returns zero" {
    const counts = UncommittedCounts{ .staged = 5, .unstaged = 0, .untracked = 0 };
    try testing.expectEqual(@as(usize, 0), counts.workdirTotal());
}

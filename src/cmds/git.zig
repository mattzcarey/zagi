const std = @import("std");
const c = @cImport(@cInclude("git2.h"));

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

const std = @import("std");
const passthrough = @import("passthrough.zig");
const log = @import("cmds/log.zig");
const status = @import("cmds/status.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("usage: zagi <command> [args...]\n", .{});
        std.process.exit(1);
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "log")) {
        try log.run(allocator, args);
    } else if (std.mem.eql(u8, cmd, "status")) {
        try status.run(allocator, args);
    } else {
        try passthrough.run(allocator, args);
    }
}

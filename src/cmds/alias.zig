const std = @import("std");
const builtin = @import("builtin");
const git = @import("git.zig");

pub const help =
    \\usage: zagi alias [--print]
    \\
    \\Set up git alias to zagi in your shell config.
    \\
    \\Options:
    \\  --print, -p  Print alias command instead of adding it
    \\
;

const Shell = enum {
    bash,
    zsh,
    fish,
    powershell,
    cmd,
    unknown,
};

pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) git.Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    var print_only = false;

    // Check for flags
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp(stdout) catch return git.Error.WriteFailed;
            return;
        }
        if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) {
            print_only = true;
        }
    }

    const shell = detectShell();

    if (print_only) {
        printInitInstructions(stdout, shell) catch return git.Error.WriteFailed;
        return;
    }

    // Try to automatically add to shell config
    addToShellConfig(allocator, shell, stdout) catch return git.Error.WriteFailed;
}

fn detectShell() Shell {
    if (builtin.os.tag == .windows) {
        // On Windows, check for PowerShell or default to cmd
        if (std.posix.getenv("PSModulePath")) |_| {
            return .powershell;
        }
        return .cmd;
    }

    // Unix-like: check SHELL environment variable
    const shell_path = std.posix.getenv("SHELL") orelse return .unknown;

    if (std.mem.endsWith(u8, shell_path, "/bash") or std.mem.eql(u8, shell_path, "bash")) {
        return .bash;
    } else if (std.mem.endsWith(u8, shell_path, "/zsh") or std.mem.eql(u8, shell_path, "zsh")) {
        return .zsh;
    } else if (std.mem.endsWith(u8, shell_path, "/fish") or std.mem.eql(u8, shell_path, "fish")) {
        return .fish;
    }

    return .unknown;
}

fn printHelp(writer: anytype) !void {
    try writer.print(
        \\zagi alias - Set up zagi as your git command
        \\
        \\Usage: zagi alias [options]
        \\
        \\Automatically adds 'alias git=zagi' to your shell config file.
        \\
        \\Options:
        \\  --print, -p  Print the alias command instead of adding it
        \\  --help, -h   Show this help
        \\
        \\Supported shells:
        \\  - bash  (~/.bashrc)
        \\  - zsh   (~/.zshrc)
        \\  - fish  (~/.config/fish/config.fish)
        \\
    , .{});
}

fn printInitInstructions(writer: anytype, shell: Shell) !void {
    switch (shell) {
        .bash => {
            try writer.print(
                \\# Add to ~/.bashrc:
                \\alias git='{s}'
                \\
            , .{getZagiPath()});
        },
        .zsh => {
            try writer.print(
                \\# Add to ~/.zshrc:
                \\alias git='{s}'
                \\
            , .{getZagiPath()});
        },
        .fish => {
            try writer.print(
                \\# Add to ~/.config/fish/config.fish:
                \\alias git '{s}'
                \\
            , .{getZagiPath()});
        },
        .powershell => {
            try writer.print(
                \\# Add to $PROFILE:
                \\Set-Alias -Name git -Value '{s}'
                \\
            , .{getZagiPath()});
        },
        .cmd => {
            try writer.print(
                \\:: Create a batch file at a location in your PATH:
                \\:: git.bat
                \\@echo off
                \\"{s}" %*
                \\
            , .{getZagiPath()});
        },
        .unknown => {
            try writer.print(
                \\# Could not detect shell. Common configurations:
                \\
                \\# bash/zsh:
                \\alias git='{s}'
                \\
                \\# fish:
                \\alias git '{s}'
                \\
                \\# PowerShell:
                \\Set-Alias -Name git -Value '{s}'
                \\
            , .{ getZagiPath(), getZagiPath(), getZagiPath() });
        },
    }
}

fn getZagiPath() []const u8 {
    // For now, assume zagi is in PATH
    // Could be enhanced to detect actual binary location
    return "zagi";
}

fn addToShellConfig(allocator: std.mem.Allocator, shell: Shell, writer: anytype) !void {
    const home = std.posix.getenv("HOME") orelse {
        try writer.print("Could not determine HOME directory. Use --print to see the alias command.\n", .{});
        return;
    };

    const config_path: ?[]const u8 = switch (shell) {
        .bash => blk: {
            // Check for .bashrc first, then .bash_profile
            const bashrc = std.fmt.allocPrint(allocator, "{s}/.bashrc", .{home}) catch return error.OutOfMemory;
            break :blk bashrc;
        },
        .zsh => std.fmt.allocPrint(allocator, "{s}/.zshrc", .{home}) catch return error.OutOfMemory,
        .fish => std.fmt.allocPrint(allocator, "{s}/.config/fish/config.fish", .{home}) catch return error.OutOfMemory,
        .powershell, .cmd, .unknown => null,
    };

    if (config_path == null) {
        try writer.print("Automatic setup not supported for this shell. Use --print to see the alias command.\n", .{});
        return;
    }

    const path = config_path.?;
    defer allocator.free(path);

    const alias_line = switch (shell) {
        .bash, .zsh => "alias git='zagi'",
        .fish => "alias git 'zagi'",
        else => unreachable,
    };

    // Check if alias already exists
    if (std.fs.cwd().openFile(path, .{})) |file| {
        defer file.close();
        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
            try writer.print("Could not read {s}\n", .{path});
            return;
        };
        defer allocator.free(content);

        if (std.mem.indexOf(u8, content, "alias git=") != null or
            std.mem.indexOf(u8, content, "alias git ") != null)
        {
            try writer.print("Git alias already exists in {s}\n", .{path});
            return;
        }
    } else |_| {
        // File doesn't exist, we'll create it
    }

    // Append alias to config file
    const file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |err| {
        if (err == error.FileNotFound) {
            // Create the file if it doesn't exist
            const new_file = std.fs.cwd().createFile(path, .{}) catch {
                try writer.print("Could not create {s}\n", .{path});
                return;
            };
            new_file.close();
            // Re-open for appending
            const f = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch {
                try writer.print("Could not open {s} for writing\n", .{path});
                return;
            };
            return writeAlias(f, path, alias_line, writer);
        }
        try writer.print("Could not open {s} for writing\n", .{path});
        return;
    };

    return writeAlias(file, path, alias_line, writer);
}

fn writeAlias(file: std.fs.File, path: []const u8, alias_line: []const u8, writer: anytype) !void {
    defer file.close();

    // Seek to end
    file.seekFromEnd(0) catch {};

    // Write alias using writeAll instead of writer
    file.writeAll("\n# zagi - a better git for agents\n") catch {
        try writer.print("Could not write to {s}\n", .{path});
        return;
    };
    file.writeAll(alias_line) catch {
        try writer.print("Could not write to {s}\n", .{path});
        return;
    };
    file.writeAll("\n") catch {
        try writer.print("Could not write to {s}\n", .{path});
        return;
    };

    try writer.print("Added to {s}:\n  {s}\n\nRestart your shell or run: source {s}\n", .{ path, alias_line, path });
}

// Tests
const testing = std.testing;

test "printHelp outputs usage information" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try printHelp(output.writer());

    const result = output.items;
    try testing.expect(std.mem.indexOf(u8, result, "zagi alias") != null);
    try testing.expect(std.mem.indexOf(u8, result, "--print") != null);
    try testing.expect(std.mem.indexOf(u8, result, "--help") != null);
}

test "printInitInstructions for bash" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try printInitInstructions(output.writer(), .bash);

    const result = output.items;
    try testing.expect(std.mem.indexOf(u8, result, ".bashrc") != null);
    try testing.expect(std.mem.indexOf(u8, result, "alias git='zagi'") != null);
}

test "printInitInstructions for zsh" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try printInitInstructions(output.writer(), .zsh);

    const result = output.items;
    try testing.expect(std.mem.indexOf(u8, result, ".zshrc") != null);
    try testing.expect(std.mem.indexOf(u8, result, "alias git='zagi'") != null);
}

test "printInitInstructions for fish" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try printInitInstructions(output.writer(), .fish);

    const result = output.items;
    try testing.expect(std.mem.indexOf(u8, result, "config.fish") != null);
    try testing.expect(std.mem.indexOf(u8, result, "alias git 'zagi'") != null);
}

test "printInitInstructions for powershell" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try printInitInstructions(output.writer(), .powershell);

    const result = output.items;
    try testing.expect(std.mem.indexOf(u8, result, "Set-Alias") != null);
    try testing.expect(std.mem.indexOf(u8, result, "$PROFILE") != null);
}

test "printInitInstructions for unknown shell shows all options" {
    var output = std.array_list.Managed(u8).init(testing.allocator);
    defer output.deinit();

    try printInitInstructions(output.writer(), .unknown);

    const result = output.items;
    try testing.expect(std.mem.indexOf(u8, result, "bash/zsh") != null);
    try testing.expect(std.mem.indexOf(u8, result, "fish") != null);
    try testing.expect(std.mem.indexOf(u8, result, "PowerShell") != null);
}

test "getZagiPath returns zagi" {
    try testing.expectEqualStrings("zagi", getZagiPath());
}

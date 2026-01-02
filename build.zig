const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libgit2_dep = b.dependency("libgit2", .{
        .target = target,
        .optimize = optimize,
    });

    // Get version from git tag at build time
    const version = getVersion(b);

    const exe = b.addExecutable(.{
        .name = "zagi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Pass version as build option
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    exe.root_module.addOptions("build_options", options);

    exe.root_module.linkLibrary(libgit2_dep.artifact("git2"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_unit_tests.root_module.addOptions("build_options", options);

    const log_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmds/log.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    log_tests.root_module.linkLibrary(libgit2_dep.artifact("git2"));

    const git_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmds/git.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    git_tests.root_module.linkLibrary(libgit2_dep.artifact("git2"));

    const alias_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmds/alias.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const add_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmds/add.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    add_tests.root_module.linkLibrary(libgit2_dep.artifact("git2"));

    const commit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmds/commit.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    commit_tests.root_module.linkLibrary(libgit2_dep.artifact("git2"));

    const diff_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmds/diff.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    diff_tests.root_module.linkLibrary(libgit2_dep.artifact("git2"));

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const run_log_tests = b.addRunArtifact(log_tests);
    const run_git_tests = b.addRunArtifact(git_tests);
    const run_alias_tests = b.addRunArtifact(alias_tests);
    const run_add_tests = b.addRunArtifact(add_tests);
    const run_commit_tests = b.addRunArtifact(commit_tests);
    const run_diff_tests = b.addRunArtifact(diff_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_log_tests.step);
    test_step.dependOn(&run_git_tests.step);
    test_step.dependOn(&run_alias_tests.step);
    test_step.dependOn(&run_add_tests.step);
    test_step.dependOn(&run_commit_tests.step);
    test_step.dependOn(&run_diff_tests.step);
}

fn getVersion(b: *std.Build) []const u8 {
    // Try to get version from git describe
    // runAllowFail returns the stdout on success, or an error on failure
    // --dirty appends "-dirty" if there are uncommitted changes
    var _code: u8 = 0;
    const result = b.runAllowFail(&.{ "git", "describe", "--tags", "--always", "--dirty" }, &_code, .Inherit) catch {
        return "dev";
    };

    // Trim whitespace and strip leading 'v' if present
    const trimmed = std.mem.trim(u8, result, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return "dev";
    }

    // Strip leading 'v' from version tags (e.g., "v0.1.6" -> "0.1.6")
    if (trimmed[0] == 'v') {
        return trimmed[1..];
    }

    return trimmed;
}

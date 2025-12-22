const std = @import("std");
const git = @import("git.zig");
const c = git.c;

pub const help =
    \\usage: git fork [<name>] [options]
    \\
    \\Manage parallel working copies of a repository.
    \\
    \\Commands:
    \\  git fork <name>             Create a new fork in .forks/<name>/
    \\  git fork                    List existing forks
    \\  git fork --pick <name>      Merge fork into base (safe)
    \\  git fork --promote <name>   Hard checkout fork to base (destructive)
    \\  git fork --delete <name>    Delete a specific fork
    \\  git fork --delete-all       Delete all forks
    \\
    \\Forks are ephemeral worktrees for parallel experimentation.
    \\
;

pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) git.Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Parse arguments
    var fork_name: ?[]const u8 = null;
    var pick_name: ?[]const u8 = null;
    var promote_name: ?[]const u8 = null;
    var delete_name: ?[]const u8 = null;
    var delete_all = false;

    var i: usize = 2; // Skip "zagi" and "fork"
    while (i < args.len) : (i += 1) {
        const arg = std.mem.sliceTo(args[i], 0);

        if (std.mem.eql(u8, arg, "--pick")) {
            i += 1;
            if (i >= args.len) {
                return git.Error.UsageError;
            }
            pick_name = std.mem.sliceTo(args[i], 0);
        } else if (std.mem.startsWith(u8, arg, "--pick=")) {
            pick_name = arg[7..];
        } else if (std.mem.eql(u8, arg, "--promote")) {
            i += 1;
            if (i >= args.len) {
                return git.Error.UsageError;
            }
            promote_name = std.mem.sliceTo(args[i], 0);
        } else if (std.mem.startsWith(u8, arg, "--promote=")) {
            promote_name = arg[10..];
        } else if (std.mem.eql(u8, arg, "--delete")) {
            i += 1;
            if (i >= args.len) {
                return git.Error.UsageError;
            }
            delete_name = std.mem.sliceTo(args[i], 0);
        } else if (std.mem.startsWith(u8, arg, "--delete=")) {
            delete_name = arg[9..];
        } else if (std.mem.eql(u8, arg, "--delete-all")) {
            delete_all = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            stdout.print("{s}", .{help}) catch {};
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return git.Error.UnsupportedFlag;
        } else {
            // Positional argument = fork name
            fork_name = arg;
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

    // Check if we're inside a worktree (fork)
    if (c.git_repository_is_worktree(repo) != 0) {
        stdout.print("error: already in a fork, run from base\n", .{}) catch {};
        return git.Error.UsageError;
    }

    // Dispatch to action
    if (pick_name) |name| {
        try pickFork(allocator, repo, name, stdout);
    } else if (promote_name) |name| {
        try promoteFork(allocator, repo, name, stdout);
    } else if (delete_name) |name| {
        try deleteFork(allocator, repo, name, stdout);
    } else if (delete_all) {
        try deleteAllForks(allocator, repo, stdout);
    } else if (fork_name) |name| {
        try createFork(allocator, repo, name, stdout);
    } else {
        try listForks(allocator, repo, stdout);
    }
}

fn validateForkName(repo: ?*c.git_repository, name: []const u8, stdout: anytype) !void {
    // Check for empty name or invalid characters
    if (hasInvalidChars(name)) {
        if (name.len == 0) {
            stdout.print("error: fork name cannot be empty\n", .{}) catch {};
        } else {
            stdout.print("error: fork name cannot contain '/', '\\', '..', or start with '.' or '-'\n", .{}) catch {};
        }
        return git.Error.UsageError;
    }

    // Check if resulting path would be too long
    const workdir = c.git_repository_workdir(repo);
    if (workdir != null) {
        const workdir_slice = std.mem.sliceTo(workdir, 0);
        // .forks/ = 7 chars, need some headroom for files inside
        const total_len = workdir_slice.len + 7 + name.len;
        if (total_len > std.fs.max_path_bytes - 256) {
            stdout.print("error: fork name too long, would exceed path limit\n", .{}) catch {};
            return git.Error.UsageError;
        }
    }

    // Check if a branch with this name already exists
    var branch_name_buf: [512]u8 = undefined;
    const branch_name = std.fmt.bufPrint(&branch_name_buf, "refs/heads/{s}", .{name}) catch return git.Error.WriteFailed;

    var branch_name_z: [512]u8 = undefined;
    @memcpy(branch_name_z[0..branch_name.len], branch_name);
    branch_name_z[branch_name.len] = 0;

    var branch_ref: ?*c.git_reference = null;
    if (c.git_reference_lookup(&branch_ref, repo, &branch_name_z) == 0) {
        // Branch exists - check if it's a worktree branch (which is ok to reuse)
        c.git_reference_free(branch_ref);

        // Check if worktree with this name exists
        var name_z: [256]u8 = undefined;
        @memcpy(name_z[0..name.len], name);
        name_z[name.len] = 0;

        var worktree: ?*c.git_worktree = null;
        if (c.git_worktree_lookup(&worktree, repo, &name_z) == 0) {
            c.git_worktree_free(worktree);
            stdout.print("error: fork '{s}' already exists\n", .{name}) catch {};
            return git.Error.UsageError;
        }

        // Branch exists but no worktree - it's a regular branch
        stdout.print("error: branch '{s}' already exists, choose a different fork name\n", .{name}) catch {};
        return git.Error.UsageError;
    }
}

fn createFork(allocator: std.mem.Allocator, repo: ?*c.git_repository, name: []const u8, stdout: anytype) !void {
    _ = allocator;

    // Validate fork name first
    try validateForkName(repo, name, stdout);

    // Get repo root path
    const workdir = c.git_repository_workdir(repo);
    if (workdir == null) {
        return git.Error.NotARepository;
    }
    const workdir_slice = std.mem.sliceTo(workdir, 0);

    // Build path: <workdir>/.forks/<name>
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const fork_path = std.fmt.bufPrint(&path_buf, "{s}.forks/{s}", .{ workdir_slice, name }) catch {
        return git.Error.WriteFailed;
    };

    // Null-terminate for C
    var path_z: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(path_z[0..fork_path.len], fork_path);
    path_z[fork_path.len] = 0;

    // Null-terminate name for C
    var name_z: [256]u8 = undefined;
    if (name.len >= name_z.len) {
        return git.Error.UsageError;
    }
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;

    // Create .forks directory if needed
    var forks_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const forks_dir = std.fmt.bufPrint(&forks_dir_buf, "{s}.forks", .{workdir_slice}) catch {
        return git.Error.WriteFailed;
    };

    const first_fork = std.fs.accessAbsolute(forks_dir, .{}) == error.FileNotFound;
    std.fs.makeDirAbsolute(forks_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            return git.Error.WriteFailed;
        }
    };

    // Add .forks/ to .gitignore on first fork
    if (first_fork) {
        var gitignore_buf: [std.fs.max_path_bytes]u8 = undefined;
        const gitignore_path = std.fmt.bufPrint(&gitignore_buf, "{s}.gitignore", .{workdir_slice}) catch {
            return git.Error.WriteFailed;
        };

        // Check if .forks/ is already in .gitignore by reading the whole file
        var needs_add = true;
        if (std.fs.openFileAbsolute(gitignore_path, .{})) |file| {
            defer file.close();
            var content_buf: [8192]u8 = undefined;
            const bytes_read = file.readAll(&content_buf) catch 0;
            const content = content_buf[0..bytes_read];

            // Check each line
            var iter = std.mem.splitScalar(u8, content, '\n');
            while (iter.next()) |line| {
                if (std.mem.eql(u8, line, ".forks/") or std.mem.eql(u8, line, ".forks")) {
                    needs_add = false;
                    break;
                }
            }
        } else |_| {}

        if (needs_add) {
            // Append .forks/ to .gitignore (or create if doesn't exist)
            const gitignore = std.fs.openFileAbsolute(gitignore_path, .{ .mode = .read_write }) catch |err| {
                if (err == error.FileNotFound) {
                    // Create new .gitignore
                    if (std.fs.createFileAbsolute(gitignore_path, .{})) |file| {
                        defer file.close();
                        file.writeAll(".forks/\n") catch {};
                    } else |_| {}
                    return createForkWorktree(repo, &name_z, &path_z, name, stdout);
                }
                return git.Error.WriteFailed;
            };
            defer gitignore.close();

            // Seek to end and check if we need a newline
            const stat = gitignore.stat() catch return git.Error.WriteFailed;
            if (stat.size > 0) {
                gitignore.seekTo(stat.size - 1) catch return git.Error.WriteFailed;
                var last_byte: [1]u8 = undefined;
                _ = gitignore.readAll(&last_byte) catch return git.Error.WriteFailed;
                gitignore.seekTo(stat.size) catch return git.Error.WriteFailed;
                if (last_byte[0] != '\n') {
                    gitignore.writeAll("\n") catch return git.Error.WriteFailed;
                }
            }
            gitignore.writeAll(".forks/\n") catch return git.Error.WriteFailed;
        }
    }

    return createForkWorktree(repo, &name_z, &path_z, name, stdout);
}

fn createForkWorktree(repo: ?*c.git_repository, name_z: *[256]u8, path_z: *[std.fs.max_path_bytes]u8, name: []const u8, stdout: anytype) !void {
    // Initialize worktree add options
    var opts: c.git_worktree_add_options = .{
        .version = c.GIT_WORKTREE_ADD_OPTIONS_VERSION,
        .lock = 0,
        .checkout_existing = 0,
        .ref = null,
        .checkout_options = .{
            .version = c.GIT_CHECKOUT_OPTIONS_VERSION,
            .checkout_strategy = c.GIT_CHECKOUT_SAFE,
            .disable_filters = 0,
            .dir_mode = 0,
            .file_mode = 0,
            .file_open_flags = 0,
            .notify_flags = 0,
            .notify_cb = null,
            .notify_payload = null,
            .progress_cb = null,
            .progress_payload = null,
            .paths = .{ .strings = null, .count = 0 },
            .baseline = null,
            .baseline_index = null,
            .target_directory = null,
            .ancestor_label = null,
            .our_label = null,
            .their_label = null,
            .perfdata_cb = null,
            .perfdata_payload = null,
        },
    };

    // Create the worktree
    var worktree: ?*c.git_worktree = null;
    const result = c.git_worktree_add(&worktree, repo, name_z, path_z, &opts);
    if (result < 0) {
        const err = c.git_error_last();
        if (err != null) {
            const msg = std.mem.sliceTo(err.*.message, 0);
            stdout.print("error: {s}\n", .{msg}) catch {};
        }
        return git.Error.WriteFailed;
    }
    defer c.git_worktree_free(worktree);

    // Success output
    stdout.print("forked: {s}\n", .{name}) catch return git.Error.WriteFailed;
    stdout.print("  .forks/{s}/\n", .{name}) catch return git.Error.WriteFailed;
    stdout.print("\nhint: cd .forks/{s} && <work here>\n", .{name}) catch return git.Error.WriteFailed;
    stdout.print("      when done: git fork --pick {s}\n", .{name}) catch return git.Error.WriteFailed;
}

fn listForks(allocator: std.mem.Allocator, repo: ?*c.git_repository, stdout: anytype) !void {
    var worktree_list: c.git_strarray = .{ .strings = null, .count = 0 };
    if (c.git_worktree_list(&worktree_list, repo) < 0) {
        return git.Error.StatusFailed;
    }
    defer c.git_strarray_free(&worktree_list);

    if (worktree_list.count == 0) {
        stdout.print("no forks\n", .{}) catch return git.Error.WriteFailed;
        return;
    }

    stdout.print("forks:\n", .{}) catch return git.Error.WriteFailed;

    for (0..worktree_list.count) |idx| {
        const name_ptr = worktree_list.strings[idx];
        const name = std.mem.sliceTo(name_ptr, 0);

        // Get commit count ahead of main
        const ahead = getCommitsAhead(allocator, repo, name) catch 0;

        if (ahead > 0) {
            stdout.print("  {s}  ({d} commit{s} ahead)\n", .{
                name,
                ahead,
                if (ahead == 1) "" else "s",
            }) catch return git.Error.WriteFailed;
        } else {
            stdout.print("  {s}\n", .{name}) catch return git.Error.WriteFailed;
        }
    }
}

fn getCommitsAhead(allocator: std.mem.Allocator, repo: ?*c.git_repository, fork_name: []const u8) !usize {
    _ = allocator;

    // Get HEAD commit of main
    var main_ref: ?*c.git_reference = null;
    if (c.git_repository_head(&main_ref, repo) < 0) {
        return 0;
    }
    defer c.git_reference_free(main_ref);

    const main_oid = c.git_reference_target(main_ref);
    if (main_oid == null) return 0;

    // Get the fork's branch ref
    var branch_name_buf: [512]u8 = undefined;
    const branch_name = std.fmt.bufPrint(&branch_name_buf, "refs/heads/{s}", .{fork_name}) catch return 0;

    var branch_name_z: [512]u8 = undefined;
    @memcpy(branch_name_z[0..branch_name.len], branch_name);
    branch_name_z[branch_name.len] = 0;

    var fork_ref: ?*c.git_reference = null;
    if (c.git_reference_lookup(&fork_ref, repo, &branch_name_z) < 0) {
        return 0;
    }
    defer c.git_reference_free(fork_ref);

    const fork_oid = c.git_reference_target(fork_ref);
    if (fork_oid == null) return 0;

    // Count commits ahead
    var ahead: usize = 0;
    var behind: usize = 0;
    if (c.git_graph_ahead_behind(&ahead, &behind, repo, fork_oid, main_oid) < 0) {
        return 0;
    }

    return ahead;
}

fn checkNotDetachedHead(repo: ?*c.git_repository, stdout: anytype) !void {
    if (c.git_repository_head_detached(repo) != 0) {
        stdout.print("error: cannot pick/promote in detached HEAD state\n", .{}) catch {};
        stdout.print("hint: checkout a branch first: git checkout <branch>\n", .{}) catch {};
        return git.Error.UsageError;
    }
}

/// Opens the repository for a fork worktree by name
fn getForkRepo(repo: ?*c.git_repository, name: []const u8) ?*c.git_repository {
    var name_z: [256]u8 = undefined;
    if (name.len >= name_z.len) return null;
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;

    var worktree: ?*c.git_worktree = null;
    if (c.git_worktree_lookup(&worktree, repo, &name_z) < 0) return null;
    defer c.git_worktree_free(worktree);

    const wt_path = c.git_worktree_path(worktree);
    if (wt_path == null) return null;

    const wt_path_slice = std.mem.sliceTo(wt_path, 0);
    var path_z: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(path_z[0..wt_path_slice.len], wt_path_slice);
    path_z[wt_path_slice.len] = 0;

    var fork_repo: ?*c.git_repository = null;
    if (c.git_repository_open(&fork_repo, &path_z) < 0) return null;

    return fork_repo;
}

fn pickFork(allocator: std.mem.Allocator, repo: ?*c.git_repository, name: []const u8, stdout: anytype) !void {
    _ = allocator;

    // Check for detached HEAD
    try checkNotDetachedHead(repo, stdout);

    // Check for uncommitted changes in the fork worktree
    const fork_repo = getForkRepo(repo, name);
    if (fork_repo != null) {
        defer c.git_repository_free(fork_repo);

        if (git.countUncommitted(fork_repo)) |counts| {
            const total = counts.total();
            if (total > 0) {
                stdout.print("warning: fork '{s}' has uncommitted changes\n", .{name}) catch {};
                stdout.print("  {d} file{s} not committed\n", .{ total, if (total == 1) "" else "s" }) catch {};
                stdout.print("\nhint: cd .forks/{s} && git add . && git commit -m \"...\"\n\n", .{name}) catch {};
            }
        }
    }

    // Check if we're already in a merge state
    const state = c.git_repository_state(repo);
    if (state == c.GIT_REPOSITORY_STATE_MERGE) {
        stdout.print("error: a merge is already in progress\n", .{}) catch {};
        stdout.print("\nTo complete the previous merge:\n", .{}) catch {};
        stdout.print("  1. Resolve any conflicts\n", .{}) catch {};
        stdout.print("  2. git add <resolved files>\n", .{}) catch {};
        stdout.print("  3. git commit\n", .{}) catch {};
        stdout.print("\nTo abort the previous merge:\n", .{}) catch {};
        stdout.print("  git merge --abort\n", .{}) catch {};
        return git.Error.UsageError;
    }

    // Get the fork's branch ref
    var branch_name_buf: [512]u8 = undefined;
    const branch_name = std.fmt.bufPrint(&branch_name_buf, "refs/heads/{s}", .{name}) catch return git.Error.WriteFailed;

    var branch_name_z: [512]u8 = undefined;
    @memcpy(branch_name_z[0..branch_name.len], branch_name);
    branch_name_z[branch_name.len] = 0;

    var fork_ref: ?*c.git_reference = null;
    if (c.git_reference_lookup(&fork_ref, repo, &branch_name_z) < 0) {
        stdout.print("error: fork '{s}' not found\n", .{name}) catch {};
        return git.Error.FileNotFound;
    }
    defer c.git_reference_free(fork_ref);

    // Create annotated commit for the fork
    var annotated_commit: ?*c.git_annotated_commit = null;
    if (c.git_annotated_commit_from_ref(&annotated_commit, repo, fork_ref) < 0) {
        stdout.print("error: failed to get fork commit\n", .{}) catch {};
        return git.Error.RevwalkFailed;
    }
    defer c.git_annotated_commit_free(annotated_commit);

    // Analyze the merge
    var analysis: c.git_merge_analysis_t = 0;
    var preference: c.git_merge_preference_t = 0;
    var annotated_commits = [_]?*c.git_annotated_commit{annotated_commit};

    if (c.git_merge_analysis(&analysis, &preference, repo, @ptrCast(&annotated_commits), 1) < 0) {
        stdout.print("error: merge analysis failed\n", .{}) catch {};
        return git.Error.RevwalkFailed;
    }

    // Check if already up-to-date
    if ((analysis & c.GIT_MERGE_ANALYSIS_UP_TO_DATE) != 0) {
        stdout.print("already up to date with {s}\n", .{name}) catch {};
        return;
    }

    // Handle fast-forward
    if ((analysis & c.GIT_MERGE_ANALYSIS_FASTFORWARD) != 0) {
        const target_oid = c.git_annotated_commit_id(annotated_commit);

        // Get the target commit and its tree for checkout
        var target_commit: ?*c.git_commit = null;
        if (c.git_commit_lookup(&target_commit, repo, target_oid) < 0) {
            return git.Error.RevwalkFailed;
        }
        defer c.git_commit_free(target_commit);

        var target_tree: ?*c.git_tree = null;
        if (c.git_commit_tree(&target_tree, target_commit) < 0) {
            return git.Error.RevwalkFailed;
        }
        defer c.git_tree_free(target_tree);

        // Checkout the tree BEFORE updating HEAD (preserves local changes)
        var checkout_opts = std.mem.zeroes(c.git_checkout_options);
        checkout_opts.version = c.GIT_CHECKOUT_OPTIONS_VERSION;
        checkout_opts.checkout_strategy = c.GIT_CHECKOUT_SAFE;

        if (c.git_checkout_tree(repo, @ptrCast(target_tree), &checkout_opts) < 0) {
            const err = c.git_error_last();
            if (err != null) {
                const msg = std.mem.sliceTo(err.*.message, 0);
                stdout.print("error: {s}\n", .{msg}) catch {};
                stdout.print("hint: commit or stash changes first\n", .{}) catch {};
            }
            return git.Error.WriteFailed;
        }

        // Get HEAD ref
        var head_ref: ?*c.git_reference = null;
        if (c.git_repository_head(&head_ref, repo) < 0) {
            return git.Error.RevwalkFailed;
        }
        defer c.git_reference_free(head_ref);

        // Fast-forward HEAD to target
        var new_ref: ?*c.git_reference = null;
        const ref_name = c.git_reference_name(head_ref);
        if (c.git_reference_create(&new_ref, repo, ref_name, target_oid, 1, "fork --pick (fast-forward)") < 0) {
            stdout.print("error: fast-forward failed\n", .{}) catch {};
            return git.Error.WriteFailed;
        }
        if (new_ref != null) c.git_reference_free(new_ref);

        stdout.print("picked: {s} (fast-forward)\n", .{name}) catch return git.Error.WriteFailed;
        return;
    }

    // Normal merge
    if ((analysis & c.GIT_MERGE_ANALYSIS_NORMAL) != 0) {
        var merge_opts = std.mem.zeroes(c.git_merge_options);
        merge_opts.version = c.GIT_MERGE_OPTIONS_VERSION;

        var checkout_opts = std.mem.zeroes(c.git_checkout_options);
        checkout_opts.version = c.GIT_CHECKOUT_OPTIONS_VERSION;
        checkout_opts.checkout_strategy = c.GIT_CHECKOUT_SAFE | c.GIT_CHECKOUT_ALLOW_CONFLICTS;

        // Perform the merge
        if (c.git_merge(repo, @ptrCast(&annotated_commits), 1, &merge_opts, &checkout_opts) < 0) {
            const err = c.git_error_last();
            if (err != null) {
                const msg = std.mem.sliceTo(err.*.message, 0);
                stdout.print("error: {s}\n", .{msg}) catch {};
            }
            return git.Error.WriteFailed;
        }

        // Check for conflicts
        var index: ?*c.git_index = null;
        if (c.git_repository_index(&index, repo) < 0) {
            return git.Error.IndexOpenFailed;
        }
        defer c.git_index_free(index);

        if (c.git_index_has_conflicts(index) != 0) {
            stdout.print("picked: {s} (conflicts)\n", .{name}) catch {};
            stdout.print("\nTo complete the merge:\n", .{}) catch {};
            stdout.print("  1. Edit conflicting files to resolve conflicts\n", .{}) catch {};
            stdout.print("  2. git add <resolved files>\n", .{}) catch {};
            stdout.print("  3. git commit\n", .{}) catch {};
            stdout.print("\nTo abort the merge:\n", .{}) catch {};
            stdout.print("  git merge --abort\n", .{}) catch {};
            return;
        }

        // No conflicts - create merge commit
        var tree_oid: c.git_oid = undefined;
        if (c.git_index_write_tree(&tree_oid, index) < 0) {
            return git.Error.IndexWriteFailed;
        }

        var tree: ?*c.git_tree = null;
        if (c.git_tree_lookup(&tree, repo, &tree_oid) < 0) {
            return git.Error.RevwalkFailed;
        }
        defer c.git_tree_free(tree);

        // Get signature
        var signature: ?*c.git_signature = null;
        if (c.git_signature_default(&signature, repo) < 0) {
            return git.Error.CommitFailed;
        }
        defer c.git_signature_free(signature);

        // Get HEAD commit
        var head_ref: ?*c.git_reference = null;
        if (c.git_repository_head(&head_ref, repo) < 0) {
            return git.Error.RevwalkFailed;
        }
        defer c.git_reference_free(head_ref);

        var head_commit: ?*c.git_commit = null;
        if (c.git_reference_peel(@ptrCast(&head_commit), head_ref, c.GIT_OBJECT_COMMIT) < 0) {
            return git.Error.RevwalkFailed;
        }
        defer c.git_commit_free(head_commit);

        // Get fork commit
        var fork_commit: ?*c.git_commit = null;
        const fork_oid = c.git_annotated_commit_id(annotated_commit);
        if (c.git_commit_lookup(&fork_commit, repo, fork_oid) < 0) {
            return git.Error.RevwalkFailed;
        }
        defer c.git_commit_free(fork_commit);

        // Create merge commit message
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Merge fork '{s}'", .{name}) catch return git.Error.WriteFailed;
        var msg_z: [256]u8 = undefined;
        @memcpy(msg_z[0..msg.len], msg);
        msg_z[msg.len] = 0;

        // Create merge commit with two parents
        var commit_oid: c.git_oid = undefined;
        var parents = [_]?*c.git_commit{ head_commit, fork_commit };

        if (c.git_commit_create(
            &commit_oid,
            repo,
            "HEAD",
            signature,
            signature,
            null,
            &msg_z,
            tree,
            2,
            @ptrCast(&parents),
        ) < 0) {
            const err = c.git_error_last();
            if (err != null) {
                const msg2 = std.mem.sliceTo(err.*.message, 0);
                stdout.print("error: {s}\n", .{msg2}) catch {};
            }
            return git.Error.CommitFailed;
        }

        // Clean up merge state
        _ = c.git_repository_state_cleanup(repo);

        stdout.print("picked: {s} (merged)\n", .{name}) catch return git.Error.WriteFailed;
        return;
    }

    stdout.print("error: cannot merge {s}\n", .{name}) catch {};
    return git.Error.WriteFailed;
}

fn promoteFork(allocator: std.mem.Allocator, repo: ?*c.git_repository, name: []const u8, stdout: anytype) !void {
    // Check for detached HEAD
    try checkNotDetachedHead(repo, stdout);

    // Get commits ahead count first
    const ahead = getCommitsAhead(allocator, repo, name) catch 0;

    // Get the fork's branch ref
    var branch_name_buf: [512]u8 = undefined;
    const branch_name = std.fmt.bufPrint(&branch_name_buf, "refs/heads/{s}", .{name}) catch return git.Error.WriteFailed;

    var branch_name_z: [512]u8 = undefined;
    @memcpy(branch_name_z[0..branch_name.len], branch_name);
    branch_name_z[branch_name.len] = 0;

    var fork_ref: ?*c.git_reference = null;
    if (c.git_reference_lookup(&fork_ref, repo, &branch_name_z) < 0) {
        stdout.print("error: fork '{s}' not found\n", .{name}) catch {};
        return git.Error.FileNotFound;
    }
    defer c.git_reference_free(fork_ref);

    const fork_oid = c.git_reference_target(fork_ref);
    if (fork_oid == null) {
        return git.Error.RevwalkFailed;
    }

    // Get the fork's tree for checkout
    var fork_commit: ?*c.git_commit = null;
    if (c.git_commit_lookup(&fork_commit, repo, fork_oid) < 0) {
        return git.Error.RevwalkFailed;
    }
    defer c.git_commit_free(fork_commit);

    var fork_tree: ?*c.git_tree = null;
    if (c.git_commit_tree(&fork_tree, fork_commit) < 0) {
        return git.Error.RevwalkFailed;
    }
    defer c.git_tree_free(fork_tree);

    // Try checkout FIRST before updating HEAD
    // This way if there are conflicts, we fail before moving HEAD
    var checkout_opts: c.git_checkout_options = .{
        .version = c.GIT_CHECKOUT_OPTIONS_VERSION,
        .checkout_strategy = c.GIT_CHECKOUT_SAFE,
        .disable_filters = 0,
        .dir_mode = 0,
        .file_mode = 0,
        .file_open_flags = 0,
        .notify_flags = 0,
        .notify_cb = null,
        .notify_payload = null,
        .progress_cb = null,
        .progress_payload = null,
        .paths = .{ .strings = null, .count = 0 },
        .baseline = null,
        .baseline_index = null,
        .target_directory = null,
        .ancestor_label = null,
        .our_label = null,
        .their_label = null,
        .perfdata_cb = null,
        .perfdata_payload = null,
    };

    // Checkout the fork's tree (not HEAD yet - HEAD still points to old commit)
    if (c.git_checkout_tree(repo, @ptrCast(fork_tree), &checkout_opts) < 0) {
        const err = c.git_error_last();
        if (err != null) {
            const msg = std.mem.sliceTo(err.*.message, 0);
            stdout.print("error: {s}\n", .{msg}) catch {};
            stdout.print("hint: commit or stash changes first\n", .{}) catch {};
        }
        return git.Error.WriteFailed;
    }

    // Checkout succeeded, now update HEAD
    var head_ref: ?*c.git_reference = null;
    if (c.git_repository_head(&head_ref, repo) < 0) {
        return git.Error.RevwalkFailed;
    }
    defer c.git_reference_free(head_ref);

    const ref_name = c.git_reference_name(head_ref);
    if (ref_name == null) {
        return git.Error.RevwalkFailed;
    }

    var new_ref: ?*c.git_reference = null;
    if (c.git_reference_create(&new_ref, repo, ref_name, fork_oid, 1, "fork --promote") < 0) {
        const err = c.git_error_last();
        if (err != null) {
            const msg = std.mem.sliceTo(err.*.message, 0);
            stdout.print("error: {s}\n", .{msg}) catch {};
        }
        return git.Error.WriteFailed;
    }
    if (new_ref != null) c.git_reference_free(new_ref);

    stdout.print("promoted: {s}\n", .{name}) catch return git.Error.WriteFailed;
    if (ahead > 0) {
        stdout.print("  {d} commit{s} applied to base\n", .{
            ahead,
            if (ahead == 1) "" else "s",
        }) catch return git.Error.WriteFailed;
    }
    stdout.print("\nhint: run `git fork --delete-all` to clean up forks\n", .{}) catch return git.Error.WriteFailed;
}

fn deleteFork(allocator: std.mem.Allocator, repo: ?*c.git_repository, name: []const u8, stdout: anytype) !void {
    _ = allocator;

    // Null-terminate name
    var name_z: [256]u8 = undefined;
    if (name.len >= name_z.len) {
        return git.Error.UsageError;
    }
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;

    // Lookup the worktree
    var worktree: ?*c.git_worktree = null;
    if (c.git_worktree_lookup(&worktree, repo, &name_z) < 0) {
        stdout.print("error: fork '{s}' not found\n", .{name}) catch {};
        return git.Error.FileNotFound;
    }
    defer c.git_worktree_free(worktree);

    // Get the path before pruning
    const wt_path = c.git_worktree_path(worktree);
    var path_copy: [std.fs.max_path_bytes]u8 = undefined;
    var path_len: usize = 0;
    if (wt_path != null) {
        const wt_path_slice = std.mem.sliceTo(wt_path, 0);
        path_len = wt_path_slice.len;
        @memcpy(path_copy[0..path_len], wt_path_slice);
    }

    // Prune the worktree (removes git data structures)
    var prune_opts: c.git_worktree_prune_options = .{
        .version = c.GIT_WORKTREE_PRUNE_OPTIONS_VERSION,
        .flags = c.GIT_WORKTREE_PRUNE_VALID | c.GIT_WORKTREE_PRUNE_WORKING_TREE,
    };

    if (c.git_worktree_prune(worktree, &prune_opts) < 0) {
        const err = c.git_error_last();
        if (err != null) {
            const msg = std.mem.sliceTo(err.*.message, 0);
            stdout.print("error: {s}\n", .{msg}) catch {};
        }
        return git.Error.WriteFailed;
    }

    // Delete the working directory
    if (path_len > 0) {
        std.fs.deleteTreeAbsolute(path_copy[0..path_len]) catch {};
    }

    // Delete the branch
    var branch_name_buf: [512]u8 = undefined;
    const branch_name = std.fmt.bufPrint(&branch_name_buf, "refs/heads/{s}", .{name}) catch return git.Error.WriteFailed;

    var branch_name_z: [512]u8 = undefined;
    @memcpy(branch_name_z[0..branch_name.len], branch_name);
    branch_name_z[branch_name.len] = 0;

    var branch_ref: ?*c.git_reference = null;
    if (c.git_reference_lookup(&branch_ref, repo, &branch_name_z) == 0) {
        _ = c.git_reference_delete(branch_ref);
        c.git_reference_free(branch_ref);
    }

    stdout.print("deleted: {s}\n", .{name}) catch return git.Error.WriteFailed;
}

fn deleteAllForks(allocator: std.mem.Allocator, repo: ?*c.git_repository, stdout: anytype) !void {
    var worktree_list: c.git_strarray = .{ .strings = null, .count = 0 };
    if (c.git_worktree_list(&worktree_list, repo) < 0) {
        return git.Error.StatusFailed;
    }
    defer c.git_strarray_free(&worktree_list);

    if (worktree_list.count == 0) {
        stdout.print("no forks to delete\n", .{}) catch return git.Error.WriteFailed;
        return;
    }

    // Collect names first (since we're modifying the list)
    var deleted_names = std.array_list.Managed([]const u8).init(allocator);
    defer deleted_names.deinit();

    for (0..worktree_list.count) |idx| {
        const name_ptr = worktree_list.strings[idx];
        const name = std.mem.sliceTo(name_ptr, 0);

        // Copy name for output
        const name_copy = allocator.dupe(u8, name) catch continue;
        deleted_names.append(name_copy) catch continue;

        // Delete the fork (silently)
        deleteForkSilent(repo, name);
    }
    defer {
        for (deleted_names.items) |n| {
            allocator.free(n);
        }
    }

    stdout.print("deleted: ", .{}) catch return git.Error.WriteFailed;
    for (deleted_names.items, 0..) |name, idx| {
        if (idx > 0) {
            stdout.print(", ", .{}) catch {};
        }
        stdout.print("{s}", .{name}) catch {};
    }
    stdout.print("\n", .{}) catch return git.Error.WriteFailed;

    // Try to remove .forks directory if empty
    const workdir = c.git_repository_workdir(repo);
    if (workdir != null) {
        const workdir_slice = std.mem.sliceTo(workdir, 0);
        var forks_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const forks_dir = std.fmt.bufPrint(&forks_dir_buf, "{s}.forks", .{workdir_slice}) catch return;
        std.fs.deleteDirAbsolute(forks_dir) catch {};
    }
}

fn deleteForkSilent(repo: ?*c.git_repository, name: []const u8) void {
    // Null-terminate name
    var name_z: [256]u8 = undefined;
    if (name.len >= name_z.len) return;
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;

    // Lookup the worktree
    var worktree: ?*c.git_worktree = null;
    if (c.git_worktree_lookup(&worktree, repo, &name_z) < 0) return;
    defer c.git_worktree_free(worktree);

    // Get path before pruning
    const wt_path = c.git_worktree_path(worktree);
    var path_copy: [std.fs.max_path_bytes]u8 = undefined;
    var path_len: usize = 0;
    if (wt_path != null) {
        const wt_path_slice = std.mem.sliceTo(wt_path, 0);
        path_len = wt_path_slice.len;
        @memcpy(path_copy[0..path_len], wt_path_slice);
    }

    // Prune
    var prune_opts: c.git_worktree_prune_options = .{
        .version = c.GIT_WORKTREE_PRUNE_OPTIONS_VERSION,
        .flags = c.GIT_WORKTREE_PRUNE_VALID | c.GIT_WORKTREE_PRUNE_WORKING_TREE,
    };
    _ = c.git_worktree_prune(worktree, &prune_opts);

    // Delete directory
    if (path_len > 0) {
        std.fs.deleteTreeAbsolute(path_copy[0..path_len]) catch {};
    }

    // Delete branch
    var branch_name_buf: [512]u8 = undefined;
    const branch_name = std.fmt.bufPrint(&branch_name_buf, "refs/heads/{s}", .{name}) catch return;

    var branch_name_z: [512]u8 = undefined;
    @memcpy(branch_name_z[0..branch_name.len], branch_name);
    branch_name_z[branch_name.len] = 0;

    var branch_ref: ?*c.git_reference = null;
    if (c.git_reference_lookup(&branch_ref, repo, &branch_name_z) == 0) {
        _ = c.git_reference_delete(branch_ref);
        c.git_reference_free(branch_ref);
    }
}

/// Checks if a fork name has invalid characters (pure function, no repo needed)
/// Returns true if the name is invalid
fn hasInvalidChars(name: []const u8) bool {
    if (name.len == 0) return true;
    if (std.mem.indexOf(u8, name, "/") != null) return true;
    if (std.mem.indexOf(u8, name, "\\") != null) return true;
    if (std.mem.indexOf(u8, name, "..") != null) return true;
    if (std.mem.startsWith(u8, name, ".")) return true;
    if (std.mem.startsWith(u8, name, "-")) return true;
    return false;
}

const testing = std.testing;

test "hasInvalidChars rejects empty name" {
    try testing.expect(hasInvalidChars(""));
}

test "hasInvalidChars rejects forward slash" {
    try testing.expect(hasInvalidChars("my/fork"));
    try testing.expect(hasInvalidChars("nested/path/fork"));
}

test "hasInvalidChars rejects backslash" {
    try testing.expect(hasInvalidChars("my\\fork"));
}

test "hasInvalidChars rejects path traversal" {
    try testing.expect(hasInvalidChars(".."));
    try testing.expect(hasInvalidChars("../escape"));
    try testing.expect(hasInvalidChars("foo/../bar"));
}

test "hasInvalidChars rejects names starting with dot" {
    try testing.expect(hasInvalidChars(".hidden"));
    try testing.expect(hasInvalidChars(".git"));
}

test "hasInvalidChars rejects names starting with dash" {
    try testing.expect(hasInvalidChars("-flag"));
    try testing.expect(hasInvalidChars("--double-dash"));
}

test "hasInvalidChars accepts valid names" {
    try testing.expect(!hasInvalidChars("feature"));
    try testing.expect(!hasInvalidChars("my-feature"));
    try testing.expect(!hasInvalidChars("feature_branch"));
    try testing.expect(!hasInvalidChars("v1.0.0"));
    try testing.expect(!hasInvalidChars("experiment123"));
}

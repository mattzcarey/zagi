const std = @import("std");
const git = @import("git.zig");
const c = git.c;

pub const help =
    \\usage: git edit <command> [options]
    \\
    \\Travel to a commit for editing, then return with rebased descendants.
    \\
    \\Commands:
    \\  <commit>                Travel to commit for editing
    \\  --back                  Return to original branch and rebase
    \\  --continue              Continue after resolving conflicts
    \\  --abort                 Cancel edit and return to original state
    \\  --status                Show current edit state
    \\
    \\Options:
    \\  -h, --help              Show this help message
    \\
    \\Examples:
    \\  git edit abc123         Travel to commit abc123 for editing
    \\  git edit HEAD~3         Travel 3 commits back for editing
    \\  git edit --back         Return and rebase descendants
    \\  git edit --continue     Continue after resolving a conflict
    \\  git edit --abort        Cancel edit session
    \\  git edit --status       Show if edit is active
    \\
;

pub const Error = git.Error || error{
    EditActive,
    EditNotActive,
    DirtyWorkingTree,
    NotAnAncestor,
    CherryPickConflict,
    CherryPickConflictExit, // Special error for exit code 2
    DetachedHead,
    InvalidCommit,
    RefReadFailed,
    RefWriteFailed,
    RefDeleteFailed,
    AllocationError,
};

// Ref names for edit state
const REF_EDIT_ORIGIN = "refs/edit/origin";
const REF_EDIT_DESCENDANTS = "refs/edit/descendants";
const REF_EDIT_CURRENT = "refs/edit/current";

/// Check if an edit session is currently active
pub fn isEditActive(repo: ?*c.git_repository) bool {
    var ref: ?*c.git_reference = null;
    const result = c.git_reference_lookup(&ref, repo, REF_EDIT_ORIGIN);
    if (result == 0) {
        c.git_reference_free(ref);
        return true;
    }
    return false;
}

/// Get the original HEAD OID from before the edit started
pub fn getOrigin(repo: ?*c.git_repository) ?c.git_oid {
    var ref: ?*c.git_reference = null;
    const result = c.git_reference_lookup(&ref, repo, REF_EDIT_ORIGIN);
    if (result < 0) {
        return null;
    }
    defer c.git_reference_free(ref);

    const target_oid = c.git_reference_target(ref);
    if (target_oid == null) {
        return null;
    }
    return target_oid.*;
}

/// Get the list of descendant commit OIDs to rebase
pub fn getDescendants(repo: ?*c.git_repository, allocator: std.mem.Allocator) Error![]c.git_oid {
    // Look up the descendants ref
    var ref: ?*c.git_reference = null;
    const lookup_result = c.git_reference_lookup(&ref, repo, REF_EDIT_DESCENDANTS);
    if (lookup_result < 0) {
        if (lookup_result == c.GIT_ENOTFOUND) {
            // No descendants stored - return empty slice
            return allocator.alloc(c.git_oid, 0) catch return Error.AllocationError;
        }
        return Error.RefReadFailed;
    }
    defer c.git_reference_free(ref);

    // Get the blob OID the ref points to
    const blob_oid = c.git_reference_target(ref);
    if (blob_oid == null) {
        return Error.RefReadFailed;
    }

    // Look up the blob
    var blob: ?*c.git_blob = null;
    if (c.git_blob_lookup(&blob, repo, blob_oid) < 0) {
        return Error.RefReadFailed;
    }
    defer c.git_blob_free(blob);

    // Get blob content
    const content_ptr = c.git_blob_rawcontent(blob);
    const content_size = c.git_blob_rawsize(blob);

    if (content_ptr == null or content_size == 0) {
        return allocator.alloc(c.git_oid, 0) catch return Error.AllocationError;
    }

    const content = @as([*]const u8, @ptrCast(content_ptr))[0..content_size];

    // Parse newline-separated OID hex strings
    var oids = std.ArrayList(c.git_oid){};
    errdefer oids.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        // Skip empty lines
        if (line.len == 0) continue;

        // Parse hex string to OID
        var oid: c.git_oid = undefined;
        if (c.git_oid_fromstr(&oid, line.ptr) == 0) {
            oids.append(allocator, oid) catch return Error.AllocationError;
        }
    }

    return oids.toOwnedSlice(allocator) catch return Error.AllocationError;
}

/// Save edit state to refs
pub fn saveState(repo: ?*c.git_repository, origin: c.git_oid, descendants: []const c.git_oid, allocator: std.mem.Allocator) Error!void {
    // Save origin ref - points directly to the commit OID
    var origin_ref: ?*c.git_reference = null;
    if (c.git_reference_create(&origin_ref, repo, REF_EDIT_ORIGIN, &origin, 1, null) < 0) {
        return Error.RefWriteFailed;
    }
    c.git_reference_free(origin_ref);

    // Save descendants ref - points to a blob containing newline-separated OIDs
    // Build content: one hex OID per line
    var content = std.ArrayList(u8){};
    defer content.deinit(allocator);

    for (descendants) |oid| {
        var hex: [40]u8 = undefined;
        _ = c.git_oid_fmt(&hex, &oid);
        content.appendSlice(allocator, &hex) catch return Error.AllocationError;
        content.append(allocator, '\n') catch return Error.AllocationError;
    }

    // Create blob from content
    var blob_oid: c.git_oid = undefined;
    if (c.git_blob_create_from_buffer(&blob_oid, repo, content.items.ptr, content.items.len) < 0) {
        return Error.RefWriteFailed;
    }

    // Create the reference pointing to the blob
    var descendants_ref: ?*c.git_reference = null;
    if (c.git_reference_create(&descendants_ref, repo, REF_EDIT_DESCENDANTS, &blob_oid, 1, null) < 0) {
        return Error.RefWriteFailed;
    }
    c.git_reference_free(descendants_ref);
}

/// Update descendants ref with a new list (used when continuing after conflict)
fn updateDescendants(repo: ?*c.git_repository, descendants: []const c.git_oid, allocator: std.mem.Allocator) Error!void {
    // Build content: one hex OID per line
    var content = std.ArrayList(u8){};
    defer content.deinit(allocator);

    for (descendants) |oid| {
        var hex: [40]u8 = undefined;
        _ = c.git_oid_fmt(&hex, &oid);
        content.appendSlice(allocator, &hex) catch return Error.AllocationError;
        content.append(allocator, '\n') catch return Error.AllocationError;
    }

    // Create blob from content
    var blob_oid: c.git_oid = undefined;
    if (c.git_blob_create_from_buffer(&blob_oid, repo, content.items.ptr, content.items.len) < 0) {
        return Error.RefWriteFailed;
    }

    // Update the reference (force=1 to overwrite)
    var descendants_ref: ?*c.git_reference = null;
    if (c.git_reference_create(&descendants_ref, repo, REF_EDIT_DESCENDANTS, &blob_oid, 1, null) < 0) {
        return Error.RefWriteFailed;
    }
    c.git_reference_free(descendants_ref);
}

/// Clear edit state by deleting refs
pub fn clearState(repo: ?*c.git_repository) Error!void {
    // Delete origin ref
    var origin_ref: ?*c.git_reference = null;
    if (c.git_reference_lookup(&origin_ref, repo, REF_EDIT_ORIGIN) == 0) {
        if (c.git_reference_delete(origin_ref) < 0) {
            c.git_reference_free(origin_ref);
            return Error.RefDeleteFailed;
        }
        c.git_reference_free(origin_ref);
    }

    // Delete descendants ref
    var descendants_ref: ?*c.git_reference = null;
    if (c.git_reference_lookup(&descendants_ref, repo, REF_EDIT_DESCENDANTS) == 0) {
        if (c.git_reference_delete(descendants_ref) < 0) {
            c.git_reference_free(descendants_ref);
            return Error.RefDeleteFailed;
        }
        c.git_reference_free(descendants_ref);
    }

    // Delete current ref (used during conflict resolution)
    var current_ref: ?*c.git_reference = null;
    if (c.git_reference_lookup(&current_ref, repo, REF_EDIT_CURRENT) == 0) {
        if (c.git_reference_delete(current_ref) < 0) {
            c.git_reference_free(current_ref);
            return Error.RefDeleteFailed;
        }
        c.git_reference_free(current_ref);
    }
}

/// Collect all commits between target (exclusive) and HEAD (inclusive).
/// Returns OIDs in oldest-first order (ready for rebasing).
/// These are the commits that will need to be rebased after editing the target.
pub fn collectDescendants(repo: ?*c.git_repository, target: c.git_oid, head: c.git_oid, allocator: std.mem.Allocator) Error![]c.git_oid {
    // Create revwalk
    var walk: ?*c.git_revwalk = null;
    if (c.git_revwalk_new(&walk, repo) < 0) {
        return Error.NotAnAncestor;
    }
    defer c.git_revwalk_free(walk);

    // Sort topologically and reverse to get oldest-first order
    _ = c.git_revwalk_sorting(walk, c.GIT_SORT_TOPOLOGICAL | c.GIT_SORT_REVERSE);

    // Start from HEAD
    if (c.git_revwalk_push(walk, &head) < 0) {
        return Error.NotAnAncestor;
    }

    // Hide the target commit and its ancestors - we only want descendants
    if (c.git_revwalk_hide(walk, &target) < 0) {
        return Error.NotAnAncestor;
    }

    // Collect all commits in the walk
    var oids = std.ArrayList(c.git_oid){};
    errdefer oids.deinit(allocator);

    var oid: c.git_oid = undefined;
    while (c.git_revwalk_next(&oid, walk) == 0) {
        oids.append(allocator, oid) catch return Error.AllocationError;
    }

    return oids.toOwnedSlice(allocator) catch return Error.AllocationError;
}

/// Start an edit session - travel to a commit for editing.
/// Preconditions: repo is clean, not already in edit mode, HEAD is on a branch, target is an ancestor of HEAD.
pub fn startEdit(repo: ?*c.git_repository, target_str: []const u8, allocator: std.mem.Allocator) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Check if edit is already active
    if (isEditActive(repo)) {
        return Error.EditActive;
    }

    // Check for uncommitted changes
    if (git.countUncommitted(repo)) |counts| {
        if (counts.total() > 0) {
            return Error.DirtyWorkingTree;
        }
    }

    // Check that HEAD is on a branch (not detached)
    var head_ref: ?*c.git_reference = null;
    if (c.git_repository_head(&head_ref, repo) < 0) {
        return Error.DetachedHead;
    }
    defer c.git_reference_free(head_ref);

    if (c.git_reference_is_branch(head_ref) == 0) {
        return Error.DetachedHead;
    }

    // Get HEAD OID
    const head_oid_ptr = c.git_reference_target(head_ref);
    if (head_oid_ptr == null) {
        return Error.DetachedHead;
    }
    const head_oid = head_oid_ptr.*;

    // Resolve target commit-ish to OID
    var target_obj: ?*c.git_object = null;
    const target_cstr = @as([*c]const u8, @ptrCast(target_str.ptr));
    if (c.git_revparse_single(&target_obj, repo, target_cstr) < 0) {
        return Error.InvalidCommit;
    }
    defer c.git_object_free(target_obj);

    // Peel to commit if needed
    var target_commit: ?*c.git_commit = null;
    if (c.git_object_peel(@ptrCast(&target_commit), target_obj, c.GIT_OBJECT_COMMIT) < 0) {
        return Error.InvalidCommit;
    }
    defer c.git_commit_free(target_commit);

    const target_oid = c.git_commit_id(target_commit).*;

    // Check that target is an ancestor of HEAD
    var merge_base: c.git_oid = undefined;
    if (c.git_merge_base(&merge_base, repo, &target_oid, &head_oid) < 0) {
        return Error.NotAnAncestor;
    }

    // Target must be the merge base (i.e., an ancestor of HEAD)
    if (c.git_oid_cmp(&merge_base, &target_oid) != 0) {
        return Error.NotAnAncestor;
    }

    // Collect descendants from target to HEAD
    const descendants = try collectDescendants(repo, target_oid, head_oid, allocator);
    defer allocator.free(descendants);

    // Save state to refs
    try saveState(repo, head_oid, descendants, allocator);

    // Checkout target commit's tree
    var target_tree: ?*c.git_tree = null;
    if (c.git_commit_tree(&target_tree, target_commit) < 0) {
        // Clean up state if checkout fails
        clearState(repo) catch {};
        return Error.InvalidCommit;
    }
    defer c.git_tree_free(target_tree);

    // Set up checkout options
    var checkout_opts: c.git_checkout_options = undefined;
    _ = c.git_checkout_options_init(&checkout_opts, c.GIT_CHECKOUT_OPTIONS_VERSION);
    checkout_opts.checkout_strategy = c.GIT_CHECKOUT_SAFE;

    if (c.git_checkout_tree(repo, @ptrCast(target_tree), &checkout_opts) < 0) {
        // Clean up state if checkout fails
        clearState(repo) catch {};
        return Error.InvalidCommit;
    }

    // Update HEAD to point to target commit (detached HEAD)
    if (c.git_repository_set_head_detached(repo, &target_oid) < 0) {
        clearState(repo) catch {};
        return Error.InvalidCommit;
    }

    // Output: 'edit: <short-hash> (<subject>)'
    var short_hash: [8]u8 = undefined;
    _ = c.git_oid_tostr(&short_hash, short_hash.len, &target_oid);

    const subject = c.git_commit_summary(target_commit);
    const subject_str = if (subject) |s| std.mem.sliceTo(s, 0) else "(no message)";

    stdout.print("edit: {s} ({s})\n", .{ short_hash[0..7], subject_str }) catch return Error.AllocationError;

    // Output: 'from: <original-head>'
    var origin_short: [8]u8 = undefined;
    _ = c.git_oid_tostr(&origin_short, origin_short.len, &head_oid);
    stdout.print("from: {s}\n", .{origin_short[0..7]}) catch return Error.AllocationError;

    // Output: 'descendants: N commits'
    stdout.print("descendants: {d} commits\n", .{descendants.len}) catch return Error.AllocationError;
}

/// Complete an edit session - cherry-pick descendants onto current HEAD.
/// Returns CherryPickConflictExit if there's a conflict that needs resolution (exit code 2).
pub fn completeEdit(repo: ?*c.git_repository, allocator: std.mem.Allocator) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Check that edit is active
    if (!isEditActive(repo)) {
        return Error.EditNotActive;
    }

    // Check for uncommitted changes
    if (git.countUncommitted(repo)) |counts| {
        if (counts.total() > 0) {
            return Error.DirtyWorkingTree;
        }
    }

    // Load state from refs
    const origin_oid = getOrigin(repo) orelse return Error.RefReadFailed;
    const descendants = try getDescendants(repo, allocator);
    defer allocator.free(descendants);

    // Get current HEAD OID (this is our new base after editing)
    var head_ref: ?*c.git_reference = null;
    if (c.git_repository_head(&head_ref, repo) < 0) {
        return Error.DetachedHead;
    }
    defer c.git_reference_free(head_ref);

    const head_oid_ptr = c.git_reference_target(head_ref);
    if (head_oid_ptr == null) {
        return Error.DetachedHead;
    }
    var current_oid = head_oid_ptr.*;

    // Get the original branch name from origin ref (stored before detaching)
    // We need to find what branch was at origin_oid
    var branch_name: ?[]const u8 = null;
    var branch_name_buf: [256]u8 = undefined;

    // Iterate through branches to find the one matching origin_oid
    var branch_iter: ?*c.git_branch_iterator = null;
    if (c.git_branch_iterator_new(&branch_iter, repo, c.GIT_BRANCH_LOCAL) == 0) {
        defer c.git_branch_iterator_free(branch_iter);

        var ref: ?*c.git_reference = null;
        var branch_type: c.git_branch_t = undefined;
        while (c.git_branch_next(&ref, &branch_type, branch_iter) == 0) {
            defer c.git_reference_free(ref);
            const target = c.git_reference_target(ref);
            if (target != null and c.git_oid_equal(target, &origin_oid) != 0) {
                const name_ptr = c.git_reference_shorthand(ref);
                if (name_ptr != null) {
                    const name = std.mem.sliceTo(name_ptr, 0);
                    @memcpy(branch_name_buf[0..name.len], name);
                    branch_name = branch_name_buf[0..name.len];
                    break;
                }
            }
        }
    }

    // Cherry-pick each descendant onto current HEAD (oldest first)
    var rebased_count: usize = 0;
    for (descendants, 0..) |old_oid, descendant_idx| {
        // Look up the original commit
        var old_commit: ?*c.git_commit = null;
        if (c.git_commit_lookup(&old_commit, repo, &old_oid) < 0) {
            return Error.InvalidCommit;
        }
        defer c.git_commit_free(old_commit);

        // Look up the current base commit
        var base_commit: ?*c.git_commit = null;
        if (c.git_commit_lookup(&base_commit, repo, &current_oid) < 0) {
            return Error.InvalidCommit;
        }
        defer c.git_commit_free(base_commit);

        // Get the parent of the old commit (for cherry-pick diff)
        var old_parent: ?*c.git_commit = null;
        if (c.git_commit_parent(&old_parent, old_commit, 0) < 0) {
            return Error.InvalidCommit;
        }
        defer c.git_commit_free(old_parent);

        // Cherry-pick: apply the diff from old_parent->old_commit onto base_commit
        var cherry_index: ?*c.git_index = null;
        var merge_opts = std.mem.zeroes(c.git_merge_options);
        merge_opts.version = c.GIT_MERGE_OPTIONS_VERSION;

        if (c.git_cherrypick_commit(&cherry_index, repo, old_commit, base_commit, 0, &merge_opts) < 0) {
            return Error.CherryPickConflict;
        }
        defer c.git_index_free(cherry_index);

        // Check for conflicts
        if (c.git_index_has_conflicts(cherry_index) != 0) {
            // Save current position to refs/edit/current for --continue
            var current_ref: ?*c.git_reference = null;
            if (c.git_reference_create(&current_ref, repo, REF_EDIT_CURRENT, &current_oid, 1, null) < 0) {
                return Error.RefWriteFailed;
            }
            c.git_reference_free(current_ref);

            // Save remaining descendants (from current index onwards) for --continue
            try updateDescendants(repo, descendants[descendant_idx..], allocator);

            // Write conflicted index to repo
            var repo_index: ?*c.git_index = null;
            if (c.git_repository_index(&repo_index, repo) < 0) {
                return Error.CherryPickConflict;
            }
            defer c.git_index_free(repo_index);

            // Clear repo index before copying from cherry-pick index
            _ = c.git_index_clear(repo_index);

            // Copy cherry-pick index entries to repo index for conflict resolution
            const entry_count = c.git_index_entrycount(cherry_index);
            for (0..entry_count) |idx| {
                const entry = c.git_index_get_byindex(cherry_index, idx);
                if (entry != null) {
                    _ = c.git_index_add(repo_index, entry);
                }
            }
            _ = c.git_index_write(repo_index);

            // Checkout the conflicted state to working tree
            var checkout_opts: c.git_checkout_options = undefined;
            _ = c.git_checkout_options_init(&checkout_opts, c.GIT_CHECKOUT_OPTIONS_VERSION);
            checkout_opts.checkout_strategy = c.GIT_CHECKOUT_FORCE | c.GIT_CHECKOUT_ALLOW_CONFLICTS;
            _ = c.git_checkout_index(repo, cherry_index, &checkout_opts);

            // Print conflict message
            stdout.print("conflict: cherry-pick failed\n", .{}) catch return Error.AllocationError;
            stdout.print("resolve conflicts then:\n", .{}) catch return Error.AllocationError;
            stdout.print("  git add <files>\n", .{}) catch return Error.AllocationError;
            stdout.print("  git edit --continue\n", .{}) catch return Error.AllocationError;
            stdout.print("or:\n", .{}) catch return Error.AllocationError;
            stdout.print("  git edit --abort\n", .{}) catch return Error.AllocationError;

            return Error.CherryPickConflictExit; // Exit code 2 for conflict
        }

        // No conflicts - write tree and create new commit
        var tree_oid: c.git_oid = undefined;
        if (c.git_index_write_tree_to(&tree_oid, cherry_index, repo) < 0) {
            return Error.CherryPickConflict;
        }

        var tree: ?*c.git_tree = null;
        if (c.git_tree_lookup(&tree, repo, &tree_oid) < 0) {
            return Error.CherryPickConflict;
        }
        defer c.git_tree_free(tree);

        // Get original commit message and author
        const message = c.git_commit_message(old_commit);
        const author = c.git_commit_author(old_commit);

        // Get committer (current user)
        var committer: ?*c.git_signature = null;
        if (c.git_signature_default(&committer, repo) < 0) {
            return Error.CherryPickConflict;
        }
        defer c.git_signature_free(committer);

        // Create new commit with same message/author but new parent
        var new_oid: c.git_oid = undefined;
        var parents = [_]?*c.git_commit{base_commit};

        if (c.git_commit_create(
            &new_oid,
            repo,
            null, // Don't update any ref yet
            author,
            committer,
            null, // UTF-8 encoding
            message,
            tree,
            1,
            @ptrCast(&parents),
        ) < 0) {
            return Error.CherryPickConflict;
        }

        // Update current_oid for next iteration
        current_oid = new_oid;
        rebased_count += 1;
    }

    // All cherry-picks succeeded - update the branch ref to final commit
    if (branch_name) |name| {
        // Build full ref name
        var ref_name_buf: [512]u8 = undefined;
        const ref_name = std.fmt.bufPrint(&ref_name_buf, "refs/heads/{s}", .{name}) catch return Error.AllocationError;

        var ref_name_z: [512]u8 = undefined;
        @memcpy(ref_name_z[0..ref_name.len], ref_name);
        ref_name_z[ref_name.len] = 0;

        // Update branch to point to new commit
        var new_ref: ?*c.git_reference = null;
        if (c.git_reference_create(&new_ref, repo, &ref_name_z, &current_oid, 1, "edit --back: rebase complete") < 0) {
            return Error.RefWriteFailed;
        }
        c.git_reference_free(new_ref);

        // Checkout the new HEAD
        var checkout_opts: c.git_checkout_options = undefined;
        _ = c.git_checkout_options_init(&checkout_opts, c.GIT_CHECKOUT_OPTIONS_VERSION);
        checkout_opts.checkout_strategy = c.GIT_CHECKOUT_SAFE;

        var final_commit: ?*c.git_commit = null;
        if (c.git_commit_lookup(&final_commit, repo, &current_oid) < 0) {
            return Error.InvalidCommit;
        }
        defer c.git_commit_free(final_commit);

        var final_tree: ?*c.git_tree = null;
        if (c.git_commit_tree(&final_tree, final_commit) < 0) {
            return Error.InvalidCommit;
        }
        defer c.git_tree_free(final_tree);

        if (c.git_checkout_tree(repo, @ptrCast(final_tree), &checkout_opts) < 0) {
            return Error.InvalidCommit;
        }

        // Re-attach HEAD to the branch
        var symbolic_name_buf: [512]u8 = undefined;
        const symbolic_ref = std.fmt.bufPrint(&symbolic_name_buf, "refs/heads/{s}", .{name}) catch return Error.AllocationError;
        var symbolic_z: [512]u8 = undefined;
        @memcpy(symbolic_z[0..symbolic_ref.len], symbolic_ref);
        symbolic_z[symbolic_ref.len] = 0;

        if (c.git_repository_set_head(repo, &symbolic_z) < 0) {
            return Error.RefWriteFailed;
        }
    } else {
        // No branch found - just update detached HEAD
        if (c.git_repository_set_head_detached(repo, &current_oid) < 0) {
            return Error.RefWriteFailed;
        }

        // Checkout the new HEAD
        var checkout_opts: c.git_checkout_options = undefined;
        _ = c.git_checkout_options_init(&checkout_opts, c.GIT_CHECKOUT_OPTIONS_VERSION);
        checkout_opts.checkout_strategy = c.GIT_CHECKOUT_SAFE;

        var final_commit: ?*c.git_commit = null;
        if (c.git_commit_lookup(&final_commit, repo, &current_oid) < 0) {
            return Error.InvalidCommit;
        }
        defer c.git_commit_free(final_commit);

        var final_tree: ?*c.git_tree = null;
        if (c.git_commit_tree(&final_tree, final_commit) < 0) {
            return Error.InvalidCommit;
        }
        defer c.git_tree_free(final_tree);

        if (c.git_checkout_tree(repo, @ptrCast(final_tree), &checkout_opts) < 0) {
            return Error.InvalidCommit;
        }
    }

    // Clear edit state
    try clearState(repo);

    // Output success
    stdout.print("edit: complete\n", .{}) catch return Error.AllocationError;
    stdout.print("rebased: {d} commits\n", .{rebased_count}) catch return Error.AllocationError;
}

/// Check if there's a conflict in progress (refs/edit/current exists)
fn isConflictActive(repo: ?*c.git_repository) bool {
    var ref: ?*c.git_reference = null;
    const result = c.git_reference_lookup(&ref, repo, REF_EDIT_CURRENT);
    if (result == 0) {
        c.git_reference_free(ref);
        return true;
    }
    return false;
}

/// Get the current commit being cherry-picked (during conflict)
fn getCurrentConflict(repo: ?*c.git_repository) ?c.git_oid {
    var ref: ?*c.git_reference = null;
    const result = c.git_reference_lookup(&ref, repo, REF_EDIT_CURRENT);
    if (result < 0) {
        return null;
    }
    defer c.git_reference_free(ref);

    const target_oid = c.git_reference_target(ref);
    if (target_oid == null) {
        return null;
    }
    return target_oid.*;
}

/// Show the current edit status.
/// Output format:
///   If not active: 'edit: not active' (exit 0)
///   If active: 'edit: active', 'target: <hash>', 'origin: <hash>', 'remaining: N commits'
///   If conflict: also 'status: conflict at <commit>'
pub fn showStatus(repo: ?*c.git_repository, allocator: std.mem.Allocator) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Check if edit is active
    if (!isEditActive(repo)) {
        stdout.print("edit: not active\n", .{}) catch return Error.AllocationError;
        return;
    }

    // Edit is active
    stdout.print("edit: active\n", .{}) catch return Error.AllocationError;

    // Get and print current HEAD (target)
    var head_ref: ?*c.git_reference = null;
    if (c.git_repository_head(&head_ref, repo) == 0) {
        defer c.git_reference_free(head_ref);
        const head_oid = c.git_reference_target(head_ref);
        if (head_oid != null) {
            var short_hash: [8]u8 = undefined;
            _ = c.git_oid_tostr(&short_hash, short_hash.len, head_oid);
            stdout.print("target: {s}\n", .{short_hash[0..7]}) catch return Error.AllocationError;
        }
    }

    // Get and print origin
    if (getOrigin(repo)) |origin_oid| {
        var short_hash: [8]u8 = undefined;
        _ = c.git_oid_tostr(&short_hash, short_hash.len, &origin_oid);
        stdout.print("origin: {s}\n", .{short_hash[0..7]}) catch return Error.AllocationError;
    }

    // Get and print remaining commits count
    const descendants = getDescendants(repo, allocator) catch {
        stdout.print("remaining: ? commits\n", .{}) catch return Error.AllocationError;
        return;
    };
    defer allocator.free(descendants);
    stdout.print("remaining: {d} commits\n", .{descendants.len}) catch return Error.AllocationError;

    // Check for conflict state
    if (isConflictActive(repo)) {
        if (getCurrentConflict(repo)) |current_oid| {
            var short_hash: [8]u8 = undefined;
            _ = c.git_oid_tostr(&short_hash, short_hash.len, &current_oid);
            stdout.print("status: conflict at {s}\n", .{short_hash[0..7]}) catch return Error.AllocationError;
        } else {
            stdout.print("status: conflict\n", .{}) catch return Error.AllocationError;
        }
    }
}

/// Abort an edit session - restore original state before the edit started.
/// This should always succeed and fully restore the original state.
pub fn abortEdit(repo: ?*c.git_repository) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Check that edit is active
    if (!isEditActive(repo)) {
        return Error.EditNotActive;
    }

    // Load origin OID from refs/edit/origin
    const origin_oid = getOrigin(repo) orelse return Error.RefReadFailed;

    // Look up the origin commit
    var origin_commit: ?*c.git_commit = null;
    if (c.git_commit_lookup(&origin_commit, repo, &origin_oid) < 0) {
        return Error.InvalidCommit;
    }
    defer c.git_commit_free(origin_commit);

    // Get origin commit's tree
    var origin_tree: ?*c.git_tree = null;
    if (c.git_commit_tree(&origin_tree, origin_commit) < 0) {
        return Error.InvalidCommit;
    }
    defer c.git_tree_free(origin_tree);

    // Checkout origin's tree (force to discard any changes from edit session)
    var checkout_opts: c.git_checkout_options = undefined;
    _ = c.git_checkout_options_init(&checkout_opts, c.GIT_CHECKOUT_OPTIONS_VERSION);
    checkout_opts.checkout_strategy = c.GIT_CHECKOUT_FORCE;

    if (c.git_checkout_tree(repo, @ptrCast(origin_tree), &checkout_opts) < 0) {
        return Error.InvalidCommit;
    }

    // Find the branch that was at origin_oid and restore HEAD to it
    var branch_name: ?[]const u8 = null;
    var branch_name_buf: [256]u8 = undefined;

    // Iterate through branches to find the one matching origin_oid
    var branch_iter: ?*c.git_branch_iterator = null;
    if (c.git_branch_iterator_new(&branch_iter, repo, c.GIT_BRANCH_LOCAL) == 0) {
        defer c.git_branch_iterator_free(branch_iter);

        var ref: ?*c.git_reference = null;
        var branch_type: c.git_branch_t = undefined;
        while (c.git_branch_next(&ref, &branch_type, branch_iter) == 0) {
            defer c.git_reference_free(ref);
            const target = c.git_reference_target(ref);
            if (target != null and c.git_oid_equal(target, &origin_oid) != 0) {
                const name_ptr = c.git_reference_shorthand(ref);
                if (name_ptr != null) {
                    const name = std.mem.sliceTo(name_ptr, 0);
                    @memcpy(branch_name_buf[0..name.len], name);
                    branch_name = branch_name_buf[0..name.len];
                    break;
                }
            }
        }
    }

    // Restore HEAD - either to branch or detached at origin
    if (branch_name) |name| {
        var symbolic_name_buf: [512]u8 = undefined;
        const symbolic_ref = std.fmt.bufPrint(&symbolic_name_buf, "refs/heads/{s}", .{name}) catch return Error.AllocationError;
        var symbolic_z: [512]u8 = undefined;
        @memcpy(symbolic_z[0..symbolic_ref.len], symbolic_ref);
        symbolic_z[symbolic_ref.len] = 0;

        if (c.git_repository_set_head(repo, &symbolic_z) < 0) {
            return Error.RefWriteFailed;
        }
    } else {
        // No matching branch found - set HEAD detached at origin
        if (c.git_repository_set_head_detached(repo, &origin_oid) < 0) {
            return Error.RefWriteFailed;
        }
    }

    // Clear all edit state refs
    try clearState(repo);

    // Output: 'edit: aborted' then 'restored: <short-hash>'
    var short_hash: [8]u8 = undefined;
    _ = c.git_oid_tostr(&short_hash, short_hash.len, &origin_oid);

    stdout.print("edit: aborted\n", .{}) catch return Error.AllocationError;
    stdout.print("restored: {s}\n", .{short_hash[0..7]}) catch return Error.AllocationError;
}

/// Continue an edit session after resolving conflicts.
/// Creates a commit from the resolved index and continues cherry-picking remaining descendants.
pub fn continueEdit(repo: ?*c.git_repository, allocator: std.mem.Allocator) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Check that edit is active
    if (!isEditActive(repo)) {
        return Error.EditNotActive;
    }

    // Check that we're in conflict state (refs/edit/current exists)
    if (!isConflictActive(repo)) {
        stdout.print("error: no conflict in progress\n", .{}) catch return Error.AllocationError;
        stdout.print("hint: use 'git edit --back' to complete the edit\n", .{}) catch return Error.AllocationError;
        return Error.EditNotActive;
    }

    // Get current base commit OID
    const current_oid = getCurrentConflict(repo) orelse return Error.RefReadFailed;

    // Get remaining descendants (first one is the commit that conflicted)
    const descendants = try getDescendants(repo, allocator);
    defer allocator.free(descendants);

    if (descendants.len == 0) {
        stdout.print("error: no commits to continue\n", .{}) catch return Error.AllocationError;
        return Error.EditNotActive;
    }

    // Check that index has no conflicts
    var repo_index: ?*c.git_index = null;
    if (c.git_repository_index(&repo_index, repo) < 0) {
        return Error.CherryPickConflict;
    }
    defer c.git_index_free(repo_index);

    if (c.git_index_has_conflicts(repo_index) != 0) {
        stdout.print("error: unresolved conflicts remain\n", .{}) catch return Error.AllocationError;
        stdout.print("hint: resolve all conflicts then 'git add <files>'\n", .{}) catch return Error.AllocationError;
        return Error.CherryPickConflict;
    }

    // Get the original commit that conflicted (first in descendants list)
    const conflicted_oid = descendants[0];
    var conflicted_commit: ?*c.git_commit = null;
    if (c.git_commit_lookup(&conflicted_commit, repo, &conflicted_oid) < 0) {
        return Error.InvalidCommit;
    }
    defer c.git_commit_free(conflicted_commit);

    // Get the base commit
    var base_commit: ?*c.git_commit = null;
    if (c.git_commit_lookup(&base_commit, repo, &current_oid) < 0) {
        return Error.InvalidCommit;
    }
    defer c.git_commit_free(base_commit);

    // Write tree from resolved index
    var tree_oid: c.git_oid = undefined;
    if (c.git_index_write_tree(&tree_oid, repo_index) < 0) {
        return Error.CherryPickConflict;
    }

    var tree: ?*c.git_tree = null;
    if (c.git_tree_lookup(&tree, repo, &tree_oid) < 0) {
        return Error.CherryPickConflict;
    }
    defer c.git_tree_free(tree);

    // Get original commit message and author
    const message = c.git_commit_message(conflicted_commit);
    const author = c.git_commit_author(conflicted_commit);

    // Get committer (current user)
    var committer: ?*c.git_signature = null;
    if (c.git_signature_default(&committer, repo) < 0) {
        return Error.CherryPickConflict;
    }
    defer c.git_signature_free(committer);

    // Create new commit with same message/author but new parent
    var new_oid: c.git_oid = undefined;
    var parents = [_]?*c.git_commit{base_commit};

    if (c.git_commit_create(
        &new_oid,
        repo,
        null, // Don't update any ref yet
        author,
        committer,
        null, // UTF-8 encoding
        message,
        tree,
        1,
        @ptrCast(&parents),
    ) < 0) {
        return Error.CherryPickConflict;
    }

    // Update refs/edit/current to the new commit
    var current_ref: ?*c.git_reference = null;
    if (c.git_reference_create(&current_ref, repo, REF_EDIT_CURRENT, &new_oid, 1, null) < 0) {
        return Error.RefWriteFailed;
    }
    c.git_reference_free(current_ref);

    // Update HEAD to point to the new commit
    if (c.git_repository_set_head_detached(repo, &new_oid) < 0) {
        return Error.RefWriteFailed;
    }

    // Remove the first descendant (we just applied it) and update the list
    if (descendants.len > 1) {
        try updateDescendants(repo, descendants[1..], allocator);
    } else {
        // No more descendants - clear to empty
        try updateDescendants(repo, &[_]c.git_oid{}, allocator);
    }

    // Delete refs/edit/current since we're done with conflict resolution
    var del_ref: ?*c.git_reference = null;
    if (c.git_reference_lookup(&del_ref, repo, REF_EDIT_CURRENT) == 0) {
        _ = c.git_reference_delete(del_ref);
        c.git_reference_free(del_ref);
    }

    stdout.print("continued: 1 commit applied\n", .{}) catch return Error.AllocationError;

    // If there are more descendants, continue with completeEdit
    if (descendants.len > 1) {
        stdout.print("remaining: {d} commits\n", .{descendants.len - 1}) catch return Error.AllocationError;
        // Call completeEdit to continue cherry-picking
        try completeEdit(repo, allocator);
    } else {
        // All done - finish up like completeEdit does
        // Find original branch and restore HEAD
        const origin_oid = getOrigin(repo) orelse return Error.RefReadFailed;

        // Find the branch that was at origin_oid
        var branch_name: ?[]const u8 = null;
        var branch_name_buf: [256]u8 = undefined;

        var branch_iter: ?*c.git_branch_iterator = null;
        if (c.git_branch_iterator_new(&branch_iter, repo, c.GIT_BRANCH_LOCAL) == 0) {
            defer c.git_branch_iterator_free(branch_iter);

            var ref: ?*c.git_reference = null;
            var branch_type: c.git_branch_t = undefined;
            while (c.git_branch_next(&ref, &branch_type, branch_iter) == 0) {
                defer c.git_reference_free(ref);
                const target = c.git_reference_target(ref);
                if (target != null and c.git_oid_equal(target, &origin_oid) != 0) {
                    const name_ptr = c.git_reference_shorthand(ref);
                    if (name_ptr != null) {
                        const name = std.mem.sliceTo(name_ptr, 0);
                        @memcpy(branch_name_buf[0..name.len], name);
                        branch_name = branch_name_buf[0..name.len];
                        break;
                    }
                }
            }
        }

        // Update branch and restore HEAD
        if (branch_name) |name| {
            var ref_name_buf: [512]u8 = undefined;
            const ref_name = std.fmt.bufPrint(&ref_name_buf, "refs/heads/{s}", .{name}) catch return Error.AllocationError;

            var ref_name_z: [512]u8 = undefined;
            @memcpy(ref_name_z[0..ref_name.len], ref_name);
            ref_name_z[ref_name.len] = 0;

            // Update branch to point to new commit
            var new_ref: ?*c.git_reference = null;
            if (c.git_reference_create(&new_ref, repo, &ref_name_z, &new_oid, 1, "edit --continue: rebase complete") < 0) {
                return Error.RefWriteFailed;
            }
            c.git_reference_free(new_ref);

            // Re-attach HEAD to the branch
            if (c.git_repository_set_head(repo, &ref_name_z) < 0) {
                return Error.RefWriteFailed;
            }
        }

        // Clear edit state
        try clearState(repo);

        stdout.print("edit: complete\n", .{}) catch return Error.AllocationError;
    }
}

/// Main entry point for the edit command
pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Parse arguments
    var target: ?[]const u8 = null;
    var do_back = false;
    var do_abort = false;
    var do_status = false;
    var do_continue = false;

    for (args[2..]) |arg| {
        const a = std.mem.sliceTo(arg, 0);
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            stdout.print("{s}", .{help}) catch {};
            return;
        } else if (std.mem.eql(u8, a, "--back")) {
            do_back = true;
        } else if (std.mem.eql(u8, a, "--abort")) {
            do_abort = true;
        } else if (std.mem.eql(u8, a, "--status")) {
            do_status = true;
        } else if (std.mem.eql(u8, a, "--continue")) {
            do_continue = true;
        } else if (!std.mem.startsWith(u8, a, "-")) {
            target = a;
        } else {
            return git.Error.UsageError;
        }
    }

    // No arguments - show help
    if (!do_back and !do_abort and !do_status and !do_continue and target == null) {
        stdout.print("{s}", .{help}) catch {};
        return;
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

    // Dispatch to appropriate action
    if (do_back) {
        try completeEdit(repo, allocator);
    } else if (do_continue) {
        try continueEdit(repo, allocator);
    } else if (do_abort) {
        try abortEdit(repo);
    } else if (do_status) {
        try showStatus(repo, allocator);
    } else if (target) |t| {
        try startEdit(repo, t, allocator);
    }
}

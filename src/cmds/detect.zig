const std = @import("std");

/// Known AI agents/tools
pub const Agent = enum {
    claude,
    opencode,
    windsurf,
    cursor,
    vscode,
    vscode_fork,
    terminal,

    /// Returns the string name for this agent
    pub fn name(self: Agent) []const u8 {
        return switch (self) {
            .claude => "claude",
            .opencode => "opencode",
            .windsurf => "windsurf",
            .cursor => "cursor",
            .vscode => "vscode",
            .vscode_fork => "vscode-fork",
            .terminal => "terminal",
        };
    }
};

/// Agent mode detection (for guardrails + --prompt requirement)
/// Checks signals that are set by parent process and hard to bypass
pub fn isAgentMode() bool {
    // Native agent signals (set by IDE/CLI parent process)
    if (std.posix.getenv("CLAUDECODE") != null) return true;
    if (std.posix.getenv("OPENCODE") != null) return true;
    // Custom agent signal (must be non-empty to enable agent mode)
    if (std.posix.getenv("ZAGI_AGENT")) |v| {
        if (v.len > 0) return true;
    }
    return false;
}

/// Detect the AI agent/tool from environment
pub fn detectAgent() Agent {
    // CLI tools - most specific signals
    if (std.posix.getenv("CLAUDECODE") != null) return .claude;
    if (std.posix.getenv("OPENCODE") != null) return .opencode;

    // VSCode forks - check app path in VSCODE_GIT_ASKPASS_NODE
    if (std.posix.getenv("VSCODE_GIT_ASKPASS_NODE")) |path| {
        if (std.mem.indexOf(u8, path, "Windsurf") != null) return .windsurf;
        if (std.mem.indexOf(u8, path, "Cursor") != null) return .cursor;
        if (std.mem.indexOf(u8, path, "Code") != null) return .vscode;
        return .vscode_fork;
    }

    return .terminal;
}

// TODO: Extract model from session transcript when surfacing agent metadata
// The model info is available in the session JSONL files and could be parsed
// from there for display in `git log --prompts`

/// Session data for transcript storage
pub const Session = struct {
    path: []const u8,
    transcript: []const u8,
};

/// Read current session transcript
pub fn readCurrentSession(allocator: std.mem.Allocator, agent: Agent, cwd: []const u8) ?Session {
    return switch (agent) {
        .claude => readClaudeCodeSession(allocator, cwd),
        .opencode => readOpenCodeSession(allocator),
        else => null,
    };
}

/// Read Claude Code session from ~/.claude/projects/{project-hash}/
fn readClaudeCodeSession(allocator: std.mem.Allocator, cwd: []const u8) ?Session {
    const home = std.posix.getenv("HOME") orelse return null;

    // Resolve to main repo path (handles worktrees)
    const project_path = resolveMainRepoPath(allocator, cwd) orelse return null;
    defer allocator.free(project_path);

    // Convert to project hash (replace / with -)
    // e.g., /Users/matt/Documents/Github/zagi -> -Users-matt-Documents-Github-zagi
    var project_hash_buf: [512]u8 = undefined;
    var hash_len: usize = 0;
    for (project_path) |char| {
        if (hash_len >= project_hash_buf.len) break;
        project_hash_buf[hash_len] = if (char == '/') '-' else char;
        hash_len += 1;
    }
    const project_hash = project_hash_buf[0..hash_len];

    // Build project directory path
    const project_dir = std.fmt.allocPrint(allocator, "{s}/.claude/projects/{s}", .{ home, project_hash }) catch return null;
    defer allocator.free(project_dir);

    // Find most recent .jsonl file
    var dir = std.fs.cwd().openDir(project_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var most_recent_path: ?[]const u8 = null;
    var most_recent_mtime: i128 = 0;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        // Get file stat for modification time
        const stat = dir.statFile(entry.name) catch continue;
        const mtime = stat.mtime;

        if (most_recent_path == null or mtime > most_recent_mtime) {
            if (most_recent_path) |old| allocator.free(old);
            most_recent_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, entry.name }) catch continue;
            most_recent_mtime = mtime;
        }
    }

    if (most_recent_path) |path| {
        // Read file content
        const file = std.fs.cwd().openFile(path, .{}) catch {
            allocator.free(path);
            return null;
        };
        defer file.close();

        // Read up to 10MB of transcript
        const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
            allocator.free(path);
            return null;
        };

        // Convert JSONL to JSON array
        const transcript = convertJsonlToArray(allocator, content) catch {
            allocator.free(content);
            allocator.free(path);
            return null;
        };
        allocator.free(content);

        return Session{
            .path = path,
            .transcript = transcript,
        };
    }

    return null;
}

/// Convert JSONL (newline-delimited JSON) to a JSON array
fn convertJsonlToArray(allocator: std.mem.Allocator, jsonl: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    try result.append('[');

    var first = true;
    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (!first) {
            try result.append(',');
        }
        first = false;
        try result.appendSlice(trimmed);
    }

    try result.append(']');
    return result.toOwnedSlice();
}

/// Read OpenCode session
fn readOpenCodeSession(allocator: std.mem.Allocator) ?Session {
    const home = std.posix.getenv("HOME") orelse return null;

    // OpenCode stores sessions in ~/.local/share/opencode/storage/session/
    const base_dir = std.fmt.allocPrint(allocator, "{s}/.local/share/opencode/storage/message", .{home}) catch return null;
    defer allocator.free(base_dir);

    // Find most recent session directory
    var dir = std.fs.cwd().openDir(base_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var most_recent_dir: ?[]const u8 = null;
    var most_recent_mtime: i128 = 0;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        const stat = dir.statFile(entry.name) catch continue;
        const mtime = stat.mtime;

        if (most_recent_dir == null or mtime > most_recent_mtime) {
            if (most_recent_dir) |old| allocator.free(old);
            most_recent_dir = allocator.dupe(u8, entry.name) catch continue;
            most_recent_mtime = mtime;
        }
    }

    if (most_recent_dir) |session_id| {
        defer allocator.free(session_id);

        // Read all message files in this session
        const session_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, session_id }) catch return null;

        var messages_dir = std.fs.cwd().openDir(session_dir, .{ .iterate = true }) catch {
            allocator.free(session_dir);
            return null;
        };
        defer messages_dir.close();

        // Collect all messages into an array
        var messages = std.array_list.Managed(u8).init(allocator);
        errdefer messages.deinit();

        messages.append('[') catch return null;

        var first = true;
        var msg_iter = messages_dir.iterate();
        while (msg_iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            const msg_content = messages_dir.readFileAlloc(allocator, entry.name, 1024 * 1024) catch continue;
            defer allocator.free(msg_content);

            if (!first) {
                messages.append(',') catch continue;
            }
            first = false;
            messages.appendSlice(msg_content) catch continue;
        }

        messages.append(']') catch return null;

        return Session{
            .path = session_dir,
            .transcript = messages.toOwnedSlice() catch return null,
        };
    }

    return null;
}

// ============================================================================
// Session Checkpoint Support - Structured JSONL Parsing & Markdown Formatting
// ============================================================================

/// Parsed session entry for checkpoint tracking
pub const SessionEntry = struct {
    uuid: []const u8,
    timestamp: []const u8,
    entry_type: []const u8, // "user", "assistant", "tool_result", etc.
    role: ?[]const u8, // "user" or "assistant" for message types
    content: ?[]const u8, // message content (may be truncated)
    tool_name: ?[]const u8, // for tool_use entries
};

/// Result of reading session entries
pub const SessionEntriesResult = struct {
    entries: []SessionEntry,
    last_uuid: ?[]const u8, // UUID of last entry (for checkpoint)
    session_path: []const u8,
};

/// Read session entries after a checkpoint UUID (or all if null)
/// Returns structured entries for markdown formatting
pub fn readSessionEntriesAfter(
    allocator: std.mem.Allocator,
    agent: Agent,
    cwd: []const u8,
    after_uuid: ?[]const u8,
) ?SessionEntriesResult {
    return switch (agent) {
        .claude => readClaudeEntriesAfter(allocator, cwd, after_uuid),
        .opencode => readOpenCodeEntriesAfter(allocator, cwd, after_uuid),
        else => null,
    };
}

/// Resolve the main repository path (handles worktrees)
/// For worktrees, returns the main repo path instead of the worktree path
fn resolveMainRepoPath(allocator: std.mem.Allocator, cwd: []const u8) ?[]const u8 {
    // Check if .git is a file (worktree) or directory (main repo)
    const git_path = std.fmt.allocPrint(allocator, "{s}/.git", .{cwd}) catch return null;
    defer allocator.free(git_path);

    const stat = std.fs.cwd().statFile(git_path) catch {
        // No .git found, return cwd as-is
        return allocator.dupe(u8, cwd) catch null;
    };

    if (stat.kind == .file) {
        // Worktree: .git is a file containing "gitdir: /path/to/.git/worktrees/name"
        const git_file = std.fs.cwd().openFile(git_path, .{}) catch return null;
        defer git_file.close();

        var buf: [1024]u8 = undefined;
        const bytes_read = git_file.readAll(&buf) catch return null;
        const content = std.mem.trim(u8, buf[0..bytes_read], " \t\r\n");

        // Parse "gitdir: /path/to/.git/worktrees/name"
        if (std.mem.startsWith(u8, content, "gitdir: ")) {
            const gitdir = content[8..];
            // Find the main .git directory (remove /worktrees/name suffix)
            if (std.mem.indexOf(u8, gitdir, "/worktrees/")) |idx| {
                const main_git_dir = gitdir[0..idx];
                // Remove /.git suffix to get main repo path
                if (std.mem.endsWith(u8, main_git_dir, "/.git")) {
                    return allocator.dupe(u8, main_git_dir[0 .. main_git_dir.len - 5]) catch null;
                }
            }
        }
    }

    // Regular repo or couldn't parse worktree, return cwd
    return allocator.dupe(u8, cwd) catch null;
}

/// Read Claude Code session entries after a checkpoint
fn readClaudeEntriesAfter(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    after_uuid: ?[]const u8,
) ?SessionEntriesResult {
    const home = std.posix.getenv("HOME") orelse return null;

    // Resolve to main repo path (handles worktrees)
    const project_path = resolveMainRepoPath(allocator, cwd) orelse return null;
    defer allocator.free(project_path);

    // Convert to project hash
    var project_hash_buf: [512]u8 = undefined;
    var hash_len: usize = 0;
    for (project_path) |char| {
        if (hash_len >= project_hash_buf.len) break;
        project_hash_buf[hash_len] = if (char == '/') '-' else char;
        hash_len += 1;
    }
    const project_hash = project_hash_buf[0..hash_len];

    // Build project directory path
    const project_dir = std.fmt.allocPrint(allocator, "{s}/.claude/projects/{s}", .{ home, project_hash }) catch return null;
    defer allocator.free(project_dir);

    // Find most recent .jsonl file
    var dir = std.fs.cwd().openDir(project_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var most_recent_path: ?[]const u8 = null;
    var most_recent_mtime: i128 = 0;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        const stat = dir.statFile(entry.name) catch continue;
        const mtime = stat.mtime;

        if (most_recent_path == null or mtime > most_recent_mtime) {
            if (most_recent_path) |old| allocator.free(old);
            most_recent_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, entry.name }) catch continue;
            most_recent_mtime = mtime;
        }
    }

    const session_path = most_recent_path orelse return null;

    // Read file content
    const file = std.fs.cwd().openFile(session_path, .{}) catch {
        allocator.free(session_path);
        return null;
    };
    defer file.close();

    // Use a large limit - session files can grow to hundreds of MB
    const content = file.readToEndAlloc(allocator, 500 * 1024 * 1024) catch {
        allocator.free(session_path);
        return null;
    };
    defer allocator.free(content);

    // Parse JSONL lines into entries
    var entries = std.array_list.AlignedManaged(SessionEntry, null).init(allocator);
    var found_checkpoint = after_uuid == null; // If no checkpoint, include all
    var last_uuid: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const entry = parseJsonlEntry(allocator, trimmed) catch continue;

        // Check if we've passed the checkpoint
        if (!found_checkpoint) {
            if (after_uuid) |checkpoint| {
                if (std.mem.eql(u8, entry.uuid, checkpoint)) {
                    found_checkpoint = true;
                }
            }
            // Free entry since we're skipping it
            allocator.free(entry.uuid);
            allocator.free(entry.timestamp);
            allocator.free(entry.entry_type);
            if (entry.role) |r| allocator.free(r);
            if (entry.content) |c| allocator.free(c);
            if (entry.tool_name) |t| allocator.free(t);
            continue;
        }

        // Skip internal entry types
        if (std.mem.eql(u8, entry.entry_type, "summary") or
            std.mem.eql(u8, entry.entry_type, "queue-operation"))
        {
            allocator.free(entry.uuid);
            allocator.free(entry.timestamp);
            allocator.free(entry.entry_type);
            if (entry.role) |r| allocator.free(r);
            if (entry.content) |c| allocator.free(c);
            if (entry.tool_name) |t| allocator.free(t);
            continue;
        }

        // Track last UUID for checkpoint
        if (last_uuid) |old| allocator.free(old);
        last_uuid = allocator.dupe(u8, entry.uuid) catch null;

        entries.append(entry) catch continue;
    }

    if (entries.items.len == 0) {
        entries.deinit();
        if (last_uuid) |u| allocator.free(u);
        allocator.free(session_path);
        return null;
    }

    return SessionEntriesResult{
        .entries = entries.toOwnedSlice() catch {
            entries.deinit();
            if (last_uuid) |u| allocator.free(u);
            allocator.free(session_path);
            return null;
        },
        .last_uuid = last_uuid,
        .session_path = session_path,
    };
}

/// Read OpenCode session entries after a checkpoint
/// OpenCode stores data in:
///   - ~/.local/share/opencode/storage/project/{project_id}.json -> contains worktree path
///   - ~/.local/share/opencode/storage/session/{project_id}/{session_id}.json -> session metadata with directory
///   - ~/.local/share/opencode/storage/message/{session_id}/msg_*.json -> message metadata
///   - ~/.local/share/opencode/storage/part/{message_id}/prt_*.json -> message content/parts
fn readOpenCodeEntriesAfter(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    after_uuid: ?[]const u8,
) ?SessionEntriesResult {
    const home = std.posix.getenv("HOME") orelse return null;

    const base_dir = std.fmt.allocPrint(allocator, "{s}/.local/share/opencode/storage", .{home}) catch return null;
    defer allocator.free(base_dir);

    // Find the project ID and most recent session for this cwd
    const session_info = findOpenCodeSession(allocator, base_dir, cwd) orelse return null;
    defer allocator.free(session_info.session_id);

    // Build message directory path
    const message_dir = std.fmt.allocPrint(allocator, "{s}/message/{s}", .{ base_dir, session_info.session_id }) catch return null;
    defer allocator.free(message_dir);

    // Build session path for return value (used as checkpoint reference)
    const session_path = std.fmt.allocPrint(allocator, "{s}/session/{s}", .{ base_dir, session_info.session_id }) catch return null;

    // Read all messages and parts
    var entries = std.array_list.AlignedManaged(SessionEntry, null).init(allocator);
    var found_checkpoint = after_uuid == null;
    var last_uuid: ?[]const u8 = null;

    // Open and iterate message directory
    var dir = std.fs.cwd().openDir(message_dir, .{ .iterate = true }) catch {
        allocator.free(session_path);
        return null;
    };
    defer dir.close();

    // Collect message files and sort by name (which contains timestamp)
    var msg_files = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer {
        for (msg_files.items) |f| allocator.free(f);
        msg_files.deinit();
    }

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (!std.mem.startsWith(u8, entry.name, "msg_")) continue;
        msg_files.append(allocator.dupe(u8, entry.name) catch continue) catch continue;
    }

    // Sort messages by filename (IDs are time-ordered)
    std.mem.sort([]const u8, msg_files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Process each message
    for (msg_files.items) |msg_filename| {
        const msg_content = dir.readFileAlloc(allocator, msg_filename, 100 * 1024) catch continue;
        defer allocator.free(msg_content);

        const entry = parseOpenCodeMessage(allocator, base_dir, msg_content) catch continue;

        // Check if we've passed the checkpoint
        if (!found_checkpoint) {
            if (after_uuid) |checkpoint| {
                if (std.mem.eql(u8, entry.uuid, checkpoint)) {
                    found_checkpoint = true;
                }
            }
            // Free entry since we're skipping it
            allocator.free(entry.uuid);
            allocator.free(entry.timestamp);
            allocator.free(entry.entry_type);
            if (entry.role) |r| allocator.free(r);
            if (entry.content) |cont| allocator.free(cont);
            if (entry.tool_name) |t| allocator.free(t);
            continue;
        }

        // Track last UUID for checkpoint
        if (last_uuid) |old| allocator.free(old);
        last_uuid = allocator.dupe(u8, entry.uuid) catch null;

        entries.append(entry) catch continue;
    }

    if (entries.items.len == 0) {
        entries.deinit();
        if (last_uuid) |u| allocator.free(u);
        allocator.free(session_path);
        return null;
    }

    return SessionEntriesResult{
        .entries = entries.toOwnedSlice() catch {
            entries.deinit();
            if (last_uuid) |u| allocator.free(u);
            allocator.free(session_path);
            return null;
        },
        .last_uuid = last_uuid,
        .session_path = session_path,
    };
}

/// Information about an OpenCode session
const OpenCodeSessionInfo = struct {
    session_id: []const u8,
};

/// Find the most recent OpenCode session for a given working directory
fn findOpenCodeSession(allocator: std.mem.Allocator, base_dir: []const u8, cwd: []const u8) ?OpenCodeSessionInfo {
    // First, find all project directories and check their sessions for matching cwd
    const session_base = std.fmt.allocPrint(allocator, "{s}/session", .{base_dir}) catch return null;
    defer allocator.free(session_base);

    var session_dir = std.fs.cwd().openDir(session_base, .{ .iterate = true }) catch return null;
    defer session_dir.close();

    var most_recent_session: ?[]const u8 = null;
    var most_recent_time: i128 = 0;

    // Iterate through all project directories
    var dir_iter = session_dir.iterate();
    while (dir_iter.next() catch null) |project_entry| {
        if (project_entry.kind != .directory) continue;

        // Open project session directory
        var project_dir = session_dir.openDir(project_entry.name, .{ .iterate = true }) catch continue;
        defer project_dir.close();

        // Check each session file in this project
        var sess_iter = project_dir.iterate();
        while (sess_iter.next() catch null) |sess_entry| {
            if (sess_entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, sess_entry.name, ".json")) continue;
            if (!std.mem.startsWith(u8, sess_entry.name, "ses_")) continue;

            // Read session file to check directory
            const sess_content = project_dir.readFileAlloc(allocator, sess_entry.name, 10 * 1024) catch continue;
            defer allocator.free(sess_content);

            const parsed = std.json.parseFromSlice(std.json.Value, allocator, sess_content, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value != .object) continue;
            const obj = parsed.value.object;

            // Check if directory matches cwd
            const dir_val = obj.get("directory") orelse continue;
            if (dir_val != .string) continue;

            if (!std.mem.eql(u8, dir_val.string, cwd)) continue;

            // Get session ID
            const id_val = obj.get("id") orelse continue;
            if (id_val != .string) continue;

            // Get update time for sorting
            var update_time: i128 = 0;
            if (obj.get("time")) |time_val| {
                if (time_val == .object) {
                    if (time_val.object.get("updated")) |updated| {
                        switch (updated) {
                            .integer => |i| update_time = i,
                            .number_string => |s| update_time = std.fmt.parseInt(i128, s, 10) catch 0,
                            else => {},
                        }
                    }
                }
            }

            if (most_recent_session == null or update_time > most_recent_time) {
                if (most_recent_session) |old| allocator.free(old);
                most_recent_session = allocator.dupe(u8, id_val.string) catch continue;
                most_recent_time = update_time;
            }
        }
    }

    if (most_recent_session) |session_id| {
        return OpenCodeSessionInfo{
            .session_id = session_id,
        };
    }

    return null;
}

/// Parse an OpenCode message file and its parts into a SessionEntry
fn parseOpenCodeMessage(allocator: std.mem.Allocator, base_dir: []const u8, msg_json: []const u8) !SessionEntry {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, msg_json, .{}) catch return error.ParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return error.ParseError;
    const obj = parsed.value.object;

    // Extract message ID (required)
    const id_val = obj.get("id") orelse return error.MissingId;
    const msg_id = switch (id_val) {
        .string => |s| s,
        else => return error.MissingId,
    };

    // Extract role (required)
    const role_val = obj.get("role") orelse return error.MissingRole;
    const role = switch (role_val) {
        .string => |s| s,
        else => return error.MissingRole,
    };

    // Extract timestamp from time.created
    var timestamp_buf: [32]u8 = undefined;
    var timestamp: []const u8 = "1970-01-01T00:00:00.000Z";
    if (obj.get("time")) |time_val| {
        if (time_val == .object) {
            if (time_val.object.get("created")) |created| {
                switch (created) {
                    .integer => |ms| {
                        // Convert epoch ms to ISO format
                        timestamp = formatEpochMs(ms, &timestamp_buf);
                    },
                    .number_string => |s| {
                        const ms = std.fmt.parseInt(i64, s, 10) catch 0;
                        timestamp = formatEpochMs(ms, &timestamp_buf);
                    },
                    else => {},
                }
            }
        }
    }

    // Determine entry type based on role
    const entry_type = role;

    // Read parts to get content and tool info
    var content: ?[]const u8 = null;
    var tool_name: ?[]const u8 = null;

    const part_dir = std.fmt.allocPrint(allocator, "{s}/part/{s}", .{ base_dir, msg_id }) catch return error.ParseError;
    defer allocator.free(part_dir);

    var dir = std.fs.cwd().openDir(part_dir, .{ .iterate = true }) catch {
        // No parts directory - return entry with just metadata
        return SessionEntry{
            .uuid = try allocator.dupe(u8, msg_id),
            .timestamp = try allocator.dupe(u8, timestamp),
            .entry_type = try allocator.dupe(u8, entry_type),
            .role = try allocator.dupe(u8, role),
            .content = null,
            .tool_name = null,
        };
    };
    defer dir.close();

    // Read parts
    var part_iter = dir.iterate();
    while (part_iter.next() catch null) |part_entry| {
        if (part_entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, part_entry.name, ".json")) continue;
        if (!std.mem.startsWith(u8, part_entry.name, "prt_")) continue;

        const part_content = dir.readFileAlloc(allocator, part_entry.name, 50 * 1024) catch continue;
        defer allocator.free(part_content);

        const part_parsed = std.json.parseFromSlice(std.json.Value, allocator, part_content, .{}) catch continue;
        defer part_parsed.deinit();

        if (part_parsed.value != .object) continue;
        const part_obj = part_parsed.value.object;

        // Get part type
        const part_type_val = part_obj.get("type") orelse continue;
        if (part_type_val != .string) continue;
        const part_type = part_type_val.string;

        if (std.mem.eql(u8, part_type, "text")) {
            // Text content
            if (part_obj.get("text")) |text_val| {
                if (text_val == .string) {
                    const text = text_val.string;
                    const max_len: usize = 2000;
                    if (text.len > max_len) {
                        content = allocator.dupe(u8, text[0..max_len]) catch null;
                    } else {
                        content = allocator.dupe(u8, text) catch null;
                    }
                }
            }
        } else if (std.mem.eql(u8, part_type, "tool")) {
            // Tool usage
            if (part_obj.get("tool")) |tool_val| {
                if (tool_val == .string) {
                    tool_name = allocator.dupe(u8, tool_val.string) catch null;
                }
            }
        }
    }

    return SessionEntry{
        .uuid = try allocator.dupe(u8, msg_id),
        .timestamp = try allocator.dupe(u8, timestamp),
        .entry_type = try allocator.dupe(u8, entry_type),
        .role = try allocator.dupe(u8, role),
        .content = content,
        .tool_name = tool_name,
    };
}

/// Format epoch milliseconds to ISO 8601 timestamp string
fn formatEpochMs(ms: i64, buf: *[32]u8) []const u8 {
    // Convert milliseconds to seconds and remaining ms
    const secs: u64 = @intCast(@divFloor(ms, 1000));
    const rem_ms: u64 = @intCast(@mod(ms, 1000));

    // Use Zig's epoch seconds conversion
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day_secs = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();

    const hour = day_secs.getHoursIntoDay();
    const minute = day_secs.getMinutesIntoHour();
    const second = day_secs.getSecondsIntoMinute();

    const month_day = year_day.calculateMonthDay();
    const year = year_day.year;
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1;

    const len = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year, month, day, hour, minute, second, rem_ms,
    }) catch return "1970-01-01T00:00:00.000Z";

    return len;
}

/// Parse a single JSONL line into a SessionEntry
/// Uses std.json.Value for flexible content parsing (content can be string or array)
fn parseJsonlEntry(allocator: std.mem.Allocator, line: []const u8) !SessionEntry {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.ParseError;

    const obj = root.object;

    // Extract uuid (required)
    const uuid_val = obj.get("uuid") orelse return error.MissingUuid;
    const uuid = switch (uuid_val) {
        .string => |s| s,
        else => return error.MissingUuid,
    };

    // Extract timestamp (required)
    const timestamp_val = obj.get("timestamp") orelse return error.MissingTimestamp;
    const timestamp = switch (timestamp_val) {
        .string => |s| s,
        else => return error.MissingTimestamp,
    };

    // Extract type
    const entry_type_val = obj.get("type");
    const entry_type = if (entry_type_val) |v| switch (v) {
        .string => |s| s,
        else => "unknown",
    } else "unknown";

    // Extract content from message
    var content_text: ?[]const u8 = null;
    var role: ?[]const u8 = null;
    var tool_name: ?[]const u8 = null;

    if (obj.get("message")) |msg_val| {
        if (msg_val == .object) {
            const msg = msg_val.object;

            // Get role
            if (msg.get("role")) |role_val| {
                if (role_val == .string) {
                    role = try allocator.dupe(u8, role_val.string);
                }
            }

            // Get content (can be string or array)
            if (msg.get("content")) |content_val| {
                switch (content_val) {
                    .string => |s| {
                        // User messages typically have string content
                        const max_len: usize = 2000;
                        if (s.len > max_len) {
                            content_text = try allocator.dupe(u8, s[0..max_len]);
                        } else {
                            content_text = try allocator.dupe(u8, s);
                        }
                    },
                    .array => |blocks| {
                        // Assistant messages have array of content blocks
                        for (blocks.items) |block_val| {
                            if (block_val != .object) continue;
                            const block = block_val.object;

                            // Get block type
                            const block_type_val = block.get("type") orelse continue;
                            if (block_type_val != .string) continue;
                            const block_type = block_type_val.string;

                            if (std.mem.eql(u8, block_type, "text")) {
                                // Extract text content
                                if (block.get("text")) |text_val| {
                                    if (text_val == .string) {
                                        const text = text_val.string;
                                        const max_len: usize = 2000;
                                        if (text.len > max_len) {
                                            content_text = try allocator.dupe(u8, text[0..max_len]);
                                        } else {
                                            content_text = try allocator.dupe(u8, text);
                                        }
                                        break;
                                    }
                                }
                            } else if (std.mem.eql(u8, block_type, "tool_use")) {
                                // Extract tool name
                                if (block.get("name")) |name_val| {
                                    if (name_val == .string) {
                                        tool_name = try allocator.dupe(u8, name_val.string);
                                    }
                                }
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }

    return SessionEntry{
        .uuid = try allocator.dupe(u8, uuid),
        .timestamp = try allocator.dupe(u8, timestamp),
        .entry_type = try allocator.dupe(u8, entry_type),
        .role = role,
        .content = content_text,
        .tool_name = tool_name,
    };
}

/// Format session entries as GitHub-flavored markdown
pub fn formatSessionMarkdown(
    allocator: std.mem.Allocator,
    entries: []const SessionEntry,
) ![]const u8 {
    if (entries.len == 0) {
        return try allocator.dupe(u8, "_No new session activity_");
    }

    var result = std.array_list.AlignedManaged(u8, null).init(allocator);
    errdefer result.deinit();

    // Get time range from first and last entries
    const first_time = formatTimestamp(entries[0].timestamp);
    const last_time = formatTimestamp(entries[entries.len - 1].timestamp);

    // Count message types for summary
    var user_count: usize = 0;
    var assistant_count: usize = 0;
    var tool_count: usize = 0;
    for (entries) |entry| {
        if (entry.role) |role| {
            if (std.mem.eql(u8, role, "user")) {
                user_count += 1;
            } else if (std.mem.eql(u8, role, "assistant")) {
                assistant_count += 1;
            }
        }
        if (entry.tool_name != null) {
            tool_count += 1;
        }
    }

    // Write header
    try result.appendSlice("<details>\n<summary>Session (");
    var count_buf: [32]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d} user, {d} assistant", .{ user_count, assistant_count }) catch "messages";
    try result.appendSlice(count_str);
    if (tool_count > 0) {
        const tool_str = std.fmt.bufPrint(&count_buf, ", {d} tools", .{tool_count}) catch "";
        try result.appendSlice(tool_str);
    }
    try result.appendSlice(" | ");
    try result.appendSlice(&first_time);
    try result.appendSlice(" - ");
    try result.appendSlice(&last_time);
    try result.appendSlice(")</summary>\n\n");

    // Write each entry
    var current_tools = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer current_tools.deinit();

    for (entries) |entry| {
        // Collect tool names for assistant messages
        if (entry.tool_name) |tool| {
            current_tools.append(tool) catch {};
            continue;
        }

        if (entry.role) |role| {
            const time_str = formatTimestamp(entry.timestamp);

            if (std.mem.eql(u8, role, "user")) {
                // Flush any pending tools before user message
                if (current_tools.items.len > 0) {
                    try result.appendSlice("**Tools:** ");
                    for (current_tools.items, 0..) |tool, i| {
                        if (i > 0) try result.appendSlice(", ");
                        try result.appendSlice(tool);
                    }
                    try result.appendSlice("\n\n");
                    current_tools.clearRetainingCapacity();
                }

                try result.appendSlice("### User _");
                try result.appendSlice(&time_str);
                try result.appendSlice("_\n");
                if (entry.content) |content| {
                    try result.appendSlice(content);
                    if (content.len == 2000) {
                        try result.appendSlice("...");
                    }
                }
                try result.appendSlice("\n\n");
            } else if (std.mem.eql(u8, role, "assistant")) {
                try result.appendSlice("### Assistant _");
                try result.appendSlice(&time_str);
                try result.appendSlice("_\n");
                if (entry.content) |content| {
                    try result.appendSlice(content);
                    if (content.len == 2000) {
                        try result.appendSlice("...");
                    }
                }
                try result.appendSlice("\n\n");
            }
        }
    }

    // Flush any remaining tools
    if (current_tools.items.len > 0) {
        try result.appendSlice("**Tools:** ");
        for (current_tools.items, 0..) |tool, i| {
            if (i > 0) try result.appendSlice(", ");
            try result.appendSlice(tool);
        }
        try result.appendSlice("\n\n");
    }

    try result.appendSlice("</details>");

    return result.toOwnedSlice();
}

/// Format ISO timestamp to short time string (HH:MM)
fn formatTimestamp(timestamp: []const u8) [5]u8 {
    // ISO format: 2026-01-09T13:18:32.503Z
    // Extract HH:MM starting at position 11
    var result: [5]u8 = "??:??".*;
    if (timestamp.len >= 16) {
        result[0] = timestamp[11];
        result[1] = timestamp[12];
        result[2] = ':';
        result[3] = timestamp[14];
        result[4] = timestamp[15];
    }
    return result;
}

// Tests
const testing = std.testing;

test "isAgentMode returns false when no env vars set" {
    // Note: This test assumes env vars are not set in test environment
    // In practice, we can't easily unset env vars in Zig tests
    const result = isAgentMode();
    _ = result; // Just verify it compiles and runs
}

test "detectAgent returns based on env vars" {
    const agent = detectAgent();
    // Without mocking, this will return based on actual env
    _ = agent.name();
}

// ============================================================================
// parseJsonlEntry tests
// ============================================================================

test "parseJsonlEntry parses user message with string content" {
    const allocator = testing.allocator;
    const jsonl =
        \\{"uuid":"abc-123","timestamp":"2026-01-09T13:18:32.503Z","type":"user","message":{"role":"user","content":"Hello world"}}
    ;

    const entry = try parseJsonlEntry(allocator, jsonl);
    defer {
        allocator.free(entry.uuid);
        allocator.free(entry.timestamp);
        allocator.free(entry.entry_type);
        if (entry.role) |r| allocator.free(r);
        if (entry.content) |c| allocator.free(c);
        if (entry.tool_name) |t| allocator.free(t);
    }

    try testing.expectEqualStrings("abc-123", entry.uuid);
    try testing.expectEqualStrings("2026-01-09T13:18:32.503Z", entry.timestamp);
    try testing.expectEqualStrings("user", entry.entry_type);
    try testing.expectEqualStrings("user", entry.role.?);
    try testing.expectEqualStrings("Hello world", entry.content.?);
    try testing.expect(entry.tool_name == null);
}

test "parseJsonlEntry parses assistant message with text block" {
    const allocator = testing.allocator;
    const jsonl =
        \\{"uuid":"def-456","timestamp":"2026-01-09T13:19:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I can help with that."}]}}
    ;

    const entry = try parseJsonlEntry(allocator, jsonl);
    defer {
        allocator.free(entry.uuid);
        allocator.free(entry.timestamp);
        allocator.free(entry.entry_type);
        if (entry.role) |r| allocator.free(r);
        if (entry.content) |c| allocator.free(c);
        if (entry.tool_name) |t| allocator.free(t);
    }

    try testing.expectEqualStrings("def-456", entry.uuid);
    try testing.expectEqualStrings("assistant", entry.entry_type);
    try testing.expectEqualStrings("assistant", entry.role.?);
    try testing.expectEqualStrings("I can help with that.", entry.content.?);
}

test "parseJsonlEntry parses assistant message with tool_use block" {
    const allocator = testing.allocator;
    const jsonl =
        \\{"uuid":"ghi-789","timestamp":"2026-01-09T13:20:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"path":"/test.txt"}}]}}
    ;

    const entry = try parseJsonlEntry(allocator, jsonl);
    defer {
        allocator.free(entry.uuid);
        allocator.free(entry.timestamp);
        allocator.free(entry.entry_type);
        if (entry.role) |r| allocator.free(r);
        if (entry.content) |c| allocator.free(c);
        if (entry.tool_name) |t| allocator.free(t);
    }

    try testing.expectEqualStrings("ghi-789", entry.uuid);
    try testing.expectEqualStrings("Read", entry.tool_name.?);
    try testing.expect(entry.content == null);
}

test "parseJsonlEntry captures first text block and stops (text before tool)" {
    const allocator = testing.allocator;
    // When text comes before tool_use, only text is captured (implementation breaks after text)
    const jsonl =
        \\{"uuid":"jkl-012","timestamp":"2026-01-09T13:21:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Let me read that file."},{"type":"tool_use","name":"Read","input":{}}]}}
    ;

    const entry = try parseJsonlEntry(allocator, jsonl);
    defer {
        allocator.free(entry.uuid);
        allocator.free(entry.timestamp);
        allocator.free(entry.entry_type);
        if (entry.role) |r| allocator.free(r);
        if (entry.content) |c| allocator.free(c);
        if (entry.tool_name) |t| allocator.free(t);
    }

    // First text block should be captured, then break happens
    try testing.expectEqualStrings("Let me read that file.", entry.content.?);
    // Tool name not captured because break happens after text block
    try testing.expect(entry.tool_name == null);
}

test "parseJsonlEntry captures tool when it comes before text" {
    const allocator = testing.allocator;
    // When tool_use comes before text, tool is captured, then text is captured (and breaks)
    const jsonl =
        \\{"uuid":"mno-345","timestamp":"2026-01-09T13:21:30.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{}},{"type":"text","text":"Done writing."}]}}
    ;

    const entry = try parseJsonlEntry(allocator, jsonl);
    defer {
        allocator.free(entry.uuid);
        allocator.free(entry.timestamp);
        allocator.free(entry.entry_type);
        if (entry.role) |r| allocator.free(r);
        if (entry.content) |c| allocator.free(c);
        if (entry.tool_name) |t| allocator.free(t);
    }

    // Tool name is captured first
    try testing.expectEqualStrings("Write", entry.tool_name.?);
    // Then text is captured (and breaks)
    try testing.expectEqualStrings("Done writing.", entry.content.?);
}

test "parseJsonlEntry returns error on missing uuid" {
    const allocator = testing.allocator;
    const jsonl =
        \\{"timestamp":"2026-01-09T13:18:32.503Z","type":"user"}
    ;

    try testing.expectError(error.MissingUuid, parseJsonlEntry(allocator, jsonl));
}

test "parseJsonlEntry returns error on missing timestamp" {
    const allocator = testing.allocator;
    const jsonl =
        \\{"uuid":"abc-123","type":"user"}
    ;

    try testing.expectError(error.MissingTimestamp, parseJsonlEntry(allocator, jsonl));
}

test "parseJsonlEntry returns error on invalid json" {
    const allocator = testing.allocator;
    const jsonl = "not valid json";

    try testing.expectError(error.ParseError, parseJsonlEntry(allocator, jsonl));
}

test "parseJsonlEntry handles entry without message field" {
    const allocator = testing.allocator;
    const jsonl =
        \\{"uuid":"xyz-999","timestamp":"2026-01-09T13:22:00.000Z","type":"summary"}
    ;

    const entry = try parseJsonlEntry(allocator, jsonl);
    defer {
        allocator.free(entry.uuid);
        allocator.free(entry.timestamp);
        allocator.free(entry.entry_type);
        if (entry.role) |r| allocator.free(r);
        if (entry.content) |c| allocator.free(c);
        if (entry.tool_name) |t| allocator.free(t);
    }

    try testing.expectEqualStrings("xyz-999", entry.uuid);
    try testing.expectEqualStrings("summary", entry.entry_type);
    try testing.expect(entry.role == null);
    try testing.expect(entry.content == null);
}

test "parseJsonlEntry truncates long content to 2000 chars" {
    const allocator = testing.allocator;

    // Create content longer than 2000 chars
    var long_content: [2500]u8 = undefined;
    for (&long_content) |*c| {
        c.* = 'a';
    }

    var json_buf: [3000]u8 = undefined;
    const json_str = std.fmt.bufPrint(&json_buf, "{{\"uuid\":\"long-001\",\"timestamp\":\"2026-01-09T13:23:00.000Z\",\"type\":\"user\",\"message\":{{\"role\":\"user\",\"content\":\"{s}\"}}}}", .{long_content}) catch unreachable;

    const entry = try parseJsonlEntry(allocator, json_str);
    defer {
        allocator.free(entry.uuid);
        allocator.free(entry.timestamp);
        allocator.free(entry.entry_type);
        if (entry.role) |r| allocator.free(r);
        if (entry.content) |c| allocator.free(c);
        if (entry.tool_name) |t| allocator.free(t);
    }

    try testing.expect(entry.content.?.len == 2000);
}

// ============================================================================
// formatTimestamp tests
// ============================================================================

test "formatTimestamp extracts HH:MM from ISO timestamp" {
    const result = formatTimestamp("2026-01-09T13:18:32.503Z");
    try testing.expectEqualStrings("13:18", &result);
}

test "formatTimestamp handles midnight" {
    const result = formatTimestamp("2026-01-09T00:00:00.000Z");
    try testing.expectEqualStrings("00:00", &result);
}

test "formatTimestamp handles end of day" {
    const result = formatTimestamp("2026-01-09T23:59:59.999Z");
    try testing.expectEqualStrings("23:59", &result);
}

test "formatTimestamp returns placeholder for short string" {
    const result = formatTimestamp("short");
    try testing.expectEqualStrings("??:??", &result);
}

test "formatTimestamp returns placeholder for empty string" {
    const result = formatTimestamp("");
    try testing.expectEqualStrings("??:??", &result);
}

// ============================================================================
// formatSessionMarkdown tests
// ============================================================================

test "formatSessionMarkdown returns no activity message for empty entries" {
    const allocator = testing.allocator;
    const entries: []const SessionEntry = &[_]SessionEntry{};

    const result = try formatSessionMarkdown(allocator, entries);
    defer allocator.free(result);

    try testing.expectEqualStrings("_No new session activity_", result);
}

test "formatSessionMarkdown formats single user message" {
    const allocator = testing.allocator;

    var entries = [_]SessionEntry{
        .{
            .uuid = "uuid-1",
            .timestamp = "2026-01-09T10:30:00.000Z",
            .entry_type = "user",
            .role = "user",
            .content = "Hello there",
            .tool_name = null,
        },
    };

    const result = try formatSessionMarkdown(allocator, &entries);
    defer allocator.free(result);

    // Check for expected structure
    try testing.expect(std.mem.indexOf(u8, result, "<details>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</details>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "1 user, 0 assistant") != null);
    try testing.expect(std.mem.indexOf(u8, result, "### User _10:30_") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Hello there") != null);
}

test "formatSessionMarkdown formats user and assistant messages" {
    const allocator = testing.allocator;

    var entries = [_]SessionEntry{
        .{
            .uuid = "uuid-1",
            .timestamp = "2026-01-09T10:30:00.000Z",
            .entry_type = "user",
            .role = "user",
            .content = "What is 2+2?",
            .tool_name = null,
        },
        .{
            .uuid = "uuid-2",
            .timestamp = "2026-01-09T10:31:00.000Z",
            .entry_type = "assistant",
            .role = "assistant",
            .content = "2+2 equals 4.",
            .tool_name = null,
        },
    };

    const result = try formatSessionMarkdown(allocator, &entries);
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "1 user, 1 assistant") != null);
    try testing.expect(std.mem.indexOf(u8, result, "### User _10:30_") != null);
    try testing.expect(std.mem.indexOf(u8, result, "### Assistant _10:31_") != null);
    try testing.expect(std.mem.indexOf(u8, result, "What is 2+2?") != null);
    try testing.expect(std.mem.indexOf(u8, result, "2+2 equals 4.") != null);
}

test "formatSessionMarkdown includes tool count in summary" {
    const allocator = testing.allocator;

    var entries = [_]SessionEntry{
        .{
            .uuid = "uuid-1",
            .timestamp = "2026-01-09T10:30:00.000Z",
            .entry_type = "user",
            .role = "user",
            .content = "Read the file",
            .tool_name = null,
        },
        .{
            .uuid = "uuid-2",
            .timestamp = "2026-01-09T10:31:00.000Z",
            .entry_type = "assistant",
            .role = "assistant",
            .content = null,
            .tool_name = "Read",
        },
        .{
            .uuid = "uuid-3",
            .timestamp = "2026-01-09T10:32:00.000Z",
            .entry_type = "assistant",
            .role = "assistant",
            .content = "Here is the file content.",
            .tool_name = null,
        },
    };

    const result = try formatSessionMarkdown(allocator, &entries);
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "1 tools") != null);
    try testing.expect(std.mem.indexOf(u8, result, "**Tools:** Read") != null);
}

test "formatSessionMarkdown shows time range in header" {
    const allocator = testing.allocator;

    var entries = [_]SessionEntry{
        .{
            .uuid = "uuid-1",
            .timestamp = "2026-01-09T09:00:00.000Z",
            .entry_type = "user",
            .role = "user",
            .content = "First message",
            .tool_name = null,
        },
        .{
            .uuid = "uuid-2",
            .timestamp = "2026-01-09T11:30:00.000Z",
            .entry_type = "assistant",
            .role = "assistant",
            .content = "Last message",
            .tool_name = null,
        },
    };

    const result = try formatSessionMarkdown(allocator, &entries);
    defer allocator.free(result);

    // Should show time range from first to last entry
    try testing.expect(std.mem.indexOf(u8, result, "09:00 - 11:30") != null);
}

test "formatSessionMarkdown adds ellipsis for truncated content" {
    const allocator = testing.allocator;

    // Content exactly 2000 chars (will have ellipsis added)
    var content_2000: [2000]u8 = undefined;
    for (&content_2000) |*c| {
        c.* = 'x';
    }

    var entries = [_]SessionEntry{
        .{
            .uuid = "uuid-1",
            .timestamp = "2026-01-09T10:30:00.000Z",
            .entry_type = "user",
            .role = "user",
            .content = &content_2000,
            .tool_name = null,
        },
    };

    const result = try formatSessionMarkdown(allocator, &entries);
    defer allocator.free(result);

    // Should have ellipsis after the 2000-char content
    try testing.expect(std.mem.indexOf(u8, result, "...") != null);
}

test "formatSessionMarkdown handles multiple tools in sequence" {
    const allocator = testing.allocator;

    var entries = [_]SessionEntry{
        .{
            .uuid = "uuid-1",
            .timestamp = "2026-01-09T10:30:00.000Z",
            .entry_type = "user",
            .role = "user",
            .content = "Edit these files",
            .tool_name = null,
        },
        .{
            .uuid = "uuid-2",
            .timestamp = "2026-01-09T10:31:00.000Z",
            .entry_type = "assistant",
            .role = "assistant",
            .content = null,
            .tool_name = "Read",
        },
        .{
            .uuid = "uuid-3",
            .timestamp = "2026-01-09T10:31:30.000Z",
            .entry_type = "assistant",
            .role = "assistant",
            .content = null,
            .tool_name = "Edit",
        },
        .{
            .uuid = "uuid-4",
            .timestamp = "2026-01-09T10:32:00.000Z",
            .entry_type = "assistant",
            .role = "assistant",
            .content = null,
            .tool_name = "Write",
        },
        .{
            .uuid = "uuid-5",
            .timestamp = "2026-01-09T10:33:00.000Z",
            .entry_type = "user",
            .role = "user",
            .content = "Thanks",
            .tool_name = null,
        },
    };

    const result = try formatSessionMarkdown(allocator, &entries);
    defer allocator.free(result);

    // Should show "3 tools" in summary
    try testing.expect(std.mem.indexOf(u8, result, "3 tools") != null);
    // Should list all tools before the next user message
    try testing.expect(std.mem.indexOf(u8, result, "**Tools:** Read, Edit, Write") != null);
}

test "formatSessionMarkdown handles messages with null content" {
    const allocator = testing.allocator;

    var entries = [_]SessionEntry{
        .{
            .uuid = "uuid-1",
            .timestamp = "2026-01-09T10:30:00.000Z",
            .entry_type = "user",
            .role = "user",
            .content = null, // No content
            .tool_name = null,
        },
        .{
            .uuid = "uuid-2",
            .timestamp = "2026-01-09T10:31:00.000Z",
            .entry_type = "assistant",
            .role = "assistant",
            .content = null, // No content
            .tool_name = null,
        },
    };

    const result = try formatSessionMarkdown(allocator, &entries);
    defer allocator.free(result);

    // Should still produce valid markdown structure
    try testing.expect(std.mem.indexOf(u8, result, "<details>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</details>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "### User _10:30_") != null);
    try testing.expect(std.mem.indexOf(u8, result, "### Assistant _10:31_") != null);
}

test "formatSessionMarkdown skips entries without role" {
    const allocator = testing.allocator;

    var entries = [_]SessionEntry{
        .{
            .uuid = "uuid-1",
            .timestamp = "2026-01-09T10:30:00.000Z",
            .entry_type = "user",
            .role = "user",
            .content = "Hello",
            .tool_name = null,
        },
        .{
            .uuid = "uuid-2",
            .timestamp = "2026-01-09T10:31:00.000Z",
            .entry_type = "summary", // Internal type with no role
            .role = null,
            .content = "Summary content",
            .tool_name = null,
        },
        .{
            .uuid = "uuid-3",
            .timestamp = "2026-01-09T10:32:00.000Z",
            .entry_type = "assistant",
            .role = "assistant",
            .content = "Goodbye",
            .tool_name = null,
        },
    };

    const result = try formatSessionMarkdown(allocator, &entries);
    defer allocator.free(result);

    // Should only count messages with roles
    try testing.expect(std.mem.indexOf(u8, result, "1 user, 1 assistant") != null);
    // Summary content should NOT appear (no role means entry is skipped)
    try testing.expect(std.mem.indexOf(u8, result, "Summary content") == null);
}

test "formatSessionMarkdown handles interleaved conversation" {
    const allocator = testing.allocator;

    var entries = [_]SessionEntry{
        .{
            .uuid = "uuid-1",
            .timestamp = "2026-01-09T10:00:00.000Z",
            .entry_type = "user",
            .role = "user",
            .content = "Question 1",
            .tool_name = null,
        },
        .{
            .uuid = "uuid-2",
            .timestamp = "2026-01-09T10:01:00.000Z",
            .entry_type = "assistant",
            .role = "assistant",
            .content = "Answer 1",
            .tool_name = null,
        },
        .{
            .uuid = "uuid-3",
            .timestamp = "2026-01-09T10:02:00.000Z",
            .entry_type = "user",
            .role = "user",
            .content = "Question 2",
            .tool_name = null,
        },
        .{
            .uuid = "uuid-4",
            .timestamp = "2026-01-09T10:03:00.000Z",
            .entry_type = "assistant",
            .role = "assistant",
            .content = "Answer 2",
            .tool_name = null,
        },
    };

    const result = try formatSessionMarkdown(allocator, &entries);
    defer allocator.free(result);

    // Should count correctly
    try testing.expect(std.mem.indexOf(u8, result, "2 user, 2 assistant") != null);

    // Check order is preserved (Question 1 appears before Answer 1, etc.)
    const q1_pos = std.mem.indexOf(u8, result, "Question 1").?;
    const a1_pos = std.mem.indexOf(u8, result, "Answer 1").?;
    const q2_pos = std.mem.indexOf(u8, result, "Question 2").?;
    const a2_pos = std.mem.indexOf(u8, result, "Answer 2").?;

    try testing.expect(q1_pos < a1_pos);
    try testing.expect(a1_pos < q2_pos);
    try testing.expect(q2_pos < a2_pos);
}

test "formatSessionMarkdown flushes tools at end of entries" {
    const allocator = testing.allocator;

    // Conversation ends with tool usage (no subsequent user message to trigger flush)
    var entries = [_]SessionEntry{
        .{
            .uuid = "uuid-1",
            .timestamp = "2026-01-09T10:30:00.000Z",
            .entry_type = "user",
            .role = "user",
            .content = "Do something",
            .tool_name = null,
        },
        .{
            .uuid = "uuid-2",
            .timestamp = "2026-01-09T10:31:00.000Z",
            .entry_type = "assistant",
            .role = "assistant",
            .content = null,
            .tool_name = "Bash",
        },
        .{
            .uuid = "uuid-3",
            .timestamp = "2026-01-09T10:32:00.000Z",
            .entry_type = "assistant",
            .role = "assistant",
            .content = null,
            .tool_name = "Read",
        },
    };

    const result = try formatSessionMarkdown(allocator, &entries);
    defer allocator.free(result);

    // Tools should be flushed at end
    try testing.expect(std.mem.indexOf(u8, result, "**Tools:** Bash, Read") != null);
}

test "formatSessionMarkdown handles content less than 2000 chars without ellipsis" {
    const allocator = testing.allocator;

    var entries = [_]SessionEntry{
        .{
            .uuid = "uuid-1",
            .timestamp = "2026-01-09T10:30:00.000Z",
            .entry_type = "user",
            .role = "user",
            .content = "Short content",
            .tool_name = null,
        },
    };

    const result = try formatSessionMarkdown(allocator, &entries);
    defer allocator.free(result);

    // Should NOT have ellipsis for short content
    try testing.expect(std.mem.indexOf(u8, result, "Short content") != null);
    // Check that we don't have "Short content..." (with ellipsis)
    try testing.expect(std.mem.indexOf(u8, result, "Short content...") == null);
}

// ============================================================================
// OpenCode parsing tests
// ============================================================================

test "formatEpochMs formats epoch milliseconds to ISO timestamp" {
    var buf: [32]u8 = undefined;
    // 2026-01-09T16:32:56.094Z = 1767976376094 ms
    const result = formatEpochMs(1767976376094, &buf);
    try testing.expectEqualStrings("2026-01-09T16:32:56.094Z", result);
}

test "formatEpochMs handles zero" {
    var buf: [32]u8 = undefined;
    const result = formatEpochMs(0, &buf);
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", result);
}

test "formatEpochMs handles midnight" {
    var buf: [32]u8 = undefined;
    // 2026-01-01T00:00:00.000Z = 1767225600000 ms
    const result = formatEpochMs(1767225600000, &buf);
    try testing.expectEqualStrings("2026-01-01T00:00:00.000Z", result);
}

test "formatEpochMs handles end of day" {
    var buf: [32]u8 = undefined;
    // 2026-01-01T23:59:59.999Z = 1767311999999 ms
    const result = formatEpochMs(1767311999999, &buf);
    try testing.expectEqualStrings("2026-01-01T23:59:59.999Z", result);
}

test "parseOpenCodeMessage parses user message" {
    const allocator = testing.allocator;
    const msg_json =
        \\{"id":"msg_test123","sessionID":"ses_abc","role":"user","time":{"created":1767976376094}}
    ;

    // Use empty base_dir since we're not reading parts in this test
    const entry = try parseOpenCodeMessage(allocator, "/nonexistent", msg_json);
    defer {
        allocator.free(entry.uuid);
        allocator.free(entry.timestamp);
        allocator.free(entry.entry_type);
        if (entry.role) |r| allocator.free(r);
        if (entry.content) |c| allocator.free(c);
        if (entry.tool_name) |t| allocator.free(t);
    }

    try testing.expectEqualStrings("msg_test123", entry.uuid);
    try testing.expectEqualStrings("2026-01-09T16:32:56.094Z", entry.timestamp);
    try testing.expectEqualStrings("user", entry.entry_type);
    try testing.expectEqualStrings("user", entry.role.?);
    try testing.expect(entry.content == null);
    try testing.expect(entry.tool_name == null);
}

test "parseOpenCodeMessage parses assistant message" {
    const allocator = testing.allocator;
    const msg_json =
        \\{"id":"msg_assist456","sessionID":"ses_abc","role":"assistant","time":{"created":1767976380000}}
    ;

    const entry = try parseOpenCodeMessage(allocator, "/nonexistent", msg_json);
    defer {
        allocator.free(entry.uuid);
        allocator.free(entry.timestamp);
        allocator.free(entry.entry_type);
        if (entry.role) |r| allocator.free(r);
        if (entry.content) |c| allocator.free(c);
        if (entry.tool_name) |t| allocator.free(t);
    }

    try testing.expectEqualStrings("msg_assist456", entry.uuid);
    try testing.expectEqualStrings("assistant", entry.entry_type);
    try testing.expectEqualStrings("assistant", entry.role.?);
}

test "parseOpenCodeMessage returns error on missing id" {
    const allocator = testing.allocator;
    const msg_json =
        \\{"sessionID":"ses_abc","role":"user","time":{"created":1767976376094}}
    ;

    try testing.expectError(error.MissingId, parseOpenCodeMessage(allocator, "/nonexistent", msg_json));
}

test "parseOpenCodeMessage returns error on missing role" {
    const allocator = testing.allocator;
    const msg_json =
        \\{"id":"msg_test123","sessionID":"ses_abc","time":{"created":1767976376094}}
    ;

    try testing.expectError(error.MissingRole, parseOpenCodeMessage(allocator, "/nonexistent", msg_json));
}

test "parseOpenCodeMessage returns error on invalid json" {
    const allocator = testing.allocator;
    const msg_json = "not valid json";

    try testing.expectError(error.ParseError, parseOpenCodeMessage(allocator, "/nonexistent", msg_json));
}

test "parseOpenCodeMessage handles missing time field" {
    const allocator = testing.allocator;
    const msg_json =
        \\{"id":"msg_notime","sessionID":"ses_abc","role":"user"}
    ;

    const entry = try parseOpenCodeMessage(allocator, "/nonexistent", msg_json);
    defer {
        allocator.free(entry.uuid);
        allocator.free(entry.timestamp);
        allocator.free(entry.entry_type);
        if (entry.role) |r| allocator.free(r);
        if (entry.content) |c| allocator.free(c);
        if (entry.tool_name) |t| allocator.free(t);
    }

    try testing.expectEqualStrings("msg_notime", entry.uuid);
    // Should use default timestamp when time is missing
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", entry.timestamp);
}

test "parseOpenCodeMessage handles string timestamp fallback" {
    const allocator = testing.allocator;
    // String timestamps (quoted numbers) are not parsed as numbers by Zig's JSON parser
    // and should fall through to default timestamp
    const msg_json =
        \\{"id":"msg_strtime","sessionID":"ses_abc","role":"assistant","time":{"created":"1767976376094"}}
    ;

    const entry = try parseOpenCodeMessage(allocator, "/nonexistent", msg_json);
    defer {
        allocator.free(entry.uuid);
        allocator.free(entry.timestamp);
        allocator.free(entry.entry_type);
        if (entry.role) |r| allocator.free(r);
        if (entry.content) |c| allocator.free(c);
        if (entry.tool_name) |t| allocator.free(t);
    }

    try testing.expectEqualStrings("msg_strtime", entry.uuid);
    // String timestamps fall back to default (not parsed as numbers)
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", entry.timestamp);
}

test "parseOpenCodeMessage handles empty time object" {
    const allocator = testing.allocator;
    const msg_json =
        \\{"id":"msg_emptytime","sessionID":"ses_abc","role":"user","time":{}}
    ;

    const entry = try parseOpenCodeMessage(allocator, "/nonexistent", msg_json);
    defer {
        allocator.free(entry.uuid);
        allocator.free(entry.timestamp);
        allocator.free(entry.entry_type);
        if (entry.role) |r| allocator.free(r);
        if (entry.content) |c| allocator.free(c);
        if (entry.tool_name) |t| allocator.free(t);
    }

    try testing.expectEqualStrings("msg_emptytime", entry.uuid);
    // Should use default timestamp when created field is missing
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", entry.timestamp);
}

test "parseOpenCodeMessage handles extra fields gracefully" {
    const allocator = testing.allocator;
    const msg_json =
        \\{"id":"msg_extra","sessionID":"ses_abc","role":"user","time":{"created":1767976376094},"model":"claude-3-opus","tokens":1234,"unknown_field":"ignored"}
    ;

    const entry = try parseOpenCodeMessage(allocator, "/nonexistent", msg_json);
    defer {
        allocator.free(entry.uuid);
        allocator.free(entry.timestamp);
        allocator.free(entry.entry_type);
        if (entry.role) |r| allocator.free(r);
        if (entry.content) |c| allocator.free(c);
        if (entry.tool_name) |t| allocator.free(t);
    }

    try testing.expectEqualStrings("msg_extra", entry.uuid);
    try testing.expectEqualStrings("user", entry.role.?);
}

// ============================================================================
// convertJsonlToArray tests
// ============================================================================

test "convertJsonlToArray converts single line" {
    const allocator = testing.allocator;
    const jsonl =
        \\{"key":"value"}
    ;

    const result = try convertJsonlToArray(allocator, jsonl);
    defer allocator.free(result);

    try testing.expectEqualStrings("[{\"key\":\"value\"}]", result);
}

test "convertJsonlToArray converts multiple lines" {
    const allocator = testing.allocator;
    const jsonl =
        \\{"a":1}
        \\{"b":2}
        \\{"c":3}
    ;

    const result = try convertJsonlToArray(allocator, jsonl);
    defer allocator.free(result);

    try testing.expectEqualStrings("[{\"a\":1},{\"b\":2},{\"c\":3}]", result);
}

test "convertJsonlToArray handles empty input" {
    const allocator = testing.allocator;
    const jsonl = "";

    const result = try convertJsonlToArray(allocator, jsonl);
    defer allocator.free(result);

    try testing.expectEqualStrings("[]", result);
}

test "convertJsonlToArray handles blank lines" {
    const allocator = testing.allocator;
    const jsonl =
        \\{"first":1}
        \\
        \\{"second":2}
        \\
        \\{"third":3}
    ;

    const result = try convertJsonlToArray(allocator, jsonl);
    defer allocator.free(result);

    try testing.expectEqualStrings("[{\"first\":1},{\"second\":2},{\"third\":3}]", result);
}

test "convertJsonlToArray handles trailing newline" {
    const allocator = testing.allocator;
    const jsonl = "{\"key\":\"value\"}\n";

    const result = try convertJsonlToArray(allocator, jsonl);
    defer allocator.free(result);

    try testing.expectEqualStrings("[{\"key\":\"value\"}]", result);
}

test "convertJsonlToArray preserves json structure" {
    const allocator = testing.allocator;
    const jsonl =
        \\{"nested":{"inner":"value"},"array":[1,2,3]}
    ;

    const result = try convertJsonlToArray(allocator, jsonl);
    defer allocator.free(result);

    try testing.expectEqualStrings("[{\"nested\":{\"inner\":\"value\"},\"array\":[1,2,3]}]", result);
}

const std = @import("std");
const git = @import("git.zig");
const c = git.c;

pub const help =
    \\usage: git agent <command> [options]
    \\
    \\AI agent for automated task execution.
    \\
    \\Commands:
    \\  run      Execute RALPH loop to complete tasks
    \\  plan     Start planning session to create tasks
    \\
    \\Run 'git agent <command> --help' for command-specific options.
    \\
    \\Environment:
    \\  ZAGI_AGENT           Executor: claude (default) or opencode
    \\  ZAGI_AGENT_CMD       Custom command override (e.g., "aider --yes")
    \\
;

const run_help =
    \\usage: git agent run [options] [prompt]
    \\
    \\Execute RALPH loop to automatically complete tasks.
    \\
    \\Arguments:
    \\  prompt               Optional guidance for all tasks (e.g., focus areas, constraints)
    \\
    \\Options:
    \\  --once               Run only one task, then exit
    \\  --dry-run            Show what would run without executing
    \\  --delay <seconds>    Delay between tasks (default: 2)
    \\  --max-tasks <n>      Stop after n tasks (safety limit)
    \\  -h, --help           Show this help message
    \\
    \\Examples:
    \\  git agent run
    \\  git agent run --once
    \\  git agent run "focus on error handling, add tests"
    \\  ZAGI_AGENT=opencode git agent run
    \\
;

const plan_help =
    \\usage: git agent plan [options] [description]
    \\
    \\Start an interactive planning session with an AI agent.
    \\
    \\The agent will:
    \\1. Ask questions to understand your requirements
    \\2. Explore the codebase to understand the architecture
    \\3. Present a detailed plan for your approval
    \\4. Create tasks only after you confirm
    \\
    \\Options:
    \\  --dry-run            Show prompt without executing
    \\  -h, --help           Show this help message
    \\
    \\Examples:
    \\  git agent plan                              # Start interactive session
    \\  git agent plan "Add user authentication"   # Start with initial context
    \\
;

pub const Error = git.Error || error{
    InvalidCommand,
    AllocationError,
    OutOfMemory,
    SpawnFailed,
    TaskLoadFailed,
    InvalidExecutor,
};

/// Valid executor values for ZAGI_AGENT
const valid_executors = [_][]const u8{ "claude", "opencode" };

/// Builds command arguments for the specified executor.
/// Returns an ArrayList that the caller must deinit.
///
/// The `interactive` parameter controls whether the executor runs in interactive
/// mode (user can converse with agent) or headless mode (non-interactive, for
/// autonomous task execution):
/// - interactive=true: Claude runs without -p, opencode uses plain mode
/// - interactive=false: Claude runs with -p (print mode), opencode uses run mode
fn buildExecutorArgs(
    allocator: std.mem.Allocator,
    executor: []const u8,
    agent_cmd: ?[]const u8,
    prompt: []const u8,
    interactive: bool,
) !std.ArrayList([]const u8) {
    var args = std.ArrayList([]const u8){};
    errdefer args.deinit(allocator);

    if (agent_cmd) |cmd| {
        // Custom command as base, but use executor to determine mode flags
        var parts = std.mem.splitScalar(u8, cmd, ' ');
        while (parts.next()) |part| {
            if (part.len > 0) try args.append(allocator, part);
        }
        // Add mode flags based on executor type (if known)
        if (!interactive) {
            if (std.mem.eql(u8, executor, "claude")) {
                try args.append(allocator, "-p");
            } else if (std.mem.eql(u8, executor, "opencode")) {
                try args.append(allocator, "run");
            }
            // Unknown executor: no auto flags added
        }
        try args.append(allocator, prompt);
    } else if (std.mem.eql(u8, executor, "claude")) {
        try args.append(allocator, "claude");
        if (!interactive) {
            try args.append(allocator, "--dangerously-skip-permissions");
            try args.append(allocator, "-p");
        }
        try args.append(allocator, prompt);
    } else if (std.mem.eql(u8, executor, "opencode")) {
        try args.append(allocator, "opencode");
        if (!interactive) {
            try args.append(allocator, "run");
        }
        try args.append(allocator, prompt);
    } else {
        var parts = std.mem.splitScalar(u8, executor, ' ');
        while (parts.next()) |part| {
            if (part.len > 0) try args.append(allocator, part);
        }
        try args.append(allocator, prompt);
    }

    return args;
}

/// Formats the executor command for dry-run display.
/// The `interactive` parameter mirrors the buildExecutorArgs behavior.
fn formatExecutorCommand(executor: []const u8, agent_cmd: ?[]const u8, interactive: bool) []const u8 {
    // Custom command - shown as-is, user is responsible for including flags
    if (agent_cmd) |cmd| return cmd;
    if (std.mem.eql(u8, executor, "claude")) {
        return if (interactive) "claude" else "claude --dangerously-skip-permissions -p";
    }
    if (std.mem.eql(u8, executor, "opencode")) {
        return if (interactive) "opencode" else "opencode run";
    }
    return executor;
}

/// Updates the failure count for a task in the consecutive_failures tracking map.
///
/// Called after each task execution attempt:
/// - On success: pass new_count = 0 to reset the counter (task proved it can work)
/// - On failure: pass the incremented count (previous + 1)
///
/// The map uses duplicated keys because task_id strings are freed after each
/// loop iteration. If the key doesn't exist yet, we allocate a copy.
fn updateFailureCount(allocator: std.mem.Allocator, map: *std.StringHashMap(u32), task_id: []const u8, new_count: u32) void {
    const gop = map.getOrPut(task_id) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = allocator.dupe(u8, task_id) catch task_id;
    }
    gop.value_ptr.* = new_count;
}

/// Creates a log path in /tmp/zagi/<cwd-basename>/<random>.log
/// Creates the directory structure but not the file (tee will create it).
fn createLogPath(path_buf: *[512]u8) ?[]const u8 {
    // Get current working directory name for the log subdirectory
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch return null;
    const repo_name = std.fs.path.basename(cwd);

    // Generate a random ID for this run
    var random_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    // Format as hex string
    var hex_buf: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (random_bytes, 0..) |byte, i| {
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 0xf];
    }

    // Build directory path and create it
    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "/tmp/zagi/{s}", .{repo_name}) catch return null;
    std.fs.cwd().makePath(dir_path) catch {};

    // Build full file path
    const path = std.fmt.bufPrint(path_buf, "/tmp/zagi/{s}/{s}.log", .{ repo_name, hex_buf }) catch return null;

    return path;
}

/// Validates ZAGI_AGENT env var. Returns validated executor or error.
/// If not set, returns "claude" as default.
/// If set to invalid value (like "1"), returns error.
fn getValidatedExecutor(stdout: anytype) Error![]const u8 {
    const env_value = std.posix.getenv("ZAGI_AGENT") orelse return "claude";

    // Check if it's a valid executor
    for (valid_executors) |valid| {
        if (std.mem.eql(u8, env_value, valid)) {
            return env_value;
        }
    }

    // Invalid value - show error with valid options
    stdout.print("error: invalid ZAGI_AGENT value '{s}'\n", .{env_value}) catch {};
    stdout.print("  valid values: claude, opencode (or unset for default)\n", .{}) catch {};
    stdout.print("  note: use ZAGI_AGENT_CMD for custom executors\n", .{}) catch {};
    return Error.InvalidExecutor;
}

pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Need at least "zagi agent <subcommand>"
    if (args.len < 3) {
        stdout.print("{s}", .{help}) catch {};
        return;
    }

    const subcommand = std.mem.sliceTo(args[2], 0);

    if (std.mem.eql(u8, subcommand, "run")) {
        return runRun(allocator, args);
    } else if (std.mem.eql(u8, subcommand, "plan")) {
        return runPlan(allocator, args);
    } else if (std.mem.eql(u8, subcommand, "-h") or std.mem.eql(u8, subcommand, "--help")) {
        stdout.print("{s}", .{help}) catch {};
        return;
    } else {
        stdout.print("error: unknown command '{s}'\n\n{s}", .{ subcommand, help }) catch {};
        return Error.InvalidCommand;
    }
}

/// Planning prompt template for the `zagi agent plan` subcommand.
///
/// This prompt instructs an AI agent to conduct an INTERACTIVE planning session
/// where it explores the codebase first, then asks clarifying questions about
/// scope, constraints, and preferences before drafting any plan. The session is
/// collaborative - the agent understands the architecture, asks targeted questions
/// to gather requirements, and only creates tasks after user approval.
///
/// Template placeholders:
/// - {0s}: Optional initial context from the user (may be empty)
/// - {1s}: Absolute path to the zagi binary (for task creation commands)
///
/// The planning agent follows a strict protocol:
/// 1. EXPLORE: Read the codebase to understand architecture FIRST
/// 2. ASK: Ask clarifying questions about scope, constraints, preferences
/// 3. PROPOSE: Present a numbered plan referencing specific files/patterns
/// 4. CONFIRM: Only create tasks after explicit approval
const planning_prompt_template =
    \\You are an interactive planning agent. Your job is to collaboratively design
    \\an implementation plan with the user through conversation.
    \\
    \\INITIAL CONTEXT: {0s}
    \\
    \\=== INTERACTIVE PLANNING PROTOCOL ===
    \\
    \\PHASE 1: EXPLORE CODEBASE (do this FIRST, before asking questions)
    \\Before asking any questions, silently explore the codebase to understand:
    \\- Read AGENTS.md for project conventions, build commands, and patterns
    \\- Examine the directory structure to understand the project layout
    \\- Identify key files and their purposes
    \\- Understand the current architecture and patterns in use
    \\- Find existing code related to the initial context (if provided)
    \\- Note any relevant tests, configs, or documentation
    \\
    \\This exploration helps you ask informed questions and propose realistic plans.
    \\
    \\PHASE 2: ASK CLARIFYING QUESTIONS (critical - do not skip)
    \\DO NOT draft a plan yet. First, engage the user with clarifying questions.
    \\Ask about these areas before proposing any implementation:
    \\
    \\SCOPE questions:
    \\- What specific functionality should be included/excluded?
    \\- Are there edge cases or error scenarios to consider?
    \\- What's the minimum viable version vs nice-to-haves?
    \\
    \\CONSTRAINTS questions:
    \\- Are there performance requirements?
    \\- Any dependencies or compatibility concerns?
    \\- Time/effort budget considerations?
    \\
    \\PREFERENCES questions:
    \\- Preferred approach or patterns? (e.g., "should this use X or Y?")
    \\- How should this integrate with existing code?
    \\- Testing requirements or coverage expectations?
    \\
    \\ACCEPTANCE CRITERIA questions:
    \\- How will we know when this is done?
    \\- What does success look like?
    \\
    \\Guidelines:
    \\- Ask 2-4 focused questions at a time, not a wall of questions
    \\- Reference what you found in the codebase to make questions specific
    \\- Keep asking until you have clarity on scope, constraints, and preferences
    \\- If context was provided, acknowledge it and ask clarifying follow-ups
    \\- If no context, start by asking "What would you like to build?"
    \\
    \\PHASE 3: PROPOSE PLAN (only after clarifying questions answered)
    \\Present a detailed, numbered implementation plan:
    \\- Reference specific files and patterns discovered in Phase 1
    \\- Break work into small, self-contained tasks
    \\- Each task should be completable in one session
    \\- Include acceptance criteria for each task
    \\- Order tasks by dependencies (foundations first)
    \\- Format as a numbered list the user can review
    \\
    \\Example plan format:
    \\  "Based on our discussion and my exploration, here's my proposed plan:
    \\
    \\   1. Add user model - create src/models/user.zig following the struct
    \\      patterns I found in src/cmds/git.zig
    \\   2. Add auth endpoint - POST /api/login, integrating with your existing
    \\      error handling in src/cmds/git.zig
    \\   3. Add middleware - JWT validation following your existing patterns
    \\   4. Add tests - unit tests matching your test/ structure
    \\
    \\   Does this look good? Should I adjust anything before creating tasks?"
    \\
    \\PHASE 4: CREATE TASKS (only after approval)
    \\Wait for explicit user confirmation before creating any tasks.
    \\When approved, you have two options:
    \\
    \\Option A - Write plan to file, then import:
    \\  1. Write plan to plan.md with numbered list (1. Task one, 2. Task two, ...)
    \\  2. Run: {1s} tasks import plan.md
    \\  This creates all tasks at once from the markdown file.
    \\
    \\Option B - Add tasks individually:
    \\  {1s} tasks add "<task description with acceptance criteria>"
    \\
    \\After creating all tasks, show the final list:
    \\  {1s} tasks list
    \\
    \\=== RULES ===
    \\- ALWAYS explore the codebase BEFORE asking questions
    \\- ALWAYS ask clarifying questions BEFORE drafting a plan
    \\- Ask informed questions that reference what you found
    \\- NEVER create tasks without explicit user approval
    \\- NEVER git push (only commit)
    \\- Keep the conversation focused and productive
    \\- If the user wants to change the plan, update it and confirm again
    \\
;

fn runPlan(allocator: std.mem.Allocator, args: [][:0]u8) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var dry_run = false;
    var initial_context: ?[]const u8 = null;

    var i: usize = 3; // Start after "zagi agent plan"
    while (i < args.len) {
        const arg = std.mem.sliceTo(args[i], 0);

        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            stdout.print("{s}", .{plan_help}) catch {};
            return;
        } else if (arg[0] == '-') {
            stdout.print("error: unknown option '{s}'\n", .{arg}) catch {};
            return Error.InvalidCommand;
        } else {
            initial_context = arg;
        }
        i += 1;
    }

    // Check ZAGI_AGENT_CMD for custom command override
    const agent_cmd = std.posix.getenv("ZAGI_AGENT_CMD");
    const executor = if (agent_cmd != null)
        std.posix.getenv("ZAGI_AGENT") orelse "" // No auto flags when only ZAGI_AGENT_CMD is set
    else
        try getValidatedExecutor(stdout);

    // Get absolute path to current executable
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_path_buf) catch {
        stderr.print("error: failed to resolve executable path\n", .{}) catch {};
        return Error.SpawnFailed;
    };

    // Use provided context or indicate none was given
    const context_str = initial_context orelse "(none - start by asking what the user wants to build)";

    // Create the planning prompt with dynamic path
    const prompt = std.fmt.allocPrint(allocator, planning_prompt_template, .{ context_str, exe_path }) catch return Error.OutOfMemory;
    defer allocator.free(prompt);

    if (dry_run) {
        stdout.print("=== Interactive Planning Session (dry-run) ===\n\n", .{}) catch {};
        if (initial_context) |ctx| {
            stdout.print("Initial context: {s}\n\n", .{ctx}) catch {};
        } else {
            stdout.print("Initial context: (none - will ask user)\n\n", .{}) catch {};
        }
        stdout.print("Would execute:\n", .{}) catch {};
        stdout.print("  {s} \"<planning prompt>\"\n", .{formatExecutorCommand(executor, agent_cmd, true)}) catch {};
        stdout.print("\n--- Prompt Preview ---\n{s}\n", .{prompt}) catch {};
        return;
    }

    stdout.print("=== Starting Interactive Planning Session ===\n", .{}) catch {};
    if (initial_context) |ctx| {
        stdout.print("Initial context: {s}\n", .{ctx}) catch {};
    }
    stdout.print("Executor: {s}\n", .{executor}) catch {};
    stdout.print("\nThe agent will ask questions to understand your requirements,\n", .{}) catch {};
    stdout.print("then propose a plan for your approval before creating tasks.\n\n", .{}) catch {};

    // Build and execute command in interactive mode (user converses with agent)
    var runner_args = buildExecutorArgs(allocator, executor, agent_cmd, prompt, true) catch return Error.OutOfMemory;
    defer runner_args.deinit(allocator);

    var child = std.process.Child.init(runner_args.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        stderr.print("Error executing agent: {s}\n", .{@errorName(err)}) catch {};
        return Error.SpawnFailed;
    };

    const success = term == .Exited and term.Exited == 0;

    if (success) {
        stdout.print("\n=== Planning session completed ===\n", .{}) catch {};
        stdout.print("Run 'zagi tasks list' to see created tasks\n", .{}) catch {};
        stdout.print("Run 'zagi agent run' to execute tasks\n", .{}) catch {};
    } else {
        stdout.print("\n=== Planning session ended ===\n", .{}) catch {};
    }
}

/// Executes the RALPH (Recursive Agent Loop Pattern for Humans) loop.
///
/// The RALPH loop is an autonomous task execution pattern:
///
/// ```
/// ┌─────────────────────────────────────────────────────────┐
/// │  RALPH Loop Algorithm                                   │
/// ├─────────────────────────────────────────────────────────┤
/// │  1. Load pending tasks from git refs                    │
/// │  2. Find next task with < 3 consecutive failures        │
/// │  3. If no eligible task found → exit loop               │
/// │  4. Execute task with configured AI agent               │
/// │  5. On success: reset failure counter, increment count  │
/// │     On failure: increment failure counter               │
/// │  6. If --once flag set → exit loop                      │
/// │  7. Wait delay seconds, goto step 1                     │
/// └─────────────────────────────────────────────────────────┘
/// ```
///
/// Key behaviors:
/// - **Failure tolerance**: Tasks are skipped after 3 consecutive failures
///   to prevent infinite loops on broken tasks
/// - **Safety limits**: Optional --max-tasks prevents runaway execution
/// - **Observability**: Output streamed to /tmp/zagi/<repo>/<task>.log
/// - **Graceful completion**: Exits when all tasks done or all remaining
///   tasks have exceeded failure threshold
fn runRun(allocator: std.mem.Allocator, args: [][:0]u8) Error!void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Parse command options
    var once = false;
    var dry_run = false;
    var delay: u32 = 2;
    var max_tasks: ?u32 = null;
    var operator_prompt: ?[]const u8 = null;

    var i: usize = 3; // Start after "zagi agent run"
    while (i < args.len) {
        const arg = std.mem.sliceTo(args[i], 0);

        if (std.mem.eql(u8, arg, "--once")) {
            once = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--delay")) {
            i += 1;
            if (i >= args.len) {
                stdout.print("error: --delay requires a number of seconds\n", .{}) catch {};
                return Error.InvalidCommand;
            }
            const delay_str = std.mem.sliceTo(args[i], 0);
            delay = std.fmt.parseInt(u32, delay_str, 10) catch {
                stdout.print("error: invalid delay value '{s}'\n", .{delay_str}) catch {};
                return Error.InvalidCommand;
            };
        } else if (std.mem.eql(u8, arg, "--max-tasks")) {
            i += 1;
            if (i >= args.len) {
                stdout.print("error: --max-tasks requires a number\n", .{}) catch {};
                return Error.InvalidCommand;
            }
            const max_str = std.mem.sliceTo(args[i], 0);
            max_tasks = std.fmt.parseInt(u32, max_str, 10) catch {
                stdout.print("error: invalid max-tasks value '{s}'\n", .{max_str}) catch {};
                return Error.InvalidCommand;
            };
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            stdout.print("{s}", .{run_help}) catch {};
            return;
        } else if (arg[0] == '-') {
            stdout.print("error: unknown option '{s}'\n", .{arg}) catch {};
            return Error.InvalidCommand;
        } else {
            // Positional argument = operator prompt
            operator_prompt = arg;
        }
        i += 1;
    }

    // Check ZAGI_AGENT_CMD for custom command override
    const agent_cmd = std.posix.getenv("ZAGI_AGENT_CMD");
    const executor = if (agent_cmd != null)
        std.posix.getenv("ZAGI_AGENT") orelse "" // No auto flags when only ZAGI_AGENT_CMD is set
    else
        try getValidatedExecutor(stdout);

    // Get absolute path to current executable
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_path_buf) catch {
        stderr.print("error: failed to resolve executable path\n", .{}) catch {};
        return Error.SpawnFailed;
    };

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

    // Create log path in temp directory: /tmp/zagi/<reponame>/<random>.log
    var log_path_buf: [512]u8 = undefined;
    const log_path = createLogPath(&log_path_buf);

    if (log_path) |p| {
        stdout.print("Log file: {s}\n", .{p}) catch {};
    }

    var tasks_completed: u32 = 0;

    // Consecutive failure tracking map: task_id -> failure_count
    //
    // This map tracks how many times each task has failed IN A ROW. The key
    // insight is "consecutive" - a task that succeeds resets its counter to 0.
    //
    // Why track consecutive failures instead of total failures?
    // - Transient errors (network issues, race conditions) shouldn't permanently
    //   disqualify a task
    // - If a task succeeds once, it proves the task CAN work
    // - 3 consecutive failures strongly suggests the task itself is broken
    //
    // Memory management: Keys are duplicated because task IDs come from
    // getPendingTasks() which frees its memory after each iteration. The
    // deferred cleanup frees all duplicated keys before map deinit.
    var consecutive_failures = std.StringHashMap(u32).init(allocator);
    defer {
        // Free all the duplicated keys before deiniting the map
        var key_iter = consecutive_failures.keyIterator();
        while (key_iter.next()) |key_ptr| {
            allocator.free(key_ptr.*);
        }
        consecutive_failures.deinit();
    }

    stdout.print("Starting RALPH loop...\n", .{}) catch {};
    if (dry_run) {
        stdout.print("(dry-run mode - no commands will be executed)\n", .{}) catch {};
    }
    stdout.print("Executor: {s}\n", .{executor}) catch {};
    if (operator_prompt) |p| {
        stdout.print("Prompt: {s}\n", .{p}) catch {};
    }
    stdout.print("\n", .{}) catch {};

    while (true) {
        if (max_tasks) |max| {
            if (tasks_completed >= max) {
                stdout.print("Reached maximum task limit ({})\n", .{max}) catch {};
                break;
            }
        }

        const pending = getPendingTasks(allocator) catch {
            stderr.print("error: failed to load tasks\n", .{}) catch {};
            return Error.TaskLoadFailed;
        };
        defer allocator.free(pending.tasks);
        defer for (pending.tasks) |t| {
            allocator.free(t.id);
            allocator.free(t.content);
        };

        if (pending.tasks.len == 0) {
            stdout.print("No pending tasks remaining. All tasks complete!\n", .{}) catch {};
            stdout.print("Run: zagi tasks pr\n", .{}) catch {};
            break;
        }

        var next_task: ?PendingTask = null;
        for (pending.tasks) |task| {
            const failure_count = consecutive_failures.get(task.id) orelse 0;
            if (failure_count < 3) {
                next_task = task;
                break;
            }
        }

        if (next_task == null) {
            stdout.print("All remaining tasks have failed 3+ times. Stopping.\n", .{}) catch {};
            break;
        }

        const task = next_task.?;
        stdout.print("Starting task: {s}\n", .{task.id}) catch {};
        stdout.print("  {s}\n\n", .{task.content}) catch {};

        if (dry_run) {
            stdout.print("Would execute:\n", .{}) catch {};
            if (agent_cmd) |cmd| {
                // Show custom command with mode flags based on executor
                if (std.mem.eql(u8, executor, "claude")) {
                    stdout.print("  {s} -p \"<prompt>\"\n", .{cmd}) catch {};
                } else if (std.mem.eql(u8, executor, "opencode")) {
                    stdout.print("  {s} run \"<prompt>\"\n", .{cmd}) catch {};
                } else {
                    stdout.print("  {s} \"<prompt>\"\n", .{cmd}) catch {};
                }
            } else {
                stdout.print("  {s} \"<prompt>\"\n", .{formatExecutorCommand(executor, agent_cmd, false)}) catch {};
            }
            stdout.print("\n", .{}) catch {};
            tasks_completed += 1;
        } else {
            const success = executeTask(allocator, executor, agent_cmd, exe_path, task.id, task.content, operator_prompt, log_path) catch false;

            if (success) {
                updateFailureCount(allocator, &consecutive_failures, task.id, 0);
                tasks_completed += 1;
                stdout.print("Task completed successfully\n\n", .{}) catch {};
            } else {
                const new_failures = (consecutive_failures.get(task.id) orelse 0) + 1;
                updateFailureCount(allocator, &consecutive_failures, task.id, new_failures);
                stdout.print("Task failed ({} consecutive failures)\n", .{new_failures}) catch {};
                if (new_failures >= 3) {
                    stdout.print("Skipping task after 3 consecutive failures\n", .{}) catch {};
                }
                stdout.print("\n", .{}) catch {};
            }
        }

        if (once) {
            stdout.print("Exiting after one task (--once flag set)\n", .{}) catch {};
            break;
        }

        if (!dry_run and delay > 0) {
            stdout.print("Waiting {} seconds before next task...\n\n", .{delay}) catch {};
            std.Thread.sleep(delay * std.time.ns_per_s);
        }
    }

    stdout.print("RALPH loop completed. {} tasks processed.\n", .{tasks_completed}) catch {};
}

const PendingTask = struct {
    id: []const u8,
    content: []const u8,
};

const PendingTasks = struct {
    tasks: []PendingTask,
};

fn getPendingTasks(allocator: std.mem.Allocator) !PendingTasks {
    // Get absolute path to current executable to avoid relative path issues
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_path_buf) catch return error.SpawnFailed;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ exe_path, "tasks", "list", "--json" },
    }) catch return error.SpawnFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const parsed = std.json.parseFromSlice(struct {
        tasks: []const struct {
            id: []const u8,
            content: []const u8,
            status: []const u8,
            created: i64,
            completed: ?i64,
        },
    }, allocator, result.stdout, .{}) catch {
        return PendingTasks{ .tasks = &.{} };
    };
    defer parsed.deinit();

    var pending = std.ArrayList(PendingTask){};
    for (parsed.value.tasks) |task| {
        if (!std.mem.eql(u8, task.status, "completed")) {
            const id_dupe = allocator.dupe(u8, task.id) catch continue;
            const content_dupe = allocator.dupe(u8, task.content) catch {
                allocator.free(id_dupe); // Free id if content alloc fails
                continue;
            };
            pending.append(allocator, .{
                .id = id_dupe,
                .content = content_dupe,
            }) catch {
                allocator.free(id_dupe);
                allocator.free(content_dupe);
                continue;
            };
        }
    }

    return PendingTasks{ .tasks = pending.toOwnedSlice(allocator) catch &.{} };
}

fn createPrompt(allocator: std.mem.Allocator, exe_path: []const u8, task_id: []const u8, task_content: []const u8, operator_prompt: ?[]const u8) ![]u8 {
    const prompt_section = if (operator_prompt) |p|
        std.fmt.allocPrint(allocator, "\nOperator guidance:\n{s}\n", .{p}) catch ""
    else
        "";
    defer if (operator_prompt != null and prompt_section.len > 0) allocator.free(prompt_section);

    return std.fmt.allocPrint(allocator,
        \\Task ID: {0s}
        \\Task: {1s}{3s}
        \\
        \\Instructions:
        \\1. Read AGENTS.md if it exists for project context
        \\2. Complete this ONE task only
        \\3. Verify your work (run tests if applicable)
        \\4. Commit changes: git commit -m "<message>"
        \\5. Mark done: {2s} tasks done {0s}
        \\6. Output the COMPLETION PROMISE below
        \\
        \\Knowledge Persistence:
        \\If you discover important insights during this task, update AGENTS.md:
        \\- Build commands that work (or gotchas that don't)
        \\- Key file locations and their purposes
        \\- Project conventions not documented elsewhere
        \\- Common errors and their solutions
        \\Only add genuinely useful operational knowledge, not task-specific details.
        \\
        \\COMPLETION PROMISE (required - output this exactly when done):
        \\
        \\COMPLETION PROMISE: I confirm that:
        \\- Tests pass: [which tests ran, or "N/A" if no tests]
        \\- Build succeeds: [build command, or "N/A" if no build]
        \\- Changes committed: [commit hash and message]
        \\- Task completed: [brief summary of what was done]
        \\-- I have not taken any shortcuts or skipped verification.
        \\
        \\Rules:
        \\- NEVER git push
        \\- Only work on this task
        \\- Must output the completion promise when done
    , .{ task_id, task_content, exe_path, prompt_section });
}

fn executeTask(allocator: std.mem.Allocator, executor: []const u8, agent_cmd: ?[]const u8, exe_path: []const u8, task_id: []const u8, task_content: []const u8, operator_prompt: ?[]const u8, log_path: ?[]const u8) !bool {
    const stderr_writer = std.fs.File.stderr().deprecatedWriter();

    const prompt = try createPrompt(allocator, exe_path, task_id, task_content, operator_prompt);
    defer allocator.free(prompt);

    // Use headless mode (interactive=false) for autonomous task execution
    var runner_args = try buildExecutorArgs(allocator, executor, agent_cmd, prompt, false);
    defer runner_args.deinit(allocator);

    // Build command string for shell execution with tee
    var cmd_buf: [4096]u8 = undefined;
    var cmd_len: usize = 0;

    // Quote each argument and join
    for (runner_args.items) |arg| {
        if (cmd_len > 0) {
            cmd_buf[cmd_len] = ' ';
            cmd_len += 1;
        }
        // Add single quotes around arg, escaping any single quotes in it
        cmd_buf[cmd_len] = '\'';
        cmd_len += 1;
        for (arg) |ch| {
            if (ch == '\'') {
                // End quote, add escaped quote, restart quote: '\''
                if (cmd_len + 4 < cmd_buf.len) {
                    cmd_buf[cmd_len] = '\'';
                    cmd_buf[cmd_len + 1] = '\\';
                    cmd_buf[cmd_len + 2] = '\'';
                    cmd_buf[cmd_len + 3] = '\'';
                    cmd_len += 4;
                }
            } else {
                if (cmd_len < cmd_buf.len) {
                    cmd_buf[cmd_len] = ch;
                    cmd_len += 1;
                }
            }
        }
        cmd_buf[cmd_len] = '\'';
        cmd_len += 1;
    }

    // Add tee to log file if we have a log path
    if (log_path) |lp| {
        const tee_suffix = std.fmt.bufPrint(cmd_buf[cmd_len..], " 2>&1 | tee '{s}'", .{lp}) catch return false;
        cmd_len += tee_suffix.len;
    }

    const shell_cmd = cmd_buf[0..cmd_len];

    // Run via shell to get tee piping
    var child = std.process.Child.init(&.{ "/bin/sh", "-c", shell_cmd }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        stderr_writer.print("Error executing runner: {s}\n", .{@errorName(err)}) catch {};
        return false;
    };

    const exited_ok = term == .Exited and term.Exited == 0;

    // Check log file for completion promise
    var found_completion = false;
    if (log_path) |lp| {
        const log_content = std.fs.cwd().readFileAlloc(allocator, lp, 10 * 1024 * 1024) catch null;
        if (log_content) |content| {
            defer allocator.free(content);
            const promise_start = "COMPLETION PROMISE: I confirm that:";
            const promise_end = "-- I have not taken any shortcuts or skipped verification.";
            const found_start = std.mem.indexOf(u8, content, promise_start) != null;
            const found_end = std.mem.indexOf(u8, content, promise_end) != null;
            found_completion = found_start and found_end;
        }
    }

    if (!found_completion) {
        stderr_writer.print("Task did not output completion promise\n", .{}) catch {};
    }

    return exited_ok and found_completion;
}

// Tests for buildExecutorArgs
const testing = std.testing;

test "buildExecutorArgs - claude headless includes --dangerously-skip-permissions and -p" {
    var args = try buildExecutorArgs(testing.allocator, "claude", null, "test prompt", false);
    defer args.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), args.items.len);
    try testing.expectEqualStrings("claude", args.items[0]);
    try testing.expectEqualStrings("--dangerously-skip-permissions", args.items[1]);
    try testing.expectEqualStrings("-p", args.items[2]);
    try testing.expectEqualStrings("test prompt", args.items[3]);
}

test "buildExecutorArgs - claude interactive no -p" {
    var args = try buildExecutorArgs(testing.allocator, "claude", null, "test prompt", true);
    defer args.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), args.items.len);
    try testing.expectEqualStrings("claude", args.items[0]);
    try testing.expectEqualStrings("test prompt", args.items[1]);
}

test "buildExecutorArgs - opencode headless includes run" {
    var args = try buildExecutorArgs(testing.allocator, "opencode", null, "test prompt", false);
    defer args.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), args.items.len);
    try testing.expectEqualStrings("opencode", args.items[0]);
    try testing.expectEqualStrings("run", args.items[1]);
    try testing.expectEqualStrings("test prompt", args.items[2]);
}

test "buildExecutorArgs - opencode interactive no run" {
    var args = try buildExecutorArgs(testing.allocator, "opencode", null, "test prompt", true);
    defer args.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), args.items.len);
    try testing.expectEqualStrings("opencode", args.items[0]);
    try testing.expectEqualStrings("test prompt", args.items[1]);
}

test "buildExecutorArgs - custom cmd with claude executor gets -p" {
    // Custom command + ZAGI_AGENT=claude → adds -p for headless
    var args = try buildExecutorArgs(testing.allocator, "claude", "my-claude --flag", "test prompt", false);
    defer args.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), args.items.len);
    try testing.expectEqualStrings("my-claude", args.items[0]);
    try testing.expectEqualStrings("--flag", args.items[1]);
    try testing.expectEqualStrings("-p", args.items[2]);
    try testing.expectEqualStrings("test prompt", args.items[3]);
}

test "buildExecutorArgs - custom cmd with opencode executor gets run" {
    // Custom command + ZAGI_AGENT=opencode → adds run for headless
    var args = try buildExecutorArgs(testing.allocator, "opencode", "my-opencode --flag", "test prompt", false);
    defer args.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), args.items.len);
    try testing.expectEqualStrings("my-opencode", args.items[0]);
    try testing.expectEqualStrings("--flag", args.items[1]);
    try testing.expectEqualStrings("run", args.items[2]);
    try testing.expectEqualStrings("test prompt", args.items[3]);
}

test "buildExecutorArgs - custom cmd with unknown executor no auto flags" {
    // Custom command + unknown executor → no auto flags
    var args = try buildExecutorArgs(testing.allocator, "aider", "aider --yes", "test prompt", false);
    defer args.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), args.items.len);
    try testing.expectEqualStrings("aider", args.items[0]);
    try testing.expectEqualStrings("--yes", args.items[1]);
    try testing.expectEqualStrings("test prompt", args.items[2]);
}

test "buildExecutorArgs - custom cmd interactive no flags added" {
    // Interactive mode never adds mode flags
    var args = try buildExecutorArgs(testing.allocator, "claude", "my-claude --flag", "test prompt", true);
    defer args.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), args.items.len);
    try testing.expectEqualStrings("my-claude", args.items[0]);
    try testing.expectEqualStrings("--flag", args.items[1]);
    try testing.expectEqualStrings("test prompt", args.items[2]);
}


# zagi

This document describes the process for adding new git commands to zagi.

## Requirements

- Zig 0.15+
- Bun (for integration tests)

## Style

- zagi is always lowercase
- No emojis in code or output
- Concise output optimized for agents

## Committing with Prompts

When committing code, **always include the complete user prompt** that created the change:

```bash
git commit -m "<commit-message>" --prompt "<complete-user-prompt-for-this-commit>"
```

The `--prompt` should contain the **full user request** that led to this commit, not a summary. This preserves context for code review.

Example:
```bash
git commit -m "Add logout button" --prompt "Add a logout button to the header. When clicked it should clear the session and redirect to /login"
```

When `--prompt` is used, zagi automatically stores metadata in git notes:
- `refs/notes/agent` - detected AI agent (claude, opencode, cursor, windsurf, vscode, terminal)
- `refs/notes/prompt` - the user prompt text
- `refs/notes/session` - full session transcript (for Claude Code, OpenCode)

View metadata with:
```bash
git log --prompts   # show prompts (truncated to 200 chars)
git log --agent     # show which AI agent made each commit
git log --session   # show session transcript (paginated, first 20k bytes)
git log --session --session-offset=20000  # continue from byte 20000
```

### Agent Mode

Agent mode is automatically enabled when running inside AI tools:
- Claude Code (sets `CLAUDECODE=1`)
- OpenCode (sets `OPENCODE=1`)
- VS Code, Cursor, Windsurf (detected from terminal environment)

You can also enable it manually:
```bash
export ZAGI_AGENT=my-agent
```

When agent mode is active:
1. `git commit` will fail without `--prompt`, ensuring all AI-generated commits have their prompts recorded
2. Destructive commands are blocked to prevent data loss

## git edit (Mid-Stack Editing)

The `git edit` command enables **jj-style mid-stack editing** - the ability to travel back to any ancestor commit, make changes, then automatically rebase all descendant commits on top. This is useful when you need to fix a bug or update code in a commit that's not at the tip of your branch.

### Workflow

```
A -- B -- C -- D  (HEAD on main)
     ^
     |
  you want to edit B
```

1. **Start the edit session:**
   ```bash
   git edit B       # or git edit HEAD~2
   ```
   This detaches HEAD at commit B and saves:
   - Original HEAD location (D)
   - List of descendant commits to rebase (C, D)

2. **Make your changes** - edit files, stage, commit (amend or new commits)

3. **Return and rebase:**
   ```bash
   git edit --back
   ```
   This cherry-picks C and D onto your modified B, then restores the branch pointer.

```
A -- B' -- C' -- D'  (HEAD back on main)
```

### Commands

| Command | Description |
|---------|-------------|
| `git edit <commit>` | Travel to commit for editing (detaches HEAD) |
| `git edit --back` | Return to branch and rebase descendants |
| `git edit --continue` | Continue after resolving a conflict |
| `git edit --abort` | Cancel edit and restore original state |
| `git edit --status` | Show current edit session state |

### State Storage (refs/edit/*)

Edit state is stored in git refs, not files, making it recoverable:

| Ref | Purpose |
|-----|---------|
| `refs/edit/origin` | Points to original HEAD (where branch was) |
| `refs/edit/descendants` | Points to blob containing OIDs of commits to rebase |
| `refs/edit/current` | Points to last successful rebase position (during conflicts) |

### Crash Recovery

If something goes wrong (crash, terminal closed), recover with:

```bash
git edit --status    # Check if edit session is active and see state
git edit --abort     # Restore original state and clear edit refs
```

The `--status` command shows:
- Whether an edit is active
- Current target commit
- Original HEAD position
- Number of remaining commits to rebase
- Conflict status (if any)

### Conflict Resolution

If a cherry-pick fails during `--back`:

```bash
# Conflict output:
conflict: cherry-pick failed
resolve conflicts then:
  git add <files>
  git edit --continue
or:
  git edit --abort
```

The `--continue` command:
1. Creates a commit from the resolved index
2. Continues cherry-picking remaining descendants
3. Completes the edit when all commits are rebased

### Guardrails

**Push is blocked during edit sessions.** Since you're in detached HEAD state with uncommitted rebase work, pushing would be dangerous:

```bash
$ git push
error: git push blocked during edit session
hint: complete with --back or --abort first
```

This prevents accidentally pushing a partial rebase state or corrupted history.

### Example Session

```bash
# Fix a typo in a commit from 3 commits ago
$ git edit HEAD~3
edit: abc1234 (Add user authentication)
from: def5678
descendants: 3 commits

# Make the fix
$ vim src/auth.zig
$ git add src/auth.zig
$ git commit --amend --no-edit

# Return with rebased history
$ git edit --back
edit: complete
rebased: 3 commits
```

## Agent Subcommands

zagi provides two agent subcommands for autonomous task execution using the RALPH pattern (Recursive Agent Loop Pattern for Humans).

### zagi agent plan

Starts an interactive planning session where an AI agent collaborates with you to design and create tasks.

```bash
# Start an interactive session (agent will ask what you want to build)
zagi agent plan

# Start with initial context
zagi agent plan "Add user authentication with JWT"

# Preview the prompt without executing
zagi agent plan --dry-run
```

The planning agent follows an interactive protocol:
1. **Explore codebase**: Reads AGENTS.md and relevant code to understand architecture
2. **Ask clarifying questions**: Asks about scope, constraints, and preferences before drafting any plan
3. **Propose plan**: Presents a numbered implementation plan for your review
4. **Create tasks**: Only creates tasks after you explicitly approve the plan

This collaborative approach ensures the agent gathers all necessary context before committing to a task breakdown. The agent will ask 2-4 focused questions at a time about:
- **Scope**: What's included/excluded, edge cases, MVP vs nice-to-haves
- **Constraints**: Performance requirements, dependencies, compatibility
- **Preferences**: Approach/patterns, integration with existing code, testing expectations
- **Acceptance criteria**: How we know it's done, what success looks like

### zagi agent run

Executes the RALPH loop to automatically complete pending tasks.

```bash
# Run until all tasks complete (or fail 3x)
zagi agent run

# Run only one task then exit
zagi agent run --once

# Preview what would run without executing
zagi agent run --dry-run

# Set delay between tasks (default: 2 seconds)
zagi agent run --delay 5

# Safety limit - stop after N tasks
zagi agent run --max-tasks 10
```

The run loop will:
1. Pick the next pending task
2. Execute it with the configured agent
3. Mark it done on success (agent calls `zagi tasks done <task-id>`)
4. Skip tasks that fail 3 consecutive times
5. Continue until all tasks complete

### Executor Configuration

Control which AI agent executes tasks using environment variables:

```bash
# Use Claude Code (default)
ZAGI_AGENT=claude zagi agent run

# Use opencode
ZAGI_AGENT=opencode zagi agent run

# Use custom command with auto mode flags
ZAGI_AGENT=claude ZAGI_AGENT_CMD="myclaude --flag" zagi agent run

# Use completely custom tool (no auto flags)
ZAGI_AGENT_CMD="aider --yes" zagi agent run
```

See [docs/setup.md](docs/setup.md) for full configuration details.

### Blocked Commands (in agent mode)

These commands cause unrecoverable data loss and are blocked when `ZAGI_AGENT` is set:

| Command | Reason |
|---------|--------|
| `reset --hard` | Discards all uncommitted changes |
| `checkout .` | Discards all working tree changes |
| `clean -f/-fd/-fx` | Permanently deletes untracked files |
| `restore .` | Discards all working tree changes |
| `restore --worktree` | Discards working tree changes |
| `push --force/-f` | Overwrites remote history |
| `push --delete` | Deletes remote branch |
| `push <remote> :<branch>` | Deletes remote branch (refspec syntax) |
| `stash drop` | Permanently deletes stashed changes |
| `stash clear` | Permanently deletes all stashes |
| `branch -D` | Force deletes branch (even if not merged) |

Safe alternatives:
- `reset --soft` - keeps changes staged
- `reset` (no flags) - keeps changes in working tree
- `clean -n` - dry run, shows what would be deleted and ask user to delete
- `branch -d` - only deletes if merged

## Flow

### 1. Investigate the git command

Before implementing, understand the existing git command:

```bash
# Run the command and observe output
git <command>

# Test different scenarios
git <command> <args>

# Check exit codes
git <command>; echo "exit: $?"

# Test error cases
git <command> nonexistent
```

Document:
- What does it output on success?
- What does it output on failure?
- What are common flags/options?
- What exit codes does it use?

### 2. Design agent-friendly output

Identify what would be better for agents:

| Problem | Solution |
|---------|----------|
| Silent success (no confirmation) | Show what was done |
| Verbose errors | Concise error messages |
| Multi-line output with decoration | Compact, parseable format |
| Unclear state | Show current state after action |

Key questions:
- What information does an agent need to continue?
- What feedback confirms the action worked?
- Can we reduce output while preserving meaning?

### 3. Confirm the API

Before implementing, confirm with the user:
- Proposed output format
- Default flags/behavior differences from git
- Error message format

Example:
```
Proposed `zagi add` output:

Success:
  staged: 2 files
    A  new-file.txt
    M  changed-file.txt

Error:
  error: file.txt not found

Confirm? (y/n)
```

### 4. Implement in Zig

Create `src/cmds/<command>.zig`:

```zig
const std = @import("std");
const c = @cImport(@cInclude("git2.h"));
const git = @import("git.zig");

pub const Error = error{
    NotARepository,
    // command-specific errors
};

pub fn run(allocator: std.mem.Allocator, args: [][:0]u8) Error!void {
    // Implementation using libgit2
    // Return errors instead of calling std.process.exit()
}
```

**Important:** Never call `std.process.exit()` in command modules. Always return errors to main.zig for centralized handling. This enables unit testing and keeps exit codes consistent.

Add routing in `src/main.zig`:
```zig
const cmd_name = @import("cmds/<command>.zig");
// ...
} else if (std.mem.eql(u8, cmd, "<command>")) {
    cmd_name.run(allocator, args) catch |err| {
        try handleError(err);
    };
}
```

### 5. Consider abstractions (after 2+ implementations)

After implementing similar code twice, ask before abstracting:

> "I've now implemented marker functions in both status.zig and add.zig. Should I extract these to a shared git.zig module?"

Only abstract when:
- Same code appears in 2+ places
- The abstraction is obvious and stable
- User confirms it's worth the indirection

### 6. Add Zig tests

Add tests for pure functions in the module:

```zig
const testing = std.testing;

test "functionName - description" {
    try testing.expectEqualStrings("expected", functionName(input));
}
```

For functions that use `std.process.exit()`, test via integration tests instead.

Update `build.zig` to include new test files:
```zig
const cmd_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/cmds/<command>.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
cmd_tests.root_module.linkLibrary(libgit2_dep.artifact("git2"));
```

### 7. Build and run

```bash
zig build              # build
zig build test         # run zig unit tests
./zig-out/bin/zagi <command>
```

Fix any compiler errors. Test manually with various inputs.

### 8. Add integration tests

Create `test/src/<command>.test.ts`:

```typescript
import { describe, test, expect } from "vitest";
import { execFileSync } from "child_process";

describe("zagi <command>", () => {
  test("produces smaller output than git", () => {
    // Compare output size
  });

  test("functional correctness", () => {
    // Verify behavior matches git
  });
});

describe("performance", () => {
  test("zagi is reasonably fast", () => {
    // Benchmark timing
  });
});
```

Run with:
```bash
cd test && bun i && bun run test
```

To run all tests (Zig + TypeScript):
```bash
zig build test && cd test && bun run test
```

### 9. Optimize (if needed)

If benchmarks show issues:
1. Profile to find bottlenecks
2. Consider caching libgit2 state
3. Reduce allocations
4. Batch operations where possible

## File Structure

```
src/
  main.zig           # Entry point, command routing
  passthrough.zig    # Pass-through to git CLI
  cmds/
    git.zig          # Shared utilities (markers, errors)
    log.zig          # zagi log
    status.zig       # zagi status
    diff.zig         # zagi diff
    add.zig          # zagi add
    commit.zig       # zagi commit
    <command>.zig    # New commands

test/
  src/
    log.test.ts      # log integration tests
    status.test.ts   # status integration tests
    diff.test.ts     # diff integration tests
    add.test.ts      # add integration tests
    commit.test.ts   # commit integration tests
  fixtures/
    setup.ts         # Test fixture repo creation
```

## Design Decisions

### No `--full` or `--verbose` flags

Zagi commands only output concise, agent-optimized formats. We don't provide flags like `--full` or `--verbose` to get git's standard output.

**Reasoning:** If a user wants the full git output, they can use the passthrough flag:
```bash
zagi -g log    # runs: git log
zagi -g diff   # runs: git diff
```

This avoids duplicating git's output formatting in zagi. Every zagi command should do one thing well: provide a concise format optimized for agents.

## Checklist for new commands

- [ ] Investigate git command behavior
- [ ] Design agent-friendly output format
- [ ] Confirm API with user
- [ ] Implement in `src/cmds/<command>.zig`
- [ ] Add routing in `main.zig`
- [ ] Extract shared code (if 2+ usages, ask first)
- [ ] Add Zig unit tests
- [ ] Build and test manually
- [ ] Add TypeScript integration tests
- [ ] Run benchmarks
- [ ] Optimize if needed

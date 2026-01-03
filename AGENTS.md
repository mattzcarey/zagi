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

View prompts with:
```bash
git log --prompts
```

### Environment Setup

Set `ZAGI_AGENT` to enable prompt enforcement:

```bash
export ZAGI_AGENT=claude-code
```

When this is set:
1. `git commit` will fail without `--prompt`, ensuring all AI-generated commits have their prompts recorded
2. Destructive commands are blocked to prevent data loss

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

# RALPH: Recursive Agent Loop Pattern for Humans

RALPH is zagi's autonomous task execution system. It spawns AI agents to complete tasks sequentially, with each agent focused on a single task.

## Architecture

```
┌────────────────────────────────────────────────────────���────────┐
│                     RALPH Orchestrator                          │
│                    (git agent run)                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐    │
│   │ Task 1  │───▶│ Task 2  │───▶│ Task 3  │───▶│ Task N  │    │
│   └────┬────┘    └────┬────┘    └────┬────┘    └────┬────┘    │
│        │              │              │              │          │
│        ▼              ▼              ▼              ▼          │
│   ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐    │
│   │ Agent   │    │ Agent   │    │ Agent   │    │ Agent   │    │
│   │ Process │    │ Process │    │ Process │    │ Process │    │
│   └─────────┘    └─────────┘    └─────────┘    └─────────┘    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

Each task spawns a **fresh agent process**. This isolation ensures:
- Clean context for each task (no state leakage)
- Independent success/failure tracking
- Parallel-safe execution (agents don't interfere)

## The Loop

```
┌─────────────────────────────────────────────────────────┐
│  1. Load pending tasks from git refs                    │
│  2. Find next task with < 3 consecutive failures        │
│  3. If no eligible task → exit loop                     │
│  4. Spawn agent process for the task                    │
│  5. Wait for agent to complete                          │
│  6. Check for COMPLETION PROMISE in output              │
│  7. On success: reset failure counter, mark complete    │
│     On failure: increment failure counter               │
│  8. If --once flag → exit loop                          │
│  9. Wait delay seconds, goto step 1                     │
└─────────────────────────────────────────────────────────┘
```

## Agent Spawning

For each task, RALPH spawns an executor process:

| Executor | Command (headless mode) |
|----------|------------------------|
| `claude` | `claude --dangerously-skip-permissions -p "<prompt>"` |
| `opencode` | `opencode run "<prompt>"` |
| Custom | `<ZAGI_AGENT_CMD> "<prompt>"` |

The spawned agent receives:
1. Task ID and description
2. Operator guidance (if provided via `git agent run "prompt"`)
3. Instructions to complete ONE task only
4. Path to `zagi tasks done <id>` command
5. Required COMPLETION PROMISE format

## Task Prompt Format

Each spawned agent receives this prompt:

```
Task ID: task-001
Task: Implement feature X

Operator guidance:
Focus on error handling, add tests

Instructions:
1. Read AGENTS.md if it exists for project context
2. Complete this ONE task only
3. Verify your work (run tests if applicable)
4. Commit changes: git commit -m "<message>"
5. Mark done: /path/to/zagi tasks done task-001
6. Output the COMPLETION PROMISE below

COMPLETION PROMISE (required - output this exactly when done):

COMPLETION PROMISE: I confirm that:
- Tests pass: [which tests ran, or "N/A" if no tests]
- Build succeeds: [build command, or "N/A" if no build]
- Changes committed: [commit hash and message]
- Task completed: [brief summary of what was done]
-- I have not taken any shortcuts or skipped verification.

Rules:
- NEVER git push
- Only work on this task
- Must output the completion promise when done
```

## Success Detection

RALPH determines task success by checking for the COMPLETION PROMISE in the agent's output:

```
COMPLETION PROMISE: I confirm that:
...
-- I have not taken any shortcuts or skipped verification.
```

Both the start and end markers must be present. This ensures the agent explicitly confirms completion rather than just exiting.

## Failure Handling

RALPH tracks **consecutive failures** per task:

| Failures | Behavior |
|----------|----------|
| 0-2 | Retry task on next iteration |
| 3+ | Skip task, move to next |

Consecutive tracking means:
- A success resets the counter to 0
- Transient failures don't permanently block tasks
- 3 consecutive failures indicates a systemic problem

## Usage

### Basic execution
```bash
git agent run
```

### With operator guidance
```bash
git agent run "focus on error handling, prioritize tests"
```

### Single task execution
```bash
git agent run --once
```

### Dry run (preview)
```bash
git agent run --dry-run
```

### With limits
```bash
git agent run --max-tasks 5 --delay 5
```

## Observability

### Log files
Output is streamed to `/tmp/zagi/<repo-name>/<random-id>.log`:

```bash
# Follow live output
tail -f /tmp/zagi/myproject/*.log

# View specific run
cat /tmp/zagi/myproject/abc123.log
```

### Task status
```bash
git tasks list          # View all tasks
git tasks show task-001 # View specific task
```

## Executor Configuration

### Environment Variables

| Variable | Description |
|----------|-------------|
| `ZAGI_AGENT` | Executor type: `claude` (default), `opencode` |
| `ZAGI_AGENT_CMD` | Custom command override |

### Examples

```bash
# Use Claude (default)
git agent run

# Use OpenCode
ZAGI_AGENT=opencode git agent run

# Use custom Claude binary
ZAGI_AGENT=claude ZAGI_AGENT_CMD="~/my-claude --flag" git agent run
# → Executes: ~/my-claude --flag --dangerously-skip-permissions -p "<prompt>"

# Use Aider (no auto flags)
ZAGI_AGENT_CMD="aider --yes" git agent run
# → Executes: aider --yes "<prompt>"
```

## Planning Integration

RALPH works with `git agent plan` for a complete workflow:

```bash
# 1. Interactive planning session
git agent plan "Add user authentication"
# → Agent explores codebase, asks questions, creates tasks

# 2. Review tasks
git tasks list

# 3. Execute tasks
git agent run

# 4. Generate PR description
git tasks pr
```

## Safety Features

- **No git push**: Agents commit but never push
- **Consecutive failure limit**: Tasks skipped after 3 failures
- **Max tasks limit**: Optional cap on tasks per run
- **Isolated processes**: Each task runs in fresh agent
- **Explicit completion**: Requires COMPLETION PROMISE

## Permissions

### Claude
Uses `--dangerously-skip-permissions` for autonomous execution. This bypasses the interactive permission prompts that would block headless operation.

### OpenCode
The `run` subcommand auto-approves all permissions for non-interactive execution. No additional flags needed.

See [OpenCode Permissions](https://opencode.ai/docs/permissions/) for details.

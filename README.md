# zagi

> [!NOTE]
> zagi is not being actively worked on. What we learned building it went into [Cloudflare Artifacts](https://blog.cloudflare.com/artifacts-git-for-agents-beta/), Git-compatible versioned storage built for agents.

> a better git interface for agents

## Why use zagi?

- 121 git compatible commands
- ~50% smaller output that doesn't overflow context windows
- 1.5-2x faster than git in all implemented commands
- Agent friendly features like `fork` and `prompt`
- Three output modes: succinct (default), `--compat` (git-identical), `--json`
- Git passthrough for non implemented commands

## Installation

```bash
curl -fsSL zagi.sh/install | sh
```

This downloads the binary and sets up `git` as an alias to `zagi`. Restart your shell after installation.

### From source

```bash
git clone https://github.com/mattzcarey/zagi.git
cd zagi
zig build -Doptimize=ReleaseFast
./zig-out/bin/zagi alias  # set up the alias
```

## Usage

Use git as normal:

```bash
git status         # compact status
git log            # concise commit history
git diff           # minimal diff format
git add .          # confirms what was staged
git commit -m "x"  # shows commit stats
```

Any commands or flags not yet implemented in zagi pass through to git. zagi also comes with its own set of features for managing code written by agents.

### Output modes

zagi has three output modes:

**Succinct** (default) — token-efficient output for agents:

```bash
git status
# branch: main
# staged: 2 files
#   A  src/new.ts
#   M  src/main.ts
```

**Compat** — identical to git CLI output:

```bash
git --compat status
git --compat log --oneline -5
git --compat diff --stat
```

**JSON** — structured output for machine parsing:

```bash
git --json status
# {"branch":"main","clean":false,"staged":[{"marker":"A","path":"src/new.ts"}],"modified":[],"untracked":[]}

git --json log -n 3
# [{"hash":"abc123f","date":"2025-01-15","author":"Alice","email":"alice@example.com","subject":"Add feature"}]

git --json diff
# {"files":[{"path":"src/main.ts","insertions":5,"deletions":2}]}
```

### Easy worktrees

zagi ships with a wrapper around worktrees called `fork`:

```bash
# Create named forks for different approaches your agent could take
git fork nodejs-based
git fork bun-based

# Work in each fork
cd .forks/nodejs-based
# ... make changes, commit ...

cd .forks/bun-based
# ... make changes, commit ...

# Compare results, then pick the winner
cd ../..
git fork                       # list forks with commit counts
git fork --pick bun-based      # merge fork into base (keeps both histories)
git fork --promote bun-based   # replace base with fork (discards base commits)

# Clean up
git fork --delete-all
```

### Agent mode

Agent mode is automatically enabled when running inside AI tools (Claude Code, OpenCode, Cursor, Windsurf, VS Code). You can also enable it manually:

```bash
export ZAGI_AGENT=my-agent
```

This enables:
- **Prompt tracking**: `git commit --prompt` records the user request that created the commit
- **AI attribution**: Automatically detects and stores which AI agent made the commit

```bash
git commit -m "Add feature" --prompt "Add a logout button to the header"
git log --prompts   # view prompts
git log --agent     # view which AI agent made commits
git log --session   # view full session transcript (with pagination)
```

Metadata is stored in git notes (`refs/notes/agent`, `refs/notes/prompt`, `refs/notes/session`) which are local by default and don't affect commit history.

### Guardrails

Opt-in protection against destructive commands (`reset --hard`, `push --force`, `clean -f`, etc.):

```bash
export ZAGI_GUARDRAILS=1
git reset --hard HEAD~1  # blocked!
```

To bypass guardrails, set an override secret:

```bash
git set-override pineapples
ZAGI_OVERRIDE=pineapples git reset --hard HEAD~1  # allowed
```

### Environment variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ZAGI_GUARDRAILS` | Block destructive git commands. Bypass with `ZAGI_OVERRIDE`. | (unset) |
| `ZAGI_OVERRIDE` | Bypass guardrails with the secret set via `git set-override`. | (unset) |
| `ZAGI_REQUIRE_PROMPT_COMMIT` | Require `--prompt` on commits in agent mode. | (unset) |
| `ZAGI_STRIP_COAUTHORS` | Strip `Co-Authored-By:` lines from commit messages. | (unset) |

Agent mode is automatically detected when running inside Claude Code (`CLAUDECODE=1`) or OpenCode (`OPENCODE=1`).

### Strip co-authors

Remove `Co-Authored-By:` lines that AI tools like Claude Code add to commit messages:

```bash
export ZAGI_STRIP_COAUTHORS=1
git commit -m "Add feature

Co-Authored-By: Claude <claude@anthropic.com>"  # stripped automatically
```

## Output comparison

Standard git log:

```
commit abc123f4567890def1234567890abcdef12345
Author: Alice Smith <alice@example.com>
Date:   Mon Jan 15 14:32:21 2025 -0800

    Add user authentication system
```

zagi log:

```
abc123f (2025-01-15) Alice: Add user authentication system
```

## Development

Requirements: Zig 0.15, Bun

```bash
zig build                           # build
zig build test                      # run zig tests
cd test && bun i && bun run test    # run integration tests
bash test/conformance.sh ./zig-out/bin/zagi  # run conformance tests
```

See [AGENTS.md](AGENTS.md) for contribution guidelines.

## License

MIT

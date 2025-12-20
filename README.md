# zagi

> a better git interface for agents

## Why use zagi?

- 121 git compatible commands
- ~50% more concise output that doesn't overflow context windows
- 1.5x and 2x faster than git
- Non implemented commands pass through to system git

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/mattzcarey/zagi/main/install.sh | sh
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
git fork                    # list forks with commit counts
git fork --pick bun-based   # apply to base

# Clean up
git fork --delete-all
```

### Prompt tracking

Store the user prompt that created a commit:

```bash
export ZAGI_AGENT=claude-code # enforces a prompt is needed for commits
git commit -m "Add feature" --prompt "Add a logout button to the header.."
git log --prompts  # view prompts
```

Commands zagi doesn't implement pass through to git:

```bash
git push           # runs standard git push
git pull           # runs standard git pull
```

Use `-g` to force standard git output:

```bash
git -g log         # full git log output
git -g diff        # full git diff output
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
```

See [AGENTS.md](AGENTS.md) for contribution guidelines.

## License

MIT

# zagi

> a better git interface for agents

- Familiar git interface for agents
- Concise output that doesn't overflow context windows
- Unrecognized commands pass through to system git
- zagi is between 1.5x and 2x faster than git

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

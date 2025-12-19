import { describe, test, expect, beforeEach, afterEach } from "vitest";
import { execFileSync } from "child_process";
import { resolve } from "path";
import { rmSync, writeFileSync, readFileSync } from "fs";
import { createFixtureRepo } from "../fixtures/setup";

const ZAGI_BIN = resolve(__dirname, "../../zig-out/bin/zagi");
let REPO_DIR: string;

function runCommand(cmd: string, args: string[]): string {
  return execFileSync(cmd, args, {
    cwd: REPO_DIR,
    encoding: "utf-8",
  });
}

beforeEach(() => {
  REPO_DIR = createFixtureRepo();
});

afterEach(() => {
  if (REPO_DIR) {
    rmSync(REPO_DIR, { recursive: true, force: true });
  }
});

describe("zagi diff", () => {
  test("produces smaller output than git diff", () => {
    const zagi = runCommand(ZAGI_BIN, ["diff"]);
    const git = runCommand("git", ["diff"]);

    expect(zagi.length).toBeLessThan(git.length);
  });

  test("shows file path with line number", () => {
    const result = runCommand(ZAGI_BIN, ["diff"]);
    // Format: path/to/file.ts:123
    expect(result).toMatch(/^[\w/.-]+:\d+/m);
  });

  test("shows additions with + prefix", () => {
    const result = runCommand(ZAGI_BIN, ["diff"]);
    expect(result).toMatch(/^\+ /m);
  });

  test("shows deletions with - prefix", () => {
    // Remove a line to create a deletion
    const filePath = resolve(REPO_DIR, "src/main.ts");
    const content = readFileSync(filePath, "utf-8");
    const lines = content.split("\n");
    lines.splice(5, 1); // Remove line 6
    writeFileSync(filePath, lines.join("\n"));

    const result = runCommand(ZAGI_BIN, ["diff"]);
    expect(result).toMatch(/^- /m);
  });

  test("--staged shows staged changes", () => {
    // Stage the existing modified file
    execFileSync("git", ["add", "src/main.ts"], { cwd: REPO_DIR });

    const result = runCommand(ZAGI_BIN, ["diff", "--staged"]);
    expect(result).toContain("src/main.ts");
  });

  test("no changes shows 'no changes'", () => {
    // Reset all changes
    execFileSync("git", ["checkout", "--", "."], { cwd: REPO_DIR });
    execFileSync("git", ["clean", "-fd"], { cwd: REPO_DIR });

    const result = runCommand(ZAGI_BIN, ["diff"]);
    expect(result).toBe("no changes\n");
  });

  test("path filter shows only specified file", () => {
    // Create another modified file
    writeFileSync(resolve(REPO_DIR, "README.md"), "# Modified\n");

    const result = runCommand(ZAGI_BIN, ["diff", "--", "src/main.ts"]);
    expect(result).toContain("src/main.ts");
    expect(result).not.toContain("README.md");
  });

  test("path filter with directory", () => {
    // Modify a file outside src/
    writeFileSync(resolve(REPO_DIR, "README.md"), "# Modified\n");

    const result = runCommand(ZAGI_BIN, ["diff", "--", "src/"]);
    expect(result).toContain("src/main.ts");
    expect(result).not.toContain("README.md");
  });

  test("revision range shows changes between commits", () => {
    // Commit the current changes first
    execFileSync("git", ["add", "."], { cwd: REPO_DIR });
    execFileSync("git", ["commit", "-m", "test commit"], { cwd: REPO_DIR });

    // Now diff between previous and current
    const result = runCommand(ZAGI_BIN, ["diff", "HEAD~1..HEAD"]);
    expect(result).toContain("src/main.ts");
  });

  test("single revision shows changes since that commit", () => {
    // Commit the current changes first
    execFileSync("git", ["add", "."], { cwd: REPO_DIR });
    execFileSync("git", ["commit", "-m", "test commit"], { cwd: REPO_DIR });

    // Diff from previous commit to HEAD
    const result = runCommand(ZAGI_BIN, ["diff", "HEAD~1"]);
    expect(result).toContain("src/main.ts");
  });

  test("revision with path filter", () => {
    // Modify README too
    writeFileSync(resolve(REPO_DIR, "README.md"), "# Modified\n");

    // Commit all changes
    execFileSync("git", ["add", "."], { cwd: REPO_DIR });
    execFileSync("git", ["commit", "-m", "test commit"], { cwd: REPO_DIR });

    // Diff with path filter - should only show src/main.ts
    const result = runCommand(ZAGI_BIN, [
      "diff",
      "HEAD~1..HEAD",
      "--",
      "src/main.ts",
    ]);
    expect(result).toContain("src/main.ts");
    expect(result).not.toContain("README.md");
  });

  test("triple dot shows changes since branches diverged", () => {
    // Create a branch from current state
    execFileSync("git", ["checkout", "-b", "feature"], { cwd: REPO_DIR });

    // Make a commit on feature branch
    execFileSync("git", ["add", "."], { cwd: REPO_DIR });
    execFileSync("git", ["commit", "-m", "feature commit"], { cwd: REPO_DIR });

    // Go back to main and make different changes
    execFileSync("git", ["checkout", "main"], { cwd: REPO_DIR });
    writeFileSync(resolve(REPO_DIR, "README.md"), "# Main branch change\n");
    execFileSync("git", ["add", "."], { cwd: REPO_DIR });
    execFileSync("git", ["commit", "-m", "main commit"], { cwd: REPO_DIR });

    // Triple dot should show feature branch changes (not main changes)
    const result = runCommand(ZAGI_BIN, ["diff", "main...feature"]);
    expect(result).toContain("src/main.ts"); // Feature branch change
    expect(result).not.toContain("Main branch change"); // Not main branch change
  });
});

describe("zagi diff output format", () => {
  test("header format is file:line for single line change", () => {
    // Create a file with a single line change
    const filePath = resolve(REPO_DIR, "single.txt");
    writeFileSync(filePath, "line1\nline2\nline3\n");
    execFileSync("git", ["add", "single.txt"], { cwd: REPO_DIR });
    execFileSync("git", ["commit", "-m", "add single.txt"], { cwd: REPO_DIR });

    // Change only line 2
    writeFileSync(filePath, "line1\nmodified\nline3\n");

    const result = runCommand(ZAGI_BIN, ["diff"]);
    // Should have format: single.txt:2
    expect(result).toMatch(/single\.txt:\d+\n/);
  });

  test("header format is file:start-end for multi-line change", () => {
    // Create a file
    const filePath = resolve(REPO_DIR, "multi.txt");
    writeFileSync(filePath, "line1\nline2\nline3\nline4\nline5\n");
    execFileSync("git", ["add", "multi.txt"], { cwd: REPO_DIR });
    execFileSync("git", ["commit", "-m", "add multi.txt"], { cwd: REPO_DIR });

    // Change multiple consecutive lines
    writeFileSync(filePath, "line1\nchanged2\nchanged3\nchanged4\nline5\n");

    const result = runCommand(ZAGI_BIN, ["diff"]);
    // Should have format: multi.txt:2-4
    expect(result).toMatch(/multi\.txt:\d+-\d+\n/);
  });

  test("additions are prefixed with + and space", () => {
    const result = runCommand(ZAGI_BIN, ["diff"]);
    const lines = result.split("\n");
    const additionLines = lines.filter((l) => l.startsWith("+"));

    expect(additionLines.length).toBeGreaterThan(0);
    // Each addition should be "+ content" (plus, space, content)
    for (const line of additionLines) {
      expect(line).toMatch(/^\+ .*/);
    }
  });

  test("deletions are prefixed with - and space", () => {
    // Remove a line to create a deletion
    const filePath = resolve(REPO_DIR, "src/main.ts");
    const content = readFileSync(filePath, "utf-8");
    const lines = content.split("\n");
    lines.splice(5, 1); // Remove line 6
    writeFileSync(filePath, lines.join("\n"));

    const result = runCommand(ZAGI_BIN, ["diff"]);
    const deletionLines = result.split("\n").filter((l) => l.startsWith("-"));

    expect(deletionLines.length).toBeGreaterThan(0);
    // Each deletion should be "- content" (minus, space, content)
    for (const line of deletionLines) {
      expect(line).toMatch(/^- .*/);
    }
  });

  test("multiple hunks show separate file:line headers", () => {
    // Create a file with content
    const filePath = resolve(REPO_DIR, "hunks.txt");
    const lines = Array.from({ length: 20 }, (_, i) => `line${i + 1}`);
    writeFileSync(filePath, lines.join("\n") + "\n");
    execFileSync("git", ["add", "hunks.txt"], { cwd: REPO_DIR });
    execFileSync("git", ["commit", "-m", "add hunks.txt"], { cwd: REPO_DIR });

    // Change lines at beginning and end (creating separate hunks)
    lines[1] = "modified2";
    lines[18] = "modified19";
    writeFileSync(filePath, lines.join("\n") + "\n");

    const result = runCommand(ZAGI_BIN, ["diff", "--", "hunks.txt"]);
    // Should have multiple file:line headers (one per hunk)
    const headers = result.match(/hunks\.txt:\d+/g);
    expect(headers).not.toBeNull();
    expect(headers!.length).toBeGreaterThanOrEqual(2);
  });

  test("output has no git diff headers (---, +++, @@)", () => {
    const result = runCommand(ZAGI_BIN, ["diff"]);
    expect(result).not.toContain("---");
    expect(result).not.toContain("+++");
    expect(result).not.toContain("@@");
    expect(result).not.toContain("diff --git");
  });
});

describe("zagi diff --stat", () => {
  test("shows file names with change counts", () => {
    const result = runCommand(ZAGI_BIN, ["diff", "--stat"]);
    // Format: " filename | N ++--"
    expect(result).toMatch(/^\s+\S+\s+\|\s+\d+/m);
  });

  test("shows +/- visualization bar", () => {
    const result = runCommand(ZAGI_BIN, ["diff", "--stat"]);
    // Should contain + or - in the output
    expect(result).toMatch(/[+-]/);
  });

  test("shows summary line with file count", () => {
    const result = runCommand(ZAGI_BIN, ["diff", "--stat"]);
    // Format: " N files changed, X insertions(+), Y deletions(-)"
    expect(result).toMatch(/\d+ files changed/);
  });

  test("shows insertions count when present", () => {
    const result = runCommand(ZAGI_BIN, ["diff", "--stat"]);
    expect(result).toMatch(/\d+ insertions?\(\+\)/);
  });

  test("--stat with no changes shows 'no changes'", () => {
    // Reset all changes
    execFileSync("git", ["checkout", "--", "."], { cwd: REPO_DIR });
    execFileSync("git", ["clean", "-fd"], { cwd: REPO_DIR });

    const result = runCommand(ZAGI_BIN, ["diff", "--stat"]);
    expect(result).toBe("no changes\n");
  });

  test("--stat with --staged works", () => {
    execFileSync("git", ["add", "src/main.ts"], { cwd: REPO_DIR });

    const result = runCommand(ZAGI_BIN, ["diff", "--staged", "--stat"]);
    expect(result).toContain("src/main.ts");
    expect(result).toMatch(/files changed/);
  });

  test("--stat shows summary info not full diff content", () => {
    const stat = runCommand(ZAGI_BIN, ["diff", "--stat"]);
    // Stat mode should not contain actual diff lines
    expect(stat).not.toMatch(/^\+ /m);
    expect(stat).not.toMatch(/^- /m);
    // But should contain the summary
    expect(stat).toMatch(/files changed/);
  });
});

describe("zagi diff --name-only", () => {
  test("shows only file names", () => {
    const result = runCommand(ZAGI_BIN, ["diff", "--name-only"]);
    // Should just be filenames, one per line
    expect(result).toContain("src/main.ts");
    // Should not have any diff content
    expect(result).not.toMatch(/^\+/m);
    expect(result).not.toMatch(/^-/m);
  });

  test("--name-only lists each file once", () => {
    const result = runCommand(ZAGI_BIN, ["diff", "--name-only"]);
    const lines = result.trim().split("\n").filter(Boolean);
    const unique = new Set(lines);
    expect(lines.length).toBe(unique.size);
  });

  test("--name-only with no changes shows 'no changes'", () => {
    // Reset all changes
    execFileSync("git", ["checkout", "--", "."], { cwd: REPO_DIR });
    execFileSync("git", ["clean", "-fd"], { cwd: REPO_DIR });

    const result = runCommand(ZAGI_BIN, ["diff", "--name-only"]);
    expect(result).toBe("no changes\n");
  });

  test("--name-only with --staged works", () => {
    execFileSync("git", ["add", "src/main.ts"], { cwd: REPO_DIR });

    const result = runCommand(ZAGI_BIN, ["diff", "--staged", "--name-only"]);
    expect(result.trim()).toBe("src/main.ts");
  });

  test("--name-only produces smallest output", () => {
    const nameOnly = runCommand(ZAGI_BIN, ["diff", "--name-only"]);
    const stat = runCommand(ZAGI_BIN, ["diff", "--stat"]);
    const patch = runCommand(ZAGI_BIN, ["diff"]);

    expect(nameOnly.length).toBeLessThanOrEqual(stat.length);
    expect(nameOnly.length).toBeLessThan(patch.length);
  });

  test("--name-only with revision range", () => {
    execFileSync("git", ["add", "."], { cwd: REPO_DIR });
    execFileSync("git", ["commit", "-m", "test commit"], { cwd: REPO_DIR });

    const result = runCommand(ZAGI_BIN, ["diff", "--name-only", "HEAD~1..HEAD"]);
    expect(result).toContain("src/main.ts");
  });
});

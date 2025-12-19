import { describe, test, expect, beforeEach, afterEach } from "vitest";
import { execFileSync } from "child_process";
import { resolve } from "path";
import { rmSync } from "fs";
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

describe("zagi log", () => {
  test("produces smaller output than git log", () => {
    const zagi = runCommand(ZAGI_BIN, ["log"]);
    const git = runCommand("git", ["log", "-n", "10"]);

    expect(zagi.length).toBeLessThan(git.length);
  });

  test("defaults to 10 commits", () => {
    const result = runCommand(ZAGI_BIN, ["log"]);
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBeLessThanOrEqual(10);
  });

  test("respects -n flag", () => {
    const result = runCommand(ZAGI_BIN, ["log", "-n", "3"]);
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBeLessThanOrEqual(3);
  });

  test("passthrough -g gives full git output", () => {
    const concise = runCommand(ZAGI_BIN, ["log", "-n", "1"]);
    const full = runCommand(ZAGI_BIN, ["-g", "log", "-n", "1"]);

    expect(full.length).toBeGreaterThan(concise.length);
    expect(full).toContain("Author:");
    expect(full).toContain("Date:");
  });

  test("output format matches spec", () => {
    const result = runCommand(ZAGI_BIN, ["log", "-n", "1"]);
    // Format: abc123f (2025-01-15) Alice: Subject line
    const line = result.split("\n")[0];
    expect(line).toMatch(/^[a-f0-9]{7} \(\d{4}-\d{2}-\d{2}\) \w+: .+$/);
  });

  test("--author filters by author name", () => {
    const result = runCommand(ZAGI_BIN, ["log", "--author=Test", "-n", "5"]);
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    // All commits should be from Test User
    expect(commitLines.length).toBeGreaterThan(0);
    commitLines.forEach((line) => {
      expect(line).toContain("Test:");
    });
  });

  test("--author with no matches returns empty", () => {
    const result = runCommand(ZAGI_BIN, ["log", "--author=NonexistentAuthor", "-n", "5"]);
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBe(0);
  });

  test("--grep filters by commit message", () => {
    const result = runCommand(ZAGI_BIN, ["log", "--grep=Fix", "-n", "20"]);
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBeGreaterThan(0);
    commitLines.forEach((line) => {
      expect(line.toLowerCase()).toContain("fix");
    });
  });

  test("--grep is case insensitive", () => {
    const lower = runCommand(ZAGI_BIN, ["log", "--grep=fix", "-n", "20"]);
    const upper = runCommand(ZAGI_BIN, ["log", "--grep=FIX", "-n", "20"]);
    const lowerLines = lower.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    const upperLines = upper.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(lowerLines.length).toBe(upperLines.length);
  });

  test("--since filters by date", () => {
    // All commits in fixture are recent, so --since yesterday should include them
    const result = runCommand(ZAGI_BIN, ["log", "--since=2020-01-01", "-n", "5"]);
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBeGreaterThan(0);
  });

  test("--until filters by date", () => {
    // All commits are recent, so --until 2020 should be empty
    const result = runCommand(ZAGI_BIN, ["log", "--until=2020-01-01", "-n", "5"]);
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBe(0);
  });

  test("-- path filters by file path", () => {
    const result = runCommand(ZAGI_BIN, ["log", "--", "src/main.ts", "-n", "20"]);
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    // Should have commits that touched main.ts
    expect(commitLines.length).toBeGreaterThan(0);
  });

  test("path filter excludes commits not touching path", () => {
    // Create a file, commit, then check log for another path
    const noMatch = runCommand(ZAGI_BIN, ["log", "--", "nonexistent.txt", "-n", "10"]);
    const commitLines = noMatch.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBe(0);
  });

  test("multiple filters combine (AND logic)", () => {
    // --grep=Fix AND --author=Test should work
    const result = runCommand(ZAGI_BIN, ["log", "--grep=Fix", "--author=Test", "-n", "20"]);
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBeGreaterThan(0);
    commitLines.forEach((line) => {
      expect(line.toLowerCase()).toContain("fix");
      expect(line).toContain("Test:");
    });
  });

  test("--oneline is accepted (already default format)", () => {
    const result = runCommand(ZAGI_BIN, ["log", "--oneline", "-n", "3"]);
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBeLessThanOrEqual(3);
  });
});

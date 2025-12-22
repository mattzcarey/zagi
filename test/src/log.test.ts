import { describe, test, expect, beforeEach, afterEach } from "vitest";
import { rmSync } from "fs";
import { createFixtureRepo } from "../fixtures/setup";
import { zagi, git } from "./shared";

let REPO_DIR: string;

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
    const zagiOut = zagi(["log"], { cwd: REPO_DIR });
    const gitOut = git(["log", "-n", "10"], { cwd: REPO_DIR });

    expect(zagiOut.length).toBeLessThan(gitOut.length);
  });

  test("defaults to 10 commits", () => {
    const result = zagi(["log"], { cwd: REPO_DIR });
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBeLessThanOrEqual(10);
  });

  test("respects -n flag", () => {
    const result = zagi(["log", "-n", "3"], { cwd: REPO_DIR });
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBeLessThanOrEqual(3);
  });

  test("passthrough -g gives full git output", () => {
    const concise = zagi(["log", "-n", "1"], { cwd: REPO_DIR });
    const full = zagi(["-g", "log", "-n", "1"], { cwd: REPO_DIR });

    expect(full.length).toBeGreaterThan(concise.length);
    expect(full).toContain("Author:");
    expect(full).toContain("Date:");
  });

  test("output format matches spec", () => {
    const result = zagi(["log", "-n", "1"], { cwd: REPO_DIR });
    // Format: abc123f (2025-01-15) Alice: Subject line
    const line = result.split("\n")[0];
    expect(line).toMatch(/^[a-f0-9]{7} \(\d{4}-\d{2}-\d{2}\) \w+: .+$/);
  });

  test("--author filters by author name", () => {
    const result = zagi(["log", "--author=Test", "-n", "5"], { cwd: REPO_DIR });
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    // All commits should be from Test User
    expect(commitLines.length).toBeGreaterThan(0);
    commitLines.forEach((line) => {
      expect(line).toContain("Test:");
    });
  });

  test("--author with no matches returns empty", () => {
    const result = zagi(["log", "--author=NonexistentAuthor", "-n", "5"], { cwd: REPO_DIR });
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBe(0);
  });

  test("--grep filters by commit message", () => {
    const result = zagi(["log", "--grep=Fix", "-n", "20"], { cwd: REPO_DIR });
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBeGreaterThan(0);
    commitLines.forEach((line) => {
      expect(line.toLowerCase()).toContain("fix");
    });
  });

  test("--grep is case insensitive", () => {
    const lower = zagi(["log", "--grep=fix", "-n", "20"], { cwd: REPO_DIR });
    const upper = zagi(["log", "--grep=FIX", "-n", "20"], { cwd: REPO_DIR });
    const lowerLines = lower.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    const upperLines = upper.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(lowerLines.length).toBe(upperLines.length);
  });

  test("--since filters by date", () => {
    // All commits in fixture are recent, so --since yesterday should include them
    const result = zagi(["log", "--since=2020-01-01", "-n", "5"], { cwd: REPO_DIR });
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBeGreaterThan(0);
  });

  test("--until filters by date", () => {
    // All commits are recent, so --until 2020 should be empty
    const result = zagi(["log", "--until=2020-01-01", "-n", "5"], { cwd: REPO_DIR });
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBe(0);
  });

  test("-- path filters by file path", () => {
    const result = zagi(["log", "--", "src/main.ts", "-n", "20"], { cwd: REPO_DIR });
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    // Should have commits that touched main.ts
    expect(commitLines.length).toBeGreaterThan(0);
  });

  test("path filter excludes commits not touching path", () => {
    // Create a file, commit, then check log for another path
    const noMatch = zagi(["log", "--", "nonexistent.txt", "-n", "10"], { cwd: REPO_DIR });
    const commitLines = noMatch.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBe(0);
  });

  test("multiple filters combine (AND logic)", () => {
    // --grep=Fix AND --author=Test should work
    const result = zagi(["log", "--grep=Fix", "--author=Test", "-n", "20"], { cwd: REPO_DIR });
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBeGreaterThan(0);
    commitLines.forEach((line) => {
      expect(line.toLowerCase()).toContain("fix");
      expect(line).toContain("Test:");
    });
  });

  test("--oneline is accepted (already default format)", () => {
    const result = zagi(["log", "--oneline", "-n", "3"], { cwd: REPO_DIR });
    const commitLines = result.split("\n").filter((l) => /^[a-f0-9]{7} /.test(l));
    expect(commitLines.length).toBeLessThanOrEqual(3);
  });
});

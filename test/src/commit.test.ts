import { describe, test, expect, beforeEach, afterEach } from "vitest";
import { resolve } from "path";
import { writeFileSync, appendFileSync, rmSync } from "fs";
import { createFixtureRepo } from "../fixtures/setup";
import { zagi, git, createTestRepo, cleanupTestRepo } from "./shared";

let REPO_DIR: string;

function stageTestFile() {
  const testFile = resolve(REPO_DIR, "commit-test.txt");
  writeFileSync(testFile, `test content ${Date.now()}\n`);
  git(["add", "commit-test.txt"], { cwd: REPO_DIR });
}

beforeEach(() => {
  REPO_DIR = createFixtureRepo();
});

afterEach(() => {
  if (REPO_DIR) {
    rmSync(REPO_DIR, { recursive: true, force: true });
  }
});

describe("zagi commit", () => {
  test("commits staged changes with message", () => {
    stageTestFile();
    const result = zagi(["commit", "-m", "Test commit"], { cwd: REPO_DIR });

    expect(result).toContain("committed:");
    expect(result).toContain("Test commit");
    expect(result).toMatch(/[0-9a-f]{7}/);
  });

  test("shows file count and stats", () => {
    stageTestFile();
    const result = zagi(["commit", "-m", "Test with stats"], { cwd: REPO_DIR });

    expect(result).toMatch(/\d+ file/);
    expect(result).toMatch(/\+\d+/);
    expect(result).toMatch(/-\d+/);
  });

  test("error when nothing staged", () => {
    const result = zagi(["commit", "-m", "Empty commit"], { cwd: REPO_DIR });

    // Fixture repo has unstaged changes, so hint is shown
    expect(result).toContain("error: nothing to commit");
  });

  test("shows usage when no message provided", () => {
    stageTestFile();
    const result = zagi(["commit"], { cwd: REPO_DIR });

    expect(result).toContain("usage:");
    expect(result).toContain("-m");
  });

  test("supports -m flag with equals sign", () => {
    stageTestFile();
    const result = zagi(["commit", "--message=Equals format"], { cwd: REPO_DIR });

    expect(result).toContain("Equals format");
  });
});

describe("zagi commit --prompt", () => {
  test("stores prompt and shows confirmation", () => {
    stageTestFile();
    const result = zagi([
      "commit",
      "-m",
      "Add test file",
      "--prompt",
      "Create a test file for testing",
    ], { cwd: REPO_DIR });

    expect(result).toContain("committed:");
    expect(result).toContain("prompt saved");
  });

  test("--prompt= syntax works", () => {
    stageTestFile();
    const result = zagi([
      "commit",
      "-m",
      "Test equals syntax",
      "--prompt=This is the prompt",
    ], { cwd: REPO_DIR });

    expect(result).toContain("prompt saved");
  });

  test("prompt can be viewed with git notes", () => {
    stageTestFile();
    zagi([
      "commit",
      "-m",
      "Commit with prompt",
      "--prompt",
      "My test prompt text",
    ], { cwd: REPO_DIR });

    // Read the note using git notes command
    const noteResult = git(["notes", "--ref=prompts", "show", "HEAD"], { cwd: REPO_DIR });

    expect(noteResult).toContain("My test prompt text");
  });

  test("prompt shown with --prompts in log", () => {
    stageTestFile();
    zagi([
      "commit",
      "-m",
      "Commit for log test",
      "--prompt",
      "Prompt visible in log",
    ], { cwd: REPO_DIR });

    const logResult = zagi(["log", "-n", "1", "--prompts"], { cwd: REPO_DIR });

    expect(logResult).toContain("Commit for log test");
    expect(logResult).toContain("prompt: Prompt visible in log");
  });

  test("log without --prompts hides prompt", () => {
    stageTestFile();
    zagi([
      "commit",
      "-m",
      "Hidden prompt commit",
      "--prompt",
      "This should be hidden",
    ], { cwd: REPO_DIR });

    const logResult = zagi(["log", "-n", "1"], { cwd: REPO_DIR });

    expect(logResult).toContain("Hidden prompt commit");
    expect(logResult).not.toContain("prompt:");
    expect(logResult).not.toContain("This should be hidden");
  });
});

describe("ZAGI_AGENT", () => {
  test("ZAGI_AGENT requires --prompt", () => {
    stageTestFile();
    const result = zagi(
      ["commit", "-m", "Agent commit"],
      { cwd: REPO_DIR, env: { ZAGI_AGENT: "claude-code" } }
    );

    expect(result).toContain("--prompt required");
    expect(result).toContain("ZAGI_AGENT");
  });

  test("ZAGI_AGENT succeeds with --prompt", () => {
    stageTestFile();
    const result = zagi(
      ["commit", "-m", "Agent commit", "--prompt", "Agent prompt"],
      { cwd: REPO_DIR, env: { ZAGI_AGENT: "claude-code" } }
    );

    expect(result).toContain("committed:");
  });
});

describe("ZAGI_STRIP_COAUTHORS", () => {
  test("strips Co-Authored-By lines when enabled", () => {
    stageTestFile();
    const message = `Add feature

Co-Authored-By: Claude <claude@anthropic.com>`;

    const result = zagi(
      ["commit", "-m", message],
      { cwd: REPO_DIR, env: { ZAGI_STRIP_COAUTHORS: "1" } }
    );

    expect(result).toContain("committed:");

    // Check the actual commit message
    const logResult = git(["log", "-1", "--format=%B"], { cwd: REPO_DIR });

    expect(logResult.trim()).toBe("Add feature");
    expect(logResult).not.toContain("Co-Authored-By");
  });

  test("preserves Co-Authored-By when not enabled", () => {
    stageTestFile();
    const message = `Add feature

Co-Authored-By: Claude <claude@anthropic.com>`;

    const result = zagi(["commit", "-m", message], { cwd: REPO_DIR });

    expect(result).toContain("committed:");

    // Check the actual commit message
    const logResult = git(["log", "-1", "--format=%B"], { cwd: REPO_DIR });

    expect(logResult).toContain("Co-Authored-By: Claude");
  });

  test("strips multiple Co-Authored-By lines", () => {
    stageTestFile();
    const message = `Fix bug

Co-Authored-By: Alice <alice@example.com>
Co-Authored-By: Bob <bob@example.com>`;

    const result = zagi(
      ["commit", "-m", message],
      { cwd: REPO_DIR, env: { ZAGI_STRIP_COAUTHORS: "1" } }
    );

    expect(result).toContain("committed:");

    const logResult = git(["log", "-1", "--format=%B"], { cwd: REPO_DIR });

    expect(logResult.trim()).toBe("Fix bug");
    expect(logResult).not.toContain("Co-Authored-By");
  });

  test("preserves other message content", () => {
    stageTestFile();
    const message = `Implement feature

This adds a great new feature.

Co-Authored-By: Claude <claude@anthropic.com>

Signed-off-by: Matt`;

    const result = zagi(
      ["commit", "-m", message],
      { cwd: REPO_DIR, env: { ZAGI_STRIP_COAUTHORS: "1" } }
    );

    expect(result).toContain("committed:");

    const logResult = git(["log", "-1", "--format=%B"], { cwd: REPO_DIR });

    expect(logResult).toContain("Implement feature");
    expect(logResult).toContain("This adds a great new feature");
    expect(logResult).toContain("Signed-off-by: Matt");
    expect(logResult).not.toContain("Co-Authored-By");
  });
});

describe("commit with unstaged changes", () => {
  let testRepoDir: string;

  beforeEach(() => {
    testRepoDir = createTestRepo();
  });

  afterEach(() => {
    cleanupTestRepo(testRepoDir);
  });

  test("shows hint when nothing staged but files modified", () => {
    // Modify a tracked file without staging
    appendFileSync(resolve(testRepoDir, "README.md"), "\nModified line\n");

    const output = zagi(["commit", "-m", "test"], { cwd: testRepoDir });

    expect(output).toContain("hint: did you mean to add?");
    expect(output).toContain("unstaged:");
    expect(output).toContain("README.md");
    expect(output).toContain("error: nothing to commit");
  });

  test("shows hint with untracked files", () => {
    // Create untracked file
    writeFileSync(resolve(testRepoDir, "new-file.txt"), "new content\n");

    const output = zagi(["commit", "-m", "test"], { cwd: testRepoDir });

    expect(output).toContain("hint: did you mean to add?");
    expect(output).toContain("??");
    expect(output).toContain("new-file.txt");
  });

  test("no hint when working tree is clean", () => {
    const output = zagi(["commit", "-m", "test"], { cwd: testRepoDir });

    expect(output).not.toContain("hint:");
    expect(output).toContain("error: nothing to commit");
  });
});

import { describe, test, expect, beforeEach, afterEach } from "vitest";
import { execFileSync } from "child_process";
import { resolve } from "path";
import { writeFileSync, rmSync } from "fs";
import { createFixtureRepo } from "../fixtures/setup";

const ZAGI_BIN = resolve(__dirname, "../../zig-out/bin/zagi");
let REPO_DIR: string;

interface CommandResult {
  output: string;
  exitCode: number;
}

function runCommand(cmd: string, args: string[], expectFail = false): CommandResult {
  try {
    const output = execFileSync(cmd, args, {
      cwd: REPO_DIR,
      encoding: "utf-8",
    });
    return { output, exitCode: 0 };
  } catch (e: any) {
    if (!expectFail) throw e;
    return {
      output: e.stderr || e.stdout || "",
      exitCode: e.status || 1,
    };
  }
}

function stageTestFile() {
  const testFile = resolve(REPO_DIR, "commit-test.txt");
  writeFileSync(testFile, `test content ${Date.now()}\n`);
  execFileSync("git", ["add", "commit-test.txt"], { cwd: REPO_DIR });
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
    const result = runCommand(ZAGI_BIN, ["commit", "-m", "Test commit"]);

    expect(result.output).toContain("committed:");
    expect(result.output).toContain("Test commit");
    expect(result.output).toMatch(/[0-9a-f]{7}/);
    expect(result.exitCode).toBe(0);
  });

  test("shows file count and stats", () => {
    stageTestFile();
    const result = runCommand(ZAGI_BIN, ["commit", "-m", "Test with stats"]);

    expect(result.output).toMatch(/\d+ file/);
    expect(result.output).toMatch(/\+\d+/);
    expect(result.output).toMatch(/-\d+/);
  });

  test("error when nothing staged", () => {
    const result = runCommand(ZAGI_BIN, ["commit", "-m", "Empty commit"], true);

    expect(result.output).toBe("error: nothing to commit\n");
    expect(result.exitCode).toBe(1);
  });

  test("shows usage when no message provided", () => {
    stageTestFile();
    const result = runCommand(ZAGI_BIN, ["commit"], true);

    expect(result.output).toContain("usage:");
    expect(result.output).toContain("-m");
    expect(result.exitCode).toBe(1);
  });

  test("supports -m flag with equals sign", () => {
    stageTestFile();
    const result = runCommand(ZAGI_BIN, ["commit", "--message=Equals format"]);

    expect(result.output).toContain("Equals format");
    expect(result.exitCode).toBe(0);
  });
});

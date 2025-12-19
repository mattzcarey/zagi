import { describe, test, expect, beforeEach, afterEach } from "vitest";
import { execFileSync } from "child_process";
import { resolve } from "path";
import { rmSync } from "fs";
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

beforeEach(() => {
  REPO_DIR = createFixtureRepo();
});

afterEach(() => {
  if (REPO_DIR) {
    rmSync(REPO_DIR, { recursive: true, force: true });
  }
});

describe("zagi add", () => {
  test("shows confirmation after adding file", () => {
    const result = runCommand(ZAGI_BIN, ["add", "src/new-file.ts"]);

    expect(result.output).toContain("staged:");
    expect(result.output).toContain("A ");
    expect(result.output).toContain("new-file.ts");
  });

  test("shows count of staged files", () => {
    const result = runCommand(ZAGI_BIN, ["add", "src/new-file.ts"]);

    expect(result.output).toMatch(/staged: \d+ file/);
  });

  test("error message is concise for missing file", () => {
    const zagi = runCommand(ZAGI_BIN, ["add", "nonexistent.txt"], true);

    expect(zagi.output).toBe("error: file not found\n");
    expect(zagi.exitCode).toBe(128);
  });

  test("git add is silent on success", () => {
    const git = runCommand("git", ["add", "src/new-file.ts"]);

    expect(git.output).toBe("");
  });

  test("zagi add provides feedback", () => {
    const zagi = runCommand(ZAGI_BIN, ["add", "src/new-file.ts"]);

    expect(zagi.output.length).toBeGreaterThan(0);
  });
});

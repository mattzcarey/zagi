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

describe("zagi add", () => {
  test("shows confirmation after adding file", () => {
    const result = zagi(["add", "src/new-file.ts"], { cwd: REPO_DIR });

    expect(result).toContain("staged:");
    expect(result).toContain("A ");
    expect(result).toContain("new-file.ts");
  });

  test("shows count of staged files", () => {
    const result = zagi(["add", "src/new-file.ts"], { cwd: REPO_DIR });

    expect(result).toMatch(/staged: \d+ file/);
  });

  test("error message is concise for missing file", () => {
    const result = zagi(["add", "nonexistent.txt"], { cwd: REPO_DIR });

    expect(result).toBe("error: file not found\n");
  });

  test("git add is silent on success", () => {
    const result = git(["add", "src/new-file.ts"], { cwd: REPO_DIR });

    expect(result).toBe("");
  });

  test("zagi add provides feedback", () => {
    const result = zagi(["add", "src/new-file.ts"], { cwd: REPO_DIR });

    expect(result.length).toBeGreaterThan(0);
  });
});

import { describe, bench, beforeAll, afterAll } from "vitest";
import { execFileSync } from "child_process";
import { resolve } from "path";
import { rmSync } from "fs";
import { createFixtureRepo } from "../fixtures/setup";

const ZAGI_BIN = resolve(__dirname, "../../zig-out/bin/zagi");
let REPO_DIR: string;

beforeAll(() => {
  REPO_DIR = createFixtureRepo();
});

afterAll(() => {
  if (REPO_DIR) {
    rmSync(REPO_DIR, { recursive: true, force: true });
  }
});

function runCommand(cmd: string, args: string[]): string {
  return execFileSync(cmd, args, {
    cwd: REPO_DIR,
    encoding: "utf-8",
    maxBuffer: 10 * 1024 * 1024,
  });
}

describe("git diff benchmarks", () => {
  bench("zagi diff", () => {
    runCommand(ZAGI_BIN, ["diff"]);
  });

  bench("git diff", () => {
    runCommand("git", ["diff"]);
  });

  bench("git diff --stat", () => {
    runCommand("git", ["diff", "--stat"]);
  });
});

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

describe("git log benchmarks", () => {
  bench("zagi log (default)", () => {
    runCommand(ZAGI_BIN, ["log"]);
  });

  bench("git log -n 10", () => {
    runCommand("git", ["log", "-n", "10"]);
  });

  bench("git log --oneline -n 10", () => {
    runCommand("git", ["log", "--oneline", "-n", "10"]);
  });

  bench("zagi log -n 50", () => {
    runCommand(ZAGI_BIN, ["log", "-n", "50"]);
  });

  bench("git log -n 50", () => {
    runCommand("git", ["log", "-n", "50"]);
  });
});

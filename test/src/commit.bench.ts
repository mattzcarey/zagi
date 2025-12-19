import { bench, describe, beforeAll, afterAll } from "vitest";
import { execFileSync } from "child_process";
import { resolve } from "path";
import { writeFileSync, rmSync } from "fs";
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

describe("git commit benchmarks", () => {
  // Use unique IDs to avoid conflicts between parallel bench runs
  const uid = () => `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

  bench("zagi commit", () => {
    const id = uid();
    const testFile = resolve(REPO_DIR, `zagi-${id}.txt`);
    writeFileSync(testFile, `zagi bench ${id}\n`);
    execFileSync("git", ["add", testFile], { cwd: REPO_DIR });
    execFileSync(ZAGI_BIN, ["commit", "-m", `zagi ${id}`], { cwd: REPO_DIR });
  });

  bench("git commit", () => {
    const id = uid();
    const testFile = resolve(REPO_DIR, `git-${id}.txt`);
    writeFileSync(testFile, `git bench ${id}\n`);
    execFileSync("git", ["add", testFile], { cwd: REPO_DIR });
    execFileSync("git", ["commit", "-m", `git ${id}`], { cwd: REPO_DIR });
  });
});

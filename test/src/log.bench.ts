import { describe, bench, beforeAll, afterAll } from "vitest";
import { rmSync } from "fs";
import { createFixtureRepo } from "../fixtures/setup";
import { zagi, git } from "./shared";

let REPO_DIR: string;

beforeAll(() => {
  REPO_DIR = createFixtureRepo();
});

afterAll(() => {
  if (REPO_DIR) {
    rmSync(REPO_DIR, { recursive: true, force: true });
  }
});

describe("git log benchmarks", () => {
  bench("zagi log (default)", () => {
    zagi(["log"], { cwd: REPO_DIR });
  });

  bench("git log -n 10", () => {
    git(["log", "-n", "10"], { cwd: REPO_DIR });
  });

  bench("git log --oneline -n 10", () => {
    git(["log", "--oneline", "-n", "10"], { cwd: REPO_DIR });
  });
});

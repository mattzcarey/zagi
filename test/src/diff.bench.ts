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

describe("git diff benchmarks", () => {
  bench("zagi diff", () => {
    zagi(["diff"], { cwd: REPO_DIR });
  });

  bench("git diff", () => {
    git(["diff"], { cwd: REPO_DIR });
  });

  bench("git diff --stat", () => {
    git(["diff", "--stat"], { cwd: REPO_DIR });
  });
});

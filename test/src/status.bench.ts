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

describe("git status benchmarks", () => {
  bench("zagi status", () => {
    zagi(["status"], { cwd: REPO_DIR });
  });

  bench("git status", () => {
    git(["status"], { cwd: REPO_DIR });
  });

  bench("git status --porcelain", () => {
    git(["status", "--porcelain"], { cwd: REPO_DIR });
  });

  bench("git status -s", () => {
    git(["status", "-s"], { cwd: REPO_DIR });
  });
});

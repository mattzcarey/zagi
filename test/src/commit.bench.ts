import { bench, describe, beforeAll, afterAll } from "vitest";
import { resolve } from "path";
import { writeFileSync, rmSync } from "fs";
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

describe("git add + commit benchmarks", () => {
  const uid = () => `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

  bench("zagi add + commit", () => {
    const id = uid();
    const testFile = resolve(REPO_DIR, `zagi-${id}.txt`);
    writeFileSync(testFile, `zagi bench ${id}\n`);
    zagi(["add", testFile], { cwd: REPO_DIR });
    zagi(["commit", "-m", `zagi ${id}`], { cwd: REPO_DIR });
  });

  bench("git add + commit", () => {
    const id = uid();
    const testFile = resolve(REPO_DIR, `git-${id}.txt`);
    writeFileSync(testFile, `git bench ${id}\n`);
    git(["add", testFile], { cwd: REPO_DIR });
    git(["commit", "-m", `git ${id}`], { cwd: REPO_DIR });
  });
});

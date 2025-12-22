import { describe, bench, beforeAll, afterAll, beforeEach } from "vitest";
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

describe("git add benchmarks", () => {
  beforeEach(() => {
    try {
      git(["reset", "HEAD", "."], { cwd: REPO_DIR });
    } catch {}
  });

  bench("zagi add (single file)", () => {
    zagi(["add", "src/new-file.ts"], { cwd: REPO_DIR });
  });

  bench("git add (single file)", () => {
    git(["add", "src/new-file.ts"], { cwd: REPO_DIR });
  });

  bench("zagi add . (all)", () => {
    zagi(["add", "."], { cwd: REPO_DIR });
  });

  bench("git add . (all)", () => {
    git(["add", "."], { cwd: REPO_DIR });
  });
});

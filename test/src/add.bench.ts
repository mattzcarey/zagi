import { describe, bench, beforeAll, afterAll, beforeEach } from "vitest";
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

describe("git add benchmarks", () => {
  beforeEach(() => {
    try {
      execFileSync("git", ["reset", "HEAD", "."], { cwd: REPO_DIR });
    } catch {}
  });

  bench("zagi add (single file)", () => {
    execFileSync(ZAGI_BIN, ["add", "src/new-file.ts"], { cwd: REPO_DIR });
  });

  bench("git add (single file)", () => {
    execFileSync("git", ["add", "src/new-file.ts"], { cwd: REPO_DIR });
  });

  bench("zagi add . (all)", () => {
    execFileSync(ZAGI_BIN, ["add", "."], { cwd: REPO_DIR });
  });

  bench("git add . (all)", () => {
    execFileSync("git", ["add", "."], { cwd: REPO_DIR });
  });
});

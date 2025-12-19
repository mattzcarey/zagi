import { describe, test, expect } from "vitest";
import { execFileSync } from "child_process";
import { resolve } from "path";

const ZAGI_BIN = resolve(__dirname, "../../zig-out/bin/zagi");
const REPO_DIR = resolve(__dirname, "../..");

interface CommandResult {
  output: string;
  duration: number;
  bytes: number;
  lines: number;
}

function runCommand(cmd: string, args: string[]): CommandResult {
  const start = performance.now();
  const output = execFileSync(cmd, args, {
    cwd: REPO_DIR,
    encoding: "utf-8",
    maxBuffer: 10 * 1024 * 1024,
  });
  const duration = performance.now() - start;

  return {
    output,
    duration,
    bytes: Buffer.byteLength(output, "utf-8"),
    lines: output.split("\n").filter((l) => l.length > 0).length,
  };
}

describe("zagi status", () => {
  test("produces smaller output than git status", () => {
    const zagi = runCommand(ZAGI_BIN, ["status"]);
    const git = runCommand("git", ["status"]);

    console.log(`\nOutput size comparison:`);
    console.log(`  zagi status: ${zagi.bytes} bytes, ${zagi.lines} lines`);
    console.log(`  git status:  ${git.bytes} bytes, ${git.lines} lines`);
    console.log(
      `  Reduction: ${(((git.bytes - zagi.bytes) / git.bytes) * 100).toFixed(1)}%`
    );

    expect(zagi.bytes).toBeLessThan(git.bytes);
  });

  test("shows branch name", () => {
    const result = runCommand(ZAGI_BIN, ["status"]);
    expect(result.output).toMatch(/^branch: \w+/);
  });

  test("shows upstream status", () => {
    const result = runCommand(ZAGI_BIN, ["status"]);
    // Should show one of: (up to date), (ahead N), (behind N), (ahead N, behind N)
    expect(result.output).toMatch(
      /\(up to date\)|\(ahead \d+\)|\(behind \d+\)|\(ahead \d+, behind \d+\)/
    );
  });

  test("detects modified files", () => {
    const zagi = runCommand(ZAGI_BIN, ["status"]);
    const git = runCommand("git", ["status", "--porcelain"]);

    // Check if git reports any modified files
    const gitHasModified = git.output.includes(" M ");
    const zagiHasModified = zagi.output.includes("modified:");

    expect(zagiHasModified).toBe(gitHasModified);
  });

  test("detects untracked files", () => {
    const zagi = runCommand(ZAGI_BIN, ["status"]);
    const git = runCommand("git", ["status", "--porcelain"]);

    // Check if git reports any untracked files
    const gitHasUntracked = git.output.includes("??");
    const zagiHasUntracked = zagi.output.includes("untracked:");

    expect(zagiHasUntracked).toBe(gitHasUntracked);
  });
});

describe("performance", () => {
  test("zagi status is reasonably fast", () => {
    const iterations = 10;
    const times: number[] = [];

    for (let i = 0; i < iterations; i++) {
      const result = runCommand(ZAGI_BIN, ["status"]);
      times.push(result.duration);
    }

    const avg = times.reduce((a, b) => a + b, 0) / times.length;
    const min = Math.min(...times);
    const max = Math.max(...times);

    console.log(`\nPerformance (${iterations} iterations):`);
    console.log(`  Average: ${avg.toFixed(2)}ms`);
    console.log(`  Min: ${min.toFixed(2)}ms`);
    console.log(`  Max: ${max.toFixed(2)}ms`);

    // Should complete in under 100ms on average
    expect(avg).toBeLessThan(100);
  });

  test("zagi overhead vs git is minimal", () => {
    const zagiTimes: number[] = [];
    const gitTimes: number[] = [];
    const iterations = 5;

    for (let i = 0; i < iterations; i++) {
      const zagi = runCommand(ZAGI_BIN, ["status"]);
      const git = runCommand("git", ["status", "--porcelain"]);
      zagiTimes.push(zagi.duration);
      gitTimes.push(git.duration);
    }

    const zagiAvg = zagiTimes.reduce((a, b) => a + b, 0) / iterations;
    const gitAvg = gitTimes.reduce((a, b) => a + b, 0) / iterations;
    const overhead = zagiAvg - gitAvg;

    console.log(`\nOverhead comparison:`);
    console.log(`  zagi avg: ${zagiAvg.toFixed(2)}ms`);
    console.log(`  git avg:  ${gitAvg.toFixed(2)}ms`);
    console.log(`  Overhead: ${overhead.toFixed(2)}ms`);

    // Overhead should be less than 50ms
    expect(overhead).toBeLessThan(50);
  });
});

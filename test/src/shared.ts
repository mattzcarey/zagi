import { execFileSync } from "child_process";
import { resolve } from "path";
import { mkdirSync, writeFileSync, rmSync } from "fs";

export const ZAGI_BIN = resolve(__dirname, "../../zig-out/bin/zagi");

export interface ZagiOptions {
  /** Override or remove env vars. Use undefined to remove a var. */
  env?: Record<string, string | undefined>;
  /** Working directory */
  cwd?: string;
}

/**
 * Run zagi command with isolated environment.
 * By default removes ZAGI_AGENT and ZAGI_STRIP_COAUTHORS to avoid test pollution.
 */
export function zagi(args: string[], options: ZagiOptions = {}): string {
  const { cwd = process.cwd(), env: envOverrides = {} } = options;

  // Create isolated env - start with current env
  const env = { ...process.env };

  // By default, remove zagi env vars unless explicitly set
  if (!("ZAGI_AGENT" in envOverrides)) {
    delete env.ZAGI_AGENT;
  }
  if (!("ZAGI_STRIP_COAUTHORS" in envOverrides)) {
    delete env.ZAGI_STRIP_COAUTHORS;
  }

  // Apply overrides (undefined removes the key)
  for (const [key, value] of Object.entries(envOverrides)) {
    if (value === undefined) {
      delete env[key];
    } else {
      env[key] = value;
    }
  }

  try {
    return execFileSync(ZAGI_BIN, args, {
      cwd,
      encoding: "utf-8",
      env,
    }) as string;
  } catch (err: any) {
    // Return combined stdout + stderr for error cases
    return (err.stdout || "") + (err.stderr || "");
  }
}

/**
 * Run git command with isolated environment.
 */
export function git(args: string[], options: ZagiOptions = {}): string {
  const { cwd = process.cwd(), env: envOverrides = {} } = options;

  const env = { ...process.env };

  // Apply overrides
  for (const [key, value] of Object.entries(envOverrides)) {
    if (value === undefined) {
      delete env[key];
    } else {
      env[key] = value;
    }
  }

  try {
    return execFileSync("git", args, {
      cwd,
      encoding: "utf-8",
      env,
      stdio: "pipe",
    }) as string;
  } catch (err: any) {
    return (err.stdout || "") + (err.stderr || "");
  }
}

/**
 * Creates a minimal test repository and returns its path.
 */
export function createTestRepo(): string {
  const repoId = "test-" + Date.now() + "-" + Math.random().toString(36).slice(2, 8);
  const repoDir = resolve(__dirname, "../fixtures/repos", repoId);

  mkdirSync(repoDir, { recursive: true });

  git(["init", "-b", "main"], { cwd: repoDir });
  git(["config", "user.email", "test@example.com"], { cwd: repoDir });
  git(["config", "user.name", "Test User"], { cwd: repoDir });

  writeFileSync(resolve(repoDir, "README.md"), "# Test\n");
  git(["add", "."], { cwd: repoDir });
  git(["commit", "-m", "Initial commit"], { cwd: repoDir });

  return repoDir;
}

/**
 * Cleans up a test repository.
 */
export function cleanupTestRepo(repoDir: string): void {
  if (repoDir) {
    rmSync(repoDir, { recursive: true, force: true });
  }
}

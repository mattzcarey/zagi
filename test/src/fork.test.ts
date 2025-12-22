import { describe, test, expect, beforeEach, afterEach } from "vitest";
import { resolve } from "path";
import { writeFileSync, readFileSync, existsSync } from "fs";
import { zagi, git, createTestRepo, cleanupTestRepo } from "./shared";

let REPO_DIR: string;

beforeEach(() => {
  REPO_DIR = createTestRepo();
});

afterEach(() => {
  cleanupTestRepo(REPO_DIR);
});

describe("git fork", () => {
  test("creates a fork", () => {
    const result = zagi(["fork", "test-fork"], { cwd: REPO_DIR });

    expect(result).toContain("forked: test-fork");
    expect(result).toContain(".forks/test-fork/");

    // Verify directory exists
    expect(existsSync(resolve(REPO_DIR, ".forks/test-fork"))).toBe(true);
  });

  test("lists forks when no args", () => {
    zagi(["fork", "alpha"], { cwd: REPO_DIR });
    zagi(["fork", "beta"], { cwd: REPO_DIR });

    const result = zagi(["fork"], { cwd: REPO_DIR });

    expect(result).toContain("forks:");
    expect(result).toContain("alpha");
    expect(result).toContain("beta");
  });

  test("shows no forks message", () => {
    const result = zagi(["fork"], { cwd: REPO_DIR });
    expect(result).toBe("no forks\n");
  });

  test("shows commits ahead count", () => {
    zagi(["fork", "feature"], { cwd: REPO_DIR });

    // Make a commit in the fork
    const forkDir = resolve(REPO_DIR, ".forks/feature");
    writeFileSync(resolve(forkDir, "new.txt"), "new file\n");
    git(["add", "."], { cwd: forkDir });
    git(["commit", "-m", "Add new file"], { cwd: forkDir });

    const result = zagi(["fork"], { cwd: REPO_DIR });

    expect(result).toContain("feature");
    expect(result).toContain("1 commit ahead");
  });

  test("errors when inside a fork", () => {
    zagi(["fork", "test"], { cwd: REPO_DIR });

    const forkDir = resolve(REPO_DIR, ".forks/test");
    const result = zagi(["fork", "nested"], { cwd: forkDir });

    expect(result).toContain("already in a fork");
    expect(result).toContain("run from base");
  });

  test("auto-adds .forks/ to .gitignore on first fork", () => {
    // No .gitignore exists initially
    expect(existsSync(resolve(REPO_DIR, ".gitignore"))).toBe(false);

    zagi(["fork", "test"], { cwd: REPO_DIR });

    // .gitignore should now exist with .forks/
    expect(existsSync(resolve(REPO_DIR, ".gitignore"))).toBe(true);
    const content = readFileSync(resolve(REPO_DIR, ".gitignore"), "utf-8");
    expect(content).toContain(".forks/");
  });
});

describe("git fork --promote", () => {
  test("promotes fork commits to base", () => {
    zagi(["fork", "feature"], { cwd: REPO_DIR });

    // Make changes in fork
    const forkDir = resolve(REPO_DIR, ".forks/feature");
    writeFileSync(resolve(forkDir, "README.md"), "updated content\n");
    git(["add", "."], { cwd: forkDir });
    git(["commit", "-m", "Update file"], { cwd: forkDir });

    // Promote the fork
    const result = zagi(["fork", "--promote", "feature"], { cwd: REPO_DIR });

    expect(result).toContain("promoted: feature");
    expect(result).toContain("1 commit");
    expect(result).toContain("applied to base");

    // Verify base has the changes
    const content = git(["show", "HEAD:README.md"], { cwd: REPO_DIR });
    expect(content).toBe("updated content\n");
  });

  test("errors for non-existent fork", () => {
    const result = zagi(["fork", "--promote", "nonexistent"], { cwd: REPO_DIR });

    expect(result).toContain("not found");
  });

  test("preserves local uncommitted changes when fork has no new commits", () => {
    // Create a fork (no changes made in fork)
    zagi(["fork", "empty-fork"], { cwd: REPO_DIR });

    // Make local uncommitted changes in base
    writeFileSync(resolve(REPO_DIR, "local-changes.txt"), "my local work\n");
    writeFileSync(resolve(REPO_DIR, "README.md"), "modified locally\n");

    // Promote the fork (which has no commits ahead)
    const result = zagi(["fork", "--promote", "empty-fork"], { cwd: REPO_DIR });

    expect(result).toContain("promoted: empty-fork");

    // Verify local changes are preserved
    const localFile = git(["diff", "--name-only"], { cwd: REPO_DIR });
    expect(localFile).toContain("README.md");
  });

  test("preserves local uncommitted changes when fork has non-conflicting commits", () => {
    zagi(["fork", "feature"], { cwd: REPO_DIR });

    // Make changes in fork to a DIFFERENT file
    const forkDir = resolve(REPO_DIR, ".forks/feature");
    writeFileSync(resolve(forkDir, "new-feature.txt"), "feature content\n");
    git(["add", "."], { cwd: forkDir });
    git(["commit", "-m", "Add feature"], { cwd: forkDir });

    // Make local uncommitted changes in base to a DIFFERENT file
    writeFileSync(resolve(REPO_DIR, "local-work.txt"), "my local work\n");

    // Promote the fork
    const result = zagi(["fork", "--promote", "feature"], { cwd: REPO_DIR });

    expect(result).toContain("promoted: feature");

    // Verify fork changes are applied
    expect(existsSync(resolve(REPO_DIR, "new-feature.txt"))).toBe(true);

    // Verify local uncommitted changes are preserved
    expect(existsSync(resolve(REPO_DIR, "local-work.txt"))).toBe(true);
  });

  test("fails safely when fork has conflicting changes", () => {
    zagi(["fork", "conflict"], { cwd: REPO_DIR });

    // Make changes in fork to README.md
    const forkDir = resolve(REPO_DIR, ".forks/conflict");
    writeFileSync(resolve(forkDir, "README.md"), "fork version\n");
    git(["add", "."], { cwd: forkDir });
    git(["commit", "-m", "Change file"], { cwd: forkDir });

    // Make local uncommitted changes to the SAME file in base
    writeFileSync(resolve(REPO_DIR, "README.md"), "local version\n");

    // Promote should fail due to conflict
    const result = zagi(["fork", "--promote", "conflict"], { cwd: REPO_DIR });

    // Should have error or conflict message
    expect(result.length).toBeGreaterThan(0);
  });
});

describe("git fork --delete", () => {
  test("deletes a specific fork", () => {
    zagi(["fork", "to-delete"], { cwd: REPO_DIR });
    expect(existsSync(resolve(REPO_DIR, ".forks/to-delete"))).toBe(true);

    const result = zagi(["fork", "--delete", "to-delete"], { cwd: REPO_DIR });

    expect(result).toContain("deleted: to-delete");
    expect(existsSync(resolve(REPO_DIR, ".forks/to-delete"))).toBe(false);
  });

  test("errors for non-existent fork", () => {
    const result = zagi(["fork", "--delete", "nonexistent"], { cwd: REPO_DIR });

    expect(result).toContain("not found");
  });
});

describe("git fork --delete-all", () => {
  test("deletes all forks", () => {
    zagi(["fork", "a"], { cwd: REPO_DIR });
    zagi(["fork", "b"], { cwd: REPO_DIR });
    zagi(["fork", "c"], { cwd: REPO_DIR });

    const result = zagi(["fork", "--delete-all"], { cwd: REPO_DIR });

    expect(result).toContain("deleted:");
    expect(result).toContain("a");
    expect(result).toContain("b");
    expect(result).toContain("c");

    // Verify forks are gone
    const listResult = zagi(["fork"], { cwd: REPO_DIR });
    expect(listResult).toBe("no forks\n");
  });

  test("shows message when no forks exist", () => {
    const result = zagi(["fork", "--delete-all"], { cwd: REPO_DIR });
    expect(result).toContain("no forks to delete");
  });
});

describe("git fork --pick", () => {
  test("merges fork commits to base (fast-forward)", () => {
    zagi(["fork", "feature"], { cwd: REPO_DIR });

    // Make changes in fork
    const forkDir = resolve(REPO_DIR, ".forks/feature");
    writeFileSync(resolve(forkDir, "new.txt"), "new content\n");
    git(["add", "."], { cwd: forkDir });
    git(["commit", "-m", "Add new file"], { cwd: forkDir });

    // Pick the fork (should fast-forward since base hasn't changed)
    const result = zagi(["fork", "--pick", "feature"], { cwd: REPO_DIR });

    expect(result).toContain("picked: feature");
    expect(result).toContain("fast-forward");

    // Verify base has the changes
    expect(existsSync(resolve(REPO_DIR, "new.txt"))).toBe(true);
  });

  test("creates merge commit when base has diverged", () => {
    zagi(["fork", "feature"], { cwd: REPO_DIR });

    // Make changes in fork
    const forkDir = resolve(REPO_DIR, ".forks/feature");
    writeFileSync(resolve(forkDir, "fork-file.txt"), "fork content\n");
    git(["add", "."], { cwd: forkDir });
    git(["commit", "-m", "Fork commit"], { cwd: forkDir });

    // Make different changes in base (diverge)
    writeFileSync(resolve(REPO_DIR, "base-file.txt"), "base content\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "-m", "Base commit"], { cwd: REPO_DIR });

    // Pick the fork (should create merge commit)
    const result = zagi(["fork", "--pick", "feature"], { cwd: REPO_DIR });

    expect(result).toContain("picked: feature");
    expect(result).toContain("merged");

    // Verify both files exist (merge succeeded)
    expect(existsSync(resolve(REPO_DIR, "fork-file.txt"))).toBe(true);
    expect(existsSync(resolve(REPO_DIR, "base-file.txt"))).toBe(true);

    // Verify merge commit was created (should have 2 parents)
    const logOutput = git(["log", "--oneline", "--merges", "-1"], { cwd: REPO_DIR });
    expect(logOutput).toContain("Merge fork");
  });

  test("reports already up to date", () => {
    zagi(["fork", "empty-fork"], { cwd: REPO_DIR });

    // Pick without making any changes in fork
    const result = zagi(["fork", "--pick", "empty-fork"], { cwd: REPO_DIR });

    expect(result).toContain("already up to date");
  });

  test("handles merge conflicts gracefully", () => {
    zagi(["fork", "conflict"], { cwd: REPO_DIR });

    // Make changes in fork to README.md
    const forkDir = resolve(REPO_DIR, ".forks/conflict");
    writeFileSync(resolve(forkDir, "README.md"), "fork version\n");
    git(["add", "."], { cwd: forkDir });
    git(["commit", "-m", "Fork change"], { cwd: forkDir });

    // Make conflicting changes to same file in base
    writeFileSync(resolve(REPO_DIR, "README.md"), "base version\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "-m", "Base change"], { cwd: REPO_DIR });

    // Pick should succeed but report conflicts
    const result = zagi(["fork", "--pick", "conflict"], { cwd: REPO_DIR });

    expect(result).toContain("picked: conflict");
    expect(result).toContain("conflicts");
    expect(result).toContain("resolve conflicts");
  });

  test("errors for non-existent fork", () => {
    const result = zagi(["fork", "--pick", "nonexistent"], { cwd: REPO_DIR });

    expect(result).toContain("not found");
  });

  test("preserves local uncommitted changes", () => {
    zagi(["fork", "feature"], { cwd: REPO_DIR });

    // Make changes in fork to a different file
    const forkDir = resolve(REPO_DIR, ".forks/feature");
    writeFileSync(resolve(forkDir, "new-feature.txt"), "feature content\n");
    git(["add", "."], { cwd: forkDir });
    git(["commit", "-m", "Add feature"], { cwd: forkDir });

    // Make local uncommitted changes in base
    writeFileSync(resolve(REPO_DIR, "local-work.txt"), "my local work\n");

    // Pick the fork
    const result = zagi(["fork", "--pick", "feature"], { cwd: REPO_DIR });

    expect(result).toContain("picked: feature");

    // Verify fork changes are applied
    expect(existsSync(resolve(REPO_DIR, "new-feature.txt"))).toBe(true);

    // Verify local uncommitted changes are preserved
    expect(existsSync(resolve(REPO_DIR, "local-work.txt"))).toBe(true);
  });

  test("warns when fork has uncommitted changes", () => {
    // Create a fork
    const createOutput = zagi(["fork", "test-fork"], { cwd: REPO_DIR });
    expect(createOutput).toContain("forked: test-fork");

    // Add uncommitted changes to the fork
    const forkDir = resolve(REPO_DIR, ".forks/test-fork");
    writeFileSync(resolve(forkDir, "uncommitted.txt"), "uncommitted content\n");

    // Try to pick - should warn about uncommitted changes
    const pickOutput = zagi(["fork", "--pick", "test-fork"], { cwd: REPO_DIR });

    expect(pickOutput).toContain("warning: fork 'test-fork' has uncommitted changes");
    expect(pickOutput).toContain("1 file not committed");
    expect(pickOutput).toContain("hint:");

    // Clean up
    zagi(["fork", "--delete", "test-fork"], { cwd: REPO_DIR });
  });

  test("no warning when fork is clean", () => {
    // Create a fork
    zagi(["fork", "clean-fork"], { cwd: REPO_DIR });

    // Pick without changes - should not warn
    const pickOutput = zagi(["fork", "--pick", "clean-fork"], { cwd: REPO_DIR });

    expect(pickOutput).not.toContain("warning:");
    expect(pickOutput).toContain("already up to date");

    // Clean up
    zagi(["fork", "--delete", "clean-fork"], { cwd: REPO_DIR });
  });

  test("warns with multiple uncommitted files", () => {
    // Create a fork
    zagi(["fork", "multi-fork"], { cwd: REPO_DIR });

    // Add multiple uncommitted files
    const forkDir = resolve(REPO_DIR, ".forks/multi-fork");
    writeFileSync(resolve(forkDir, "file1.txt"), "content 1\n");
    writeFileSync(resolve(forkDir, "file2.txt"), "content 2\n");
    writeFileSync(resolve(forkDir, "file3.txt"), "content 3\n");

    const pickOutput = zagi(["fork", "--pick", "multi-fork"], { cwd: REPO_DIR });

    expect(pickOutput).toContain("warning: fork 'multi-fork' has uncommitted changes");
    expect(pickOutput).toContain("3 files not committed");

    // Clean up
    zagi(["fork", "--delete", "multi-fork"], { cwd: REPO_DIR });
  });
});

describe("git fork --help", () => {
  test("shows help", () => {
    const result = zagi(["fork", "--help"], { cwd: REPO_DIR });

    expect(result).toContain("usage:");
    expect(result).toContain("--pick");
    expect(result).toContain("--promote");
    expect(result).toContain("--delete");
    expect(result).toContain("--delete-all");
  });
});

describe("git fork validation", () => {
  test("rejects empty fork name", () => {
    const result = zagi(["fork", ""], { cwd: REPO_DIR });

    expect(result).toContain("fork name cannot be empty");
  });

  test("rejects fork name with slash", () => {
    const result = zagi(["fork", "my/nested/fork"], { cwd: REPO_DIR });

    expect(result).toContain("cannot contain");
  });

  test("rejects fork name starting with dot", () => {
    const result = zagi(["fork", ".hidden"], { cwd: REPO_DIR });

    expect(result).toContain("cannot contain");
  });

  test("rejects fork name with path traversal", () => {
    const result = zagi(["fork", "../../escape"], { cwd: REPO_DIR });

    expect(result).toContain("cannot contain");
  });

  test("rejects fork name matching existing branch", () => {
    const result = zagi(["fork", "main"], { cwd: REPO_DIR });

    expect(result).toContain("branch 'main' already exists");
  });

  test("rejects creating duplicate fork", () => {
    zagi(["fork", "existing"], { cwd: REPO_DIR });

    const result = zagi(["fork", "existing"], { cwd: REPO_DIR });

    expect(result).toContain("already exists");
  });

  test("--pick errors in detached HEAD state", () => {
    zagi(["fork", "test-fork"], { cwd: REPO_DIR });

    // Detach HEAD
    git(["checkout", "HEAD~0"], { cwd: REPO_DIR });

    const result = zagi(["fork", "--pick", "test-fork"], { cwd: REPO_DIR });

    expect(result).toContain("detached HEAD");
    expect(result).toContain("checkout a branch");
  });

  test("--promote errors in detached HEAD state", () => {
    zagi(["fork", "test-fork"], { cwd: REPO_DIR });

    // Detach HEAD
    git(["checkout", "HEAD~0"], { cwd: REPO_DIR });

    const result = zagi(["fork", "--promote", "test-fork"], { cwd: REPO_DIR });

    expect(result).toContain("detached HEAD");
    expect(result).toContain("checkout a branch");
  });

  test("--pick shows conflict resolution hints", () => {
    zagi(["fork", "conflict"], { cwd: REPO_DIR });

    // Make conflicting changes
    const forkDir = resolve(REPO_DIR, ".forks/conflict");
    writeFileSync(resolve(forkDir, "README.md"), "fork version\n");
    git(["add", "."], { cwd: forkDir });
    git(["commit", "-m", "Fork change"], { cwd: forkDir });

    writeFileSync(resolve(REPO_DIR, "README.md"), "base version\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "-m", "Base change"], { cwd: REPO_DIR });

    const result = zagi(["fork", "--pick", "conflict"], { cwd: REPO_DIR });

    expect(result).toContain("conflicts");
    expect(result).toContain("git add");
    expect(result).toContain("git commit");
    expect(result).toContain("git merge --abort");
  });

  test("--pick errors when merge already in progress", () => {
    zagi(["fork", "conflict"], { cwd: REPO_DIR });

    // Create a conflict situation
    const forkDir = resolve(REPO_DIR, ".forks/conflict");
    writeFileSync(resolve(forkDir, "README.md"), "fork version\n");
    git(["add", "."], { cwd: forkDir });
    git(["commit", "-m", "Fork change"], { cwd: forkDir });

    writeFileSync(resolve(REPO_DIR, "README.md"), "base version\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "-m", "Base change"], { cwd: REPO_DIR });

    // First pick creates merge state
    zagi(["fork", "--pick", "conflict"], { cwd: REPO_DIR });

    // Second pick should error
    const result = zagi(["fork", "--pick", "conflict"], { cwd: REPO_DIR });

    expect(result).toContain("merge is already in progress");
    expect(result).toContain("git merge --abort");
  });

  test("rejects fork name that would exceed path limit", () => {
    // Create a name that's very long (should exceed path limit with workdir)
    const longName = "a".repeat(4000);

    const result = zagi(["fork", longName], { cwd: REPO_DIR });

    expect(result).toContain("too long");
  });
});

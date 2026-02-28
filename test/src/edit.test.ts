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

/**
 * Helper to create a test repo with commits A->B->C->D
 * Returns the commit hashes for A, B, C, D
 */
function setupFourCommits(): { A: string; B: string; C: string; D: string } {
  // A is already created by createTestRepo (Initial commit)
  const logA = git(["rev-parse", "HEAD"], { cwd: REPO_DIR }).trim();

  // B
  writeFileSync(resolve(REPO_DIR, "b.txt"), "content B\n");
  git(["add", "."], { cwd: REPO_DIR });
  git(["commit", "-m", "Commit B"], { cwd: REPO_DIR });
  const logB = git(["rev-parse", "HEAD"], { cwd: REPO_DIR }).trim();

  // C
  writeFileSync(resolve(REPO_DIR, "c.txt"), "content C\n");
  git(["add", "."], { cwd: REPO_DIR });
  git(["commit", "-m", "Commit C"], { cwd: REPO_DIR });
  const logC = git(["rev-parse", "HEAD"], { cwd: REPO_DIR }).trim();

  // D
  writeFileSync(resolve(REPO_DIR, "d.txt"), "content D\n");
  git(["add", "."], { cwd: REPO_DIR });
  git(["commit", "-m", "Commit D"], { cwd: REPO_DIR });
  const logD = git(["rev-parse", "HEAD"], { cwd: REPO_DIR }).trim();

  return { A: logA, B: logB, C: logC, D: logD };
}

describe("git edit <commit>", () => {
  test("travels to target commit and shows correct output", () => {
    const { B, D } = setupFourCommits();

    // Travel to commit B
    const result = zagi(["edit", B.slice(0, 7)], { cwd: REPO_DIR });

    // Should show edit output
    expect(result).toContain("edit:");
    expect(result).toContain(B.slice(0, 7));
    expect(result).toContain("from:");
    expect(result).toContain(D.slice(0, 7));
    expect(result).toContain("descendants: 2 commits");

    // HEAD should now be at B (detached)
    const currentHead = git(["rev-parse", "HEAD"], { cwd: REPO_DIR }).trim();
    expect(currentHead).toBe(B);

    // Should be in detached HEAD state
    const headRef = git(["symbolic-ref", "HEAD"], { cwd: REPO_DIR });
    expect(headRef).toContain("not a symbolic ref");
  });

  test("errors when working tree is dirty", () => {
    setupFourCommits();

    // Make uncommitted changes
    writeFileSync(resolve(REPO_DIR, "dirty.txt"), "uncommitted\n");

    const result = zagi(["edit", "HEAD~2"], { cwd: REPO_DIR });

    expect(result).toContain("uncommitted changes");
  });

  test("errors when target is not in history", () => {
    setupFourCommits();

    // Create a branch that diverges
    git(["checkout", "-b", "other", "HEAD~3"], { cwd: REPO_DIR });
    writeFileSync(resolve(REPO_DIR, "other.txt"), "other branch\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "-m", "Other commit"], { cwd: REPO_DIR });
    const otherCommit = git(["rev-parse", "HEAD"], { cwd: REPO_DIR }).trim();

    // Go back to main
    git(["checkout", "main"], { cwd: REPO_DIR });

    // Try to edit a commit not in main's history
    const result = zagi(["edit", otherCommit.slice(0, 7)], { cwd: REPO_DIR });

    expect(result).toContain("not an ancestor");
  });

  test("errors when edit is already active", () => {
    const { B } = setupFourCommits();

    // Start first edit
    zagi(["edit", B.slice(0, 7)], { cwd: REPO_DIR });

    // Try to start another edit
    const result = zagi(["edit", "HEAD~1"], { cwd: REPO_DIR });

    expect(result).toContain("edit already in progress");
  });

  test("errors with invalid commit reference", () => {
    setupFourCommits();

    const result = zagi(["edit", "nonexistent123"], { cwd: REPO_DIR });

    expect(result).toContain("invalid commit");
  });
});

describe("git edit --back", () => {
  test("rebases descendants correctly after amend", () => {
    const { B } = setupFourCommits();

    // Travel to B
    zagi(["edit", B.slice(0, 7)], { cwd: REPO_DIR });

    // Amend B with new content
    writeFileSync(resolve(REPO_DIR, "b.txt"), "amended content B\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "--amend", "--no-edit"], { cwd: REPO_DIR });
    const amendedB = git(["rev-parse", "HEAD"], { cwd: REPO_DIR }).trim();

    // Return with --back
    const result = zagi(["edit", "--back"], { cwd: REPO_DIR });

    expect(result).toContain("edit: complete");
    expect(result).toContain("rebased: 2 commits");

    // Should be back on main branch
    const branch = git(["rev-parse", "--abbrev-ref", "HEAD"], {
      cwd: REPO_DIR,
    }).trim();
    expect(branch).toBe("main");

    // The amended content should be in the history
    const bContent = readFileSync(resolve(REPO_DIR, "b.txt"), "utf-8");
    expect(bContent).toBe("amended content B\n");

    // C and D should have been rebased (different hashes, same messages)
    const log = git(["log", "--oneline"], { cwd: REPO_DIR });
    expect(log).toContain("Commit D");
    expect(log).toContain("Commit C");
    expect(log).toContain("Commit B");

    // B should now be the amended version
    const newB = git(["rev-parse", "HEAD~2"], { cwd: REPO_DIR }).trim();
    expect(newB).toBe(amendedB);
  });

  test("errors when no edit is active", () => {
    setupFourCommits();

    const result = zagi(["edit", "--back"], { cwd: REPO_DIR });

    expect(result).toContain("no edit in progress");
  });

  test("errors when working tree is dirty", () => {
    const { B } = setupFourCommits();

    // Start edit
    zagi(["edit", B.slice(0, 7)], { cwd: REPO_DIR });

    // Make uncommitted changes
    writeFileSync(resolve(REPO_DIR, "dirty.txt"), "uncommitted\n");

    const result = zagi(["edit", "--back"], { cwd: REPO_DIR });

    expect(result).toContain("uncommitted changes");
  });
});

describe("git edit --abort", () => {
  test("restores original HEAD", () => {
    const { B, D } = setupFourCommits();

    // Travel to B
    zagi(["edit", B.slice(0, 7)], { cwd: REPO_DIR });

    // Verify we're at B
    expect(git(["rev-parse", "HEAD"], { cwd: REPO_DIR }).trim()).toBe(B);

    // Make some changes
    writeFileSync(resolve(REPO_DIR, "b.txt"), "modified during edit\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "--amend", "--no-edit"], { cwd: REPO_DIR });

    // Abort
    const result = zagi(["edit", "--abort"], { cwd: REPO_DIR });

    expect(result).toContain("edit: aborted");
    expect(result).toContain("restored:");
    expect(result).toContain(D.slice(0, 7));

    // Should be back at original D on main
    const currentHead = git(["rev-parse", "HEAD"], { cwd: REPO_DIR }).trim();
    expect(currentHead).toBe(D);

    // Should be on main branch
    const branch = git(["rev-parse", "--abbrev-ref", "HEAD"], {
      cwd: REPO_DIR,
    }).trim();
    expect(branch).toBe("main");

    // Original content should be restored
    const bContent = readFileSync(resolve(REPO_DIR, "b.txt"), "utf-8");
    expect(bContent).toBe("content B\n");
  });

  test("errors when no edit is active", () => {
    setupFourCommits();

    const result = zagi(["edit", "--abort"], { cwd: REPO_DIR });

    expect(result).toContain("no edit in progress");
  });
});

describe("git edit --status", () => {
  test("shows not active when no edit session", () => {
    setupFourCommits();

    const result = zagi(["edit", "--status"], { cwd: REPO_DIR });

    expect(result).toBe("edit: not active\n");
  });

  test("shows correct state when edit is active", () => {
    const { B, D } = setupFourCommits();

    // Start edit at B
    zagi(["edit", B.slice(0, 7)], { cwd: REPO_DIR });

    const result = zagi(["edit", "--status"], { cwd: REPO_DIR });

    expect(result).toContain("edit: active");
    expect(result).toContain("target:");
    expect(result).toContain(B.slice(0, 7));
    expect(result).toContain("origin:");
    expect(result).toContain(D.slice(0, 7));
    expect(result).toContain("remaining: 2 commits");
  });

  test("shows updated state after amending", () => {
    const { B } = setupFourCommits();

    // Start edit at B
    zagi(["edit", B.slice(0, 7)], { cwd: REPO_DIR });

    // Amend B
    writeFileSync(resolve(REPO_DIR, "b.txt"), "amended\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "--amend", "--no-edit"], { cwd: REPO_DIR });

    const result = zagi(["edit", "--status"], { cwd: REPO_DIR });

    expect(result).toContain("edit: active");
    // target should now be the amended commit
    const newHead = git(["rev-parse", "HEAD"], { cwd: REPO_DIR })
      .trim()
      .slice(0, 7);
    expect(result).toContain(newHead);
  });
});

describe("git edit --help", () => {
  test("shows help message", () => {
    const result = zagi(["edit", "--help"], { cwd: REPO_DIR });

    expect(result).toContain("usage:");
    expect(result).toContain("--back");
    expect(result).toContain("--abort");
    expect(result).toContain("--status");
    expect(result).toContain("--continue");
  });

  test("shows help with no arguments", () => {
    const result = zagi(["edit"], { cwd: REPO_DIR });

    expect(result).toContain("usage:");
  });
});

describe("git edit with HEAD~N syntax", () => {
  test("works with HEAD~N reference", () => {
    const { B } = setupFourCommits();

    // HEAD~2 should be commit B (D -> C -> B)
    const result = zagi(["edit", "HEAD~2"], { cwd: REPO_DIR });

    expect(result).toContain("edit:");
    expect(result).toContain(B.slice(0, 7));

    const currentHead = git(["rev-parse", "HEAD"], { cwd: REPO_DIR }).trim();
    expect(currentHead).toBe(B);
  });
});

describe("git edit edge cases", () => {
  test("handles editing the immediate parent", () => {
    const { C, D } = setupFourCommits();

    // Edit HEAD~1 (commit C)
    const result = zagi(["edit", "HEAD~1"], { cwd: REPO_DIR });

    expect(result).toContain("edit:");
    expect(result).toContain(C.slice(0, 7));
    expect(result).toContain("descendants: 1 commits");

    // Verify at C
    const currentHead = git(["rev-parse", "HEAD"], { cwd: REPO_DIR }).trim();
    expect(currentHead).toBe(C);
  });

  test("completes correctly with no actual changes", () => {
    const { B } = setupFourCommits();

    // Travel to B but don't make changes
    zagi(["edit", B.slice(0, 7)], { cwd: REPO_DIR });

    // Return without making changes
    const result = zagi(["edit", "--back"], { cwd: REPO_DIR });

    expect(result).toContain("edit: complete");
    expect(result).toContain("rebased: 2 commits");

    // Note: Even without changes, rebase creates new commits (different hashes)
    // Verify we're back on main branch with all content intact
    const branch = git(["rev-parse", "--abbrev-ref", "HEAD"], {
      cwd: REPO_DIR,
    }).trim();
    expect(branch).toBe("main");

    // Verify all files exist with original content
    expect(readFileSync(resolve(REPO_DIR, "b.txt"), "utf-8")).toBe(
      "content B\n"
    );
    expect(readFileSync(resolve(REPO_DIR, "c.txt"), "utf-8")).toBe(
      "content C\n"
    );
    expect(readFileSync(resolve(REPO_DIR, "d.txt"), "utf-8")).toBe(
      "content D\n"
    );
  });

  test("preserves commit messages during rebase", () => {
    const { B } = setupFourCommits();

    // Travel to B and amend
    zagi(["edit", B.slice(0, 7)], { cwd: REPO_DIR });
    writeFileSync(resolve(REPO_DIR, "b.txt"), "amended\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "--amend", "--no-edit"], { cwd: REPO_DIR });

    // Return
    zagi(["edit", "--back"], { cwd: REPO_DIR });

    // Check commit messages are preserved
    const messages = git(["log", "--format=%s", "-4"], { cwd: REPO_DIR });
    expect(messages).toContain("Commit D");
    expect(messages).toContain("Commit C");
    expect(messages).toContain("Commit B");
    expect(messages).toContain("Initial commit");
  });

  test("edit state is cleared after abort", () => {
    const { B } = setupFourCommits();

    // Start and abort
    zagi(["edit", B.slice(0, 7)], { cwd: REPO_DIR });
    zagi(["edit", "--abort"], { cwd: REPO_DIR });

    // Status should show not active
    const status = zagi(["edit", "--status"], { cwd: REPO_DIR });
    expect(status).toBe("edit: not active\n");

    // Should be able to start a new edit
    const result = zagi(["edit", B.slice(0, 7)], { cwd: REPO_DIR });
    expect(result).toContain("edit:");
    expect(result).not.toContain("already active");
  });

  test("edit state is cleared after successful --back", () => {
    const { B } = setupFourCommits();

    // Complete an edit
    zagi(["edit", B.slice(0, 7)], { cwd: REPO_DIR });
    zagi(["edit", "--back"], { cwd: REPO_DIR });

    // Status should show not active
    const status = zagi(["edit", "--status"], { cwd: REPO_DIR });
    expect(status).toBe("edit: not active\n");
  });
});

describe("git edit - conflict handling", () => {
  test("reports conflict with clear message when cherry-pick fails", () => {
    // Create a repo with commits that modify the same file
    // A: initial (README.md = "# Test")
    // B: modifies README.md to "# Test B"
    // C: adds c.txt

    // Modify README.md in second commit
    writeFileSync(resolve(REPO_DIR, "README.md"), "# Test B\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "-m", "Modify README"], { cwd: REPO_DIR });

    writeFileSync(resolve(REPO_DIR, "c.txt"), "content C\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "-m", "Add C"], { cwd: REPO_DIR });

    // Travel to initial commit
    zagi(["edit", "HEAD~2"], { cwd: REPO_DIR });

    // Modify README.md differently (will conflict with B)
    writeFileSync(resolve(REPO_DIR, "README.md"), "# Test CONFLICT\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "--amend", "--no-edit"], { cwd: REPO_DIR });

    // Try to --back, which should fail with conflict
    const result = zagi(["edit", "--back"], { cwd: REPO_DIR });

    expect(result).toContain("conflict");
    expect(result).toContain("git edit --continue");
    expect(result).toContain("git edit --abort");
  });

  test("--status shows conflict state during conflict", () => {
    // Create commits that will conflict
    writeFileSync(resolve(REPO_DIR, "README.md"), "# Test B\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "-m", "Modify README"], { cwd: REPO_DIR });

    // Start edit at initial commit
    zagi(["edit", "HEAD~1"], { cwd: REPO_DIR });

    // Create conflicting change
    writeFileSync(resolve(REPO_DIR, "README.md"), "# Test CONFLICT\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "--amend", "--no-edit"], { cwd: REPO_DIR });

    // Trigger conflict
    zagi(["edit", "--back"], { cwd: REPO_DIR });

    // Check status shows conflict
    const result = zagi(["edit", "--status"], { cwd: REPO_DIR });

    expect(result).toContain("edit: active");
    expect(result).toContain("conflict");
  });

  test("--continue resumes after resolving conflict", () => {
    // Create commits that will conflict
    writeFileSync(resolve(REPO_DIR, "README.md"), "# Test B\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "-m", "Modify README"], { cwd: REPO_DIR });

    // Start edit at initial commit
    zagi(["edit", "HEAD~1"], { cwd: REPO_DIR });

    // Create conflicting change
    writeFileSync(resolve(REPO_DIR, "README.md"), "# Test CONFLICT\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "--amend", "--no-edit"], { cwd: REPO_DIR });

    // Trigger conflict
    zagi(["edit", "--back"], { cwd: REPO_DIR });

    // Resolve the conflict by accepting a merged version
    writeFileSync(resolve(REPO_DIR, "README.md"), "# Test RESOLVED\n");
    git(["add", "README.md"], { cwd: REPO_DIR });

    // Continue the edit
    const result = zagi(["edit", "--continue"], { cwd: REPO_DIR });

    expect(result).toContain("continued");
  });

  test("--continue errors when no conflict in progress", () => {
    const { B } = setupFourCommits();

    // Start edit but no conflict
    zagi(["edit", B.slice(0, 7)], { cwd: REPO_DIR });

    const result = zagi(["edit", "--continue"], { cwd: REPO_DIR });

    expect(result).toContain("no conflict");
    expect(result).toContain("--back");
  });

  test("--abort works during conflict", () => {
    // Create commits that will conflict
    writeFileSync(resolve(REPO_DIR, "README.md"), "# Test B\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "-m", "Modify README"], { cwd: REPO_DIR });
    const originalHead = git(["rev-parse", "HEAD"], { cwd: REPO_DIR }).trim();

    // Start edit at initial commit
    zagi(["edit", "HEAD~1"], { cwd: REPO_DIR });

    // Create conflicting change
    writeFileSync(resolve(REPO_DIR, "README.md"), "# Test CONFLICT\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "--amend", "--no-edit"], { cwd: REPO_DIR });

    // Trigger conflict
    zagi(["edit", "--back"], { cwd: REPO_DIR });

    // Abort during conflict
    const result = zagi(["edit", "--abort"], { cwd: REPO_DIR });

    expect(result).toContain("edit: aborted");
    expect(result).toContain("restored:");

    // Verify HEAD is back to original
    const currentHead = git(["rev-parse", "HEAD"], { cwd: REPO_DIR }).trim();
    expect(currentHead).toBe(originalHead);

    // Verify we're back on main
    const branch = git(["rev-parse", "--abbrev-ref", "HEAD"], {
      cwd: REPO_DIR,
    }).trim();
    expect(branch).toBe("main");
  });

  test("edit state is cleared after aborting during conflict", () => {
    // Create commits that will conflict
    writeFileSync(resolve(REPO_DIR, "README.md"), "# Test B\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "-m", "Modify README"], { cwd: REPO_DIR });

    // Start edit and create conflict
    zagi(["edit", "HEAD~1"], { cwd: REPO_DIR });
    writeFileSync(resolve(REPO_DIR, "README.md"), "# Test CONFLICT\n");
    git(["add", "."], { cwd: REPO_DIR });
    git(["commit", "--amend", "--no-edit"], { cwd: REPO_DIR });
    zagi(["edit", "--back"], { cwd: REPO_DIR });

    // Abort
    zagi(["edit", "--abort"], { cwd: REPO_DIR });

    // Verify state is cleared
    const status = zagi(["edit", "--status"], { cwd: REPO_DIR });
    expect(status).toBe("edit: not active\n");

    // Should be able to start a new edit
    const result = zagi(["edit", "HEAD~0"], { cwd: REPO_DIR });
    expect(result).toContain("edit:");
  });
});

describe("git edit - detached HEAD errors", () => {
  test("errors when starting edit from detached HEAD", () => {
    const { B } = setupFourCommits();

    // Detach HEAD
    git(["checkout", "--detach", "HEAD"], { cwd: REPO_DIR });

    const result = zagi(["edit", B.slice(0, 7)], { cwd: REPO_DIR });

    expect(result).toContain("detached");
  });
});

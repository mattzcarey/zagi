import { execFileSync } from "child_process";
import { existsSync, mkdirSync, writeFileSync, rmSync, readFileSync } from "fs";
import { resolve } from "path";

const FIXTURES_BASE = resolve(__dirname, "repos");
const COMMIT_COUNT = 100;

// Generate unique IDs for parallel safety
function uid() {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 11)}`;
}

function gitIn(repoDir: string, ...args: string[]) {
  execFileSync("git", args, { cwd: repoDir, stdio: "pipe" });
}

/**
 * Creates a new isolated fixture repo and returns its path.
 * Each call creates a fresh repo with unique ID.
 */
export function createFixtureRepo(): string {
  const repoId = `repo-${uid()}`;
  const repoDir = resolve(FIXTURES_BASE, repoId);

  // Ensure base directory exists
  mkdirSync(FIXTURES_BASE, { recursive: true });

  // Clean up if exists (shouldn't happen with unique IDs but just in case)
  if (existsSync(repoDir)) {
    rmSync(repoDir, { recursive: true });
  }

  // Create directory
  mkdirSync(repoDir, { recursive: true });

  // Initialize git repo
  gitIn(repoDir, "init");
  gitIn(repoDir, "config", "user.email", "test@example.com");
  gitIn(repoDir, "config", "user.name", "Test User");

  // Create initial structure
  mkdirSync(resolve(repoDir, "src"));
  mkdirSync(resolve(repoDir, "tests"));
  mkdirSync(resolve(repoDir, "docs"));

  writeFileSync(
    resolve(repoDir, "README.md"),
    "# Test Repository\n\nThis is a fixture for benchmarking.\n"
  );

  writeFileSync(
    resolve(repoDir, "src/main.ts"),
    'export function main() {\n  console.log("hello");\n}\n'
  );

  writeFileSync(
    resolve(repoDir, "src/utils.ts"),
    "export function add(a: number, b: number) {\n  return a + b;\n}\n"
  );

  writeFileSync(
    resolve(repoDir, "tests/main.test.ts"),
    'import { main } from "../src/main";\n\ntest("main runs", () => {\n  main();\n});\n'
  );

  // Initial commit
  gitIn(repoDir, "add", ".");
  gitIn(repoDir, "commit", "-m", "Initial commit");

  // Generate commits with varied content
  const actions = [
    "Add",
    "Update",
    "Fix",
    "Refactor",
    "Improve",
    "Implement",
    "Remove",
    "Clean up",
  ];
  const subjects = [
    "user authentication",
    "database connection",
    "API endpoints",
    "error handling",
    "logging system",
    "caching layer",
    "input validation",
    "unit tests",
    "documentation",
    "configuration",
  ];

  for (let i = 1; i < COMMIT_COUNT; i++) {
    const action = actions[i % actions.length];
    const subject = subjects[i % subjects.length];
    const message = `${action} ${subject}`;

    // Modify a file
    const files = ["src/main.ts", "src/utils.ts", "README.md"];
    const fileNum = i % files.length;
    const filePath = resolve(repoDir, files[fileNum]!);

    const content =
      existsSync(filePath) && fileNum !== 2
        ? `// Change ${i}\n` +
          readFileSync(filePath, "utf-8") +
          `\n// End change ${i}\n`
        : `# Test Repository\n\nChange ${i}\n`;

    writeFileSync(filePath, content);
    gitIn(repoDir, "add", ".");
    gitIn(repoDir, "commit", "-m", message);
  }

  // Create some uncommitted changes for status tests
  writeFileSync(resolve(repoDir, "src/new-file.ts"), "// New file\n");
  writeFileSync(
    resolve(repoDir, "src/main.ts"),
    readFileSync(resolve(repoDir, "src/main.ts"), "utf-8") + "\n// Modified\n"
  );

  return repoDir;
}

/**
 * Cleans up all fixture repos
 */
export function cleanupFixtures() {
  if (existsSync(FIXTURES_BASE)) {
    rmSync(FIXTURES_BASE, { recursive: true });
  }
}
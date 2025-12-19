import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/**/*.test.ts"],
    globalSetup: "./globalSetup.ts",
    globalTeardown: "./globalTeardown.ts",
    benchmark: {
      include: ["src/**/*.bench.ts"],
    },
  },
});

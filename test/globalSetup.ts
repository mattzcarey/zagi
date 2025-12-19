import { cleanupFixtures } from "./fixtures/setup";

export default function () {
  // Clean up any leftover fixtures from previous runs
  cleanupFixtures();
}

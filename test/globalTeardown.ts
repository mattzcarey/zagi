import { cleanupFixtures } from "./fixtures/setup";

export default function () {
  // Clean up all fixtures after tests complete
  cleanupFixtures();
}

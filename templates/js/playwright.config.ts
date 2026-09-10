// Copied into the target project only after Tier 1 detection confirms
// @playwright/test is already installed. This framework never runs
// `npm install` on your behalf — if this file is here, you (or your own
// tooling) put the dependency there first.
import { defineConfig } from '@playwright/test';
import { readFileSync } from 'node:fs';

// base_url lives in tests/credentials.json, never in this file, so the
// same config works against every environment a role's session was
// captured for.
const creds = JSON.parse(readFileSync('tests/credentials.json', 'utf8'));

export default defineConfig({
  testDir: 'tests/specs',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: [
    ['list'],
    // JUnit XML is what makes Tier 2 possible: junit-to-csv.mjs reads this
    // file and writes the results CSV without any model involvement.
    ['junit', { outputFile: 'tests/results/junit.xml' }],
  ],
  use: {
    baseURL: creds.base_url,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
});

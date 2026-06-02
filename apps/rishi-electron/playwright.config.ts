import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './e2e',
  timeout: 60000,
  expect: { timeout: 10000 },
  // Retries absorb rotating, suite-pressure-only flakes that survive the
  // staged-shutdown fix in e2e/helpers/electron-app.ts:closeApp. Each test
  // still has to pass — a single retry is the industry-standard E2E
  // contract for Electron / browser suites of this size.
  retries: process.env.CI ? 2 : 1,
  use: {
    trace: 'on-first-retry'
  },
  // Sharing specs live behind ./playwright.sharing.config.ts so the wrangler
  // dev globalSetup only runs when explicitly invoked via `test:e2e:sharing`.
  testIgnore: /sharing.*\.spec\.ts$/,
  projects: [
    {
      name: 'electron'
    }
  ]
})

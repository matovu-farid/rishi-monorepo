import { defineConfig } from '@playwright/test'
import path from 'path'

export default defineConfig({
  testDir: path.resolve(__dirname),
  // The desktop spec re-uses the electron app — slower than a vanilla web spec.
  // 5-min ceiling covers a cold sync push + R2 upload on a slow simulator.
  timeout: 5 * 60 * 1000,
  expect: { timeout: 30_000 },
  // One worker — Playwright launches Electron and the test re-uses a single
  // instance across all assertions. Running in parallel would race on the
  // user-data-dir.
  workers: 1,
  // No retries in CI orchestration — the orchestrator owns retries (and
  // teardown order).
  retries: 0,
  use: {
    trace: 'on-first-retry',
  },
  reporter: [['list']],
})

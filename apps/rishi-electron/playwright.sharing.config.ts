import { defineConfig } from '@playwright/test'
import path from 'path'

export default defineConfig({
  testDir: './e2e',
  testMatch: /sharing.*\.spec\.ts$/,
  timeout: 120_000,
  expect: { timeout: 15_000 },
  globalSetup: path.resolve(__dirname, 'e2e/global-setup-sharing.ts'),
  globalTeardown: path.resolve(__dirname, 'e2e/global-teardown-sharing.ts'),
  use: {
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure'
  },
  projects: [
    {
      name: 'sharing'
    }
  ]
})

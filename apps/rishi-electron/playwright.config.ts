import { defineConfig } from '@playwright/test'
import path from 'path'

export default defineConfig({
  testDir: './e2e',
  timeout: 60000,
  expect: { timeout: 10000 },
  use: {
    trace: 'on-first-retry'
  },
  projects: [
    {
      name: 'electron',
      testMatch: /^(?!.*sharing).*\.spec\.ts$/
    },
    {
      name: 'sharing',
      testMatch: /sharing.*\.spec\.ts$/,
      timeout: 120_000,
      expect: { timeout: 15_000 },
      globalSetup: path.resolve(__dirname, 'e2e/global-setup-sharing.ts'),
      globalTeardown: path.resolve(__dirname, 'e2e/global-teardown-sharing.ts')
    }
  ]
})

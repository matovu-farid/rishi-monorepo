/**
 * Jest configuration for Detox end-to-end tests.
 *
 * IMPORTANT: this is a separate Jest config from `<rootDir>/../jest.config.js`,
 * which runs the 74 unit tests in `__tests__/`. Detox needs `jest-circus`
 * as the test runner and a long per-test timeout because it drives a real
 * iOS Simulator. Do NOT merge these configs.
 */
/** @type {import('jest').Config} */
module.exports = {
  rootDir: '..',
  testMatch: ['<rootDir>/e2e/**/*.test.ts', '<rootDir>/e2e/**/*.test.js'],
  testTimeout: 120000,
  maxWorkers: 1,
  globalSetup: 'detox/runners/jest/globalSetup',
  globalTeardown: 'detox/runners/jest/globalTeardown',
  reporters: ['detox/runners/jest/reporter'],
  testEnvironment: 'detox/runners/jest/testEnvironment',
  setupFilesAfterEnv: ['<rootDir>/e2e/setup.ts'],
  verbose: true,
  transform: {
    '^.+\\.tsx?$': [
      'ts-jest',
      {
        // Keep diagnostics off so unrelated app-side type issues don't
        // break the e2e harness. The smoke test surface is tiny and
        // self-contained.
        diagnostics: false,
      },
    ],
  },
};

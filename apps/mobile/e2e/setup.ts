/**
 * Detox per-suite setup. Runs once per worker after `jest-circus` has
 * loaded the test framework but BEFORE individual `test(...)` blocks
 * execute. The Detox environment (`detox/runners/jest/testEnvironment`)
 * has already called `detox.init()` by this point — see
 * `e2e/jest.config.js`.
 *
 * Use this file for lightweight cross-test helpers only. Heavy fixtures
 * belong in dedicated helper modules under `e2e/helpers/`.
 */
import { beforeAll } from '@jest/globals';

beforeAll(async () => {
  // Cold-launch the app fresh for the first test in this worker.
  // `device` is provided as a global by the Detox jest environment.
  await device.launchApp({
    newInstance: true,
    launchArgs: {
      // Mirror the configuration in `.detoxrc.js` so the app boots in
      // E2E mode even on subsequent relaunches inside a single test.
      EXPO_PUBLIC_E2E_TEST: 'true',
    },
  });
});

export type {
  AssertionResult,
  IpcLogEntry,
  DomSnapshot,
  CyConfig,
  MatcherFn,
} from "./types.js";

export { cy } from "./cy.js";
export { createTestRunner } from "./runner.js";
export { matcherRegistry } from "./assertions/matchers.js";

import { matcherRegistry } from "./assertions/matchers.js";
import { createTestRunner } from "./runner.js";

const defaultRunner = createTestRunner();

export const describe = defaultRunner.describe;
export const it = defaultRunner.it;
export const beforeEach = defaultRunner.beforeEach;
export const afterEach = defaultRunner.afterEach;

/**
 * Register a custom assertion matcher.
 *
 * Usage:
 *   addCustomMatcher('have.data', (subject, key, value) => {
 *     const el = subject as HTMLElement;
 *     const actual = el.dataset[key as string];
 *     return {
 *       passed: value === undefined ? actual !== undefined : actual === value,
 *       actual,
 *       expected: value ?? 'data-' + key + ' to exist',
 *     };
 *   });
 */
export function addCustomMatcher(
  name: string,
  fn: (subject: unknown, ...args: unknown[]) => {
    passed: boolean;
    actual: unknown;
    expected: unknown;
  }
): void {
  matcherRegistry.set(name, fn);
}

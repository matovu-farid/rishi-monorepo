import type { AssertionResult } from "../types.js";
import { applyMatcher } from "./matchers.js";
import { retry } from "../retry.js";

/**
 * Evaluates a `.should(matcher, ...args)` assertion with retry.
 *
 * `queryFn` re-runs the preceding query command to get a fresh subject.
 * The matcher is applied to the result. If it fails, retry kicks in
 * and re-runs both the query and assertion.
 */
export async function evaluateShould(
  queryFn: () => unknown | Promise<unknown>,
  matcher: string,
  args: unknown[],
  timeout: number
): Promise<{ subject: unknown; assertion: AssertionResult }> {
  let lastSubject: unknown;

  const result = await retry(
    async () => {
      lastSubject = await queryFn();
      const matchResult = applyMatcher(matcher, lastSubject, ...args);
      if (!matchResult.passed) {
        throw new Error(
          `Expected to ${matcher}` +
            (args.length > 0 ? ` ${JSON.stringify(args[0])}` : "") +
            ` but got ${JSON.stringify(matchResult.actual)}`
        );
      }
      return matchResult;
    },
    { timeout, interval: 50 }
  );

  return {
    subject: lastSubject,
    assertion: {
      description: `expected to ${matcher}` +
        (args.length > 0 ? ` ${JSON.stringify(args[0])}` : ""),
      passed: result.passed,
      expected: result.expected,
      actual: result.actual,
    },
  };
}

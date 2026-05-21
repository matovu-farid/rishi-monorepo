/**
 * Jest setup — set the React act-environment flag so react-test-renderer
 * stops printing warnings about updates not being wrapped in `act(...)`.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
;(globalThis as any).IS_REACT_ACT_ENVIRONMENT = true

/**
 * Suppress the package-level `react-test-renderer is deprecated` console.error
 * spam.
 *
 * Why we keep using react-test-renderer:
 *   - This project runs jest in `testEnvironment: 'node'` (see jest.config.js)
 *     and does NOT use the `jest-expo` preset. RNTL (@testing-library/react-native)
 *     ALSO depends on react-test-renderer under the hood, so swapping to RNTL
 *     wouldn't silence the warning either — RTR is unavoidable on this stack.
 *   - The actual `act` API used in tests is now imported from `react` (the
 *     non-deprecated source); only RTR's `create()` / `unmount()` host
 *     wrappers still emit the package-level deprecation banner.
 *   - React 19 ships a replacement (`@testing-library/react`) but it targets
 *     DOM hosts; there's no first-party RN replacement yet.
 *
 * The filter is intentionally narrow: it ONLY drops the specific deprecation
 * banner. Any other console.error keeps flowing so real test failures are
 * still visible. Documented in .parity/BATCH-9-NOTES.md.
 */
const originalConsoleError = console.error
const RTR_DEPRECATION_MARKER = 'react-test-renderer is deprecated'
console.error = (...args: unknown[]) => {
  if (
    typeof args[0] === 'string' &&
    args[0].includes(RTR_DEPRECATION_MARKER)
  ) {
    return
  }
  originalConsoleError(...args)
}

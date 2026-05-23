/**
 * Single source of truth for the worker (sync server) base URL.
 *
 * Production default is `https://api.fidexa.org`. End-to-end tests (Playwright,
 * cross-platform-sync) override this at build time via `VITE_WORKER_URL` so the
 * renderer talks to a local `wrangler dev` instance or a staging environment.
 *
 * Why a single export (and not multiple per-module constants):
 *   - Until 2026-05-22 this URL was hard-coded in seven separate renderer
 *     modules. The cross-platform sync test needs to point them all at a test
 *     worker simultaneously; centralising here lets the test flip one env var.
 *
 * Why also exposed on `window.__RISHI_WORKER_URL__`:
 *   - Playwright cannot read the renderer's `import.meta.env` directly, but it
 *     can `page.evaluate(() => window.__RISHI_WORKER_URL__)` to assert that the
 *     override actually took effect inside the built bundle. This is a
 *     read-only diagnostic — production builds also set it; the value is the
 *     same string the renderer would have used anyway.
 *
 * The main process still reads its own `RISHI_API_URL` env var
 * (`src/main/auth/auth-service.ts`); that override is independent because the
 * main and renderer processes don't share a vite build.
 */
export const WORKER_URL: string =
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- import.meta.env shape is augmented in vite-env.d.ts; cast keeps this file framework-agnostic for vitest.
  ((import.meta as any)?.env?.VITE_WORKER_URL as string | undefined) ?? 'https://api.fidexa.org'

// Side-effect: expose to the window for E2E assertions. Guarded so this module
// stays importable in node-side vitest contexts where `window` is undefined.
if (typeof window !== 'undefined') {
  ;(window as unknown as { __RISHI_WORKER_URL__?: string }).__RISHI_WORKER_URL__ = WORKER_URL
}

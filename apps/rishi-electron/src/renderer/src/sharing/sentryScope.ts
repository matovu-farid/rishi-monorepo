/**
 * Sharing-feature Sentry scope helpers.
 *
 * The shared-reading rollout runbook (`workers/sharing-worker/logpush/`)
 * monitors via Sentry with `tag: feature=sharing`, plus breadcrumbs for
 * `sharing.ice_failed` and the `actor=fileTransferActor` tag. This module
 * wires those up.
 *
 * Design notes:
 * - The existing project Sentry init in `src/renderer/src/utils/sentry.ts`
 *   skips `Sentry.init` in dev (it guards on `import.meta.env.PROD`). All
 *   helpers here therefore have to be defensive: if Sentry isn't initialized
 *   the SDK still exports `withScope`/`addBreadcrumb`/`captureException` as
 *   no-ops, but we additionally wrap every call in a try/catch so a SDK
 *   regression or hot-reload race can't take the sharing actors down.
 * - We import the same `@sentry/electron/renderer` entry point the rest of
 *   the renderer already depends on. No new SDK dependency.
 */
import * as Sentry from '@sentry/electron/renderer'

const SHARING_TAG_KEY = 'feature'
const SHARING_TAG_VALUE = 'sharing'

function safe(fn: () => void): void {
  try {
    fn()
  } catch {
    /* Sentry must never crash the app — silent no-op. */
  }
}

/**
 * Run `cb` inside a Sentry scope tagged `feature=sharing` plus any extra
 * tags supplied. Returns whatever `cb` returns. If the SDK throws while
 * setting up the scope, falls back to invoking `cb` directly so callers
 * always see the original return value.
 */
export function withSharingScope<T>(
  cb: () => T,
  extras?: { tags?: Record<string, string>; extras?: Record<string, unknown> }
): T {
  let result!: T
  let captured = false
  try {
    Sentry.withScope((scope) => {
      scope.setTag(SHARING_TAG_KEY, SHARING_TAG_VALUE)
      if (extras?.tags) for (const [k, v] of Object.entries(extras.tags)) scope.setTag(k, v)
      if (extras?.extras) scope.setExtras(extras.extras)
      result = cb()
      captured = true
    })
  } catch {
    /* fall through */
  }
  if (!captured) result = cb()
  return result
}

/**
 * Capture an error with the `feature=sharing` tag. Optional `extras` are
 * attached via `scope.setExtras` and any `actor` extra is also lifted to a
 * tag so it shows up in the Sentry sidebar (matches the runbook's
 * `actor=fileTransferActor` query).
 */
export function recordSharingError(error: unknown, extras?: Record<string, unknown>): void {
  const err = error instanceof Error ? error : new Error(String(error))
  safe(() => {
    Sentry.withScope((scope) => {
      scope.setTag(SHARING_TAG_KEY, SHARING_TAG_VALUE)
      if (extras) {
        scope.setExtras(extras)
        if (typeof extras.actor === 'string') scope.setTag('actor', extras.actor)
      }
      Sentry.captureException(err)
    })
  })
}

/**
 * Drop a sharing-category breadcrumb. Matches the names the rollout runbook
 * expects (`sharing.ice_failed`, `signaling.opened`, etc.). Breadcrumbs are
 * attached to the next captured event automatically by Sentry.
 */
export function recordSharingBreadcrumb(name: string, data?: Record<string, unknown>): void {
  safe(() => {
    Sentry.addBreadcrumb({
      category: 'sharing',
      message: name,
      data,
      level: 'info'
    })
  })
}

/**
 * Pin `feature=sharing` on the global scope for the duration of an active
 * session. Called from sessionMachine entry/exit hooks. Defensive — if
 * `configureScope` is missing (older SDKs) we fall back to a no-op scope
 * via `withScope`.
 */
export function setSharingFeatureTag(): void {
  safe(() => {
    const cfg = (Sentry as unknown as {
      configureScope?: (cb: (s: { setTag: (k: string, v: string) => void }) => void) => void
    }).configureScope
    if (typeof cfg === 'function') {
      cfg((scope) => scope.setTag(SHARING_TAG_KEY, SHARING_TAG_VALUE))
      return
    }
    // Fallback: getCurrentScope on newer SDKs (v8+).
    const getCurrent = (Sentry as unknown as {
      getCurrentScope?: () => { setTag: (k: string, v: string) => void }
    }).getCurrentScope
    if (typeof getCurrent === 'function') {
      getCurrent().setTag(SHARING_TAG_KEY, SHARING_TAG_VALUE)
    }
  })
}

export function clearSharingFeatureTag(): void {
  safe(() => {
    const cfg = (Sentry as unknown as {
      configureScope?: (
        cb: (s: { setTag: (k: string, v: string | undefined) => void }) => void
      ) => void
    }).configureScope
    if (typeof cfg === 'function') {
      cfg((scope) => scope.setTag(SHARING_TAG_KEY, undefined))
      return
    }
    const getCurrent = (Sentry as unknown as {
      getCurrentScope?: () => { setTag: (k: string, v: string | undefined) => void }
    }).getCurrentScope
    if (typeof getCurrent === 'function') {
      getCurrent().setTag(SHARING_TAG_KEY, undefined)
    }
  })
}

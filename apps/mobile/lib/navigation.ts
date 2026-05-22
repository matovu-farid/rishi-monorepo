/**
 * Safe-back navigation helper (P1-B).
 *
 * Deep-link cold-start into `/reader/[id]`, `/reader/pdf/[id]`,
 * `/reader/mobi/[id]`, `/reader/djvu/[id]`, or `/chat/[bookId]` leaves the
 * navigation stack empty. An unguarded `router.back()` then strands the
 * user on a blank screen.
 *
 * `safeBack` mirrors the pattern already used on the reader error screen
 * (commit 37d773ed): pop if possible, otherwise replace to the tabs root.
 *
 * Typed against a structural subset of expo-router's `Router` so it stays
 * easy to unit-test without pulling in the full expo-router module (which
 * brings in React Navigation + its native deps). `replace` is typed loosely
 * (`unknown`) because expo-router uses a templated `Href` that's awkward to
 * mirror — the actual call site passes a literal string we control.
 */

export interface SafeBackRouter {
  canGoBack: () => boolean
  back: () => void
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  replace: (href: any) => void
}

export function safeBack(
  router: SafeBackRouter,
  fallback: string = '/(tabs)',
): void {
  if (router.canGoBack()) {
    router.back()
    return
  }
  router.replace(fallback)
}

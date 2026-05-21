# Practices Audit — Tester B-T7 (TTS / AI-Chat)

## 1. Arbitrary `waitForTimeout` as test oracle (B095)
- `tts-page-navigation.spec.ts:646` — `waitForTimeout(300)`
- `tts-page-navigation.spec.ts:1010` — `waitForTimeout(6000)` in
  T1 (BUG-marked)
- `tts-page-navigation.spec.ts:1194` — `waitForTimeout(2000)` in
  T2 (BUG-marked)
- All three should be replaced with `expect.poll` / `waitForFunction` on
  the observable the test actually cares about. Static waits mask races
  and bloat wall-clock. See B095.

## 2. `test.skip(true, ...)` inside test bodies (B099)
- `read-aloud-from-selection.spec.ts` L97, L165, L231 — soft-skips on
  fixture races. Promotes flake into green. Promote each precondition to
  an assertion (or extend the wait helpers) so a fixture-readiness gap
  fails loudly.

## 3. Length-only assertions on TTS log (B100)
- `read-aloud-from-selection.spec.ts:142, 269` —
  `expect(log.length).toBeGreaterThan(0)`. A request for the wrong CFI
  would still pass. Assert `log.some((r) => r.cfiRange === <expected>)`
  using the same pattern as
  `tts-page-navigation.spec.ts:700, 750-752, 938`.

## 4. Inline WAV byte arrays duplicated across tests
- `tts-page-navigation.spec.ts:95-99`, `173-193`, etc. Six tests
  hand-build RIFF headers inline; others import `installSilentMockTts`
  from `helpers/player-helpers`. Two patterns for one concern. Extract
  the inline WAVs into a `helpers/wav-fixtures.ts` so a fixture-format
  change (e.g., sample-rate bump) requires one edit, not six.

## 5. CSS-style assertions on implementation details
- `tts.spec.ts:43` — `await expect(orb).toHaveCSS('position', 'fixed')`.
  Tests the positioning *strategy*, not the user-visible "orb is in the
  bottom-right of the viewport". A future Flexbox/Grid refactor that
  keeps the orb in the same screen position would fail this test for no
  user-visible reason. Replace with a `boundingBox()` assertion against
  the viewport's bottom-right quadrant.

## 6. `.first()` on aria-label selectors masks DOM ambiguity
- `ai-chat.spec.ts:42, 48, 51, 55, 57, 64` and elsewhere —
  `[aria-label="Start voice chat"]`.first() / `text=Sign in`.first() /
  `text=Maybe later`.first(). The `.first()` modifier suggests multiple
  matching nodes; a regression that removes the user-clickable one but
  leaves the portal-rendered duplicate would keep the test green. Prefer
  a more specific selector (scoped via `dialog-content`,
  `data-testid="..."`, or `getByRole(...)`).

## 7. `text=Sign in` / `text=Maybe later` are localization-fragile
- `ai-chat.spec.ts:51, 57` and `tts.spec.ts:63-64`. If i18n lands, these
  break. Migrate to `getByRole('button', { name: /sign in/i })` or a
  test-id. Low urgency given the codebase is currently single-locale.

## 8. `installMockTts` cleanup not enforced
- Several tests in `tts-page-navigation.spec.ts` call
  `setTestTtsService(null)` in teardown (e.g., L137-139, L668-671,
  L754-759); not all do (verify via grep). Missing teardown leaks the
  mock across tests in the same window. Each test currently imports a
  fresh book and opens a fresh window per the L23-25 comment — confirm
  this is actually the case in all 12 tests; if any reuse the window,
  teardown is mandatory.

## 9. `audioElement.pause` monkey-patch leaks
- `tts-page-navigation.spec.ts:90-94` replaces `audioElement.pause` for
  the duration of one test. If the window is reused, the patch leaks.
  Same fix as #8: per-window isolation + explicit restore in teardown.

## 10. Hardcoded auth bypass via `authStore.setState`
- `read-aloud-from-selection.spec.ts:70-81` — fine and documented for
  this spec, but no other spec should adopt the same bypass without
  knowing about this. Add a helper (e.g.,
  `helpers/auth.ts: injectFakeAuthUser(page)`) so the bypass is in one
  place.

## 11. `tts.spec.ts` shares `bookPage` across tests via outer scope
- L33-39: `bookPage` is assigned in `beforeEach` but the orb / dialog
  state from a previous test can leak if `closeOverlays` is incomplete.
  The `Stop is disabled` test (L54) is order-coupled with `Play without
  auth opens premium dialog` (L59). Recommend per-test fresh windows or
  an explicit "player is in stopped state" precondition assertion.

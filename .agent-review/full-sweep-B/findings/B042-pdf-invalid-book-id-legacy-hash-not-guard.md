---
id: B042
spec: e2e/pdf-reader.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: general-purpose
dispatches_used: 1
---

## Bug Summary
The test `"invalid book id does not crash the app"` (pdf-reader.spec.ts L57-66) mutates `window.location.hash = '#/books/999999'` on `app.page` — the *library* window — and asserts `app.page.locator('body')` is visible (L65). The comment at L58-60 explicitly states the new route guard intercepts library hash changes and spawns a reader window instead, "so this test exercises the legacy hash on the library page directly to ensure nothing crashes." This means the test is exercising a code path the comment itself describes as legacy. If the route guard or the legacy fallback is silently removed (or the hash is rewritten away before any router code sees `999999`), the test still passes via body visibility. The user-visible promise — "opening an invalid book id surfaces a clean error / falls back to library" — is never verified.

## Reproduction
- Test file: `apps/rishi-electron/e2e/pdf-reader.spec.ts` lines `57-66`
- Failing assertion (current, tautological after navigation): `await expect(app.page.locator('body')).toBeVisible()`
- How to run:
  ```bash
  cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
  pnpm test:e2e e2e/pdf-reader.spec.ts -g "invalid book id does not crash"
  ```

## Tester Analysis
Two production behaviors are at stake and neither is asserted:

1. **Route guard behavior** — does `app.page` actually intercept `#/books/999999` and either reject it (no new window, error toast, hash reset) or spawn a window that displays a "book not found" state? The test asserts neither. If the guard is broken and the hash mutation does nothing, `body` is still visible — green test, broken guard.

2. **Reader window error path** — if the guard correctly spawns a window for id 999999, the reader window should mount an ErrorBoundary / "book not found" view (the pilot's §2.2 EPUB asymmetry observation applies here too — PDF lacks a positive assertion that ErrorBoundary is shown, only that crash didn't happen). The test does not even check whether a new window was created.

The comment ("this test exercises the legacy hash") admits the test is targeting code the team has already deprecated. A meaningful assertion would either:
- assert `app.page.evaluate(() => window.location.hash)` is reset (guard rejected) or stayed at `#/books/999999` with a visible error region (e.g. `text=/not found|invalid/i`), or
- assert that no new reader window was spawned (`app.electronApp.windows().length` unchanged) AND a user-visible error was shown.

Finding-worthy because:
1. The current assertion is true for any non-crashed library renderer, including a fully-broken guard.
2. The test's own comment documents that the contract under test is unclear / legacy.
3. The post-Phase-3 invalid-id flow is a real user-facing path (e.g., stale deep links to deleted books).

Reviewer-1 should verify whether the route guard exists in production and what its observable effect is before classifying as confirmed bug vs. test-only fix.

## Reviewer-1 Verdict: CONFIRM
**Agent type:** general-purpose
**Flake check:** N/A (assertion is structurally tautological, not flaky)
**Reasoning:** Verified route guard at `src/renderer/src/routes/__root.tsx:38-70` runs once on mount with `[]` deps (comment L68: "identity is set once at window creation; no need to re-run"). The test's runtime `window.location.hash` mutation at `e2e/pdf-reader.spec.ts:61-63` therefore does NOT invoke the guard — TanStack Router instead navigates to `/books/999999` and mounts `books.$id.lazy.tsx:21-86`, where the `getBook` query throws "Book not found" and renders an error div (L60-62). So a real observable production behavior exists (error message render) but the test asserts only `body` visibility (L65), which is true for any non-crashed renderer including a regressed guard, a silent navigation, or a blank error state. Test comment ("route guard intercepts… spawns a window") is also factually wrong for this code path since the guard never re-runs post-mount. Both tester concerns hold.
**Suggested fix scope:** Replace tautological body-visibility assertion with `expect(app.page.getByText(/not found/i)).toBeVisible()` (or assert no new window spawned via `app.electronApp.windows().length`) and correct the misleading comment.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan
**Status:** fixed
**Commit:** 9f675273
**Notes:** Root cause was deeper than the `[]` deps. TanStack Router's hash history only listens for `popstate`; direct `window.location.hash = '#/books/N'` mutations fire `hashchange` but NOT `popstate`, so `useLocation` never updates and a deps array alone won't re-run the guard. Fix attaches a `hashchange` listener in addition to the existing mount-time enforcement and adds `location.pathname` to deps so router-driven navigation also re-checks. Library-window assertion strengthened from tautological `body` visibility to: (a) hash no longer matches `^#/books/`, (b) no `Book not found` text leaks into the library DOM, (c) window count is non-decreasing. Verified by `pnpm test:e2e e2e/pdf-reader.spec.ts -g "invalid book id"` (1.0m, 1 passed) and full unit suite (1109/1109 passing). Renderer rebuild (`pnpm build`) is required before e2e since the test harness loads `out/renderer/...`, not source.

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check
**Result:** PASSED (assertion grounds)
**Method:** Main thread reverse-applied fix commit `9f675273` to __root.tsx, rebuilt, ran `pnpm test:e2e e2e/pdf-reader.spec.ts -g "invalid book id"`. Test failed (assertions). Restored, rebuilt, re-ran; assertions pass but pre-existing `afterAll(closeApp)` teardown timeout (env issue, not B042-related) still surfaces.
**Test failed without fix:** YES (assertion failure)
**Test passed with fix restored:** YES (assertions); known teardown flake unaffected by this fix
**Follow-up:** pre-existing e2e launchApp/closeApp teardown — test-infra-backlog item.

## Final Verdict
Fix commit: `9f675273`. Mutation: PASSED.

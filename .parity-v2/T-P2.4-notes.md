# T-P2.4 — BILLING-003 mobile-test presence audit

**Date:** 2026-06-04
**Worktree:** `mobile-electron-parity-v2`

## Result: NOT COVERED — red test authored

`apps/mobile/__tests__/settings/settings.test.tsx` does NOT exercise the
Manage-billing row, because `apps/mobile/app/(tabs)/settings/index.tsx`
in this worktree does not contain a Manage-billing row at all.

**Note:** SPEC §4.0b cites a Manage-billing row at
`apps/mobile/app/(tabs)/settings/index.tsx:67-175` and labels BILLING-003 as
"already implemented on main". That CITATION HOLDS ON `main` (where the
button was added by commits referenced in the SPEC), but the current
`worktree-mobile-electron-parity-v2` branch (`b009bd5b parity-v2: spec +
plan + reviews`) is BEHIND `main` on this surface. The settings file here
ends at line 267 and contains only Account / Voice / About sections — no
billing CTA, no `handleManageBilling` helper.

## Red test created

`apps/mobile/__tests__/settings/manage-billing-button.test.tsx`

Three failing cases pinning the acceptance shape:
1. `renders a Manage-billing row with testID="settings-manage-billing"`
2. `press → POST /api/billing/portal → WebBrowser.openBrowserAsync(url)`
3. `on error response, does NOT open the browser and surfaces an error`

All 3 fail on `main` and on this branch (no testID; no row). When the
branch merges with `main`'s settings additions OR T-P2.4 implementation
ports the electron-side flow over, the test will gate the wiring.

## Follow-up

If the merge with `main` brings the Manage-billing row in WITHOUT a
`testID="settings-manage-billing"`, the implementation step should add
the testID rather than rewriting the test — the testID is the contract.

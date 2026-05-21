# Parity Gaps — Tester B-T4 (PDF Scroll Specs)

Scope: `e2e/pdf-scroll-position.spec.ts`, `e2e/pdf-scroll-up-jitter.spec.ts`.

## Gaps tracked as findings (production bug surface)

- B046 — restore tolerance ±450px masks partial page-snap regression.
- B047 — restore path never asserts the displayed page index; right-pixel
  wrong-page bug slips through.
- B051 — jitter spec lacks a precondition that pages above were
  actually unmounted before scrolling back up; silently stops testing
  the remount path if overscan/fixture changes.
- B052 — 600ms sample window shorter than the spec's own 2500ms
  render-settle wait; late-frame jitter invisible.
- B053 — 80px jitter threshold leaves regression headroom; original bug
  magnitude likely >80px so a partial regression would pass.

## Gaps NOT escalated to findings (out of cap / lower severity)

- `pdf-scroll-position.spec.ts` L49 regex `/^\d+:\d+/` couples the test
  to the literal "page:offset" wire format. Confirmed against
  `apps/rishi-electron/src/main/ipc/books.ts:65`
  (`books:updateLocation`) — IPC accepts opaque `location` string, so
  the format is owned by the renderer write side. If the format were
  ever migrated (e.g. JSON), this would silently fail. Parity gap, not
  a bug today.
- Both specs select the scroll container via structural CSS
  (`div.overflow-y-scroll`). No `data-testid`. A DOM refactor breaks
  both silently and the failure mode is "no scroll container" — a
  testing-infra concern routed below.
- Neither spec asserts that the `expect.poll`-able reader-ready signal
  exists. They use fixed `waitForTimeout` for cold open, mid-test
  settle, close, and reopen.
- Per-test launch/close with tmp userDataDir is correct isolation;
  no parity gap there.

## Production cross-checks performed

- Verified `books:updateLocation` IPC entry in
  `apps/rishi-electron/src/main/ipc/books.ts:65`. Did not deep-dive the
  pdfStore debounce constants (80ms listener / 400ms persist) cited in
  the spec comment — would have exceeded tool budget; flagged in
  practices audit instead.

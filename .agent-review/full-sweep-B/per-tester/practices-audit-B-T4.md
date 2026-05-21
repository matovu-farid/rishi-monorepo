# Practices Audit — Tester B-T4 (PDF Scroll Specs)

## Arbitrary `waitForTimeout` durations

| Spec | Line | Wait | Why brittle |
|------|------|------|-------------|
| `pdf-scroll-position.spec.ts` | 31 | 3000ms | Cold open settle. CPU / PDF.js worker init dependent. Replace with `expect.poll` on first `canvas.react-pdf__Page__canvas` visible. |
| `pdf-scroll-position.spec.ts` | 44 | 1500ms | Comment says "scroll listener (80ms) + persist debounce (400ms) + IPC margin". Two load-bearing constants buried in renderer code; if either drifts, this silently breaks. Replace with `expect.poll` on `getBookLocation` returning a non-null `page:offset` string. |
| `pdf-scroll-position.spec.ts` | 61 | 1500ms | Post-close. Poll `app.context().pages()` until book window gone. |
| `pdf-scroll-position.spec.ts` | 63 | 4000ms | Post-reopen. Biggest brittle wait. Poll on reader-ready (same as L31). |
| `pdf-scroll-up-jitter.spec.ts` | 38 | 3000ms | Same cold-open issue. |
| `pdf-scroll-up-jitter.spec.ts` | 47 | 2500ms | Post-scrollTo settle. Poll on virtualizer measured state / canvas count stabilising. |

## DEFENDED (not a violation)

`pdf-scroll-up-jitter.spec.ts` L57-65 — the 16ms `setTimeout` loop is
the assertion mechanism (sampling `scrollTop` to detect frame-level
back-jumps). This is correct usage; do NOT migrate to event-driven
polling without preserving sample frequency. See B052 about the
*window length*, which is a separate concern.

## Magic numbers

- `pdf-scroll-position.spec.ts` L38: `scrollTo({ top: 6500 })` — tied
  to fixture per-page measured height. Fixture identity lives in
  `e2e/helpers/electron-app.ts` (`PDF_FIXTURE`).
- `pdf-scroll-position.spec.ts` L41: `toBeGreaterThan(6000)` — guard
  for that scroll target. Acceptable as a sanity bound.
- `pdf-scroll-position.spec.ts` L77: `tolerance = 450`. See B046.
- `pdf-scroll-up-jitter.spec.ts` L45: `scrollTo({ top: 14000 })` —
  must truly unmount pages above. See B051 for the missing
  precondition assertion.
- `pdf-scroll-up-jitter.spec.ts` L54: `target = scrollTop - 600` —
  assumes 600px crosses a page boundary upward.
- `pdf-scroll-up-jitter.spec.ts` L77: `toBeLessThan(80)`. See B053.

## Selector fragility

Both specs use `document.querySelector('div.overflow-y-scroll')`. CSS
class selectors against Tailwind utility classes are unstable across
restyles. Recommend a `data-testid="pdf-scroll-container"` on the
container. Practice issue, not a current bug.

## Async correctness

- Single 600ms sample window in the jitter spec (see B052) — practice
  concern about duration; the loop itself is correct.
- No exact-equality on timestamps; no real-network calls; no snapshot
  tests. Otherwise clean.

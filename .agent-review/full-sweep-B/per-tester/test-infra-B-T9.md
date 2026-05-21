# Test Infrastructure Notes — B-T9

Tester: B-T9
Slice: smoke / no-toolbar / mobi-global-page-counter / scanner
Date: 2026-05-20

Observations on the e2e harness, helpers, and shared patterns surfaced
while auditing this slice. Not findings — infra improvements.

---

## INF-T9-01 — Need a `closeAllModals(page)` helper

Two of the four specs in this slice (and per pilot/plan others
elsewhere) hand-roll modal cleanup with bare `waitForTimeout`:

- `scanner.spec.ts:15-28` (three sleeps in `beforeEach`)
- Mentioned at plan §2.7

The shared `helpers/electron-app.ts` exports `launchApp`, `closeApp`,
`importBook`, `openBook` — but no `closeAllModals`. A helper that
presses Escape, then awaits `expect(page.locator('[role="dialog"]')).toHaveCount(0, { timeout: 2000 })`
would replace ~15 lines of fragile setup across the slice.

## INF-T9-02 — `openBook` resolution timing not documented

`no-toolbar.spec.ts:9` and `mobi-global-page-counter.spec.ts` both
work around `openBook` by polling/sleeping after it resolves. The
helper at `e2e/helpers/electron-app.ts:206-224` polls for a new
window's existence but does not necessarily wait for the reader's
content surface (iframe, canvas, or component-mount signal) to be
ready. Document the contract: does `openBook` resolve on window-
created, on first paint, or on reader-ready? Right now each caller
guesses with a sleep.

## INF-T9-03 — Reader-format testids are not format-namespaced

`[data-testid="azw3-page-counter"]` is shared between AZW3 and MOBI
viewers (see `mobi-global-page-counter.spec.ts:25`). When the same
testid serves multiple formats, a refactor that splits the viewers
breaks tests across formats with no obvious link. Convention proposal:
either (a) a format-neutral name like `paged-counter` for shared
components, or (b) per-format aliases (`mobi-page-counter`,
`azw3-page-counter`) wired through one component.

## INF-T9-04 — Smoke spec lacks data-testid on empty-library state

`smoke.spec.ts:22-23` is forced to use copy strings (`No books yet`,
`drag and drop`) because the empty-library component does not expose
a testid. Add `data-testid="empty-library"` to that component (small
prod change) so smoke can stop pinning marketing copy.

## INF-T9-05 — `expect.poll` adoption is uneven

`mobi-global-page-counter.spec.ts` uses `expect.poll` well. The other
three specs in this slice (and most specs per plan) still mix
`waitForTimeout` + manual `count()` polling. Recommend a project-wide
sweep that converts `waitForTimeout`-as-settle into either auto-wait
locators or `expect.poll` — likely a separate refactor PR.

## INF-T9-06 — Per-test vs shared launchApp inconsistency

Within this slice alone:
- smoke: shared `beforeAll(launchApp)` (OK, read-only)
- scanner: shared `beforeAll(launchApp)` (risky, mutates state)
- no-toolbar: per-test `launchApp`
- mobi-global-page-counter: per-test `launchApp`

No documented policy on when to use which. Plan §2.3 and §2.4 both
flag the shared-state risk. Worth a short ADR / convention doc:
"per-test for mutating specs; shared only for read-only smoke."

## INF-T9-07 — No CI flake report tracked per spec

The plan recommends ≥3 runs to detect flake (pilot §5.6). Of the four
specs in this slice, `mobi-global-page-counter` is the most likely to
flake (polling, blob-URL chapter loads). There is no per-spec flake
metric exported from CI. Suggest emitting a flake-rate JSON from the
Playwright reporter so timing-sensitive specs can be tracked.

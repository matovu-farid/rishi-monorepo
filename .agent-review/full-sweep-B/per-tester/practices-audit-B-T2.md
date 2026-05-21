# Practices Audit — Tester B-T2 (EPUB e2e batch)

## PA-T2-01 — `waitForTimeout` used as a poll substitute in 6+ sites

| Spec | Line | Duration | Purpose |
|---|---|---|---|
| epub-cache-no-flash | L46 | 500ms | "after first open" settle |
| epub-cache-no-flash | L59 | 800ms | "let library settle" |
| epub-cache-no-flash | L112 | 300ms | "drain a few extra frames" |
| epub-reader | L46 | 500ms | post-click settle |
| epub-reader | L62, L64 | 200ms ×2 | between keyboard presses |
| epub-reader | L73 | 200ms (in 5-iter loop) | between rapid clicks |

All of these are time-based proxies for an unmeasured idle signal. The
800ms "library settle" (cache-no-flash L59) is plainly superstitious —
no documented contract sets that bound. Recommended replacements:
- `expect.poll(...)` against an idle attribute (e.g. wait for a known
  library list count, or for `__readerCache.epub` to expose a stable
  fingerprint).
- For navigation settle (epub-reader): poll a CFI/location getter for
  change rather than sleeping.

## PA-T2-02 — Non-discriminating final assertions in navigation tests

See finding B017 for the load-bearing case. Beyond B017's three tests,
the practice generalizes: `expect(<aria-label>).toBeVisible()` after
clicking that same label, or `expect(body).toBeVisible()`, is the same
shape as `mobi.spec.ts` L40 called out in pilot review. Recommend a
codebase-wide lint or review-time rule: "the final assertion of a
navigation test must observe a value that changes as a result of the
navigation."

## PA-T2-03 — Silent-skip patterns must include a positive smoke gate

Finding B018 covers `epub-reader.spec.ts` L50–57. The general practice:
when using `test.skip(true, ...)` in a conditional, add a separate
`beforeAll` smoke that fails-loud when the gated capability is absent
in CI's canonical config. Otherwise CI green is a one-way ratchet.

## PA-T2-04 — Inline `evaluate(...)` blocks > 30 lines should not swallow throws

`epub-cache-no-flash.spec.ts` L67–107 is 40 lines of inline JS injected
via `page.evaluate`. The injected poller self-schedules via
`requestAnimationFrame`; any throw inside `tick()` silently terminates
the chain (finding B020). Practice: any rAF / setInterval injected via
`page.evaluate` must (a) wrap the body in `try/catch` and surface the
error back, AND (b) expose a tick-count or iteration counter the test
can sanity-check on readback.

## PA-T2-05 — `.catch(() => {})` in teardown loses signal when wiring breaks

`epub-text-selection.spec.ts` L75–77 chains three `.catch(() => {})` in
`afterAll`. Reasonable for `bookPage?.close()` (the page may already be
gone), but blanket-suppressing `deleteAllBooks` and `closeApp` errors
hides regressions in those helpers. Practice: catch and **log** in
teardown — `.catch((e) => console.error('[teardown] closeApp:', e))` —
so failures show in the report without aborting subsequent teardown
steps.

## PA-T2-06 — `text=Loading...` locator is too broad when multiple loader surfaces exist

Finding B016. Practice: when more than one surface in the app may
render the same loader text (visible vs hidden paragraph reader), every
spec touching that loader must filter for visibility (mirror the
`visibleToUser(...)` walker in cache-no-flash L74–94). Otherwise the
locator is a known-false-positive trap.

## PA-T2-07 — Synthetic-event dispatch should target a documented element, not an `iframe.parentElement?.parentElement` walk

Finding B019. Practice: synthetic events fired in `evaluate(...)` must
target an element matched by a documented contract (data-testid, ARIA
role, computed-style signature) — never by ancestor-count walks. The
target identity is otherwise silently coupled to wrapper-div count.

## PA-T2-08 — `text-selection` rationale block is exemplary; cite as model

Defending the practice in `epub-text-selection.spec.ts` L1–42: the
40-line comment documents the regression mode, the failing assertion,
and why the structural assertion catches it. This is the pattern other
specs should follow when asserting against impl-detail signatures.

---

**Summary:** 8 practices observations across the EPUB batch. Three are
upgrades of findings; five are batch-wide rules worth codifying for
later test work.

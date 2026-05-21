# Phase B practices audit — Tester B-T1

Scope: 4 AZW3 e2e specs.

- **`waitForTimeout` used as a settling primitive (anti-pattern).**
  - `azw3-column-alignment.spec.ts:78` — `await bookPage.waitForTimeout(300) // settle initial measurement`. Replace with `expect.poll` on `minLeft` stabilizing across two consecutive reads.
  - `azw3-column-alignment.spec.ts:99` — `await bookPage.waitForTimeout(150) // let scroll settle`. Replace with `expect.poll` on `body.scrollLeft` equaling the expected page-N offset.
  - `azw3-parity.spec.ts:74` — `await bookPage.waitForTimeout(300)` after `bringToFront()`. Replace with a focus poll or drop entirely (clickMenuItem already waits).
  - `azw3-parity.spec.ts:121, 154, 159` — three `waitForTimeout(400/800/800)` calls inside the bookmark focus-retry loop. Defensible because of the macOS focus race (documented L131-134), but should be capped and the timeout values commented with rationale.

- **`test.setTimeout(60000)` may be redundant.** Used in `azw3-column-alignment.spec.ts:10`, `azw3-parity.spec.ts:89`, and twice in `azw3-render-content.spec.ts:12, L122`. Per pilot Q03, if `playwright.config.ts`'s global `timeout` is already ≥60000, all four overrides are no-ops and should be removed. If global is <60000, leave them but add a comment explaining why each test individually needs the bump.

- **Retry loop with hard assertion inside the loop body.** `azw3-parity.spec.ts:157` asserts `expect(clicked).toBe(true)` inside the 5-attempt focus-retry `for` loop. If `clickMenuItem` returns `false` transiently (the very condition the retry exists to tolerate), the assertion fails on attempt 1 and subsequent attempts never run. Move the hard assertion outside the loop (assert at least one attempt succeeded), or convert to a soft check inside the loop and a single hard check on `after === before + 1` afterward.

- **Borderline implementation-detail locator.** `azw3-parity.spec.ts:81` uses `[data-slot="sheet-content"]` (a Radix internal data attribute) to detect the TOC sheet. Prefer `role="dialog"` plus visible-text anchor (e.g. "Contents") so the test survives a Radix major-version bump.

- **Relative screenshot path.** `azw3-render-content.spec.ts:83` writes `path: 'test-results/azw3-iframe.png'`. Relative to Playwright's cwd; if invoked from a different directory the file lands somewhere unexpected. Use Playwright's `testInfo.outputPath()` or an absolute path under `testInfo.outputDir`.

- **`body.textContent.trim().length > 50` is a weak content check.** `azw3-render-content.spec.ts:144-149` includes hidden / off-screen text. Pair with a visible-locator assertion (e.g. wait for the first `<p>` or chapter heading to be visible) to ensure the text is actually painted.

- **Screenshot byte-length heuristic.** `azw3-render-content.spec.ts:94` — see finding B003. Even if Reviewer-1 demotes that finding, this remains a practice violation: byte size is not a behavior contract.

# Phase B test-infra observations — Tester B-T1

Scope: 4 AZW3 e2e specs.

- **`importBook(kind: 'azw3')` hard-codes the kind in `e2e/helpers/electron-app.ts`** (confirmed per plan-azw3 §2.1 and pilot 2.4). All 4 AZW3 specs in scope use this path and therefore inherit the dispatch-routing blind spot. Infra ask: split helper into `importBookAsKind(...)` (current behavior, explicit-kind for non-routing tests) and `importBookViaDispatch(...)` (uses real format detection) so the kind=hardcode is opt-in and visible at the call site.

- **No shared "wait for AZW3 reader ready" helper.** Every spec repeats:
  ```
  const counter = bookPage.locator('[data-testid="azw3-page-counter"]')
  await counter.waitFor({ state: 'attached', timeout: 20000 })
  ```
  Three of four specs also follow with an `iframe[title="..."]` visibility check. Extract `await waitForAzw3Ready(bookPage, { title })` so the 20-second magic number lives in one place and per-spec drift is impossible.

- **No shared "focus AZW3 book window + click menu" helper.** `azw3-parity.spec.ts:135-167` reinvents a 5-attempt focus-retry loop in-spec; this same pattern will be needed for any future menu-driven AZW3 / MOBI / EPUB test. Extract to `helpers/menu.ts` (or co-locate with `clickMenuItem`) as `clickMenuItemWithFocusRetry(launched, bookPage, path, opts)` returning a boolean indicating success after N attempts.

- **No pixel-sampling helper for "iframe is not blank".** Multiple readers face this regression class (the user-reported blank-iframe bug). `azw3-render-content.spec.ts:80-94` uses a screenshot byte-length heuristic (see finding B003) because no shared "sample pixels via canvas readback" helper exists. Build `assertIframeIsPainted(iframe, opts?)` that does `page.evaluate` + offscreen `<canvas>.drawImage` + `getImageData` over a sparse grid and asserts at least one non-near-white pixel.

- **No console-capture helper.** `azw3-render-content.spec.ts:14-26` wires up console/`pageerror` collection inline (~12 lines) and uses it only in the catch branch at L73. EPUB / MOBI / PDF specs likely need the same. Extract `createConsoleCapture(app, filter?)` returning `{ messages, dump() }`.

- **`AZW3_FIXTURE` is a single 339 KB single-section fixture** (per spec comment at L116-120). Infra ask: add at least one *multi-section* AZW3 fixture so chapter-Next-into-next-section transitions can be tested; currently `azw3-parity.spec.ts:29-34` has to special-case "single-page fixture" and skip the multi-page assertion path.

- **Reviewer-1 flake check command in plan-azw3 §4 uses `||` rather than tracking pass counts.** Minor: the documented `for i in 1 2 3; do ... || echo "run $i: FAIL"; done` prints failures but does not fail the loop. Consider `set -e` + explicit counter so a flake-check run can be machine-parsed.

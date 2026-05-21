# Phase B Plan — AZW3 E2E Specs (Planner P1)

**Scope (4 files):**
- `apps/rishi-electron/e2e/azw3-column-alignment.spec.ts`
- `apps/rishi-electron/e2e/azw3-open.spec.ts`
- `apps/rishi-electron/e2e/azw3-parity.spec.ts`
- `apps/rishi-electron/e2e/azw3-render-content.spec.ts`

**Tester ID range:** B001-B015 (Tester B-T1 covers all 4 files). Reviewer-1 alternation per pilot §4.4 (odd → team-reviewer, even → feature-dev:code-reviewer).

---

## 1. Skip list

**No `test.skip(...)` in any of the 4 AZW3 specs.** All tests are active. Findings here can be real bugs (unlike pilot's warm-restore specs which were predominantly `.skip`).

---

## 2. Per-file audit checklist

### 2.1 `azw3-column-alignment.spec.ts`

- **L10** — `test.setTimeout(60000)`. Per pilot §2.3 Q03 lesson: confirm `playwright.config.ts` global timeout isn't already ≥60s (no-op override). If it is, drop the line; if it isn't, the AZW3 import path may genuinely be slow — possible perf finding.
- **L78** — `waitForTimeout(300)` to "settle initial measurement". Brittle. Prefer `expect.poll` on `minLeft` stabilizing across two consecutive reads. **Practice violation** if no auto-wait alternative is wired.
- **L99** — `waitForTimeout(150)` to "let scroll settle" inside the loop. Same anti-pattern; better signal would be `expect.poll` on `body.scrollLeft` matching the expected page offset. **Practice violation**.
- **L13-17** — Uses `importBook(launched.page, { kind: 'azw3' })` helper which (per pilot 2.4 / `electron-app.ts:114`) **hardcodes kind**, bypassing the dispatch routing bug class. Note: this spec is about column alignment, not routing — defensible — but flag as a parity/coverage observation (only `azw3-real-import-routing.spec.ts` exercises real dispatch).
- **L20-24** — Assertions on `[data-testid="azw3-page-counter"]` and `iframe[title="AZW3 Alignment"]` are **on `bookPage` (the openBook return value)**, not on `launched.page`. This is correct (Phase-3 per-window). Verify all later locators stay on `bookPage`. ✓ they do.
- **L86-97** — Uses `initialCurrent` + `expect.poll` on `data-current`. Good pattern; defend it. Not a finding.
- **L104-107** — Tolerance of 2px on `minLeft` drift. Reasonable; flag only if found to be flaky across runs (Reviewer-1 ≥3-run check).
- **L35-69** — Heavy `page.evaluate` reaching into the iframe (`Range.getClientRects()`). Test does the right thing (per-line fragment), but the iframe-traversal is verbose; not a defect.

### 2.2 `azw3-open.spec.ts`

- **No `test.setTimeout` override** but each `waitFor` uses explicit `timeout: 20000`/`10000`. Consistent.
- **L14-18** — Same `importBook(..., kind: 'azw3')` hardcoded-kind observation as above. Not a finding for *this* file (file's purpose is render check, not routing).
- **L24-25** — `counter.waitFor({ state: 'attached', timeout: 20000 })` — note: `attached` not `visible`. The counter may be in the DOM but invisible; assertions on `data-current` / `data-total` still work, so behavior is fine. Flag only if a finding emerges where the counter is attached with stale/empty attributes.
- **L27-31** — Assertions `total ≥ 1`, `current ≥ 1`, `current ≤ total`. Solid; not tautological. Defend.
- **L34-35** — `iframe[title="AZW3 Render Test"]` is title-scoped (good), checked `toBeVisible()` (good). Not an implementation-detail locator the way `canvas.react-pdf__Page__canvas` would be (per pilot §2.1) — title is a content contract, not a CSS class.
- **No CSP / sandbox / paint assertion.** That is `azw3-render-content.spec.ts`'s job — file boundary is clean, not a parity gap *within this file*.

### 2.3 `azw3-parity.spec.ts`

- **L33** — `await expect(bookPage.locator('button[aria-label="Next page"]')).toHaveCount(0)`. **Not tautological** (asserting against constant 0, not `await locator.count()`). Distinct from the pilot's `mobi.spec.ts:36-39` finding. Defend.
- **L74, L121, L154, L159** — Multiple `waitForTimeout(300/800/400/800)` calls for "focus settle" and "IPC flush". **Practice violation** but partially defensible (focus races on macOS are real, see L132-134 comment). Recommendation: try `expect.poll` against the bookmark-count IPC; if it still races, document the focus race as a known limitation.
- **L89** — `test.setTimeout(60000)` on the bookmark test only. Confirm vs global config (Q03 lesson). The 5-attempt focus retry loop suggests genuine flakiness in the macOS menu path — possible finding against the production menu-event dispatch or `Azw3View` syncId-on-mount caching (which the test seeds around at L102-113 — that seeding pattern itself is a hint that production caches stale null).
- **L98-113** — Comment at L100-103 explicitly documents: *"Azw3View fetches booksGetSyncId once on mount and caches the result in a ref. If the syncId arrives after mount, the bookmark handler stays null for the lifetime of that window."* This is a candidate **production bug**: the cache-once-on-mount-without-refetch pattern means a book imported without syncId and opened immediately can never bookmark. The test works around it by pre-seeding syncId. Tester B-T1 should investigate `Azw3View` source for this pattern (allowed: callee of `bookmarksList`/`booksGetSyncId`) — file as finding if confirmed.
- **L135-168** — 5-attempt focus retry loop with `expect(clicked).toBe(true)` *inside* the loop (L157). If `clickMenuItem` returns false transiently, the assertion fails immediately and the retry is wasted. **Practice violation** — assertion should move outside retry or be a soft check.
- **L76** — `clickMenuItem(launched.app, ['View', 'Show TOC'])` returns boolean; asserted `toBe(true)`. Good. Sheet then polled via `waitFor`. Reasonable.
- **L81** — Locator `[data-slot="sheet-content"]` — this is a Radix internal data-slot. Stable across Radix versions? Borderline implementation-detail locator. Mild **practice observation**.

### 2.4 `azw3-render-content.spec.ts`

- **L10, L122** — Both tests use `test.setTimeout(60000)`. Same Q03 check vs config.
- **L14-26** — Console-capture helper (`messages: string[]`) wired before book open; used only in error path (L73). Good defensive pattern; not a finding.
- **L42-45** — `iframeBox.width/height > 200`. Magic numbers, but reasonable lower bound for "non-trivial layout". Defend.
- **L54-63** — `expect.poll` on `scrollHeight > 400` — correct auto-wait pattern. Defend.
- **L80-94** — **Screenshot byte-length heuristic** (L94: `dataLen > 6000`). This is a **proxy** for "page is not all-white." Flaky/brittle:
  - PNG compression varies with renderer + libpng version; a 1200x800 mostly-white page with sparse glyphs *could* compress to ~6KB.
  - The threshold is empirical and platform-dependent (CI Linux vs local macOS).
  - **Practice violation** — prefer actual pixel sampling via `page.evaluate` + canvas readback, or compare against a known-blank reference. Flag as candidate finding only if the heuristic has caused flakes; otherwise `practices-audit.md`.
- **L83** — `path: 'test-results/azw3-iframe.png'` — writes to a relative path. If cwd is not `apps/rishi-electron`, this lands in an unexpected location. Minor **practice observation**.
- **L102-106** — Sandbox token assertions (`allow-same-origin`, `allow-scripts`). Behavior contract, good. Defend.
- **L144-149** — `body.textContent.trim().length > 50`. Pilot §2.4 flagged a similar `not.toBeEmpty()` as weak. Here the threshold is at least quantitative (50 chars), but `textContent` includes hidden nodes — same class of weakness as pilot finding 4. **Practice observation**: consider asserting on a visible chapter heading or first paragraph locator instead.
- **L164-170** — `Next page` advances `data-current` by 1, asserted via `expect.poll`. Solid. Defend.

---

## 3. Tester ID range

**B001-B015** assigned to Tester B-T1 (single tester for all 4 AZW3 specs). Max 5 findings per spec per pilot §4.2 cap; expect most output in `parity-gaps.md` / `practices-audit.md`.

Reviewer-1 alternation:
- B001, B003, B005, B007, B009, B011, B013, B015 → `team-reviewer`
- B002, B004, B006, B008, B010, B012, B014 → `feature-dev:code-reviewer`

---

## 4. Test commands

**Prerequisite (build main process if `out/main/index.js` missing):**

```bash
pnpm build
```

(Per pilot §5.1: no `pretest:e2e` hook; manual build required.)

**Run specific spec:**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e e2e/azw3-column-alignment.spec.ts
pnpm test:e2e e2e/azw3-open.spec.ts
pnpm test:e2e e2e/azw3-parity.spec.ts
pnpm test:e2e e2e/azw3-render-content.spec.ts
```

**Single test by name (parity has 3 tests):**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e e2e/azw3-parity.spec.ts -g "chapter Next/Prev"
pnpm test:e2e e2e/azw3-parity.spec.ts -g "Show TOC"
pnpm test:e2e e2e/azw3-parity.spec.ts -g "Add Bookmark"
```

**Reviewer-1 flake check (≥3 runs, per pilot §5.6):**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
for i in 1 2 3; do pnpm test:e2e <spec> -g "<test name>" || echo "run $i: FAIL"; done
```

**Discovery dry-run:**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e --list e2e/azw3-parity.spec.ts
```

---

## 5. Likely real-bug candidates (for tester triage priority)

1. **`Azw3View` syncId caches null on mount** (parity spec L100-103 comment + workaround). Likely production bug — file as finding if production code confirms the once-on-mount fetch without refetch.
2. **Screenshot byte-length heuristic** (render-content L94) — practice issue, candidate finding only if flake history exists.
3. **Bookmark focus race** (parity L88-170) — could be production menu-dispatch bug OR test environment limitation; investigate before filing.
4. Routing dispatch hardcoding via `importBook` helper — already covered by pilot's `azw3-real-import-routing.spec.ts`; no new finding needed from these 4 files.

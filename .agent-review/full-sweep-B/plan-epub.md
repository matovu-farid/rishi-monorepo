# Phase B Plan — EPUB e2e Specs (Planner P2)

**Scope (4 specs):**
- `apps/rishi-electron/e2e/epub-cache-no-flash.spec.ts`
- `apps/rishi-electron/e2e/epub-first-open.spec.ts`
- `apps/rishi-electron/e2e/epub-reader.spec.ts`
- `apps/rishi-electron/e2e/epub-text-selection.spec.ts`

**Tester ID range:** B016 – B030 (Tester B-T2). Max 5 findings per spec (20 total).
Per pilot rule, odd IDs route to `team-reviewer`, even IDs to `feature-dev:code-reviewer`.

---

## 1. Skip List

| Spec | Line | Test | Skip type | Notes |
|---|---|---|---|---|
| `epub-cache-no-flash.spec.ts` | L28 | `warm-restore reopen does not flash the inner loading view` | unconditional `test.skip(...)` | Skipped pending Phase-3 per-window cache rework; same status as `epub-warm-restore.spec.ts` from pilot. Parity gap, NOT a bug source. |
| `epub-reader.spec.ts` | L52 | `TOC toggle opens and closes the table of contents` | conditional `test.skip(true, ...)` via `if ((await tocToggle.count()) === 0)` | Auto-skip when build lacks TOC toggle. Risk: test silently passes on every CI run if TOC selector silently changes — flag in practices-audit. |
| `epub-first-open.spec.ts` | — | — | no skips | All active. |
| `epub-text-selection.spec.ts` | — | — | no skips | All active. |

---

## 2. Per-File Audit Checklist

### 2.1 `epub-cache-no-flash.spec.ts` (entire test skipped)
Even though skipped, audit for when un-skipped:
- **L46, L59, L112** — three `waitForTimeout(500/800/300)` calls. The 800ms "let library settle" is purest superstition. Prefer `expect.poll(...)` against an idle signal. **Practices-audit.**
- **L48–53 — `?? false` fallback pattern.** Pilot A091/A099 flagged this: `w.__readerCache?.epub?.has(id) ?? false` silently coerces an undefined diagnostic surface into a "not cached" verdict, hiding the case where the surface itself is broken. The L54 assertion `expect(isCached, ...).toBe(true)` would still flag a true cache miss, BUT if `__readerCache.epub` is undefined entirely the failure message ("cache populated after first open") would mislead the reader away from the real cause (missing surface). **Finding-candidate** (test-quality bug surfacing potential production diagnostic issue) — verify whether `epub-cache.ts` actually attaches `has()` symmetrically with `pdf-cache.ts`.
- **L114–121 — `__loaderEverSeen === true` second `?? -1`-shaped read.** `w.__loaderEverSeen === true` — strict equality to `true` correctly avoids the `?? -1` antipattern. Defend this as the right shape.
- **L67–107 — 40-line `evaluate` polling block.** Inline `requestAnimationFrame` poller is ambitious; if it throws it'd silently hide a real loading-view render. Wrap try/catch and surface the error back to the test. **Practices-audit.**
- **No CFI/location assertion** after warm restore — same parity gap as the pilot's epub-warm-restore observation.
- **`importBook` hardcodes `kind: 'epub'`** (L37–41), bypassing the real dispatcher — pilot finding 011 pattern. Parity gap: no `epub-real-import-routing.spec.ts` exists.

### 2.2 `epub-first-open.spec.ts`
- **L25** — single active test, no skips. Clean structure.
- **L34** — `openBook(...)` returns `bookPage` — correctly asserts against the BrowserWindow page, not `app.page`. **Wrong-window check: PASS.**
- **L36–44** — two assertions: iframe visible (15s timeout) + `text=Loading...` count 0 (5s timeout). Tight. No `waitForTimeout` between. **Practices: clean.**
- **L42 — `text=Loading...` locator.** Matches any `Loading...` text node across the page; the hidden paragraph-reader (mentioned in cache-no-flash design) also renders ReactReader without cache. Risk of false-positive (passing when the visible loader is still up but a hidden one cleared). Compare against epub-cache-no-flash's visibility-checked poller. **Practices-audit / parity-gap** (assertion strength asymmetry across specs).
- **`importBook` hardcoding** (L28–32) — same pilot-011 pattern; parity-gap.
- **No `bookPage` returned-window assertion of URL/route** — light coverage of dispatcher correctness.

### 2.3 `epub-reader.spec.ts`
- **L17–25 — shared `beforeAll(launchApp)`** with single import, multiple `beforeEach(openBook)`. Acceptable but fragile per pilot §2.4 critique of `mobi.spec.ts`. **Practices-audit, low-sev.**
- **L34–36** — `Next page` aria-label visible w/ 30s timeout. Defensible (cold-start).
- **L44–48 — `next-page click does not crash`** — `waitForTimeout(500)` then re-asserts the same `[aria-label="Next page"]` is visible. The assertion is near-tautological: clicking a button does not unmount it, so visibility after click reveals little. Replace with a page-progressed signal (CFI change, or `.epub-view` scroll delta). **Practices-audit.**
- **L50–57 — TOC toggle**: conditional skip on L52 (see Skip List). If the selector breaks, the test perpetually skips silently. **Practices-audit (silent-skip drift).**
- **L59–66 — keyboard navigation**: two `waitForTimeout(200)` calls between key presses. Brittle. Final assertion (`Next page` visible) is again non-discriminating. **Practices-audit.**
- **L68–76 — rapid forward navigation**: loop with `waitForTimeout(200)` per click; assertion is `expect(body).toBeVisible()` — trivially true (pilot called this exact pattern out in `mobi.spec.ts` L40). **Practices-audit.**
- **No location/CFI assertion** after any navigation — entire spec is structural ("nothing crashed"). **Parity-gap** vs intended user-visible navigation.

### 2.4 `epub-text-selection.spec.ts`
- **L59–78 — `beforeAll(launchApp)`/`afterAll` teardown with `bookPage?.close()`** — good explicit window cleanup; comment at L70–74 documents Phase-3 hang. **Defend this pattern.**
- **L75–77** — three `.catch(() => {})` in afterAll suppress errors. Reasonable for teardown but loses signal if `closeApp` regresses. **Practices-audit, low-sev.**
- **L87–124 — overlay-absence test**: structural DOM/computed-style match. Asserts implementation detail (z-index 200, position absolute) rather than the user-observable behavior (text actually selectable). Pilot warned about impl-detail locators. **Possible practices-audit, but countered by L1–42 design rationale**. The rationale is strong; defend it but consider whether a companion behavioral test would catch the same regression more cheaply.
- **L126–152 — synthetic mousedown defaultPrevented check**: dispatches a synthetic `MouseEvent` two ancestors above the iframe. The choice of ancestor (`iframe.parentElement?.parentElement ?? ...`) is impl-detail-fragile; refactoring the wrapper shape silently changes target. **Practices-audit.**
- **Wrong-window check:** all assertions go through `bookPage` (the openBook-returned window). **PASS.**
- **`importBook` hardcoding** L61–65 — same pilot-011 pattern; parity-gap.

### 2.5 Cross-file patterns
- 4/4 specs hardcode `kind: 'epub'` in `importBook(...)` — bypasses real dispatcher. Single parity-gap entry, not per-file.
- 0/4 specs assert CFI or chapter-location restoration — large parity gap vs `pdf-persistence.spec.ts`.
- 0/4 specs verify `__readerCache.epub.stats()` (hits/misses) outside the skipped one — parity gap vs PDF cache plans.
- No spec exercises EPUB import via `importBookViaOpenFile` (real OS-dispatch).

---

## 3. Tester ID Range

**B016 – B030** (Tester B-T2, EPUB e2e batch).

- Findings → `.agent-review/full-sweep-B/findings/B016-<slug>.md` … `B030-<slug>.md`.
- Parity-gaps → `.agent-review/full-sweep-B/parity-gaps.md` (append).
- Practices-audit → `.agent-review/full-sweep-B/practices-audit.md` (append).
- Reviewer-1 alternation:
  - Odd-ending ID (B017, B019, B021, B023, B025, B027, B029) → `team-reviewer`.
  - Even-ending ID (B016, B018, B020, B022, B024, B026, B028, B030) → `feature-dev:code-reviewer`.

Cap: 5 findings/spec → max 20. Zero findings is a valid outcome (per pilot §4.3).

---

## 4. Test Commands

### 4.1 Prerequisite — build main process

```bash
pnpm --filter rishi-electron build
```

Required because `e2e/helpers/electron-app.ts:12` resolves `../../out/main/index.js`. No `pretest:e2e` hook exists; build is manual.

### 4.2 Run each spec individually

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e e2e/epub-cache-no-flash.spec.ts   # currently skipped
pnpm test:e2e e2e/epub-first-open.spec.ts
pnpm test:e2e e2e/epub-reader.spec.ts
pnpm test:e2e e2e/epub-text-selection.spec.ts
```

### 4.3 Single test by name

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e e2e/epub-reader.spec.ts -g "TOC toggle"
```

### 4.4 Discovery sanity (no execution)

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e --list e2e/epub-cache-no-flash.spec.ts
```

### 4.5 Flake check (Reviewer-1, ≥3 runs)

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
for i in 1 2 3; do pnpm test:e2e <spec> -g "<test>" || echo "run $i: FAIL"; done
```


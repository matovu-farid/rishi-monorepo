# Plan PDF-A — Phase B Tester B-T3

**Scope (3 specs):**
- `apps/rishi-electron/e2e/pdf-import.spec.ts`
- `apps/rishi-electron/e2e/pdf-persistence.spec.ts` (pilot's "live parity baseline" for warm-restore)
- `apps/rishi-electron/e2e/pdf-reader.spec.ts`

**Tester ID range:** B031–B045 (Tester B-T3). Pad as `031`…`045`. Reviewer-1 alternation: odd-ending → `team-reviewer`, even-ending → `feature-dev:code-reviewer` (per pilot §4.4).

---

## 1. Skip list

- Do NOT re-audit `pdf-warm-restore.spec.ts` (already covered by pilot — entire suite is `test.skip` at L33).
- Do NOT re-audit `pdf-scroll-position.spec.ts` (referenced by pilot only; out of B-T3 scope).
- Do NOT re-file findings the pilot already raised verbatim about `importBook` hardcoded `kind` in `helpers/electron-app.ts` — instead, when this leaks into B-T3 specs, cite the pilot's framing and treat new occurrences as parity gaps in `parity-gaps.md`, not duplicate findings.
- Do NOT chase production fixes; B-T3 produces findings/parity notes only.
- Do NOT audit non-PDF helpers (`epub-*`, `mobi-*`, `azw3-*`) even if imported transitively.
- Skip auditing `helpers/electron-app.ts` itself (cross-cutting; owned by helpers-sweep).

---

## 2. Per-file audit checklist

### 2.1 `e2e/pdf-import.spec.ts`

Anti-patterns to verify and (if real) classify:

- **`waitForTimeout` in setup / between actions** — L30 (500), L45 (1500), L55 (3000), L78 (1500). Each one is a timing-based pause where Playwright auto-wait (`expect(...).toBeVisible({ timeout })` or `expect.poll`) would be more robust. **Practice violation** → `practices-audit.md` unless the timeout actually hides a production race (then finding).
- **Wrong-window assertions (Phase-3 split)** — L34, L35, L46, L79 assert on `app.page` (library window). Confirm these *are* library-window assertions, not reader-window mis-targets. Cross-check: `openBook` returns the new BrowserWindow `Page`; reader assertions at L52, L65 correctly target `bookPage`. Likely OK; flag only if any reader-side locator slips onto `app.page`.
- **`importBook` hardcoded `kind`** — L41 (`kind: 'pdf'`), L60 (`kind: 'epub'`), L74 (`kind: 'pdf'`). Same dispatcher-bypass pattern the pilot flagged for MOBI. This spec is named "import & open lifecycle" but never exercises the real OS-open-file dispatch. **Parity gap** → `parity-gaps.md` (note: PDF lacks a `pdf-real-import-routing.spec.ts` analogue to AZW3's).
- **Tautological / weak assertions** — L52 `toBeAttached` (not `toBeVisible`); for a "renders pages" test, attached is weaker than visible. Borderline practice violation.
- **`page.reload()` between import and open** — L44. Confirms persistence-on-reload accidentally instead of the named "imports, opens, renders" intent. If `reload()` is load-bearing for the assertion at L46, that's hidden coverage of a different behavior; document as scope-creep practice note.
- **Impl-detail locators** — L52 `div.overflow-y-scroll`. CSS-class-based, not data-testid or aria. Brittle to Tailwind/utility-class refactor. The pilot already noted react-pdf's `canvas.react-pdf__Page__canvas` as a similar concern. **Practice violation** → `practices-audit.md`.
- **Native menu admission** — L51 comment "no in-window back link to assert against anymore." Confirm no orphaned back-link assertion remains; if there is one elsewhere it's a stale Phase-3 artifact.
- **`text=...` locators** — L34, L35, L79. Translation/i18n fragile. Note as practice.
- **No assertion that ErrorBoundary is absent** on cold open (pilot §2.2 raised same asymmetry for EPUB). Parity gap.

### 2.2 `e2e/pdf-persistence.spec.ts`

- **`waitForTimeout` proliferation** — L22 (3000), L34 (1500), L46 (1500), L48 (3000). The 3000ms after open is a "give the renderer time to settle" pause; replace with `expect.poll(() => getBookLocation(...))` or wait for the reader's stable-state marker. **Practice violation**; possibly hides a race in `books:updateLocation` debounce.
- **Impl-detail locator** — L30 `document.querySelector<HTMLElement>('div.overflow-y-scroll')` inside `page.evaluate`. Same brittleness as pdf-import. Could become a finding if production renames the scroll container and the persistence path silently regresses (test still throws `'no scroll container'` but the user-visible bug — page-not-restoring — is masked by the test never reaching the assertion).
- **Page-of parsing** — L24 `Number((loc ?? '0').split(':')[0])` makes a strong assumption about the location format `'<page>:<offset>'`. If location format changes (e.g. CFI-like for PDF), this silently coerces to NaN/0 and the `toBe(pageOf(afterScroll))` comparison could pass for the wrong reason (0===0). **Potential finding** if production location encoding is unstable; otherwise **practice violation** (assertion that can pass under broken data).
- **Wrong-window assertion check (Phase-3)** — L26 (`app.page` for `getBookLocation`), L29 (`bookPage` for scroll), L40 (`app.page` for `closeBook` IPC), L47 (`app.page` again for `openBook`). Map matches the per-window split correctly; OK.
- **Scroll target `top: 6000`** — L32. Magic number; if fixture page sizes change, scroll may not cross a page boundary and `toBeGreaterThan(1)` fails for fixture reasons not production reasons. **Practice violation**; not a bug.
- **No assertion that the cache (`window.__readerCache.pdf`) was used on reopen** — pilot §2.1 noted PDF's cache diagnostic is unused. Parity gap repeats here in the live spec.
- **No teardown of book** between cases — single-test file, fine.
- **Tautology check** — none obvious; `toBeGreaterThan(1)` and `toBe(pageOf(afterScroll))` are real assertions.
- **setTimeout-as-no-op** — none in this file; all timeouts have a settle purpose (even if heuristic).

### 2.3 `e2e/pdf-reader.spec.ts`

- **Shared-instance fragility** — L17 `beforeAll(launchApp)` + one book imported once for all tests. Pilot §2.4 flagged this exact pattern for `mobi.spec.ts`. **Practice violation**.
- **`waitForTimeout` in `beforeEach`** — L34 (3000), L51 (300), L53 (300), L64 (2000). Same auto-wait anti-pattern.
- **Weak rendering assertion** — L54 `expect(bookPage.locator('body')).toBeVisible()` and L65 `expect(app.page.locator('body')).toBeVisible()`. Body visibility is tautologically true unless the renderer crashed entirely. Pilot called the same out at `mobi.spec.ts:40`. **Practice violation**.
- **"keyboard navigation does not crash" (L49-55)** — asserts only that body is visible after ArrowRight/ArrowLeft. Does NOT assert page changed, did not change, or that focus stayed correct. Test name promises behavior; assertion delivers smoke. **Practice violation**, possibly a missed real bug if Arrow keys are no-ops in the PDF window post-Phase-3.
- **"invalid book id does not crash" (L57-66)** — L61 sets `window.location.hash = '#/books/999999'` on the *library* window (`app.page`), then asserts body visible. Comment at L58-60 admits this is intentionally exercising the legacy hash path, not the new per-window route. Verify the comment matches reality: does the route guard truly intercept `/books/N` on `app.page`? If so, the test is asserting a legacy code path may not exist; if production removed the guard, this test silently passes by hitting a 404. **Potential finding** — verify guard wiring before classifying.
- **Wrong-window check** — L38 `bookPage`, L44 `bookPage`, L50/52 `bookPage`, L54 `bookPage`, L65 `app.page`. Map looks correct for Phase-3 split.
- **Locators are aria-label-based** (L38, L44) — good practice, defend.
- **No assertion that TTS orb / voice-chat launcher are functional**, only present. Spec name says "reader" — presence-only is acceptable smoke. Practice note only.
- **`bookId` reused across tests** — if any test mutates persisted state (page restored from prior test), order-dependence could mask bugs. Audit each test's mutation.

### 2.4 Cross-spec checks (apply to all 3)

- **Tester ID assignment per finding:** allocate sequentially from B031 upward; never reuse.
- **Finding cap:** 5 per spec max (15 total ceiling for B-T3). Pilot notes most output should land in `parity-gaps.md` / `practices-audit.md`, not `findings/`.
- **Reviewer-1 alternation:** odd last digit → `team-reviewer`; even → `feature-dev:code-reviewer`.
- **Before filing:** verify the runner sees the test (§4 below).
- **Disqualifiers:** parity gaps and practice violations are NOT findings (see pilot §4.3). A finding requires a real production code path producing user-visible incorrect behavior plus a demonstrating test.

---

## 3. Tester ID range

**B031–B045** (15 slots total, 5 per spec hard cap).

| Spec | ID slots |
|---|---|
| `pdf-import.spec.ts` | B031–B035 |
| `pdf-persistence.spec.ts` | B036–B040 |
| `pdf-reader.spec.ts` | B041–B045 |

Reviewer-1 mapping examples: B031→team-reviewer (odd), B032→feature-dev:code-reviewer (even), …, B045→team-reviewer (odd).

---

## 4. Test commands

**Build prerequisite (always):** Playwright resolves `apps/rishi-electron/out/main/index.js` via `e2e/helpers/electron-app.ts:12`. If missing or stale:

```bash
pnpm --filter rishi-electron build
```

Working tree had `out/main/index.js` at pilot time; re-verify before any e2e run.

**Run each spec:**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e e2e/pdf-import.spec.ts
pnpm test:e2e e2e/pdf-persistence.spec.ts
pnpm test:e2e e2e/pdf-reader.spec.ts
```

**Single test by name:**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e e2e/pdf-reader.spec.ts -g "voice chat launcher is present"
```

**Discovery check (no execution) before citing a test in a finding:**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e --list e2e/pdf-import.spec.ts
```

**Reviewer-1 flake check (≥3 runs):**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
for i in 1 2 3; do pnpm test:e2e e2e/pdf-persistence.spec.ts -g "persists" || echo "run $i: FAIL"; done
```

Use pnpm ≥10.22.0 locally (release CI pin; transitively-dropped deps on 10.29.3+ — `project_pnpm_pin`).

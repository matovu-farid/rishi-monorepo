# Test infrastructure observations — B-T10

Notes on shared harness / helpers surfaced by auditing
`search.spec.ts`, `tutorial.spec.ts`, `window-split.spec.ts`.

## Helpers in play

- `launchApp({ keepOnboarding?: boolean })` — returns
  `{ app: ElectronApplication, page: Page }`. Used by all three specs.
- `closeApp(launched)` — afterAll teardown.
- `importBook(page, { fixturePath, kind, title? })` — IPC-based import,
  returns `{ id }`.
- `openBook(page, bookId)` — opens the book in a new window.
- `deleteAllBooks(page)` — used by `search.spec.ts` only.

## Gaps in the helper surface

1. **`openBook` lacks a documented "wait until window mounted" contract.**
   Window-split tests compensate with `waitForTimeout(800|1000)`. The
   helper should await `app.waitForEvent('window')` and the new page's
   `waitForLoadState('domcontentloaded')` so callers can drop the
   `waitForTimeout`s. See finding B132 and practices audit.

2. **No `closeAllModals()` / `dismissOnboarding()` helper.**
   `tutorial.spec.ts` reinvents this in its `beforeEach` (L23-29). The
   same pattern appears in `scanner.spec.ts` and elsewhere per the plan.
   Centralize once; callers shouldn't replicate conditional-modal logic.

3. **No `waitForWindowCount(app, n, opts)` helper.** All three
   window-split tests would benefit from a single
   `await expect.poll(() => app.windows().length, opts).toBe(n)` wrapper.

4. **No `setLocalStorage(page, keys)` / `clearLocalStorage(page, keys)`
   helper.** `tutorial.spec.ts` hand-rolls
   `page.evaluate(() => localStorage.removeItem(...))` for three keys.
   `search.spec.ts` would benefit too if it ever needed to seed search
   history. Factor out.

5. **Fixture inventory is opaque.** `EPUB_FIXTURE` / `PDF_FIXTURE` are
   imported but nothing documents their token contents. Plan §2.8 calls
   out the need for a "known token in fixture" for the search assertion —
   without a fixture-content manifest, testers can't write the
   `r.length > 0` assertion confidently. Add a
   `e2e/fixtures/MANIFEST.md` (or typed export) listing known tokens
   per fixture (`{ fixture: 'sample.epub', tokens: ['the', 'chapter'] }`).

## Shared-instance fragility

- `search.spec.ts` and `tutorial.spec.ts` both use a single
  `beforeAll(launchApp)` for the entire `describe`. Test order matters.
  Playwright defaults to file-level parallelism, so within-file order is
  declaration order — but if anyone runs `--workers > 1` against the
  same userData dir, these will collide.
- `window-split.spec.ts` correctly uses per-test `launchApp` and is the
  cleanest of the three on this axis.

## Suggested helper additions (priority order)

| Priority | Helper | Why |
|----------|--------|-----|
| P0 | `openBook` waits for window mount | Removes 5 `waitForTimeout`s; eliminates race in B132 |
| P0 | `waitForWindowCount(app, n)` | Replaces fixed timeouts in window-split |
| P1 | `dismissOnboarding(page)` / `closeAllModals(page)` | De-duplicates tutorial+scanner+library setup |
| P1 | Fixture manifest with known tokens | Unblocks meaningful search assertions |
| P2 | `withFreshApp(fn)` per-test helper | Migration path off `beforeAll(launchApp)` in search + tutorial |

## Test command reference (from plan §4)

```
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm --filter rishi-electron build
pnpm test:e2e e2e/search.spec.ts
pnpm test:e2e e2e/tutorial.spec.ts
pnpm test:e2e e2e/window-split.spec.ts
```

Flake-check (recommended for window-split before closing this audit):

```
for i in 1 2 3 4 5; do
  pnpm test:e2e e2e/window-split.spec.ts || echo "run $i FAIL"
done
```

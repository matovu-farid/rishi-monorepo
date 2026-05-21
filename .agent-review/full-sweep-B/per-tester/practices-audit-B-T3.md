# Practices Audit — B-T3 (PDF e2e)

Scope: `pdf-import.spec.ts`, `pdf-persistence.spec.ts`, `pdf-reader.spec.ts`.

Practice violations are anti-patterns that do not currently demonstrate a production bug but increase fragility, false-negatives, or maintenance cost. Per pilot §4.3 these are **not** findings.

---

## PA-T3-1: `waitForTimeout` proliferation

Every B-T3 spec uses fixed-duration `waitForTimeout` as a settle pause where Playwright's auto-wait (`expect(...).toBeVisible({ timeout })`, `expect.poll`, `waitForFunction`) would be more robust.

Inventory:

| File | Line | Duration | Purpose |
|---|---|---|---|
| `pdf-import.spec.ts` | 30 | 500 | post-hash-reset settle |
| `pdf-import.spec.ts` | 45 | 1500 | post-reload settle |
| `pdf-import.spec.ts` | 55 | 3000 | post-open settle (no assertion follows) |
| `pdf-import.spec.ts` | 78 | 1500 | post-reload settle |
| `pdf-persistence.spec.ts` | 22 | 3000 | post-open renderer settle |
| `pdf-persistence.spec.ts` | 34 | 1500 | post-scroll debounce settle |
| `pdf-persistence.spec.ts` | 45 | 1500 | post-closeBook IPC settle |
| `pdf-persistence.spec.ts` | 48 | 3000 | post-reopen settle |
| `pdf-reader.spec.ts` | 34 | 3000 | `beforeEach` post-open settle (shared) |
| `pdf-reader.spec.ts` | 51 | 300 | post-ArrowRight |
| `pdf-reader.spec.ts` | 53 | 300 | post-ArrowLeft |
| `pdf-reader.spec.ts` | 64 | 2000 | post-hash-mutation settle |

The 3000ms after `openBook` is particularly load-bearing — if the renderer settles faster on a fast machine, the test still waits; on a slow machine, the test may proceed before settle. Both directions are wrong.

Recommended pattern: `await expect.poll(() => getBookLocation(app.page, book.id), { timeout: 10000 }).not.toBeUndefined()` or wait on the first canvas to be visible.

## PA-T3-2: Implementation-detail CSS-class locators

`div.overflow-y-scroll` appears at `pdf-import.spec.ts:52` and `pdf-persistence.spec.ts:30`. This is a Tailwind utility class on the PDF reader's scroll container. Renaming the container class (Tailwind v4 migration, refactor to CSS Modules, etc.) silently breaks the persistence path's `scrollTo` call (`pdf-persistence.spec.ts:30-32` throws `'no scroll container'`) — masking the user-visible behavior (page-not-persisting) behind a test error that looks like an infrastructure failure.

Recommendation: add `data-testid="pdf-scroll-container"` (or aria role) on the production element; locate via testid.

## PA-T3-3: `toBeVisible` on `body`

`pdf-reader.spec.ts:54` and `:65`. Tautological — `body` is visible unless the renderer whitescreens. See findings B041, B042 for the cases promoted to findings; this audit entry captures the pattern itself for repo-wide policy.

## PA-T3-4: `text=...` locators (i18n-fragile)

`pdf-import.spec.ts:34` (`text=Add Book`), `:35` (`text=No books yet`), `:79` (`text=No books yet`). These break the moment the library copy changes or i18n lands. Prefer `data-testid` or `aria-label`.

## PA-T3-5: `toBeAttached` where `toBeVisible` is the contract

`pdf-import.spec.ts:52` — attached is weaker than visible (an offscreen / `display:none` / `visibility:hidden` element is attached). For "the reader's unmistakable shell" the test should assert visible.

## PA-T3-6: Shared `beforeAll` + reused `bookId` across tests

`pdf-reader.spec.ts:17-25` imports one book in `beforeAll` and reuses `bookId` across all four tests. Pilot §2.4 flagged the same in `mobi.spec.ts`. Risks:

- Test order dependence: persisted page from the keyboard-nav test (if Arrow keys actually advance the page) leaks into the next test's `beforeEach openBook`.
- Failure of any test in the middle leaves the book imported for downstream tests, masking cleanup bugs.

Recommendation: per-test import OR explicit reset-to-page-1 in `beforeEach` after open.

## PA-T3-7: `page.reload()` in a test whose name doesn't mention reload

`pdf-import.spec.ts:44`. The "PDF imports, opens, and renders" test reloads the library between import and open. This is hidden coverage of persistence-on-reload bundled into a test about import lifecycle. Either split (two tests) or rename.

## PA-T3-8: Magic scroll value

`pdf-persistence.spec.ts:32` scrolls `top: 6000` to cross a page boundary. If the fixture PDF page height changes, the test's `toBeGreaterThan(1)` (L36) fails for a fixture reason, not a production reason. Recommendation: compute scroll target from the first page's bounding box, or scroll by a known multiple of page height.

## PA-T3-9: Format-coupled location parser

`pdf-persistence.spec.ts:24` — `Number((loc ?? '0').split(':')[0])`. Hard-codes the `'<page>:<offset>'` location encoding. If PDF later moves to CFI-like locations, this silently returns `NaN` / `0` and `toBe(pageOf(afterScroll))` could pass as `0 === 0` for entirely broken data. Borderline-finding (see B036 slot, not promoted); flagged here as practice.

---

Total practice violations: 9. None promoted to findings (findings B031/B041/B042 are about missing/weak assertions, not the patterns above).

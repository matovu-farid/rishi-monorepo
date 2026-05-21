# Parity gaps — B-T10 (search, tutorial, window-split)

Each entry: spec + behavior that has no test, with a one-line rationale.

## search.spec.ts

1. **No cross-format search coverage.** Only EPUB is exercised (L17-22 import a
   single EPUB fixture). PDF, MOBI, and AZW3 search paths each have distinct
   text-extraction pipelines and could regress independently. Add at minimum
   a PDF `searchBookText` round-trip against a known fixture token.

2. **No assertion on result shape or content.** `Array.isArray(r)` (L48) does
   not cover the per-match contract — no test pins `{ chapterId, cfi/page,
   snippet, matchStart, matchEnd }` (or whatever the actual schema is). A
   schema-shape regression in the IPC return value is invisible.

3. **No "no results" path.** A query guaranteed to miss (e.g. a UUID string)
   should return `[]` deterministically. Currently untested — the broken
   path "throws on empty" vs "returns []" is unconstrained.

4. **No empty-query / invalid-bookId edge cases.** What does
   `searchBookText('', bookId)` return? `searchBookText('the', -1)`?
   Neither is asserted. Both are obvious input-validation surfaces.

5. **No library-search-input → results-list wiring test.** L30-40 only
   round-trips the input value; there is no test that typing into the
   search box filters the library grid. The user-facing search UX is
   uncovered end-to-end.

## tutorial.spec.ts

6. **No "tour completes all steps" test.** Plan §2.9. Tests cover step 1
   target, 1→2 advance, skip, and persistence. A middle step (step 2→3,
   3→4, etc.) being broken would pass all four current tests. Add an
   iterate-Next-to-completion test that asserts the final-step state
   transitions to `tour-completed = '1'` without skip.

7. **No interrupted-tour-resume test.** Plan §2.9. If a user closes the
   app mid-tour (step 2 of 4), reopens, does the tour resume at step 2,
   restart at step 1, or stay dismissed? Unconstrained behavior.

8. **No target-attachment assertion beyond step 1.** L32 asserts
   `[data-tour="import-books"]` is attached for step 1. No equivalent for
   step 2 (`[data-tour="book-grid"]` or whatever the step 2 anchor is).
   A regression that renders step 2 popper detached from its target
   passes.

9. **No "Back/Previous" coverage.** Tests cover Next + Skip only. If the
   tour exposes a Back affordance, its behavior is untested.

10. **No keyboard / a11y coverage.** Esc to dismiss, Tab through popper
    controls, focus trap — all untested.

## window-split.spec.ts

11. **No "re-open raises existing window" assertion.** Plan §2.10. The
    duplicate-prevention test (L35-52) verifies count stays at 2 but not
    that the existing book window gains focus. A regression that
    silently no-ops the second open (instead of raising) passes.

12. **No closed-then-reopened windowIdentity test.** Plan §2.10. Close the
    book window, reopen the same book — does the new window have the
    same `windowIdentity.bookId`? Does it reuse window bounds/zoom?
    Uncovered.

13. **No cross-window state sync.** Plan §2.10. If the library window
    deletes a book whose window is open, what happens to the book
    window? If metadata (title/cover) is edited in one, does the other
    reflect it? Out of scope for this spec but no spec covers it.

14. **No three-or-more-windows test.** Open 3+ book windows + library —
    the count assertion shape (`length === N`) is only tested up to
    N=3. A regression that caps at 3 windows would not be caught.

15. **No "close book window leaves library running" test.** Window
    lifecycle on close (does closing the last book window keep library
    alive? does closing library close all books?) is uncovered. macOS
    vs Windows differ here — platform-conditional behavior is
    completely untested.

---
id: B056
spec: e2e/menu-book-epub.spec.ts
status: rejected
created: 2026-05-20
reviewer1_agent_type: feature-dev:code-reviewer
dispatches_used: 1
---

## Bug Summary
`menu-book-epub.spec.ts` asserts `Show Thumbnails` and `Dual Page` are
`undefined` under `View`, but the path resolves to `undefined` whenever the
entire `View` submenu is absent (e.g. if `menuBuilder` regressed and dropped
View for EPUB context). The negative assertions pass vacuously, giving a
false sense of safety. Format-enablement parity is therefore *not* actually
guarded by this test — a bug that nukes the View submenu in EPUB would slip
through, even though the spec exists specifically to assert PDF-only items
are hidden.

## Reproduction
- Test file: `apps/rishi-electron/e2e/menu-book-epub.spec.ts` lines `42-46`
- Failing assertion (today's text):
  ```
  expect(findMenuItem(menu, ['View', 'Show TOC'])).toBeDefined()
  expect(findMenuItem(menu, ['View', 'Show Thumbnails'])).toBeUndefined()
  expect(findMenuItem(menu, ['View', 'Dual Page'])).toBeUndefined()
  ```
- How to run:
  `cd apps/rishi-electron && pnpm test:e2e e2e/menu-book-epub.spec.ts`

## Tester Analysis
`findMenuItem(menu, ['View', 'X'])` walks the tree and returns `undefined`
either when (a) View exists but X is missing (the intended assertion) or
(b) View itself is missing. Only case (a) corresponds to the format-gating
invariant in `src/main/menu/menuBuilder.ts:60-99` ("PDF-only items appear
under View only when context is PDF"). A regression in `menuBuilder.ts`
that conditionally omits the View submenu in EPUB context (or renames it)
satisfies the negative assertions vacuously while breaking user-visible
behavior. The positive `Show TOC` check on L44 partially mitigates by
asserting at least one EPUB-only item exists, but if `Show TOC` is gated
on a runtime flag (e.g. presence of TOC entries) and the EPUB fixture
yields none, the test could flip from "vacuous-pass on negatives" to
"failure on Show TOC" — masking the underlying View-presence gap.

The fix is to assert `findMenuItem(menu, ['View'])).toBeDefined()` first,
then the negative leaf assertions. This is a production-contract gap in
the test, but it directly enables a category of production regressions
(missing View menu in EPUB context) to ship undetected.

## Reviewer-1 Verdict: INVALID
**Agent type:** general-purpose
**Flake check:** N/A (static analysis only)
**Reasoning:** Vacuous-pass scenario is doubly guarded by existing code: (1) `menuBuilder.ts:164` unconditionally pushes `{ label: 'View', submenu: viewSubmenu }` into top-level — there is no code path that omits View; (2) `menuBuilder.ts:67-77` unconditionally adds `Show TOC` whenever `ctx.kind === 'book'` with no runtime flag (tester's speculation about TOC-entry gating is unfounded — the menu item is added based on `kind`, not on TOC content). The positive `Show TOC` assertion on L44 therefore already requires View to exist AND contain a known EPUB-book item, fully refuting case (b). The theoretical regression class (View dropped) cannot satisfy L44, so negative assertions on L45-46 are not actually vacuous in practice. Test-quality nit at best; no production-contract gap.
**Suggested fix scope:** No fix needed; optional defensive `expect(findMenuItem(menu, ['View'])).toBeDefined()` is hygiene, not bug-shield.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan
status: no-op (INVALID)
commit: n/a
notes: Reviewer-1 verdict is INVALID and suggested fix scope is "No fix needed".
The negative assertions on L45-46 are not vacuous in practice: the positive
`Show TOC` assertion on L44 already requires the View submenu to exist and
contain an EPUB-only item, refuting the "View dropped" regression class.
No code change applied; finding closed as INVALID.

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict

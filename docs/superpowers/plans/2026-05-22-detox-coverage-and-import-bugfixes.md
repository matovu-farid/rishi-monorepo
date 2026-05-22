# Detox Coverage Expansion + Import-Path Bug Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the two PDF-import-path bugs surfaced by the user (GestureHandlerRootView at root + indexBook noise) and extend the Detox suite from "reader screen mounts" smoke assertions to functional reading (open → assert position indicator → navigate one page → assert position changed) across EPUB / PDF / MOBI / AZW3. Stub DJVU.

**Architecture:**
- Bug fixes are JS-only: wrap root `<Slot />` in `<GestureHandlerRootView>`, and gate the fire-and-forget `indexBook()` call on `IS_E2E_TEST || !sessionToken`.
- Each reader exposes one new always-mounted invisible `<View testID="reader-position-indicator" accessibilityLabel={positionString} />` so Detox can read the current position regardless of toolbar visibility. EPUB+PDF rely on their native swipe gesture for navigation; MOBI+DJVU use a new `testID="reader-next-page-btn"` on their existing toolbar button (Detox taps the reader to show toolbar first).
- AZW3 imports through the existing MOBI reader path (verified in Task 3); a new fixture + entries in three format unions are required, but no new reader screen.

**Tech Stack:**
- Detox 20.x on iOS Simulator (iPhone 17 / iOS 26.2)
- Expo 54 / React Native 0.81 / expo-router 6
- `@gorhom/bottom-sheet` 5 + `react-native-gesture-handler` 2
- TypeScript / Jest 30 / ts-jest

**Spec:** [docs/superpowers/specs/2026-05-22-detox-coverage-and-import-bugfixes-design.md](../specs/2026-05-22-detox-coverage-and-import-bugfixes-design.md)

---

## File Inventory

**New files:**
- `apps/mobile/e2e/fixtures/test-book.azw3` (binary — copied from electron)
- `apps/mobile/e2e/reader-azw3.test.ts`
- `apps/mobile/e2e/reader-djvu.test.ts` (deferred — `describe.skip`)

**Modified files (bug fixes):**
- `apps/mobile/app/_layout.tsx` — wrap children in `GestureHandlerRootView`
- `apps/mobile/lib/file-import.ts` — gate `indexBook` at two call sites

**Modified files (reader instrumentation):**
- `apps/mobile/app/reader/[id].tsx` (EPUB) — add position indicator
- `apps/mobile/app/reader/pdf/[id].tsx` — add position indicator
- `apps/mobile/app/reader/mobi/[id].tsx` — add position indicator + next-page testID + `mobi-reader` testID confirmed on root
- `apps/mobile/app/reader/djvu/[id].tsx` — add `djvu-reader` root testID + position indicator + next-page testID

**Modified files (seed bridge — add `azw3`):**
- `apps/mobile/e2e/helpers/seed-book.ts` — extend `SeedFormat` union
- `apps/mobile/app/_layout.tsx` (`handleE2ESeedLink`) — extend accepted format list

**Modified files (existing tests extended):**
- `apps/mobile/e2e/reader-pdf.test.ts` — add functional navigation
- `apps/mobile/e2e/reader-epub.test.ts` — add functional navigation
- `apps/mobile/e2e/reader-mobi.test.ts` — add functional navigation
- `apps/mobile/e2e/library.test.ts` — extend format loop with `azw3`

---

## Task 0: Verify AZW3 reader routing

Before doing any AZW3 work, confirm which reader handles `format='azw3'`. The picker code at `lib/file-import.ts:144` stores AZW3 with `format: 'azw3'`, but there's no `app/reader/azw3/` directory. Need to find the dispatcher.

**Files:**
- Read: `apps/mobile/components/BookRow.tsx`
- Read: `apps/mobile/app/reader/_layout.tsx` (if it does format-based redirection)

- [ ] **Step 1: Find routing logic for opening a book by format**

Run:
```bash
grep -n "router.push\|format" apps/mobile/components/BookRow.tsx apps/mobile/app/reader/_layout.tsx apps/mobile/app/\(tabs\)/index.tsx
grep -rn "reader/azw3\|format === 'azw3'\|'azw3'" apps/mobile/app apps/mobile/components apps/mobile/lib | head -30
```

Expected: one of these outcomes—

- **(A)** AZW3 routes to `/reader/mobi/[id]` (MOBI reader handles both `.mobi` and `.azw3`). No new reader needed; AZW3 test asserts against `mobi-reader` testID.
- **(B)** AZW3 routes to `/reader/[id]` (EPUB reader). No new reader needed; AZW3 test asserts against `reader-epub` testID.
- **(C)** AZW3 has its own reader route or is unrouted. New work needed — escalate to user before proceeding.

- [ ] **Step 2: Document the finding inline in this plan**

> **Finding:** AZW3 routes to `/reader/[id]` (option B — EPUB reader). The only book-format dispatcher is `apps/mobile/app/(tabs)/index.tsx:85-98` (`handleBookPress`), which has explicit branches for `'pdf'`, `'mobi'`, and `'djvu'` and falls through to `router.push(\`/reader/${book.id}\`)` (the EPUB reader) for everything else. Since `lib/file-import.ts:144` stores AZW3 with `format: 'azw3'` and `lib/book-storage.ts:139-151` preserves that format on read (`row.format as Book['format']`), an AZW3 book's `format` value at tap time is `'azw3'`, which does not match any explicit branch and therefore hits the EPUB else-clause. The R2-download adapter at `lib/book-storage.ts:81-82` does collapse `azw3 → mobi` for the download port, but only for the storage bucket key — it does NOT change the in-memory `Book.format`, so it does not affect routing. There is no `app/reader/azw3/` directory and no other dispatcher (`grep -rn "router.push.*reader"` returned only the index.tsx branches plus `app/chat/[bookId].tsx:161` which is the chat→reader return path, not format-aware). The AZW3 Detox test will therefore assert against `reader-epub` testID and `reader-position-indicator`. Note: Task 11 below currently scripts against `mobi-reader` (assuming option A) — update those testIDs when executing Task 11.

If outcome is (C), STOP and surface to the user — Tasks 11 (AZW3 reader test) will need to be re-planned.

- [ ] **Step 3: Commit the documented finding**

```bash
git add docs/superpowers/plans/2026-05-22-detox-coverage-and-import-bugfixes.md
git commit -m "docs(plan): document AZW3 reader routing finding"
```

---

## Task 1: Bug fix — wrap root layout in GestureHandlerRootView

The PDF reader crashes on mount because `app/_layout.tsx:202` renders `<Slot />` without a `<GestureHandlerRootView>` ancestor; `<NoteEditor>`'s `BottomSheet` internals throw `GestureDetector must be used as a descendant of GestureHandlerRootView`. Per `react-native-gesture-handler` docs, the canonical fix is wrapping the root.

**Files:**
- Modify: `apps/mobile/app/_layout.tsx` (both the E2E branch at line 199-207 and the production branch at line 209-220)

- [ ] **Step 1: Add the import**

Edit `apps/mobile/app/_layout.tsx`. After line 13 (`import '../global.css'`), add:

```ts
import { GestureHandlerRootView } from 'react-native-gesture-handler'
```

- [ ] **Step 2: Wrap the E2E branch**

Replace this block in `apps/mobile/app/_layout.tsx` (currently lines ~199-207):

```tsx
  if (IS_E2E_TEST) {
    return (
      <ThemeProvider value={colorScheme === 'dark' ? DarkTheme : DefaultTheme}>
        <Slot />
        <RagExtractorHost />
        <StatusBar style="auto" />
      </ThemeProvider>
    )
  }
```

with:

```tsx
  if (IS_E2E_TEST) {
    return (
      <GestureHandlerRootView style={{ flex: 1 }}>
        <ThemeProvider value={colorScheme === 'dark' ? DarkTheme : DefaultTheme}>
          <Slot />
          <RagExtractorHost />
          <StatusBar style="auto" />
        </ThemeProvider>
      </GestureHandlerRootView>
    )
  }
```

- [ ] **Step 3: Wrap the production branch**

Replace this block in `apps/mobile/app/_layout.tsx` (currently lines ~209-220):

```tsx
  return (
    <ThemeProvider value={colorScheme === 'dark' ? DarkTheme : DefaultTheme}>
      <Slot />
      {/*
        Hidden host that drives pdfjs / djvu.js text extraction inside
        WebViews on demand. Mounted at root so import jobs can extract
        text regardless of which screen the user is on. See
        lib/rag/extractors/* + lib/rag/chunker.ts for the contract.
       */}
      <RagExtractorHost />
      <StatusBar style="auto" />
```

with:

```tsx
  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <ThemeProvider value={colorScheme === 'dark' ? DarkTheme : DefaultTheme}>
        <Slot />
        {/*
          Hidden host that drives pdfjs / djvu.js text extraction inside
          WebViews on demand. Mounted at root so import jobs can extract
          text regardless of which screen the user is on. See
          lib/rag/extractors/* + lib/rag/chunker.ts for the contract.
         */}
        <RagExtractorHost />
        <StatusBar style="auto" />
```

Then ensure the trailing closing tag (currently `</ThemeProvider>` followed by the surrounding wrapper) closes the new `<GestureHandlerRootView>`. Read lines 220-230 first and add `</GestureHandlerRootView>` after `</ThemeProvider>` before the function returns.

- [ ] **Step 4: Type-check**

Run:
```bash
cd apps/mobile && npx tsc --noEmit -p tsconfig.json
```

Expected: zero errors related to the change. Pre-existing errors in unrelated files are acceptable.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/app/_layout.tsx
git commit -m "fix(mobile): wrap root layout in GestureHandlerRootView

PDF reader was crashing on mount because NoteEditor's BottomSheet
internals invoke GestureDetector without a GestureHandlerRootView
ancestor. Only app/reader/[id].tsx (EPUB) wrapped its subtree; PDF /
MOBI / DJVU routes had no wrapper. Lifting the wrapper to the root
fixes all of them and is the canonical setup per
react-native-gesture-handler docs."
```

---

## Task 2: Bug fix — gate indexBook on E2E / unauthenticated

`indexBook()` calls a Worker endpoint that requires a session token. In E2E mode there's no real session, so it always fails with `"Unable to obtain Worker session token. User must sign in."`. In production when the user is unauthenticated (rare but possible), it spams logs and triggers pointless retries. Skip the call in both cases; log once at info level.

**Files:**
- Modify: `apps/mobile/lib/file-import.ts:80-88` (real import path)
- Modify: `apps/mobile/lib/file-import.ts:311-315` (E2E fixture seed path)
- Test: `apps/mobile/__tests__/file-import-index-gate.test.ts` (NEW unit test)

- [ ] **Step 1: Write the failing unit test**

Create `apps/mobile/__tests__/file-import-index-gate.test.ts`:

```ts
/**
 * Unit test for the indexBook gating logic in lib/file-import.ts.
 *
 * We don't import file-import.ts directly because it depends on
 * expo-file-system (which requires the native module). Instead, we
 * test the pure predicate `shouldSkipIndexing` which both call sites
 * use to decide whether to fire indexBook.
 */
import { describe, it, expect } from '@jest/globals'
import { shouldSkipIndexing } from '@/lib/file-import-index-gate'

describe('shouldSkipIndexing', () => {
  it('skips when E2E mode is on, regardless of token', () => {
    expect(shouldSkipIndexing({ isE2E: true, sessionToken: 'tok' })).toBe(true)
    expect(shouldSkipIndexing({ isE2E: true, sessionToken: null })).toBe(true)
  })

  it('skips in production when no session token is present', () => {
    expect(shouldSkipIndexing({ isE2E: false, sessionToken: null })).toBe(true)
  })

  it('proceeds in production when a session token is present', () => {
    expect(shouldSkipIndexing({ isE2E: false, sessionToken: 'tok' })).toBe(false)
  })

  it('treats empty-string token as missing', () => {
    expect(shouldSkipIndexing({ isE2E: false, sessionToken: '' })).toBe(true)
  })
})
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd apps/mobile && npx jest __tests__/file-import-index-gate.test.ts
```

Expected: FAIL with `Cannot find module '@/lib/file-import-index-gate'`.

- [ ] **Step 3: Implement the pure predicate**

Create `apps/mobile/lib/file-import-index-gate.ts`:

```ts
/**
 * Pure predicate extracted from file-import.ts so the gating logic is
 * unit-testable without dragging in expo-file-system or the import
 * service. Both call sites in file-import.ts use this.
 *
 * Gating rules:
 *   - E2E mode always skips (no real backend session).
 *   - Production with no session token skips (avoids noisy Worker
 *     401s; indexing will retry next time the book opens after the
 *     user signs in, gated by vector-store.isBookEmbedded).
 *   - Production with a session token proceeds.
 */
export interface IndexGateInput {
  isE2E: boolean
  sessionToken: string | null
}

export function shouldSkipIndexing(input: IndexGateInput): boolean {
  if (input.isE2E) return true
  if (!input.sessionToken) return true
  return false
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd apps/mobile && npx jest __tests__/file-import-index-gate.test.ts
```

Expected: PASS, 4 tests green.

- [ ] **Step 5: Wire the predicate into both file-import.ts call sites**

Edit `apps/mobile/lib/file-import.ts`. After existing imports at the top, add:

```ts
import { IS_E2E_TEST } from "@/app/_layout";
import { getSessionToken } from "@/lib/auth";
import { shouldSkipIndexing } from "@/lib/file-import-index-gate";
```

Replace the block at lines 84-88:

```ts
  void service
    .indexBook(bookId, undefined, bookPath, opts.format)
    .catch((err) => {
      console.warn("[file-import] indexBook failed:", err);
    });
```

with:

```ts
  void (async () => {
    const sessionToken = await getSessionToken().catch(() => null);
    if (shouldSkipIndexing({ isE2E: IS_E2E_TEST, sessionToken })) {
      console.info(
        `[file-import] skipping indexBook for ${bookId} (isE2E=${IS_E2E_TEST}, hasToken=${!!sessionToken})`,
      );
      return;
    }
    try {
      await service.indexBook(bookId, undefined, bookPath, opts.format);
    } catch (err) {
      console.warn("[file-import] indexBook failed:", err);
    }
  })();
```

Replace the block at lines 311-315 (the E2E `importBookFromFile` path):

```ts
  void service
    .indexBook(opts.bookId, undefined, bookPath, opts.format)
    .catch((err) => {
      console.warn("[file-import] e2e indexBook failed:", err);
    });
```

with:

```ts
  void (async () => {
    const sessionToken = await getSessionToken().catch(() => null);
    if (shouldSkipIndexing({ isE2E: IS_E2E_TEST, sessionToken })) {
      console.info(
        `[file-import] skipping indexBook for ${opts.bookId} (isE2E=${IS_E2E_TEST}, hasToken=${!!sessionToken})`,
      );
      return;
    }
    try {
      await service.indexBook(opts.bookId, undefined, bookPath, opts.format);
    } catch (err) {
      console.warn("[file-import] e2e indexBook failed:", err);
    }
  })();
```

- [ ] **Step 6: Verify `getSessionToken` exists and is async**

Run:
```bash
grep -n "export.*getSessionToken\|export async function getSessionToken" apps/mobile/lib/auth.ts
```

Expected: a line showing `export` for `getSessionToken`. If the signature is synchronous, drop the `await` and `.catch()`. If the function doesn't exist, STOP and surface to user — auth.ts may use a different name.

- [ ] **Step 7: Type-check**

Run:
```bash
cd apps/mobile && npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E "file-import|file-import-index-gate" || echo "no errors in modified files"
```

Expected: `no errors in modified files`.

- [ ] **Step 8: Run all unit tests to confirm no regression**

Run:
```bash
cd apps/mobile && npx jest
```

Expected: all pre-existing tests still pass; the new file-import-index-gate test passes.

- [ ] **Step 9: Commit**

```bash
git add apps/mobile/lib/file-import-index-gate.ts apps/mobile/lib/file-import.ts apps/mobile/__tests__/file-import-index-gate.test.ts
git commit -m "fix(mobile): skip indexBook in E2E or when unauthenticated

indexBook hits a Worker endpoint that requires a session token. In
E2E mode there is no real session and the call always 401s with a
loud warning. Same in prod for unauthenticated users — log spam plus
pointless retry queue churn.

Extract the gating into a pure predicate (lib/file-import-index-gate)
so it is unit-testable without expo-file-system. Both call sites in
file-import.ts use it and log at info level when skipping. Indexing
still retries opportunistically on next book-open via
vector-store.isBookEmbedded."
```

---

## Task 3: Add `azw3` to seed bridge format unions

The seed bridge needs to accept `'azw3'` end-to-end. Three places: the host-side `SeedFormat` type, the in-app deep-link handler's accepted formats, and (already) the shared `BookFormat`-typed `seedBookFromFixture` which is fine. Also copy the fixture from electron.

**Files:**
- Modify: `apps/mobile/e2e/helpers/seed-book.ts`
- Modify: `apps/mobile/app/_layout.tsx` (`handleE2ESeedLink`)
- Create: `apps/mobile/e2e/fixtures/test-book.azw3` (binary copy)

- [ ] **Step 1: Copy the AZW3 fixture from electron**

Run:
```bash
cp /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron/e2e/fixtures/test-book.azw3 \
   /Users/faridmatovu/projects/rishi-monorepo/apps/mobile/e2e/fixtures/test-book.azw3
ls -la /Users/faridmatovu/projects/rishi-monorepo/apps/mobile/e2e/fixtures/
```

Expected: `test-book.azw3` (~252 KB) listed alongside `test-book.epub`, `test-book.mobi`, `test-book.pdf`.

- [ ] **Step 2: Extend `SeedFormat` in `e2e/helpers/seed-book.ts`**

Edit `apps/mobile/e2e/helpers/seed-book.ts`. Find:

```ts
export type SeedFormat = 'epub' | 'pdf' | 'mobi' | 'djvu'
```

Replace with:

```ts
export type SeedFormat = 'epub' | 'pdf' | 'mobi' | 'azw3' | 'djvu'
```

- [ ] **Step 3: Extend the format check in `_layout.tsx` `handleE2ESeedLink`**

Edit `apps/mobile/app/_layout.tsx`. Find this block (currently around lines ~80-90):

```ts
  if (action === 'seed-book') {
    const format = String(params.format ?? '') as
      | 'epub'
      | 'pdf'
      | 'mobi'
      | 'djvu'
    if (!['epub', 'pdf', 'mobi', 'djvu'].includes(format)) {
      console.warn(`[e2e-seed] unknown format: ${format}`)
      return
    }
    await seedModule.seedBookFromFixture(format)
    return
  }
```

Replace with:

```ts
  if (action === 'seed-book') {
    const format = String(params.format ?? '') as
      | 'epub'
      | 'pdf'
      | 'mobi'
      | 'azw3'
      | 'djvu'
    if (!['epub', 'pdf', 'mobi', 'azw3', 'djvu'].includes(format)) {
      console.warn(`[e2e-seed] unknown format: ${format}`)
      return
    }
    await seedModule.seedBookFromFixture(format)
    return
  }
```

- [ ] **Step 4: Type-check the e2e and app modifications**

Run:
```bash
cd apps/mobile && npx tsc --noEmit -p e2e/tsconfig.json && npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E "seed-book|_layout" || echo "no errors in modified files"
```

Expected: `no errors in modified files`.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/e2e/fixtures/test-book.azw3 apps/mobile/e2e/helpers/seed-book.ts apps/mobile/app/_layout.tsx
git commit -m "test(mobile): wire azw3 into E2E seed bridge

Copy the AZW3 fixture from apps/rishi-electron/e2e/fixtures/ and
extend the seed-bridge format unions (SeedFormat + the deep-link
handler's accepted list). The shared seedBookFromFixture already
accepts every BookFormat, so no app-side changes beyond the type
union are needed."
```

---

## Task 4: Add position indicator to PDF reader

Add an always-mounted invisible `<View testID="reader-position-indicator" />` whose `accessibilityLabel` reflects `pageNumber/pageCount`. This lets Detox read the current page regardless of whether the toolbar is visible.

**Files:**
- Modify: `apps/mobile/app/reader/pdf/[id].tsx` (around line 441 where the root `<View testID="pdf-reader">` opens)

- [ ] **Step 1: Add the position indicator inside the PDF reader root view**

Edit `apps/mobile/app/reader/pdf/[id].tsx`. Find the root view at line 441:

```tsx
    <View ref={pageCaptureRef} testID="pdf-reader" style={{ flex: 1, backgroundColor: '#000' }}>
```

Add this child element as the FIRST child inside that `<View>` (immediately after the opening tag, before any existing content):

```tsx
      {/*
        E2E observability — invisible indicator that exposes the current
        page as an accessibilityLabel that Detox can read via
        `by.id('reader-position-indicator')`. Permanently mounted so
        tests don't need to tap to reveal the toolbar first.
       */}
      <View
        testID="reader-position-indicator"
        accessible={true}
        accessibilityLabel={`${pageNumber || 1}/${pageCount || 0}`}
        style={{ position: 'absolute', width: 0, height: 0 }}
      />
```

- [ ] **Step 2: Type-check**

Run:
```bash
cd apps/mobile && npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E "reader/pdf" || echo "no errors in modified files"
```

Expected: `no errors in modified files`.

- [ ] **Step 3: Commit**

```bash
git add 'apps/mobile/app/reader/pdf/[id].tsx'
git commit -m "test(mobile): add reader-position-indicator to PDF reader

Always-mounted invisible View whose accessibilityLabel reflects
\`{pageNumber}/{pageCount}\`. Lets Detox observe page changes without
having to first reveal the toolbar (where the visible page counter
lives)."
```

---

## Task 5: Add position indicator + next-page testID to MOBI reader

MOBI reader root already has `testID="mobi-reader"`. Add the position indicator and a testID on the existing "next chapter" button so Detox can drive navigation.

**Files:**
- Modify: `apps/mobile/app/reader/mobi/[id].tsx`

- [ ] **Step 1: Add the position indicator inside the MOBI reader root view**

Edit `apps/mobile/app/reader/mobi/[id].tsx`. Find the root view at line 435:

```tsx
    <View ref={pageCaptureRef} testID="mobi-reader" style={{ flex: 1, backgroundColor: '#fafaf8' }}>
```

Add as the FIRST child inside that `<View>`:

```tsx
      {/* E2E observability — see PDF reader for rationale. */}
      <View
        testID="reader-position-indicator"
        accessible={true}
        accessibilityLabel={`${currentChapter + 1}/${chapterCount || 0}`}
        style={{ position: 'absolute', width: 0, height: 0 }}
      />
```

- [ ] **Step 2: Add the testID to the existing "next chapter" button**

Find the next-chapter button in `apps/mobile/app/reader/mobi/[id].tsx` — around line 559 (the second nav button, the one with `disabled={currentChapter >= chapterCount - 1}`). It's a `<TouchableOpacity>` or `<Pressable>`. Add `testID="reader-next-page-btn"` to its existing props.

Run this to find the exact line first:
```bash
grep -n "currentChapter >= chapterCount - 1" 'apps/mobile/app/reader/mobi/[id].tsx'
```

Then edit the element on that line, adding `testID="reader-next-page-btn"` to its prop list. Example: if the line currently reads:

```tsx
              disabled={currentChapter >= chapterCount - 1}
```

That's the prop on a wrapper. Find the enclosing `<TouchableOpacity ...>` or `<Pressable ...>` opening tag (a few lines above) and add `testID="reader-next-page-btn"` to it.

- [ ] **Step 3: Type-check**

Run:
```bash
cd apps/mobile && npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E "reader/mobi" || echo "no errors in modified files"
```

Expected: `no errors in modified files`.

- [ ] **Step 4: Commit**

```bash
git add 'apps/mobile/app/reader/mobi/[id].tsx'
git commit -m "test(mobile): add position indicator + next-page testID to MOBI reader

Position indicator exposes \`{currentChapter+1}/{chapterCount}\` via
accessibilityLabel for Detox. Existing toolbar 'next' button gets a
testID so tests can drive navigation after revealing the toolbar."
```

---

## Task 6: Add root testID + position indicator + next-page testID to DJVU reader

DJVU reader root currently has no testID (Task 0's discovery confirmed). Add `djvu-reader` to the root, plus the position indicator and next-page testID.

**Files:**
- Modify: `apps/mobile/app/reader/djvu/[id].tsx`

- [ ] **Step 1: Add `djvu-reader` testID to the root view**

Edit `apps/mobile/app/reader/djvu/[id].tsx`. Find line 359:

```tsx
    <View ref={pageCaptureRef} style={{ flex: 1, backgroundColor: '#1a1a1a' }}>
```

Replace with:

```tsx
    <View ref={pageCaptureRef} testID="djvu-reader" style={{ flex: 1, backgroundColor: '#1a1a1a' }}>
```

- [ ] **Step 2: Add the position indicator as the first child**

Add as the FIRST child inside that `<View>`:

```tsx
      {/* E2E observability — see PDF reader for rationale. */}
      <View
        testID="reader-position-indicator"
        accessible={true}
        accessibilityLabel={`${currentPage}/${pageCount || 0}`}
        style={{ position: 'absolute', width: 0, height: 0 }}
      />
```

- [ ] **Step 3: Add the testID to the existing "next page" button**

Run:
```bash
grep -n "currentPage >= pageCount" 'apps/mobile/app/reader/djvu/[id].tsx'
```

Find the `<TouchableOpacity>` opening tag enclosing that `disabled` prop and add `testID="reader-next-page-btn"`.

- [ ] **Step 4: Type-check**

Run:
```bash
cd apps/mobile && npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E "reader/djvu" || echo "no errors in modified files"
```

Expected: `no errors in modified files`.

- [ ] **Step 5: Commit**

```bash
git add 'apps/mobile/app/reader/djvu/[id].tsx'
git commit -m "test(mobile): add root testID + observability to DJVU reader

Adds 'djvu-reader' testID to the root view (was missing), plus the
position indicator and next-page testID matching MOBI/PDF/EPUB."
```

---

## Task 7: Add position indicator to EPUB reader

EPUB reader root already has `testID="reader-epub"`. Add the position indicator using the existing `currentCfi` ref and `currentHref` state. No navigation testID — EPUB tests use Detox `swipe()` because `enableSwipe={true}` is set on the `<Reader>`.

**Files:**
- Modify: `apps/mobile/app/reader/[id].tsx`

- [ ] **Step 1: Add the position indicator inside the root view**

Edit `apps/mobile/app/reader/[id].tsx`. Find line 606:

```tsx
    <View ref={pageCaptureRef} testID="reader-epub" style={{ flex: 1, backgroundColor: theme.background }}>
```

Add as the FIRST child inside that `<View>`:

```tsx
      {/*
        E2E observability — exposes the current CFI as
        accessibilityLabel. The CFI string mutates on every page turn
        (epubjs assigns it from the spine + character offset), so
        Detox can detect navigation by reading two snapshots and
        comparing.
       */}
      <View
        testID="reader-position-indicator"
        accessible={true}
        accessibilityLabel={currentHref ?? currentCfiRef.current ?? 'unknown'}
        style={{ position: 'absolute', width: 0, height: 0 }}
      />
```

Note: `currentCfiRef` is a ref, not state — its `.current` value won't trigger re-renders. `currentHref` is state and DOES re-render when location changes. Using `currentHref` as the primary signal is correct because epubjs fires `onLocationChange` (which calls `setCurrentHref`) on every page turn.

- [ ] **Step 2: Type-check**

Run:
```bash
cd apps/mobile && npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E "reader/\[id\]" || echo "no errors in modified files"
```

Expected: `no errors in modified files`.

- [ ] **Step 3: Commit**

```bash
git add 'apps/mobile/app/reader/[id].tsx'
git commit -m "test(mobile): add reader-position-indicator to EPUB reader

Uses currentHref (state, re-rendered on onLocationChange) as the
position string. Tests use Detox swipe() for navigation since
<Reader enableSwipe={true}> handles it directly — no toolbar button
needed."
```

---

## Task 8: Extend `reader-pdf.test.ts` to functional navigation

Builds on Tasks 1, 2, 4: PDF reader no longer crashes (Task 1) and exposes a position indicator (Task 4). Tests open the PDF, capture initial page indicator, swipe to next page, assert indicator changed.

**Files:**
- Modify: `apps/mobile/e2e/reader-pdf.test.ts`

- [ ] **Step 1: Add helper for reading accessibilityLabel**

Edit `apps/mobile/e2e/reader-pdf.test.ts`. At the top after existing imports, add:

```ts
/**
 * Read the accessibilityLabel of a testID-matched element. Detox does
 * not expose a direct "read label" API, so we use the attributes
 * snapshot. iOS returns labels under `label` (singular). Returns
 * `null` if the element cannot be resolved.
 */
async function readAccessibilityLabel(testID: string): Promise<string | null> {
  // @ts-expect-error — Detox `getAttributes()` returns an untyped record.
  const attrs = await element(by.id(testID)).getAttributes()
  if (!attrs) return null
  // iOS shape: `{ label: '...' }`. Android (when added later): `{ text: '...' }`.
  return (attrs.label ?? attrs.text ?? null) as string | null
}
```

- [ ] **Step 2: Add the functional navigation test**

Append to the existing `describe('reader: PDF — open from library', ...)` block in `apps/mobile/e2e/reader-pdf.test.ts`:

```ts
  it('swiping advances to the next page (position indicator updates)', async () => {
    // Read the starting position. The indicator's accessibilityLabel
    // is `"<pageNumber>/<pageCount>"`. We don't assert on a specific
    // page count because fixture page count is fixture-specific.
    const before = await readAccessibilityLabel('reader-position-indicator')
    expect(before).toMatch(/^\d+\/\d+$/)

    // Swipe left on the reader root to advance one page. react-native-pdf
    // natively handles horizontal swipes for paged navigation.
    await element(by.id('pdf-reader')).swipe('left', 'fast', 0.8)

    // The page indicator should update within ~3s. We retry-read it a
    // few times rather than relying on Detox `waitFor` matchers,
    // which don't observe accessibilityLabel mutations.
    let after: string | null = before
    const startedAt = Date.now()
    while (Date.now() - startedAt < 5000) {
      after = await readAccessibilityLabel('reader-position-indicator')
      if (after !== before) break
      await new Promise((r) => setTimeout(r, 250))
    }

    expect(after).not.toBe(before)
    expect(after).toMatch(/^\d+\/\d+$/)
  })
```

- [ ] **Step 3: Commit**

```bash
git add apps/mobile/e2e/reader-pdf.test.ts
git commit -m "test(mobile): extend reader-pdf to functional navigation

After tapping into the PDF reader, capture the position indicator,
swipe left, and assert the indicator changed. Catches the
GestureHandlerRootView class of crash (where the screen would mount
but the indicator would never update because the WebView/reader
torn down)."
```

---

## Task 9: Extend `reader-epub.test.ts` to functional navigation

**Files:**
- Modify: `apps/mobile/e2e/reader-epub.test.ts`

- [ ] **Step 1: Add the helper and functional test**

Edit `apps/mobile/e2e/reader-epub.test.ts`. At the top after existing imports, add the same `readAccessibilityLabel` helper from Task 8 Step 1.

Append to the existing `describe('reader: EPUB — open from library', ...)` block:

```ts
  it('swiping advances to the next page (CFI indicator updates)', async () => {
    // EPUB indicator carries currentHref (chapter href) or a CFI
    // string. We assert *change* rather than a specific value because
    // epubjs CFIs are fixture-dependent.
    const before = await readAccessibilityLabel('reader-position-indicator')
    expect(before).not.toBeNull()
    expect(before).not.toBe('unknown')

    await element(by.id('reader-epub')).swipe('left', 'fast', 0.8)

    let after: string | null = before
    const startedAt = Date.now()
    while (Date.now() - startedAt < 5000) {
      after = await readAccessibilityLabel('reader-position-indicator')
      if (after !== before) break
      await new Promise((r) => setTimeout(r, 250))
    }

    expect(after).not.toBe(before)
  })
```

- [ ] **Step 2: Commit**

```bash
git add apps/mobile/e2e/reader-epub.test.ts
git commit -m "test(mobile): extend reader-epub to functional navigation"
```

---

## Task 10: Extend `reader-mobi.test.ts` to functional navigation

MOBI uses the toolbar's next-button rather than swipe (the WebView intercepts gestures). Test must tap the reader root first to reveal the toolbar.

**Files:**
- Modify: `apps/mobile/e2e/reader-mobi.test.ts`

- [ ] **Step 1: Add the helper and functional test**

Edit `apps/mobile/e2e/reader-mobi.test.ts`. Add the `readAccessibilityLabel` helper from Task 8 Step 1.

Append to the existing `describe('reader: MOBI — open from library', ...)` block:

```ts
  it('tapping next-chapter advances the position indicator', async () => {
    const before = await readAccessibilityLabel('reader-position-indicator')
    expect(before).toMatch(/^\d+\/\d+$/)

    // Reveal the toolbar (single tap on the reader root toggles it).
    await element(by.id('mobi-reader')).tap()

    // Wait briefly for the toolbar animation; toolbar mounts the next
    // button synchronously once toolbarVisible flips true.
    await new Promise((r) => setTimeout(r, 500))

    await element(by.id('reader-next-page-btn')).tap()

    let after: string | null = before
    const startedAt = Date.now()
    while (Date.now() - startedAt < 5000) {
      after = await readAccessibilityLabel('reader-position-indicator')
      if (after !== before) break
      await new Promise((r) => setTimeout(r, 250))
    }

    expect(after).not.toBe(before)
    expect(after).toMatch(/^\d+\/\d+$/)
  })
```

- [ ] **Step 2: Commit**

```bash
git add apps/mobile/e2e/reader-mobi.test.ts
git commit -m "test(mobile): extend reader-mobi to functional navigation"
```

---

## Task 11: Create `reader-azw3.test.ts`

Uses the finding from Task 0 to decide which reader testID to target. The test below assumes outcome (A) — AZW3 routes through the MOBI reader. If Task 0's finding was (B) (EPUB) or (C) (other), adapt the testIDs accordingly before writing.

**Files:**
- Create: `apps/mobile/e2e/reader-azw3.test.ts`

- [ ] **Step 1: Create the test file**

Create `apps/mobile/e2e/reader-azw3.test.ts`:

```ts
/**
 * Reader (AZW3) E2E.
 *
 * AZW3 is stored with format='azw3' and (per Task 0 of the detox-
 * coverage plan) routes through the MOBI reader. So this suite
 * mirrors reader-mobi.test.ts almost exactly — the only differences
 * are the seeded format ('azw3') and the resulting BookRow id.
 *
 * If AZW3 ever gets its own reader screen, the assertion targets
 * below need to be re-pointed.
 */
import { describe, it, beforeAll } from '@jest/globals'
import { seedBook, fixtureBookRowTestID } from './helpers/seed-book'

async function readAccessibilityLabel(testID: string): Promise<string | null> {
  // @ts-expect-error — Detox `getAttributes()` returns an untyped record.
  const attrs = await element(by.id(testID)).getAttributes()
  if (!attrs) return null
  return (attrs.label ?? attrs.text ?? null) as string | null
}

describe('reader: AZW3 — open from library', () => {
  let bookRowId: string

  beforeAll(async () => {
    await seedBook('azw3')
    bookRowId = fixtureBookRowTestID('azw3')
    await device.disableSynchronization()
  }, 120000)

  it('seeded AZW3 appears as a BookRow in the library', async () => {
    await waitFor(element(by.id(bookRowId)))
      .toBeVisible()
      .withTimeout(15000)
  })

  it('tapping the BookRow navigates into a reader route', async () => {
    await element(by.id(bookRowId)).tap()
    // AZW3 routes through the MOBI reader per Task 0 finding.
    await waitFor(element(by.id('mobi-reader')))
      .toExist()
      .withTimeout(20000)
  })

  it('tapping next-chapter advances the position indicator', async () => {
    const before = await readAccessibilityLabel('reader-position-indicator')
    expect(before).toMatch(/^\d+\/\d+$/)

    await element(by.id('mobi-reader')).tap()
    await new Promise((r) => setTimeout(r, 500))
    await element(by.id('reader-next-page-btn')).tap()

    let after: string | null = before
    const startedAt = Date.now()
    while (Date.now() - startedAt < 5000) {
      after = await readAccessibilityLabel('reader-position-indicator')
      if (after !== before) break
      await new Promise((r) => setTimeout(r, 250))
    }

    expect(after).not.toBe(before)
  })
})
```

- [ ] **Step 2: Commit**

```bash
git add apps/mobile/e2e/reader-azw3.test.ts
git commit -m "test(mobile): add reader-azw3 functional test

Mirrors reader-mobi (AZW3 routes through the MOBI reader per Task 0
finding in the detox-coverage plan)."
```

---

## Task 12: Create `reader-djvu.test.ts` (deferred stub)

Stub the suite so it appears in test discovery as `.skip`. When a DJVU fixture is sourced later, only the `.skip` → `describe` flip is needed.

**Files:**
- Create: `apps/mobile/e2e/reader-djvu.test.ts`

- [ ] **Step 1: Create the stub**

Create `apps/mobile/e2e/reader-djvu.test.ts`:

```ts
/**
 * Reader (DJVU) E2E — DEFERRED.
 *
 * Skipped pending a DJVU fixture. The seed-bridge (e2e/helpers/seed-book.ts,
 * app/_layout.tsx handleE2ESeedLink) already accepts format='djvu',
 * so once a fixture lands at `e2e/fixtures/test-book.djvu`, swap
 * `describe.skip` → `describe` and the suite is live.
 *
 * TODO(djvu-fixture): source a small public-domain DjVu file (e.g.
 * from archive.org's DjVu archive) and commit it as
 * `apps/mobile/e2e/fixtures/test-book.djvu`.
 */
import { describe, it } from '@jest/globals'
import { fixtureBookRowTestID } from './helpers/seed-book'

describe.skip('reader: DJVU — open from library (TODO: needs fixture)', () => {
  it('seeded DJVU appears as a BookRow in the library', async () => {
    const bookRowId = fixtureBookRowTestID('djvu')
    await waitFor(element(by.id(bookRowId)))
      .toBeVisible()
      .withTimeout(15000)
  })

  it('tapping the BookRow navigates into the DJVU reader route', async () => {
    const bookRowId = fixtureBookRowTestID('djvu')
    await element(by.id(bookRowId)).tap()
    await waitFor(element(by.id('djvu-reader')))
      .toExist()
      .withTimeout(20000)
  })
})
```

- [ ] **Step 2: Commit**

```bash
git add apps/mobile/e2e/reader-djvu.test.ts
git commit -m "test(mobile): add reader-djvu deferred stub

Skipped pending a DJVU fixture file. Seed bridge already accepts
format='djvu', so future work only needs to drop a fixture and flip
describe.skip to describe."
```

---

## Task 13: Extend `library.test.ts` format loop with `azw3`

Add `azw3` to the format array driving the library-import suite. Don't add `djvu` yet (no fixture).

**Files:**
- Modify: `apps/mobile/e2e/library.test.ts`

- [ ] **Step 1: Extend the format array**

Edit `apps/mobile/e2e/library.test.ts`. Find:

```ts
  const formats: SeedFormat[] = ['epub', 'pdf', 'mobi'];
```

Replace with:

```ts
  const formats: SeedFormat[] = ['epub', 'pdf', 'mobi', 'azw3'];
```

- [ ] **Step 2: Commit**

```bash
git add apps/mobile/e2e/library.test.ts
git commit -m "test(mobile): include azw3 in library import format loop"
```

---

## Task 14: Build the Detox app and run the full suite

Final verification. One xcodebuild Release build (~5-10 min), then the full e2e suite.

- [ ] **Step 1: Build the Detox iOS app**

Run:
```bash
cd apps/mobile && npm run e2e:build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`. If it fails, read the xcodebuild log and resolve — likely simulator-not-installed or Pods-out-of-date issues. Do NOT proceed until this passes.

- [ ] **Step 2: Run the full Detox suite**

Run:
```bash
cd apps/mobile && npm run e2e:test 2>&1 | tee logs/detox-run.txt | tail -60
```

Expected: every non-`.skip` test passes, including:
- `smoke.test.ts` (2 tests)
- `auth.test.ts` (existing)
- `chat.test.ts` (existing)
- `settings.test.ts` (existing)
- `cross-platform-sync.test.ts` (existing)
- `library.test.ts` — including new `azw3` format
- `reader-epub.test.ts` — including new functional navigation
- `reader-pdf.test.ts` — including new functional navigation
- `reader-mobi.test.ts` — including new functional navigation
- `reader-azw3.test.ts` — all three tests (NEW)
- `reader-djvu.test.ts` — `.skip` (counted as skipped, not failed)

If any test fails, capture the failure mode (which testID didn't appear, which indicator didn't change) and STOP. Iterate on the relevant Task before continuing.

- [ ] **Step 3: Commit the test log as evidence**

```bash
git add apps/mobile/logs/detox-run.txt
git commit -m "test(mobile): record passing detox run log"
```

If `logs/` is gitignored, replace the log path with one that isn't, or skip this step.

---

## Task 15: Manual verification of the original user bug

The user reported the bug while running `npx expo start` against the EAS dev build, not under Detox. Verify the fix lands in the dev experience too.

- [ ] **Step 1: Verify with the user**

Surface to the user:

> "Bug fixes + Detox coverage landed. Please reproduce your original PDF import flow with `npx expo start` against your EAS dev build to confirm the GestureHandlerRootView error no longer fires and the worker-session-token noise is gone. Both fixes are pure JS, so the dev build picks them up automatically — no EAS rebuild needed."

This step is verification-by-user, not by Claude — surface and wait.

---

## Self-Review Notes

After writing this plan:

**Spec coverage:** all sections of the spec map to tasks—
- Spec §"Bug Fix 1" → Task 1
- Spec §"Bug Fix 2" → Task 2 (with unit test)
- Spec §"Format coverage matrix" — azw3 → Tasks 3, 11, 13; djvu → Task 12 stub
- Spec §"Functional reader test pattern" → Tasks 4-7 (instrumentation) + 8-10 (test extensions)
- Spec §"Reader instrumentation" → Tasks 4-7
- Spec §"TDD" → Task 2 follows red-green-refactor; Tasks 8-10 are red-by-default until Tasks 4-7 ship (they reference testIDs that don't exist yet)
- Spec §"Build cadence" → Task 14
- Spec §"Out of scope" — Android, CI, document picker, highlights/TTS: not in any task ✓

**Placeholder scan:** searched for "TBD", "TODO", "implement later" — only the deliberate TODO in Task 12's stub (DJVU fixture pending) and Task 0's discovery instruction. Both are explicit and necessary.

**Type consistency:** `readAccessibilityLabel` helper is duplicated in Tasks 8/9/10/11 by design (engineer may execute tasks out of order). Position-indicator testID is `reader-position-indicator` everywhere. Next-page testID is `reader-next-page-btn` in MOBI + DJVU + AZW3. Root testIDs are unchanged: `pdf-reader`, `reader-epub`, `mobi-reader`, `djvu-reader` (NEW).

# Unified Reader — Manual QA Matrix

**Companion to:** `2026-04-16-unified-reader-design.md`
**Required pre-merge.** Each cell must pass with notes; failures block cutover.

## Test books to prepare

Before running the matrix, gather one fixture book per format from real-world sources:

- **EPUB**: a real EPUB with TOC, embedded images, footnotes, and pre-existing highlights from the current build
- **MOBI**: a real MOBI with multiple chapters, ideally KF8-compressed
- **PDF**: a multi-hundred-page PDF with selectable text, an outline, and at least one page with images
- **DJVU**: a multi-page DJVU; ideally one with an OCR text layer and one without

## Matrix

For each format × scenario, mark PASS / FAIL with a short note. All 32 cells must be PASS or have an explicit "documented limitation" note tied to a Risk Register entry.

| Scenario | EPUB | MOBI | PDF | DJVU |
|---|---|---|---|---|
| **Open** — book opens within 3s, content renders, no console errors |  |  |  |  |
| **Navigate** — next/prev (keyboard, swipe, on-screen), TOC click jumps correctly |  |  |  |  |
| **Highlight** — text selection → popover → save → highlight visible, persists across reload |  |  |  |  |
| **TTS** — start playback, paragraph advance works, audio cache hits on replay, prefetch queued |  |  |  |  |
| **Chat** — open ChatPanel, ask a question, get a response with book context |  |  |  |  |
| **Theme** — switch theme; chrome and (where applicable) content colors update without reload |  |  |  |  |
| **Location persistence** — close mid-book, reopen, restored to same position |  |  |  |  |
| **Close-and-reopen** — close book, navigate away, reopen, no leaks (memory, blob URLs, audio handles) |  |  |  |  |

## Format-specific extra checks

**EPUB**
- [ ] Pre-existing highlights from the old `react-reader` build still render after migration
- [ ] Footnotes / internal links jump to the right place
- [ ] Embedded images load
- [ ] CSS from the EPUB does not leak into the app's chrome (Tailwind, Radix)
- [ ] Sanitization: load a deliberately malicious EPUB (script tag in chapter HTML) and confirm no script execution

**MOBI**
- [ ] Chapter list TOC works
- [ ] Inline images: confirmed broken-image fallback (documented limitation)

**PDF**
- [ ] Outline (TOC) loads and is navigable
- [ ] Zoom in/out preserves position
- [ ] "Dark mode for pages" toggle in settings works and is OFF by default
- [ ] Text selection across columns works
- [ ] Cover image generated for first-time-opened PDFs (when `book.coverKind === 'fallback'`)
- [ ] Virtualization: scroll a 500+ page PDF; memory does not balloon

**DJVU**
- [ ] Pages render at multiple zoom levels
- [ ] OCR text selection works on pages with text
- [ ] No-text-pages show "no text on this page" hint when user attempts selection or TTS
- [ ] LRU cache evicts and revokes blob URLs (no leaks)

## Cross-cutting checks

- [ ] Keyboard shortcuts work identically across all four formats: `←`/`PgUp` prev, `→`/`PgDn`/`Space` next, `Esc` closes panels
- [ ] Swipe gestures work identically
- [ ] All four panels (TOC, Settings, Highlights, Chat) open/close consistently and look identical
- [ ] Settings panel hides font controls when content is paged (PDF, DJVU)
- [ ] Settings panel shows font controls when content is reflowable (EPUB, MOBI)
- [ ] No `react-reader` or `react-pdf` references remain in the bundle
- [ ] DOMPurify present in bundle; sanitization runs before any chapter mount
- [ ] Tauri webview CSP reviewed and `script-src` appropriately restricted

## Performance smoke tests

- [ ] Opening a 100MB+ EPUB does not block the UI
- [ ] Opening a 500-page PDF: first page visible within 2s
- [ ] Memory after reading 50 pages of a PDF: not more than 2x baseline
- [ ] Switching between books (close one, open another): old parser cleaned up, no orphaned blob URLs

## Sign-off

Once all cells pass:

- [ ] Reviewer signs off on commit-by-commit review
- [ ] Cutover commit lands
- [ ] Post-merge: monitor Sentry for regressions for 48h before considering safe

# Unified Reader — Design

**Status:** Proposed
**Date:** 2026-04-16
**Scope:** `apps/main` (Tauri desktop app)

## Goal

Deliver a single reading experience across all four book formats currently supported (EPUB, MOBI, PDF, DJVU). "Unified" specifically means **same chrome, same controls, same feel** — top bar, panels (TOC, settings, highlights, chat), TTS controls, theme switching, keyboard shortcuts, and gestures behave identically regardless of format. Content rendering remains format-aware underneath, but everything *around* the content is one component tree.

## Scope decisions

These were settled during brainstorming:

- **Goal A — same chrome, same feel.** Not "same features only" (B) and not "force PDFs into reflowable mode" (C).
- **Scope A — all four formats, one cutover.** Not phased per format.
- **Approach 1 — replace the wrapper libraries.** Drop `react-reader` and `react-pdf`. Use `epubjs` and `pdfjs-dist` directly as parsers. Build our own `ReflowableRenderer` and `PagedRenderer`.

## Architecture

Three layers:

```
ReaderShell (chrome + state owner)
  ├── ReflowableRenderer | PagedRenderer (renderers)
  └── Adapters: useEpubAdapter | useMobiAdapter | usePdfAdapter | useDjvuAdapter
       └── Sources: epubjs (parser only), pdfjs-dist (direct), Rust commands
```

**Two renderers, four formats.** Reflowable (EPUB, MOBI) and Paged (PDF, DJVU) are the only two rendering modes. Each format's adapter normalizes its source data into one of these two shapes. This is the entire mechanism by which unification works.

**Adapters are read-only data sources.** They're React hooks returning `AdapterState`. They do not own mutable state. All mutable state (current location, selection, theme, viewport, panel visibility) lives in `ReaderShell`. This eliminates the scattered atom-and-event-bus state that the current `PlayerControlInterface` hierarchy uses.

**Single route component.** `apps/main/src/routes/books.$id.lazy.tsx` collapses from a 4-branch switch to `<ReaderShell book={book} />`. Format dispatch happens inside the shell via `useBookAdapter(book)`.

**Shadow DOM for reflowable content.** EPUB and MOBI HTML is rendered inside a Shadow DOM root, **not** directly inserted via `dangerouslySetInnerHTML`. This gives both CSS isolation (book stylesheets can't leak into the app) and a single, well-defined sanitization boundary. See "Security model" below.

### What gets deleted

- `apps/main/src/components/react-reader/**` (entire directory)
- `apps/main/src/components/epub.tsx`
- `apps/main/src/components/pdf/components/pdf.tsx`
- `apps/main/src/components/mobi/MobiView.tsx`
- `apps/main/src/components/djvu/DjvuView.tsx`
- `apps/main/src/models/player_control.ts`
- `apps/main/src/models/epub_player_contol.ts`
- `apps/main/src/models/pdf_player_control.ts`
- npm deps: `react-reader`, `react-pdf`. **Verify and likely also remove** `@react-pdf/renderer` (PDF *generation* lib, not viewer — confirm unused).

### What gets added

- npm deps: `dompurify` (HTML sanitization for book content)

### What gets kept

- `epubjs`, `pdfjs-dist` (parser-only usage)
- `apps/main/src/epubwrapper.ts` (logic migrates into `useEpubAdapter`)
- `apps/main/src/models/PlayerClass.ts` (audio cache, retry, prefetch logic kept; input source rewired)
- `apps/main/src/components/highlights/**`, `apps/main/src/components/chat/**`, `apps/main/src/components/reader/ReaderSettings.tsx`, `apps/main/src/components/TTSControls.tsx`
- `apps/main/src/modules/highlight-storage.ts`, `apps/main/src/modules/sync-triggers.ts`
- All Rust commands for MOBI/DJVU/PDF/EPUB metadata
- PDF hook utilities under `apps/main/src/components/pdf/hooks/` (`useScrolling`, `useVirualization`, `useCurrentPageNumber`, `useUpdateCoverIMage`) — relocate into renderer/shell

### Critical invariants (must not break)

- TTS playback, paragraph highlighting, audio prefetch, cache, retry
- Voice chat / `ChatPanel` integration including `bookId` wiring
- Highlight creation, persistence, restoration on re-open, cloud sync
- Book location auto-save and restore on re-open (including legacy values)
- Cover image generation for PDFs (currently triggered in PDF view)
- RAG embeddings pipeline (currently triggered on book open)
- Theme persistence

## Security model

Book content (EPUB, MOBI) is third-party HTML that may include scripts, inline event handlers, malicious `<img>` payloads, or `javascript:` URLs. The current implementation isolates this via `react-reader`'s iframe. Removing the iframe requires explicit sanitization and isolation:

1. **Sanitize before mount.** Every HTML string returned by `chapter.loadHtml()` passes through `DOMPurify.sanitize(html, {RETURN_DOM_FRAGMENT: true, FORBID_TAGS: ['script', 'iframe', 'object', 'embed'], FORBID_ATTR: ['onerror', 'onload', 'onclick', /* full inline-handler list */]})` before being attached to the DOM. Strips `<script>`, inline event handlers, and dangerous URL schemes.

2. **Shadow DOM for CSS isolation.** Each chapter mounts inside a shadow root attached to a host element in the renderer. Book CSS is scoped to the shadow tree and cannot leak into the app's global styles. App theme variables are injected into the shadow root via `<style>` injection so the content can read `--reader-bg` etc.

3. **Resource URL rewriting.** Internal references (`<img src="images/foo.png">`) are rewritten to blob URLs created from `content.resolveResource(path)`. Absolute URLs are stripped or sanitized to prevent leakage to external hosts.

4. **No script execution.** Sanitization removes all script execution paths. The Tauri webview's CSP should additionally restrict `script-src` to the app's own origin (verify current `tauri.conf.json` CSP and tighten if needed).

PDFs and DJVUs render to canvas/image, not HTML — no injection surface there.

## Content model and types

```typescript
// apps/main/src/types/reader.ts

type BookContent = ReflowableContent | PagedContent;

interface ReflowableContent {
  kind: 'reflowable';
  metadata: Metadata;
  chapters: Chapter[];
  resolveResource: (path: string) => Promise<Blob | null>;
}

interface Chapter {
  id: string;                       // stable: EPUB idref, MOBI chapter index
  index: number;
  title?: string;
  loadHtml: () => Promise<string>;  // raw HTML; sanitization happens in the renderer, not the adapter
}

interface PagedContent {
  kind: 'paged';
  metadata: Metadata;
  pageCount: number;
  renderPage: (pageIndex: number, viewport: Viewport) => Promise<RenderedPage>;
}

interface Viewport {
  scale: number;                    // 1.0 = 100%
  rotation?: 0 | 90 | 180 | 270;
}

interface RenderedPage {
  source:
    | { kind: 'canvas'; canvas: HTMLCanvasElement }
    | { kind: 'blob'; url: string };
  textItems: TextItem[];            // empty allowed (DJVU may lack OCR)
  width: number;
  height: number;
}

interface TextItem {
  text: string;
  bbox: { x: number; y: number; width: number; height: number };
}

interface Metadata {
  title?: string;
  author?: string;
  publisher?: string;
  tableOfContents: TOCEntry[];
}

interface TOCEntry {
  title: string;
  location: Location;
  children: TOCEntry[];
}

type Location =
  | { kind: 'reflowable'; chapterId: string; cfi?: string }
  | { kind: 'paged'; pageIndex: number };  // 0-indexed; UI displays as +1

interface Paragraph {
  id: string;                       // stable for TTS audio cache key
  text: string;
  location: Location;
}

interface SelectionInfo {
  text: string;
  location: Location;
  rects: DOMRect[];                 // viewport coords, used for popover positioning
  serialized: SerializedSelection;  // opaque to shell; renderer round-trips it
}

type SerializedSelection =
  | { kind: 'reflowable'; chapterId: string; cfiRange: string }
  | { kind: 'paged'; pageIndex: number; quadPoints: number[] };

interface AdapterState {
  content: BookContent | null;
  status: 'loading' | 'ready' | 'error';
  error?: Error;
}
```

**Key choices:**

- **Discriminated unions everywhere.** `Location`, `BookContent`, `RenderedPage.source`, `SerializedSelection` all use `kind` discriminators.
- **Adapters are pure data.** `AdapterState` has no mutating methods. "Do something" lives on the renderer's imperative handle.
- **Highlights store opaque serialized form.** The shell never inspects `SerializedSelection`. The renderer that produced it is the only thing that knows how to re-apply it.
- **MOBI synthesizes CFI-like paths.** MOBI lacks a true CFI scheme; the adapter generates `cfi` strings using stable chapter ids + element offsets.
- **Sanitization happens in the renderer, not the adapter.** Adapters return raw HTML; the renderer applies DOMPurify before mounting. This keeps adapters simple and centralizes the security boundary.

## Renderers

### `ReflowableRenderer` — for EPUB and MOBI

**Layout.** Single host container per chapter, each containing a Shadow DOM root with the sanitized chapter HTML. Outer container uses CSS multi-column layout for pagination:

```css
.reflowable-host {
  height: 100%;
  column-width: var(--reader-column-width);
  column-gap: 40px;
  overflow-x: auto;
  overflow-y: hidden;
  scroll-snap-type: x mandatory;
}
```

The shadow root inherits the column layout from its host (CSS layout context crosses the shadow boundary even though styles do not).

**Chapter loading.**
1. Call `chapter.loadHtml()` → raw HTML string.
2. Rewrite internal resource URLs to blob URLs via `content.resolveResource(path)`.
3. Sanitize via `DOMPurify.sanitize(html, {RETURN_DOM_FRAGMENT: true, FORBID_TAGS, FORBID_ATTR})`.
4. Attach a closed shadow root to the host element.
5. Inject a base `<style>` into the shadow root with theme CSS variables and reader defaults.
6. Append the sanitized DOM fragment to the shadow root.

Previous and next chapters prefetched to memory (sanitized fragments cached) but not mounted; cross-chapter navigation unmounts/remounts.

**Pagination tracking.** Current "page" derived from `scrollLeft / (columnWidth + columnGap)` on the host. Page changes fire `onLocationChange` with `{kind: 'reflowable', chapterId, cfi: <derived from leftmost visible element in shadow root>}` using `epubjs`'s `EpubCFI` utility class.

**Paragraph extraction.** On each page change (debounced), walk the shadow root's visible DOM for block-level text elements (`p`, `li`, `h1`-`h6`, `blockquote`, etc.). Each gets a synthetic CFI id and produces a `Paragraph`. Emitted via `onVisibleParagraphsChange`.

**Selection.** Native browser selection works across shadow boundaries in modern browsers. `selectionchange` listener computes `SelectionInfo` with serialized CFI range. Note: `getSelection()` returns the top-level selection; for shadow DOM content, use `shadowRoot.getSelection()` where supported, with a fallback to walking composed ranges.

**Theme + fonts.** CSS custom properties on the shadow root's injected `<style>`: `--reader-bg`, `--reader-fg`, `--reader-font-family`, `--reader-font-size`, `--reader-line-height`. Updated reactively when `themeAtom` or `fontSettingsAtom` change.

**Imperative handle.** `{ next(), prev(), jumpTo(loc), getCurrentLocation(), applyHighlights(highlights[]) }`. `applyHighlights` uses CFI ranges to wrap matching text in `<mark>` elements inside the shadow root.

### `PagedRenderer` — for PDF and DJVU

**Layout.** Virtualized vertical list of page slots. Reuses `useVirualization`, `useScrolling`, `useCurrentPageNumber` from `apps/main/src/components/pdf/hooks/`.

**Page rendering.**
- PDF: adapter's `renderPage()` calls `pdfjs.PDFDocumentProxy.getPage(i+1).render(...)` into a fresh canvas, then `getTextContent()` for text items. Renderer mounts the canvas + a positioned text-layer overlay.
- DJVU: adapter's `renderPage()` returns `{kind: 'blob', url}` (Rust pre-rasterizes). Renderer mounts an `<img>` + a text-layer overlay built from `getDjvuPageText` results.

**Selection.** Native browser selection across the text-layer spans. `SelectionInfo.serialized` derived from selection rects → `{kind: 'paged', pageIndex, quadPoints: [...]}`.

**Theme.** Page contents can't be themed at the pixel level. Container background and chrome respect the theme via CSS vars. Settings exposes an opt-in **"Dark mode for pages"** toggle that adds `filter: invert(1) hue-rotate(180deg)` to the page layer (off by default).

**Zoom.** `Viewport.scale` controlled by shell. Changing it re-renders visible pages (PDF) or re-fetches at new DPI (DJVU). Zoom range and step size port from current `DjvuView` (`MIN_ZOOM=0.5`, `MAX_ZOOM=3.0`, `ZOOM_STEP=0.25`).

**Paragraph stream.** Text items grouped into paragraphs via existing utilities `wordsToParagraphs` and `getPageParagraphs` from `apps/main/src/components/pdf/utils/`.

**Imperative handle.** Same shape as reflowable: `{ next(), prev(), jumpTo(loc), getCurrentLocation(), applyHighlights(highlights[]) }`. `applyHighlights` overlays absorbing `<div>`s at quadPoint coords on a layer above the text layer.

### Shared concerns

- **Imperative handle exposed via `useImperativeHandle` + `forwardRef`.** Shell uses it for keyboard, gesture, and TOC-click-driven navigation.
- **Loading and error states owned by the renderer.**

### Non-goals for v1

- Continuous scroll mode for reflowable content (paged-only)
- Two-up / spread view for PDF
- Right-to-left reading direction
- Forced reflowable mode for PDFs (OCR-based)
- Search

## Adapters

Each adapter is a custom React hook returning `AdapterState`. A dispatcher `useBookAdapter(book)` selects the right one based on `book.kind`.

### `useEpubAdapter(filepath)` → `ReflowableContent`

```typescript
const book = useMemo(() => new ePub(filepath), [filepath]);
useEffect(() => () => book.destroy(), [book]);

await book.ready;
return {
  kind: 'reflowable',
  metadata: {
    title: book.packaging.metadata.title,
    author: book.packaging.metadata.creator,
    publisher: book.packaging.metadata.publisher,
    tableOfContents: book.navigation.toc.map(toTOCEntry),
  },
  chapters: book.spine.items.map((item, i) => ({
    id: item.idref,
    index: i,
    title: book.navigation.get(item.href)?.label,
    loadHtml: async () => {
      const section = book.spine.get(item.idref);
      return section.load(book.load.bind(book)) as Promise<string>;
    },
  })),
  resolveResource: (path) => book.archive.getBlob(path),
};
```

`epubwrapper.ts` logic migrates here. **No `Rendition` is ever created.**

### `useMobiAdapter(filepath)` → `ReflowableContent`

Reuses existing Rust commands `getMobiChapterCount` and `getMobiChapter` (returns chapter HTML string). Builds chapters with lazy `loadHtml`. TOC synthesized as flat chapter list (`Chapter 1`, `Chapter 2`, ...). `resolveResource` returns `null` (MOBI inline images are a v1 punt — see Risks).

### `usePdfAdapter(filepath)` → `PagedContent`

```typescript
const doc = await pdfjs.getDocument(filepath).promise;
useEffect(() => () => doc.destroy(), [doc]);

const outline = await doc.getOutline();
const info = (await doc.getMetadata()).info as { Title?: string; Author?: string; /* ... */ };
return {
  kind: 'paged',
  metadata: {
    title: info?.Title,
    author: info?.Author,
    tableOfContents: outline?.map(toTOCEntry) ?? [],
  },
  pageCount: doc.numPages,
  renderPage: async (i, vp) => {
    const page = await doc.getPage(i + 1);
    const viewport = page.getViewport({ scale: vp.scale });
    const canvas = document.createElement('canvas');
    canvas.width = viewport.width;
    canvas.height = viewport.height;
    await page.render({ canvasContext: canvas.getContext('2d')!, viewport }).promise;
    const textContent = await page.getTextContent();
    return {
      source: { kind: 'canvas', canvas },
      textItems: textContent.items.map(toTextItem),
      width: viewport.width,
      height: viewport.height,
    };
  },
};
```

PDF.js worker URL configured once at module load (currently in `pdf.tsx:51-54`; moves to a shared init module).

### `useDjvuAdapter(filepath)` → `PagedContent`

Reuses existing Rust commands `getDjvuPageCount`, `getDjvuPage`, `getDjvuPageText`. LRU cache (size 5) for rendered pages, with blob-URL revocation on eviction (port from current `DjvuView.tsx`). DJVU TOC is a v1 punt — flat page list.

### Dispatcher

```typescript
function useBookAdapter(book: Book): AdapterState {
  switch (book.kind) {
    case 'epub': return useEpubAdapter(book.filepath);
    case 'mobi': return useMobiAdapter(book.filepath);
    case 'pdf':  return usePdfAdapter(book.filepath);
    case 'djvu': return useDjvuAdapter(book.filepath);
  }
}
```

Hooks-in-conditional is acceptable because `book.kind` is stable for a given route mount. If the linter objects, use a wrapper component pattern that mounts one of four adapter components.

## ReaderShell and feature integration

### Shell composition

```typescript
function ReaderShell({ book }: { book: Book }) {
  const adapter = useBookAdapter(book);
  const [location, setLocation] = useState<Location>(decodeLocation(book.location, book.kind));
  const [selection, setSelection] = useState<SelectionInfo | null>(null);
  const [visibleParagraphs, setVisibleParagraphs] = useState<Paragraph[]>([]);
  const [openPanel, setOpenPanel] = useState<PanelId | null>(null);
  const [viewport, setViewport] = useState<Viewport>({ scale: 1 });
  const theme = useAtomValue(themeAtom);
  const fontSettings = useAtomValue(fontSettingsAtom);
  const rendererRef = useRef<RendererHandle>(null);

  // useEffect blocks for: keyboard, gestures, location persistence,
  // highlight loading on location change, RAG embedding job,
  // cover generation, Player wiring.

  return (
    <div className="reader-shell" /* CSS vars from theme + fontSettings */>
      <TopBar book={book} progress={...} onOpenPanel={setOpenPanel} />
      <ContentArea>
        {adapter.content?.kind === 'reflowable'
          ? <ReflowableRenderer ref={rendererRef} {...refloProps} />
          : <PagedRenderer ref={rendererRef} {...pagedProps} />}
        {selection && <SelectionPopover selection={selection} onAction={...} />}
      </ContentArea>
      <BottomBar><TTSControls player={player} /></BottomBar>
      <SidePanel open={openPanel} onClose={() => setOpenPanel(null)}>
        {/* TOCPanel | ReaderSettings | HighlightsPanel | ChatPanel */}
      </SidePanel>
    </div>
  );
}
```

### Feature integrations

**Highlights.** Selection → `SelectionPopover` offers "Highlight (color)" → `saveHighlight(serialized, location, color)` via existing `highlight-storage` module → `triggerSyncOnWrite()`. Restoration: on chapter or page change, query highlights for that location, call `rendererRef.current.applyHighlights([...])`. Each renderer's `applyHighlights` knows how to interpret its own `SerializedSelection` shape.

**Chat / RAG.** `ChatPanel` already accepts `bookId`; pass through unchanged. Selection-driven "Ask AI about this" sends `{text, location}` as a seed. RAG embedding-job kickoff (currently scattered across `MobiView`/`DjvuView` first-render effects calling `processEpubJob`) consolidates into a single shell `useEffect` that runs once per book open.

**TTS / Player.** `Player` from `models/PlayerClass.ts` keeps its audio cache, retry logic, prefetch, and `audioElement`. **Input source change:** instead of subscribing to `eventBus` events for paragraph updates, it gains a setter `player.setVisibleParagraphs(paragraphs)` called by a shell `useEffect` whenever `visibleParagraphs` changes. **Output change:** when it advances past the last visible paragraph, it calls `rendererRef.current.next()` instead of publishing an event. `Player.initialize()` simplifies to no eventBus subscriptions. The `eventBus`-based paragraph plumbing in `EpubPlayerControl` and the commented-out `PdfPlayerControl` is deleted entirely.

**Theme + fonts.** `themeAtom` remains the single source of truth. Shell injects CSS variables on `.reader-shell`. Reflowable renderer re-injects them into each shadow root. Paged renderer applies them to chrome only; settings panel exposes a "Dark mode for pages" toggle that adds the inverting filter (off by default). Settings panel hides font-size/family/line-height controls when `contentKind === 'paged'`.

**Cover image.** Move `useUpdateCoverIMage` logic from PDF view into shell. Trigger condition: `book.coverKind === 'fallback' && content.kind === 'paged'`. Action: call `content.renderPage(0, {scale: 0.3})`, encode the canvas/blob as PNG, persist via existing flow. EPUB and MOBI already have proper covers from Rust extraction; no-op for those formats.

**Keyboard and gestures.** Shell attaches global listeners on its root:

- `ArrowLeft`, `PageUp` → `rendererRef.current.prev()`
- `ArrowRight`, `PageDown`, `Space` → `rendererRef.current.next()`
- `Esc` → close any open panel
- Swipe left/right via `@use-gesture/react` (already a dep) → `next()` / `prev()`

No iframe boundary to bridge.

**Location persistence.** `setLocation` wrapped in a debounced effect calling `updateBookLocation(book.id, encodeLocation(location))`. `encodeLocation` JSON-stringifies the discriminated union. `decodeLocation` parses, falling back to legacy interpretation:

- JSON.parse succeeds → use directly
- Numeric string → interpret based on `book.kind`: PDF/DJVU → `{kind: 'paged', pageIndex: n - 1}`, MOBI → `{kind: 'reflowable', chapterId: String(n)}`
- CFI string → `{kind: 'reflowable', chapterId: <derived>, cfi: <as-is>}`

Migration is automatic on first open after upgrade.

### State ownership summary

| State | Owner | Persisted? |
|---|---|---|
| `location`, `selection`, `visibleParagraphs`, `viewport`, `openPanel` | Shell (`useState`) | `location` only |
| `theme`, `fontSettings` | Jotai atoms | Yes |
| Adapter content + parser instance | Adapter hook | No (re-created per book open) |
| Audio cache, paragraph index | `Player` instance | No |
| Highlights | DB via `highlight-storage` + cloud sync | Yes |

## Migration plan

Single feature branch. Build in dependency order with each commit compiling and passing lint/test.

1. **Types and utilities.** `apps/main/src/types/reader.ts` (content model). `apps/main/src/utils/location-codec.ts` (encode/decode + legacy fallback). `apps/main/src/utils/sanitize-html.ts` (DOMPurify wrapper with reader-specific config). No behavior change yet.
2. **Adapters** (parallelizable). All four hooks. Each tested independently against fixture books.
3. **Renderers** (parallelizable; depend on types only). `ReflowableRenderer` and `PagedRenderer`, render-only with no shell wiring. Stand up demo/test routes mounting each with a fixture content for development.
4. **Shell skeleton.** `ReaderShell` with chrome but no feature integrations — routes the right adapter to the right renderer.
5. **Feature wiring** (each can land independently on the branch):
   - Highlights apply/restore
   - Player input/output rewiring
   - Chat panel and selection seeding
   - Theme/font CSS plumbing
   - Cover generation move
   - RAG embedding-job consolidation
   - Location persistence with legacy decode
   - Keyboard/gesture handlers
6. **Cutover.** Replace `apps/main/src/routes/books.$id.lazy.tsx`'s 4-branch switch with `<ReaderShell book={book} />`. Delete the four old view files. Delete `react-reader/**`, the three `*_player_contol.ts` files. `bun remove react-reader react-pdf` (verify `@react-pdf/renderer` is unused first). `bun add dompurify @types/dompurify`.
7. **Cleanup.** Move `epubwrapper.ts` logic into `useEpubAdapter`. Move PDF hooks into renderer/shell. Remove orphaned imports.

### Verification gates

Each step ends with `bun run lint` and `bun run test` clean. Cutover (step 6) blocks on:

- **Adapter unit tests** (per format, fixture-driven): metadata extraction, chapter/page count, lazy load returns expected shape, location encode/decode round-trip including legacy values
- **Sanitization tests**: a corpus of malicious HTML inputs (script tags, inline event handlers, `javascript:` URLs, SVG-based XSS) confirms the sanitizer strips them. Snapshot tests on a benign-EPUB-chapter corpus confirm sanitization does not break legitimate content.
- **Renderer browser tests** (vitest browser mode, already configured): paragraph extraction matches expected for fixture HTML/PDF; selection produces correct serialized form; `applyHighlights` re-renders correctly; shadow DOM theme variable propagation works.
- **Shell integration tests** (browser mode): per format — open book → location restored → next page works → highlight saves and persists across reload → TTS plays a paragraph → settings panel hides font controls only when paged
- **Manual QA matrix** (separate file: `2026-04-16-unified-reader-qa-matrix.md`)

### Rollback

Cutover is one commit on the route file. `git revert <commit>` restores the previous reader. NPM deps come back via `bun install`. Worst-case revert window: minutes.

## Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| **XSS via malicious EPUB/MOBI content** | High | All chapter HTML passes through DOMPurify before mount. Shadow DOM provides additional CSS isolation. Tauri webview CSP restricts `script-src`. Sanitization test corpus covers known XSS vectors. |
| **Player rewiring breaks TTS for any format** | High | Keep `Player`'s internals (cache, retry, prefetch, audio element) intact. Change only the input source (setter instead of eventBus) and one output point (`renderer.next()` instead of event publish). Cover with explicit integration test per format before cutover. |
| **Existing EPUB highlights stop resolving after dropping iframe rendering** | High | epubjs's `EpubCFI` operates on any DOM, but iframe-generated CFIs may include path segments specific to the iframe's `<html>`/`<body>` chain that won't match the shadow-root structure exactly. Plan: (1) verify resolution against a fixture book with real highlights migrated from the current build, (2) if mismatch found, ship a one-time per-highlight rewriter that re-anchors paths against the new mount point on first failed resolution, (3) failed highlights persist as orphans (visible in HighlightsPanel with their text snippet) rather than silently disappearing. |
| **Sanitization breaks legitimate book content** | Medium | DOMPurify defaults are conservative. Snapshot tests on real EPUB chapters confirm typography, lists, blockquotes, footnotes, internal links, and inline images survive sanitization. Allowlist additions for any necessary book-specific elements (e.g., `<svg>` for math) made explicitly with review. |
| **Selection behavior in Shadow DOM is browser-inconsistent** | Medium | `getSelection()` semantics with shadow roots vary; shadow `getSelection()` is not yet universal. Implementation uses `document.getSelection()` then walks composed ranges; covered by browser tests in webview. |
| **Legacy `book.location` values fail to decode** | Medium | `decodeLocation` has explicit fallbacks for JSON, numeric, and CFI strings. Test against real existing book records before cutover. |
| **PDF performance regresses without `react-pdf`'s built-in virtualization** | Medium | Reuse existing `useVirualization` hook from `components/pdf/hooks/`. Confirm it has no `react-pdf` coupling during step 3. |
| **One-PR cutover is large and hard to review** | Medium | Branch built across multiple commits in dependency order above. Reviewer reviews per-commit, not per-PR. Each commit compiles. |
| **MOBI inline images render broken** | Low | `resolveResource` returns `null`, image tags display alt text or broken-image icon. Track as follow-up to extend Rust `getMobiChapter` to return `{html, resources}`. |
| **DJVU pages without OCR have no selection or TTS** | Low | UI shows "no text on this page" hint when user attempts selection or TTS on a text-empty page. |
| **PDF inverted dark mode looks bad on color-heavy pages** | Low | Off by default, opt-in toggle in settings. |

## Out of scope (explicit non-goals)

- Continuous scroll mode for reflowable content
- Two-up / spread view for PDF
- Right-to-left reading direction
- Forced reflowable mode for PDFs (OCR-based)
- Full-text search across the book
- MOBI inline image resources (Rust extension required)
- DJVU table of contents
- Format-format conversion (e.g., reading PDF as EPUB)

## Open questions

None at design time. Implementation details were pinned in the plan (`docs/superpowers/plans/2026-04-16-unified-reader.md`):

- **Shadow root mode**: `open` (not `closed`). Closed shadow roots don't provide real security isolation against same-document JS and make DevTools debugging painful; the spec's parenthetical preference for `closed` was revisited. See `ChapterFrame.tsx` — `host.attachShadow({ mode: 'open' })`.
- **Synthetic CFI path format for MOBI/reflowable paragraphs**: `${chapterId}::${i}` for paragraph indices; `${chapterId}::page::${pageIdx}` for page-level locations. Internal only — not epubcfi-compliant.
- **Quad-points serialization for PDF highlights**: flat `number[]` with 8 numbers per quad (`[x0, y0, x1, y0, x0, y1, x1, y1]`), matching PDF.js convention. See `rectsToQuadPoints` / `quadPointsToRects` in the plan.
- **CSS cascade-layer setup**: not needed. Theme CSS is injected into the shadow root as a `<style>` child (style-isolation by construction); inverted-dark-mode is a single inline `filter: invert(1) hue-rotate(180deg)` on the host.

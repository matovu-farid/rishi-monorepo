# Read Aloud From Here — Design

**Date:** 2026-05-16
**Status:** Draft (awaiting user review)
**Owner:** TBD on implementation

## 1. Summary

Let the user select text in a book, then trigger TTS playback that starts at the sentence containing the selection's first character and continues forward through the book until the user stops.

Triggers: a play-icon button on the selection popover, a native/in-app context-menu item, or the ⌘⇧L keyboard shortcut.

**Ship order:** EPUB + PDF in v1; AZW3 + MOBI in v2 (same pattern, deferred for scope).

**Prerequisite:** Text selection in the EPUB reader is currently broken — page-swipe gestures intercept pointer events before selection can complete. Phase 0 fixes this before Phase 1 ships the feature.

## 2. Behavioral contract

| Situation | Behavior |
|---|---|
| User selects text and triggers the action | Resolve `(paragraphIndex P, sentenceStartOffset S)`. Build partial first text = `paragraph[P].text.slice(S)`. Start TTS at that partial chunk; continue with normal full-paragraph TTS from `P+1` onward. |
| TTS already playing when triggered | Stop current playback, jump to new position, auto-play. |
| Multi-paragraph selection | Only the selection's *start* matters. Selection extent is ignored; playback continues to end-of-book as normal. |
| ⌘⇧L with no selection | Falls through to the existing Reader → Read Aloud command (toggle play/pause from current position). |
| Selection start lands at sentence boundary | `partialFirstText = paragraph.text` (no truncation). |
| Selection start in last sentence of paragraph | Partial text = just that sentence. After it ends, normal flow advances to `P+1`. |
| Empty selection / cursor only | All entry points are no-ops (or ⌘⇧L → standard Read Aloud). |
| Selection that starts in a not-yet-published paragraph | EPUB adapter falls back to "no override, play from paragraph 0 of current view". |
| Trigger fires while the reader is mid-page-curl (`playingState === 'pageNavigating'`) | Format adapter detects this and no-ops; the selection becomes stale once the page turns and re-selection on the new page is required. |
| User pauses then resumes mid-partial-first-paragraph | Override survives `RESUME`. |
| User stops, page-navigates, or hits final `AUDIO_ERROR` | Override cleared. |

## 3. Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ UI surfaces (per format)                                         │
│  • SelectionPopover  +  new "Read aloud from here" play button   │
│  • Native iframe contextmenu (EPUB) / Radix menu (PDF)           │
│  • Global ⌘⇧L accelerator → menu command                        │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼ calls
┌──────────────────────────────────────────────────────────────────┐
│ Format adapters                                                  │
│  • EpubView.handleReadAloudFrom(cfiRange)                        │
│      uses epub.js CFI to find paragraph + char offset            │
│  • PdfView.handleReadAloudFrom(domRange)                         │
│      uses wordSpans mapping → paragraph + char offset            │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼ both call
┌──────────────────────────────────────────────────────────────────┐
│ Pure module:  src/renderer/src/modules/read-aloud-from/          │
│  • findSentenceStart(text, charOffset) → sentence-start offset   │
│  • buildPartialFirst(paragraphIndex, text, charOffset)           │
│      → { partialFirstText, partialFirstKey, sentenceStartChar }  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼ dispatches PLAY_FROM
┌──────────────────────────────────────────────────────────────────┐
│ Player layer (XState — minimal extension)                        │
│  • playerMachine: new PLAY_FROM event + 3 context fields         │
│  • usePlayerMachine loading effect: uses partial text/key when   │
│      override active, skips prefetch for override paragraph      │
└──────────────────────────────────────────────────────────────────┘
```

### Invariants preserved

- `currentParagraphs` is never mutated by this feature. The override lives only in machine context.
- Override consumed exactly once, then auto-cleared.
- Prefetch (`usePlayerMachine.ts` `unsubCurrent`/`unsubNext`) still runs for non-override paragraphs; it skips the override paragraph's index.

## 4. Phase 0 — Selection vs. swipe gesture differentiation

### Problem

Currently the user can't reliably select text in the EPUB reader because:
1. `<ReactReader swipeable={true}>` (`EpubView.tsx:593` and `:734`) wires epub.js's internal swipe-to-turn inside the iframe, which captures pointer events on text.
2. The outer `usePageCurl` page-curl uses `EDGE_ZONE = 60` px on each side (`usePageCurl.ts:19`), large enough that selections starting near the edge get hijacked by `setPointerCapture` at `usePageCurl.ts:145`.

### Solution: three coordinated mechanisms

New module `src/renderer/src/components/pagecurl/useReaderGesture.ts` (consolidates and replaces `usePageCurl`):

| Device | Mechanism | Trigger condition |
|---|---|---|
| Touchscreen (`pointerType === 'touch'`) | 2-pointer-down swipe | `activePointers.size >= 2` AND avg horizontal delta exceeds threshold |
| Mac trackpad | Wheel-event accumulator | `wheel` events with `|deltaX| > |deltaY| * 1.5` AND cumulative `|sum| > 50 px`, fires after `>120 ms` settle window |
| Mouse / pen | Existing edge-zone curl | `EDGE_ZONE` reduced from 60 → **24** px; gated by `pointerType !== 'touch'` |

### Iframe / canvas-level changes

- **EPUB:** set `swipeable={false}` on both `<ReactReader>` instances in `EpubView.tsx` (lines 593, 734). Kills epub.js's internal swipe handler inside the iframe.
- **PDF:** ensure reader root has `touch-action: pan-y` so single-finger vertical scroll works while horizontal-swipe is delegated to the gesture layer.

### Existing surfaces (unchanged, continue to work)

- Arrow-button click → `pageCurl.autoTurn('right' | 'left')`
- Keyboard arrow keys
- TTS auto-page-turn via `pageRequest` → nav machine
- Bookmarks / TOC navigation via `useNavStore`

### Acceptance criteria for Phase 0

1. In Playwright: open an EPUB, drag-select 3 words in the middle of the page → `window.getSelection().toString()` returns those words.
2. Mouse drag in the middle 90% of the page width does NOT trigger page-curl.
3. Mouse drag from `x < 24` triggers page-curl.
4. Manual: two-finger trackpad swipe right turns page; one-finger trackpad drag does not.
5. Manual: two-finger touchscreen swipe turns page; one-finger touch drag selects text.
6. All existing page-turn surfaces (arrow keys, arrow buttons, TTS auto-turn, bookmark nav) continue to work.

## 5. Phase 1 — Read Aloud From Here

### 5.1 New pure module: `modules/read-aloud-from`

Lives at `src/renderer/src/modules/read-aloud-from/index.ts`. Pure, no DOM/React/XState dependencies.

```ts
export interface PartialFirst {
  /** Full text from sentence start to end of paragraph. */
  partialFirstText: string
  /** Stable TTS cache key: `${paragraphIndex}#s=${sentenceStartChar}` */
  partialFirstKey: string
  /** 0 if the selection start is already at a sentence boundary. */
  sentenceStartChar: number
}

/** Char offset of the start of the sentence containing `charOffset`.
 *  Uses Intl.Segmenter('en', { granularity: 'sentence' }) — falls back to a
 *  regex tokenizer if Segmenter is unavailable. */
export function findSentenceStart(text: string, charOffset: number): number

/** Builds the partial-first payload from a paragraph and selection-start offset. */
export function buildPartialFirst(
  paragraphIndex: string,
  paragraphText: string,
  selectionStartChar: number
): PartialFirst
```

#### Edge cases (each covered by a unit test)

- `selectionStartChar === 0` → sentence start is 0; partial text = full paragraph.
- `selectionStartChar` already at a sentence boundary → returns that offset unchanged.
- Empty paragraph text → returns `{ partialFirstText: '', sentenceStartChar: 0 }`; caller skips fetch and advances.
- Selection in last sentence → returns `(lastSentenceStart, remaining text)`.
- Unicode sentence terminators (Chinese 。, Arabic ؟, etc.) handled via Intl.Segmenter.
- `selectionStartChar > text.length` → clamped to `text.length`; partial text empty (caller advances to `P+1`).

### 5.2 `playerMachine` extension

#### Context additions

```ts
type PlayerMachineContext = {
  // ... existing fields ...
  partialFirstText: string | null
  partialFirstKey: string | null
  partialFirstParagraphIndex: number | null
}
```

#### New event

```ts
{ type: 'PLAY_FROM'
  paragraphIndex: number
  partialFirstText: string
  partialFirstKey: string }
```

#### Transition table (additions only)

| State | Event | Target | Actions |
|---|---|---|---|
| `idle` | `PLAY_FROM` | (ignored) | — (format adapter must wait for `playingState !== 'idle'`) |
| `stopped` | `PLAY_FROM` | `loading` | `setPartialFirst`, `setParagraphIndex` |
| `paused.clean` | `PLAY_FROM` | `loading` | `setPartialFirst`, `setParagraphIndex` |
| `paused.stale` | `PLAY_FROM` | `loading` | `setPartialFirst`, `setParagraphIndex` |
| `playing` | `PLAY_FROM` | `loading` | `setPartialFirst`, `setParagraphIndex` |
| `loading` | `PLAY_FROM` | `loading` (reenter) | `setPartialFirst`, `setParagraphIndex` |
| `waitingForParagraphs` | `PLAY_FROM` | `loading` | `setPartialFirst`, `setParagraphIndex` |
| `pageNavigating` | `PLAY_FROM` | (ignored) | — the page is mid-curl and the staged `paragraphIndex` would refer to the old page's paragraphs; the existing `PARAGRAPHS_UPDATED` handler would also `resetIndexByDirection` and clobber it. Format adapter must check `playingState !== 'pageNavigating'` before dispatching. |
| `error` | `PLAY_FROM` | `loading` | `clearErrors`, `setPartialFirst`, `setParagraphIndex` |

#### New actions

```ts
setPartialFirst:   assign 3 fields from event
clearPartialFirst: assign 3 fields → null
setParagraphIndex: assign({ paragraphIndex: event.paragraphIndex })
clearPartialFirstIfConsumed: clear iff the just-ended paragraph was the override target
```

#### Override clear rules

| Event / transition | Override |
|---|---|
| `STOP` | cleared |
| `CLEANUP` | cleared |
| `PAUSE` (intentional) | cleared |
| `PAGE_NAVIGATING` | cleared |
| `AUDIO_ERROR` → `error` (retries exhausted) | cleared |
| `AUDIO_ENDED` for override paragraph | cleared via `clearPartialFirstIfConsumed` |
| `RESUME` from `paused.clean` | **preserved** (still mid-override) |
| `loading` retry on `AUDIO_ERROR` with `hasRetries` | **preserved** |
| `PARAGRAPHS_UPDATED` while in `pageNavigating` with override and paragraph index unchanged | **preserved** |

#### `usePlayerMachine` loading-effect change

Inside the `loading` branch (currently `usePlayerMachine.ts:164`):

```ts
const useOverride =
  ctx.partialFirstText !== null &&
  ctx.partialFirstParagraphIndex === ctx.paragraphIndex
const ttsText = useOverride ? ctx.partialFirstText! : paragraph.text
const ttsKey  = useOverride ? ctx.partialFirstKey!  : paragraph.index

getTtsService()
  .requestAudio({ bookId, cfiRange: ttsKey, text: ttsText, priority: 1 })
  // ... existing handling
```

Prefetch loop in `unsubCurrent` (currently `usePlayerMachine.ts:71`) skips the override paragraph's index so we don't waste a full-paragraph TTS fetch that won't be played.

### 5.3 EPUB adapter — `EpubView.handleReadAloudFrom(cfiRange)`

The EPUB selection produces a CFI range like `epubcfi(/6/12!/4/2/1,/1:23,/1:67)` via `rendition.on('selected', ...)` already wired at `epub_viewer/index.tsx:290` and surfaced to `EpubView.handleTextSelected` (`EpubView.tsx:279`).

Mapping:
1. Parse selection CFI's **start** with `new EpubCFI(...)`.
2. Walk `playerStore.currentParagraphs`. Each paragraph's `index` field is a CFI range covering the whole paragraph. Use `EpubCFI.compare` to find the paragraph whose range contains the selection start.
3. Compute char offset within that paragraph by rendering the paragraph's CFI range to a DOM `Range` and counting characters from `range.startContainer/startOffset` to the selection's `startContainer/startOffset`.
4. Call `buildPartialFirst(paragraph.index, paragraph.text, charOffset)`.
5. If `playerStore.playingState === 'pageNavigating'` or `'idle'`, no-op (selection is or will be stale).
6. `requireAuth('tts', () => send({ type: 'PLAY_FROM', paragraphIndex, partialFirstText, partialFirstKey }))`.

#### Edge cases

- Selection start not found in any current paragraph (e.g. selection spans into not-yet-published next page): play from paragraph 0 of current view with no override.
- Empty partial text (selection at end of paragraph): start from `paragraphIndex + 1` with no override.

### 5.4 PDF adapter — `PdfView.handleReadAloudFrom(domRange)`

PDF has **no selection capture wiring today** (confirmed: no `Selection`/`getSelection`/`onSelect` references in `components/pdf/components/`). Phase 1 PDF must add the popover surface from scratch — this is a real cost not present in EPUB.

#### New scaffolding

1. Add a `selectionchange` listener (debounced) inside `components/pdf/components/pdf-page.tsx` that captures non-empty selections within the page's text layer.
2. Mount a `SelectionPopover` instance at the `PdfView` level, positioned at the selection's bounding rect.
3. Wire it the same way `EpubView` does today.

#### Selection → paragraph mapping (structured, per § 5 decision)

Extend `wordsToFinalParagraphs` (`components/pdf/utils/wordsToParaagraphs.ts`) to also return per-final-paragraph mapping data:

```ts
export interface ParagraphWordSpan {
  paragraphIndex: number       // index in the final paragraphs array
  startItemIndex: number       // index in the source words array
  startCharInParagraph: number // char offset of this item within the joined paragraph
}

export function wordsToFinalParagraphsWithSpans(
  words: string[],
  options?: Options
): { paragraphs: string[]; wordSpans: ParagraphWordSpan[] }
```

The PDF text-layer span carries `data-item-index` (already present on react-pdf text spans, or we add it via the text-renderer prop). DOM selection's start container → walk up → `data-item-index` → binary search `wordSpans` → `(paragraphIndex, charOffsetInParagraph)`.

#### Edge cases

- Selection across two paragraphs: use only the start.
- Selection on an image-only area (no text layer): no-op (popover doesn't appear).
- Empty `wordSpans` (page is still loading): popover button shows a brief "Loading..." disabled state.

### 5.5 UI surfaces

#### SelectionPopover — new prop

Add an optional `onReadAloud?: () => void` prop to `SelectionPopover` (`components/highlights/SelectionPopover.tsx`). Render a play-icon button (Lucide `Play`) next to the color swatches when the prop is provided. Click: invoke `onReadAloud()` and `onClose()`.

Both `EpubView` and `PdfView` pass `onReadAloud` wired to their respective `handleReadAloudFrom`.

#### Native context menu (EPUB)

- Register a `contextmenu` listener on the rendition's content document (inside the iframe).
- On right-click with non-empty selection: capture the selection CFI, IPC into main process via a new `ipc:reader:popupContextMenu` channel with `{ x, y, cfiRange }`.
- Main process builds a native `Menu` with one item ("Read Aloud From Here") and calls `Menu.popup({ x, y })`. On click, sends `ipc:reader:readAloudFrom` back to renderer with the CFI range.
- Renderer dispatches `handleReadAloudFrom(cfiRange)`.

#### In-app context menu (PDF)

- Use `@radix-ui/react-context-menu` (already in repo via shadcn — confirmed during planning if not, add it).
- Single item: "Read Aloud From Here". Click → `handleReadAloudFrom(domRange)`.

#### ⌘⇧L keyboard shortcut

- Add menu accelerator in `electron/main/menu.ts` (or wherever the Reader menu lives): "Read Aloud From Selection" with accelerator `CommandOrControl+Shift+L`.
- Menu command IPCs to renderer's `useMenuCommands` hook with a new `readAloudFromSelection` handler.
- Handler reads `window.getSelection()` and the active reader's selection state from a small new store (`selectionStore`) populated by `EpubView` and `PdfView`. If selection present, calls the active reader's `handleReadAloudFrom`. If absent, falls through to existing `readAloudToggle` (`EpubView.tsx:217`).

### 5.6 Phase 1 acceptance criteria

1. With an EPUB open, select a sentence in the middle of a paragraph and click the popover's play icon → audio starts and the first paragraph spoken is the partial text from the selected sentence to end-of-paragraph.
2. Same flow with selection at the start of a paragraph → entire paragraph is spoken.
3. Same flow with selection at end of paragraph (no text remains) → playback advances to next paragraph.
4. Same flow with no selection but ⌘⇧L pressed → existing Read Aloud command runs.
5. PDF: equivalent for points 1–4.
6. Right-click on selected text in EPUB → native macOS context menu shows "Read Aloud From Here"; clicking starts playback.
7. Right-click on selected text in PDF → Radix context menu shows "Read Aloud From Here"; clicking starts playback.
8. Trigger during active playback → audio stops, new playback starts at the new position with no leaked audio from the previous paragraph.
9. Trigger, then immediately page-curl → override cleared, normal page-nav playback resumes (or stays stopped, per existing rules).

## 6. Rejected alternatives

- **Approach 2 — Paragraphs-splicing.** Format readers temporarily replace `currentParagraphs` with `[partialParagraph, ...rest]` before `PLAY`. Rejected: mutates the canonical paragraphs array; races with `PARAGRAPHS_UPDATED` from the rendition; pollutes prefetch keys.
- **Approach 3 — External "start hint" + wrapper send.** Stash `pendingStart` on `playerStore`; wrap `actor.send` to consult it. Rejected: adds another implicit signal to a store that already coordinates many cross-cutting effects; behavior becomes read-order-dependent.
- **Word-level TTS seek via timestamps.** Most precise mid-paragraph start. Rejected: provider-dependent; user preferred sentence-snap for simpler reasoning.
- **Word-level partial-paragraph TTS** (exact selection start, not sentence-snapped). Rejected: awkward prosody starting mid-word; extra cache miss per trigger.
- **Phase 0 option B — Remove all page-turn gestures.** Rejected: too aggressive a regression for trackpad/touch users; coordinated multi-device gestures chosen instead.
- **Phase 0 option A — Edge-zone-only.** Rejected: doesn't restore touch- and trackpad-native swipe-to-turn that some users rely on.

## 7. Testing strategy (TDD)

All work is test-first (red → green → refactor) per the repo's TDD norm. Plans created against this spec must list tests before implementation tasks.

### Test pyramid

| Layer | Location | Coverage |
|---|---|---|
| Pure module | `modules/read-aloud-from/__tests__/index.test.ts` *(new)* | Sentence-snap, edge cases from § 5.1 |
| PDF builder | `components/pdf/utils/wordsToParaagraphs.test.ts` *(extended)* | `wordsToFinalParagraphsWithSpans` mapping; equivalence with existing builder when spans ignored |
| State machine | `machines/playerMachine.test.ts` *(extended)* | `PLAY_FROM` from every state; override clear/preserve rules; `partialFirstParagraphIndex` mismatch |
| Hook | `hooks/usePlayerMachine.test.ts` *(new)* | When override active, TTS request uses partial fields; prefetch skips override index; override clears after override `AUDIO_ENDED` |
| Gesture | `components/pagecurl/useReaderGesture.test.ts` *(new — replaces parts of `usePageCurl.test.ts`)* | Touch single vs. two-pointer; mouse edge-zone with `EDGE_ZONE=24`; wheel accumulator + ratio + debounce; per-pointer cleanup |
| EPUB adapter | `components/epub/__tests__/handleReadAloudFrom.test.ts` *(new)* | CFI start → paragraph + char offset; selection out-of-view fallback; multi-paragraph selection handling |
| PDF adapter | `components/pdf/__tests__/handleReadAloudFrom.test.ts` *(new)* | DOM span → `(paragraphIndex, charOffset)` via `wordSpans`; selection across multiple text items |
| Popover UI | `components/highlights/SelectionPopover.test.tsx` *(new)* | New play-icon button calls `onReadAloud`; absence of `onReadAloud` hides the button; existing color buttons unaffected |
| Integration | `e2e/read-aloud-from-selection.spec.ts` *(new, Playwright)* | EPUB and PDF: select sentence mid-paragraph → click play icon → assert `audioElement.src` changes and `paused === false`; ⌘⇧L with no selection → standard Read Aloud starts |

### Test-driven flow

- **Phase 0**: `useReaderGesture.test.ts` red → implement gesture module green → swap `EpubView`/`PdfView` to use it + set `swipeable={false}` → Playwright: select text in EPUB body, assert non-empty selection.
- **Phase 1**: pure module test → PDF builder test → machine test → hook test → adapter tests → popover test → E2E. Each step is its own red-green-refactor cycle.

### Parallel execution opportunities

After Phase 0 lands, the pure module, machine extension, and PDF builder mapping can be developed in parallel by separate subagents — they share no state.

### Not test-driven (explicit)

- Native macOS context-menu wiring via Electron `Menu.popup`: smoke-tested manually and via Playwright keystroke trigger; native-menu IPC is hard to unit-test from renderer.
- Trackpad wheel-swipe under E2E: Playwright can synthesize wheel events but the cumulative-delta + debounce heuristic is fragile in CI. Unit tests cover the math; manual verification on a real trackpad covers the real signal.

## 8. Rollout

```
Phase 0  ──►  Phase 1 (pure module + machine ext.)  ──►  Phase 1 (EPUB adapter + UI)
                                                    ╲
                                                     ╲──►  Phase 1 (PDF adapter + UI)
                                                    ╲
                                                     ╲──►  v2 (AZW3 + MOBI — defer)
```

- Phase 0 must merge first; Phase 1 is untestable without working selection.
- After Phase 0 and the shared Phase 1 plumbing (pure module + machine extension), EPUB and PDF adapter work can run in parallel — separate subagents, separate PRs.
- v2 (AZW3 + MOBI) applies the same pattern; deferred until v1 is validated by real-user feedback.

## 9. Risks

| Risk | Mitigation |
|---|---|
| `swipeable={false}` breaks a workflow we don't know about | Replacement gestures (edge-zone, 2-finger touch, trackpad wheel-swipe, arrow buttons, keyboard) all enumerated in PR description for QA review. |
| Trackpad wheel heuristic fires on innocent horizontal scroll | Ratio gate + cumulative threshold + debounce; tune down on first user complaint. |
| `Intl.Segmenter` not available in Electron's bundled Chromium | Confirmed during implementation; regex fallback already specified in § 5.1. |
| Override paragraph never finishes (TTS network failure) | Existing retry path in `playerMachine` `loading` state; override survives retry, clears on final error per § 5.2 clear rules. |
| Selection spans EPUB page boundary | EPUB adapter falls back to paragraph 0 of current view with no override; user can re-select on the next page. |
| PDF needs selection capture from scratch | Acknowledged cost; allocated under § 5.4. |
| `data-item-index` not present on react-pdf text spans | Use the text-renderer prop to wrap each item with the attribute; covered in Phase 1 PDF plan. |
| ⌘⇧L conflicts with another binding | Verify against current menu; choose alternate accelerator if needed before merge. |

## 10. Open questions

(None at design time. Discovered open questions land here during implementation planning.)

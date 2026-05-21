# Reader Navigation History Design

**Date:** 2026-05-21
**Scope:** apps/rishi-electron (per `feedback_electron_only.md`)
**Formats covered in v1:** EPUB, PDF, AZW3, MOBI

## Problem

When reading a book, the user frequently jumps to other locations — clicking an internal link, footnote, cross-reference, TOC entry, bookmark, or search result — and then wants a quick way back to where they were reading. The current reader has no back-navigation affordance for in-book jumps.

Separately, when the user flips a few pages forward or back to peek at something without engaging (no tap, no TTS, no selection), and then returns to the page they were last reading, the reader should silently resume from where they actually were on that page (scroll offset, TTS paragraph) — not from the top.

## Goals

1. Give the user a one-tap "back" after any deliberate jump.
2. Preserve per-page reading state (scroll offset + TTS paragraph) so returning to a page resumes correctly.
3. Distinguish "I'm browsing/peeking" from "I'm settled in here, this is my new spot" using cheap, observable engagement signals.
4. Reuse existing machinery (`pdfReaderMachine` scroll-offset persistence, `playerMachine` paragraph index, EPUB CFI) rather than re-implementing position tracking.

## Non-Goals (explicitly deferred)

- Forward stack (browser-style redo)
- Persisting the back stack across app restarts (per-book reading position keeps persisting to DB as today)
- Mid-paragraph TTS resume (paragraph-start resume only in v1)
- Visual history viewer / list of all stack entries
- Cross-book back navigation
- Web and mobile clients (electron only per `feedback_electron_only.md`)

## Two Subsystems Behind One Machine

The feature is two distinct mechanisms with one shared signal source (engagement detection):

### Subsystem A — Explicit Back Stack

- **Push trigger:** deliberate navigation — link click, TOC click, bookmark click, search result click.
- **UI:** floating "← Back to p. 142" pill at bottom-center.
- **Pop trigger:** pill tap or `Cmd/Ctrl+[` keyboard shortcut.
- **Depth:** multi-level, no forward, cap of 10 entries (oldest dropped on overflow).
- **Lifetime:** in-memory only. Clears on book switch, book close, app quit.

### Subsystem B — Implicit Page Resume

- **Capture trigger:** engagement on a page (explicit interaction OR ≥20s dwell OR TTS playback).
- **UI:** none.
- **Apply trigger:** `PAGE_VISITED` event with no sub-page intent (i.e., plain page-flip, not a deep-link jump).
- **Data:** per-page anchor map (`Map<pageKey, AnchorPoint>`).
- **Lifetime:** in-memory per book session.

Single XState machine owns both because the engagement signals feed both (auto-dismiss pill AND update resume map). Splitting would force duplicate signal plumbing.

## Architecture

### New components

| Piece | Type | Responsibility |
|---|---|---|
| `navigationHistoryMachine` | XState machine | Owns stack + resumeMap + engagement state + pill visibility |
| `useEngagementDetector(position)` | React hook | Emits ENGAGEMENT_TAP / DWELL_ELAPSED events for the visible page |
| `<NavigationHistoryFooter />` | React component | Renders the floating pill; subscribes to machine via `@xstate/react` `useSelector` |
| Per-format link interceptors | Hooks into existing reader components | Capture link clicks, send `JUMP_REQUESTED` before navigating |

### React subscription pattern

Components read machine state directly via `@xstate/react`'s `useSelector` — no Zustand mirror. This matches the user-confirmed preference and the existing `useNavState` pattern that consumes `navMachine`.

A thin send-only wrapper (analogous to `navStore.ts`) is added **only if** a non-React class component needs to send events, mirroring the existing convention.

### Existing machines this depends on

- `pdfReaderMachine` — current page + scroll offset (already persisted)
- `playerMachine` — TTS paragraph index and `PAGE_NAVIGATING` event (already exists)
- `navMachine` — EPUB navigation serialization (already exists; navigation requests still go through it)

## Data Model

```ts
type PositionDescriptor =
  | { kind: 'pdf'; page: number; offset: number }
  | { kind: 'epub'; cfi: string }
  | { kind: 'azw3' | 'mobi'; cfi: string };

type TtsContext = {
  paragraphIndex: number;
} | null;

type AnchorPoint = {
  id: string;                    // uuid for React keys & dedup
  bookId: string;                // sanity check on book switch
  position: PositionDescriptor;
  tts: TtsContext;               // captured at moment of jump/engagement
  label: string;                 // "p. 142" or chapter name
  capturedAt: number;            // epoch ms
  source: 'link' | 'toc' | 'bookmark' | 'search' | 'engagement';
};

type Context = {
  bookId: string | null;
  stack: AnchorPoint[];                          // max 10
  resumeMap: Map<string, AnchorPoint>;           // key = pageKey(position)
  currentPage: PositionDescriptor | null;
  pillVisible: boolean;
};
```

### `pageKey(position)` normalization

Strips sub-page granularity so a user flipping away and back to "the same page" matches their stored resume anchor:

- PDF: `pdf:${page}` (ignore offset)
- EPUB / AZW3 / MOBI: `epub:${spineIndexFromCfi(cfi)}` (ignore intra-spine position)

The stored `AnchorPoint` keeps the full sub-page detail for restoration; only the lookup key is normalized.

### Label generation

- PDF: `"p. ${page}"`
- EPUB / AZW3 / MOBI: best-effort TOC lookup via `book.navigation.get(cfi)`; fall back to `"location ${spineIndex}"`
- Stack depth >1 appends count: `"← Back to p. 142 (3)"`

### Memory

- Stack capped at 10 entries.
- `resumeMap` not capped — a 500-page book is ~500 entries (~50KB). Cost of LRU eviction exceeds the benefit.

## State Machine

```
navigationHistoryMachine
├── inactive
│     on BOOK_OPENED → active
│
└── active
      states: parallel
      ├── stack
      │     idle
      │       JUMP_REQUESTED → push from, set pillVisible, → navigating
      │       POP_BACK → pop, → navigating
      │     navigating
      │       PAGE_VISITED → idle
      │       (PAGE_VISITED here is treated as the jump landing —
      │        engagement region uses this signal to bypass resumeMap lookup)
      │
      ├── engagement
      │     idle
      │       PAGE_VISITED → dwelling (start 20s timer)
      │       ENGAGEMENT_TAP → engaged
      │       ENGAGEMENT_TTS_PLAYING → engaged
      │     dwelling
      │       DWELL_ELAPSED → engaged
      │       PAGE_VISITED → reset timer, stay dwelling
      │       ENGAGEMENT_TAP / ENGAGEMENT_TTS_PLAYING → engaged
      │       visibility hidden / window blur → pause timer
      │     engaged
      │       entry: build AnchorPoint from currentPage +
      │              playerMachine.paragraphIndex; write into
      │              resumeMap[pageKey(currentPage)]; pillVisible = false
      │       PAGE_VISITED (different page) → idle
      │
      └── pill
            hidden
              JUMP_REQUESTED → visible
            visible
              engagement.engaged reached → hidden (stack entry retained)
              POP_BACK and stack empty after pop → hidden
              DISMISS_PILL → hidden
```

Three parallel regions because stack mutations, engagement, and pill visibility are orthogonal. Pattern matches `pdfReaderMachine`'s parallel `seek` × `persist`.

## Engagement Signals

Captured by `useEngagementDetector(position)` in each reader:

| Signal | Source | Event sent |
|---|---|---|
| Tap / pointerdown on content | DOM | `ENGAGEMENT_TAP` |
| Selection change | DOM `selectionchange` | `ENGAGEMENT_TAP` |
| Dwell ≥20s | `setTimeout` | `DWELL_ELAPSED` |
| TTS entering `playing` state | `playerMachine` subscription | `ENGAGEMENT_TTS_PLAYING` |

Dwell timer is paused on `document.visibilitychange: hidden` and window `blur` — leaving the app open overnight should not count as "engaged".

Selection counts as engagement: false-positive cost is low (means stored resume is slightly more aggressive), and not counting it would just mean dwell catches it 20s later.

## Smart-Resume Decision Flow (per `PAGE_VISITED`)

```
                    PAGE_VISITED(position)
                            │
                            ▼
              ┌──────────── ┴ ────────────┐
              │ Same page as currentPage? │
              └────────────┬──────────────┘
                  yes  ◀──┤├──▶  no
                   │       │      │
                   ▼       │      ▼
                  no-op    │  Look up resumeMap[pageKey(position)]
                           │              │
                           │      ┌───────┴────────┐
                           │      │  hit?          │
                           │      └───┬────────┬───┘
                           │       no │     yes│
                           │          ▼        ▼
                           │   Render at   Compare: incoming
                           │   natural     position vs stored anchor
                           │   position           │
                           │             ┌──────┴──────────┐
                           │             │ incoming has    │
                           │             │ sub-page detail │
                           │             │ (deep-link)?    │
                           │             └─┬─────────────┬─┘
                           │             yes│           no│
                           │                ▼             ▼
                           │      Honor incoming   Restore stored
                           │      (deliberate      anchor's position
                           │      jump wins)       + TTS context
                           │
                           ▼
                  Reset engagement region → dwelling
                  Start 20s timer
```

**Critical rule:** deliberate jumps always win over stored resume positions. Clicking `chapter3.html#footnote-5` must land on `#footnote-5`, not on whatever paragraph you last engaged with on chapter 3.

**Implementation of the rule:** the resumeMap lookup is gated on the machine's `stack` region being in the `idle` state. If `stack` is in `navigating` (i.e., a `JUMP_REQUESTED` is in flight and this `PAGE_VISITED` is its landing), the incoming position is honored unchanged and the resumeMap lookup is skipped entirely. No need to inspect the position payload for "is this a deep link?" — the state machine already knows because the jump went through it.

## UI

### Pill

- **Position:** floating, bottom-center of reader, above existing toolbar/progress chrome
- **Label:** chapter name if TOC lookup succeeds, else `"p. ${N}"`; `"← Back to p. 142 (3)"` when stack depth >1
- **Tap target:** main label area pops one level; `✕` dismisses without popping (entry retained, accessible via keyboard)
- **Animation:** ~200ms slide-up on push, ~300ms fade-out on engagement
- **A11y:** `role="status"`, `aria-live="polite"`, tap target ≥44px
- **Keyboard:** `Cmd/Ctrl+[` always pops back regardless of pill visibility (mirrors browser convention; no collision detected in current reader)

### Placement decision

Floating bottom-center, not tucked into existing chrome. Reason: discoverable to first-time users and does not compete with page-counter / progress controls.

## Per-Format Integration

All format paths funnel into the same `JUMP_REQUESTED` event. The machine is format-agnostic.

| Format | File | Hook |
|---|---|---|
| EPUB body links | `components/react-reader/epub_viewer/index.tsx` | `rendition.hooks.content.register((contents) => contents.document.addEventListener('click', interceptLink))` |
| EPUB TOC/bookmark/search | `components/epub/EpubView.tsx` (`setLocation` callsite) | Wrap `setLocation` so it emits `JUMP_REQUESTED` before `rendition.display` |
| PDF annotation links | `components/pdf/PdfView.tsx` | react-pdf's `<Page onItemClick>` |
| PDF TOC/thumbnail | thumbnail/outline click handlers | Wrap to emit `JUMP_REQUESTED` |
| AZW3 / MOBI | `components/azw3/`, `components/mobi/` | Same `rendition.hooks.content` pattern if epub.js; else format-specific DOM source |

### Capture timing — critical

`JUMP_REQUESTED` must fire **before** the navigation commits, so the captured "from" reflects the pre-jump position with current TTS context.

```
1. user clicks link
2. interceptor reads currentPage + playerStore.activeParagraph
3. machine.send(JUMP_REQUESTED { from, to, source, label })
   → push from, show pill
4. interceptor calls rendition.display(target) / setPage(target)
5. reader emits PAGE_VISITED with new position
   → machine updates currentPage, resets engagement
```

## Events Summary

| Event | Sender | Purpose |
|---|---|---|
| `BOOK_OPENED { bookId, initialPosition }` | reader on book load | reset stack, hydrate `currentPage` |
| `BOOK_CLOSED` | reader unmount | clear everything |
| `PAGE_VISITED { position, ttsContext }` | reader on every page change | drives resume lookup + currentPage tracking |
| `JUMP_REQUESTED { from, to, source, label }` | link/TOC/bookmark/search interceptor | push + show pill |
| `POP_BACK` | pill tap or keyboard shortcut | pop + restore |
| `DISMISS_PILL` | explicit `✕` tap | hide pill, keep stack entry |
| `ENGAGEMENT_TAP` | `useEngagementDetector` | strong engagement signal |
| `ENGAGEMENT_TTS_PLAYING` | playerMachine subscription | TTS-based engagement |
| `DWELL_ELAPSED` | internal 20s timer | dwell-based engagement |

## Test Plan (TDD — red first per `feedback_tdd.md`)

### Unit (Vitest, machine in isolation)

1. `BOOK_OPENED` resets stack and resumeMap
2. `JUMP_REQUESTED` pushes anchor and shows pill
3. Stack caps at 10 — oldest dropped on overflow
4. `POP_BACK` removes top entry and emits navigation intent
5. `POP_BACK` on empty stack is a no-op
6. `ENGAGEMENT_TAP` → engaged, hides pill, writes resumeMap entry
7. `DWELL_ELAPSED` (fake timers) → engaged
8. Engagement region resets on `PAGE_VISITED` to a different page
9. `PAGE_VISITED` to known page with stored anchor restores stored position
10. `PAGE_VISITED` arriving while `stack` is in `navigating` skips resumeMap lookup (deliberate-jump-wins)
11. Visibility hidden / window blur pauses dwell timer
12. `BOOK_CLOSED` clears everything

### Integration (React Testing Library)

13. `useEngagementDetector` fires `ENGAGEMENT_TAP` on pointerdown
14. `useEngagementDetector` fires `DWELL_ELAPSED` after 20s (fake timers)
15. `<NavigationHistoryFooter />` renders pill when machine reports `pillVisible`
16. Pill tap dispatches `POP_BACK`
17. `Cmd+[` keyboard shortcut dispatches `POP_BACK`

### E2E (Playwright — extend `e2e/tts-page-navigation.spec.ts` pattern)

18. EPUB internal anchor → pill appears → tap → returns to original CFI with TTS resumed at same paragraph
19. EPUB TOC entry → pill → back
20. PDF annotation link → pill → back at original page + scroll offset
21. Page-flip away and back without engagement → resumes from last engaged position on destination page
22. Page-flip away and back *with* tap on destination → on return, lands at the tapped spot, not the original

## Open Risks

- **Selection-as-engagement false positives** — accepted; dwell would catch most cases anyway.
- **EPUB CFI quirks across books** — `book.navigation.get(cfi)` lookup for label generation may fail for malformed TOCs. Fallback label handles this; no functional impact.
- **react-pdf `onItemClick` coverage** — only fires for annotation-encoded links, not for plain HTML-looking links rendered in the page text. If a PDF has text that *looks* like a link but isn't an annotation, no jump is captured. Acceptable for v1.
- **Engagement timer drift** — `setTimeout` is fine; not using `performance.now()` precision.

## File Inventory

### New
- `src/renderer/src/machines/navigationHistoryMachine.ts`
- `src/renderer/src/hooks/useEngagementDetector.ts`
- `src/renderer/src/components/NavigationHistoryFooter.tsx`
- Test files paralleling each of the above

### Modified
- `src/renderer/src/components/react-reader/epub_viewer/index.tsx` — link interception
- `src/renderer/src/components/epub/EpubView.tsx` — TOC/bookmark/search wrap
- `src/renderer/src/components/pdf/PdfView.tsx` — `onItemClick` integration
- `src/renderer/src/components/azw3/` and `src/renderer/src/components/mobi/` — link interception
- Reader root (wherever readers mount) — render `<NavigationHistoryFooter />` and dispatch `BOOK_OPENED` / `BOOK_CLOSED`
- Keyboard shortcut registry — bind `Cmd/Ctrl+[`

# Player State Machine Refactor — XState + Zustand + AudioService

**Date:** 2026-04-19
**Status:** Approved
**Scope:** Replace the implicit Player state machine (class + EventEmitter + boolean flags + eventBus) with an explicit XState machine, a Zustand reactive store, and a thin AudioService wrapper. Remove the eventBus entirely.

## Problem

The `PlayerClass` manages TTS playback as a singleton class extending `EventEmitter`. State is tracked via a `PlayingState` enum plus scattered boolean flags (`_stoppedByTimeout`, `_paragraphsChangedWhilePaused`, `_autoAdvancing`, `_aborted`). Communication between the player and format readers (PDF, Epub, DJVU, MOBI) happens through a global `eventBus` singleton requiring manual subscribe/unsubscribe management.

This architecture has produced a class of bugs where an event arrives in a state the handler didn't account for. Example: `onNewParagraphs` handled `WaitingForNewParagraphs` and `Playing` but not `Paused`, causing the player to replay old audio after scroll-resume. These bugs are hard to catch because the state machine is implicit — missing branches are silent omissions in if-else chains.

## Solution

Three layers with clear responsibilities:

1. **XState machine** (`playerMachine.ts`) — Owns all state transitions. Every (state, event) pair is explicitly defined. Missing transitions are visible gaps, not silent bugs.
2. **Zustand store** (`playerStore.ts`) — Reactive layer for React. Replaces the eventBus as the communication channel between the player and all format readers.
3. **AudioService** (`audioService.ts`) — Thin imperative wrapper around `HTMLAudioElement`. Handles audio I/O, TTS fetching, caching, and prefetching. No state logic.

---

## Section 1: XState Machine

### States

```
idle                     — No book loaded. Entry state.
stopped                  — Book loaded, no playback.
loading                  — TTS audio being fetched for current paragraph.
playing                  — Audio element actively playing.
paused                   — Audio paused.
  paused.clean           — Paragraphs unchanged since pause.
  paused.stale           — Paragraphs changed while paused (user scrolled to new page).
waitingForParagraphs     — End of page, waiting for new paragraphs.
error                    — Retries exhausted for current paragraph.
```

`paused` is a compound state. The `clean`/`stale` sub-states replace the `_paragraphsChangedWhilePaused` boolean flag — the machine tracks it structurally.

### Events

```
// User actions
PLAY, PAUSE, RESUME, STOP, NEXT, PREV

// System events
AUDIO_LOADED, AUDIO_ENDED, AUDIO_ERROR

// Data events
PARAGRAPHS_UPDATED, NEXT_PARAGRAPHS_UPDATED, PREV_PARAGRAPHS_UPDATED, PAGE_BOUNDARY_REACHED

// Lifecycle
INITIALIZE, CLEANUP
```

### Transition Table

| From | Event | Guard | To | Actions |
|---|---|---|---|---|
| idle | INITIALIZE | — | stopped | storeBookId, resetIndex |
| stopped | PLAY | hasParagraphs | loading | fetchAudio |
| stopped | PLAY | !hasParagraphs | waitingForParagraphs | — |
| stopped | PARAGRAPHS_UPDATED | wasTimedOut | loading | resetIndex, fetchAudio |
| loading | AUDIO_LOADED | — | playing | playAudio, prefetch |
| loading | AUDIO_ERROR | hasRetries | loading | incrementRetry, retryFetch |
| loading | AUDIO_ERROR | !hasRetries | error | logError |
| playing | PAUSE | — | paused.clean | pauseAudio |
| playing | AUDIO_ENDED | hasMoreParagraphs | loading | advanceIndex, fetchAudio |
| playing | AUDIO_ENDED | !hasMoreParagraphs | waitingForParagraphs | requestNextPage |
| playing | NEXT | — | loading | advanceIndex, stopAudio, fetchAudio |
| playing | PREV | — | loading | retreatIndex, stopAudio, fetchAudio |
| playing | PARAGRAPHS_UPDATED | — | loading | resetIndex, stopAudio, fetchAudio |
| playing | STOP | — | stopped | stopAudio, resetIndex |
| paused.clean | RESUME | — | playing | resumeAudio |
| paused.clean | PARAGRAPHS_UPDATED | — | paused.stale | resetIndex |
| paused.stale | RESUME | — | loading | stopOldAudio, fetchAudio |
| paused.stale | PARAGRAPHS_UPDATED | — | paused.stale | resetIndex |
| paused.* | STOP | — | stopped | stopAudio, resetIndex |
| waitingForParagraphs | PARAGRAPHS_UPDATED | — | loading | resetIndex, fetchAudio |
| waitingForParagraphs | TIMEOUT (10s) | — | stopped | flagTimedOut |
| error | NEXT | — | loading | advanceIndex, fetchAudio |
| error | STOP | — | stopped | resetIndex |
| * | CLEANUP | — | idle | abortAll, clearAudio |

### Context

```typescript
{
  bookId: string;
  paragraphIndex: number;
  direction: 'forward' | 'backward';
  currentParagraphs: ParagraphWithIndex[];
  nextPageParagraphs: ParagraphWithIndex[];
  prevPageParagraphs: ParagraphWithIndex[];
  errors: string[];
  retryCount: number;
  timedOut: boolean;
}
```

---

## Section 2: Zustand `playerStore`

The store replaces the eventBus as the communication channel between the player and all format readers.

### Player-side state (written by machine, read by React)

```typescript
{
  playingState: string;                    // replaces eventBus PLAYING_STATE_CHANGED
  activeParagraph: ParagraphWithIndex | null;  // replaces eventBus PLAYING_AUDIO
  endedParagraph: ParagraphWithIndex | null;   // replaces eventBus AUDIO_ENDED
  lastMove: {                                  // replaces eventBus MOVED_TO_NEXT/PREV_PARAGRAPH
    from: ParagraphWithIndex;
    to: ParagraphWithIndex;
    direction: Direction;
  } | null;
  errors: string[];
}
```

### Format-reader-side state (written by readers, read by machine)

```typescript
{
  currentParagraphs: ParagraphWithIndex[];     // replaces eventBus NEW_PARAGRAPHS_AVAILABLE
  nextPageParagraphs: ParagraphWithIndex[];    // replaces eventBus NEXT_VIEW_PARAGRAPHS_AVAILABLE
  prevPageParagraphs: ParagraphWithIndex[];    // replaces eventBus PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE
}
```

### Actions and signals

```typescript
{
  // Format readers call these
  setCurrentParagraphs: (p: ParagraphWithIndex[]) => void;
  setNextPageParagraphs: (p: ParagraphWithIndex[]) => void;
  setPrevPageParagraphs: (p: ParagraphWithIndex[]) => void;

  // Machine sets this; format readers subscribe
  pageRequest: 'next' | 'prev' | null;        // replaces eventBus NEXT/PREVIOUS_PAGE_PARAGRAPHS_EMPTIED
  requestNextPage: () => void;
  requestPrevPage: () => void;
  clearPageRequest: () => void;

  // Machine send function reference for non-React code
  send: ((event: PlayerEvent) => void) | null;
}
```

### EventBus → Zustand mapping

| Old (eventBus) | New (Zustand) |
|---|---|
| `eventBus.on(PLAYING_AUDIO, cb)` | `playerStore.subscribe(s => s.activeParagraph, cb)` |
| `eventBus.on(AUDIO_ENDED, cb)` | `playerStore.subscribe(s => s.endedParagraph, cb)` |
| `eventBus.on(PLAYING_STATE_CHANGED, cb)` | `playerStore.subscribe(s => s.playingState, cb)` |
| `eventBus.on(MOVED_TO_NEXT_PARAGRAPH, cb)` | `playerStore.subscribe(s => s.lastMove, cb)` |
| `eventBus.on(NEXT_PAGE_PARAGRAPHS_EMPTIED, cb)` | `playerStore.subscribe(s => s.pageRequest, cb)` |
| `eventBus.publish(NEW_PARAGRAPHS_AVAILABLE, p)` | `playerStore.getState().setCurrentParagraphs(p)` |

---

## Section 3: AudioService

The `PlayerClass` is replaced by a stateless service that the XState machine invokes for audio I/O.

### What stays (extracted from PlayerClass)

- `HTMLAudioElement` ownership
- TTS audio fetching (`requestAudio`, disk cache check, IPC calls)
- Audio cache (`Map<string, string>`)
- Prefetch scheduling
- `setupEventListeners` (canplaythrough/error promise)
- Retry logic

### What moves out

- `playingState` → machine state
- `currentParagraphIndex` → machine context
- All paragraph arrays → playerStore
- `direction` → machine context
- All boolean flags → encoded in machine states
- `eventBus` subscriptions/publishes → Zustand subscriptions
- State transition logic → machine transitions
- `initialize()` / `cleanup()` → machine lifecycle events

### Interface

```typescript
interface AudioService {
  loadAndPlay(audioPath: string): Promise<void>;
  pauseAudio(): void;
  resumeAudio(): void;
  stopAudio(): void;

  fetchAudio(bookId: string, paragraph: ParagraphWithIndex, skipCache?: boolean): Promise<string>;

  schedulePrefetch(paragraphs: ParagraphWithIndex[], immediate: boolean): void;
  cancelPrefetch(): void;
  clearCache(): void;

  // Callbacks wired to machine.send by usePlayerMachine
  onAudioEnded: () => void;
  onAudioError: (error: MediaError) => void;
}
```

---

## Section 4: Format Reader Integration

Each format reader replaces eventBus calls with playerStore interactions.

### Publishing paragraphs

| Format | Current | New |
|---|---|---|
| PDF (`useCurrentPageNumber`) | `eventBus.publish(NEW_PARAGRAPHS_AVAILABLE, p)` | `playerStore.getState().setCurrentParagraphs(p)` |
| Epub (`epubStore`) | `eventBus.publish(NEW_PARAGRAPHS_AVAILABLE, p)` | `playerStore.getState().setCurrentParagraphs(p)` |
| DJVU (`DjvuView`) | `eventBus.publish(NEW_PARAGRAPHS_AVAILABLE, p)` | `playerStore.getState().setCurrentParagraphs(p)` |
| MOBI (`MobiView`) | `eventBus.publish(NEW_PARAGRAPHS_AVAILABLE, p)` | `playerStore.getState().setCurrentParagraphs(p)` |

### Subscribing for highlights and navigation

Format readers replace `eventBus.on(...)` with `playerStore.subscribe(...)`:

- `activeParagraph` changes → highlight the paragraph being read
- `endedParagraph` changes → remove highlight
- `lastMove` changes → remove old highlight
- `playingState` changes → clear highlights when stopped
- `pageRequest` changes → navigate to next/prev page, then `clearPageRequest()`

### TTSControls

- Reads state via `usePlayerStore(s => s.playingState)` (React selector)
- Sends events via `send({ type: 'PLAY' })` from `usePlayerMachine`
- No eventBus subscription, no manual cleanup

---

## Section 5: Wiring — usePlayerMachine Hook

```
TTSControls useEffect(bookId)
  │
  ├─ 1. machine.send({ type: 'INITIALIZE', bookId })
  │
  ├─ 2. Machine → store sync
  │     machine.subscribe(snapshot => playerStore.setState({ ... }))
  │
  ├─ 3. Store → machine sync (paragraphs)
  │     playerStore.subscribe(s => s.currentParagraphs,
  │       (p) => machine.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: p }))
  │
  ├─ 4. AudioService → machine callbacks
  │     audioService.onAudioEnded = () => machine.send({ type: 'AUDIO_ENDED' })
  │     audioService.onAudioError = (e) => machine.send({ type: 'AUDIO_ERROR', error: e })
  │
  └─ 5. Cleanup
        machine.send({ type: 'CLEANUP' })
        unsubscribe all
```

### File structure

```
apps/main/src/
  machines/
    playerMachine.ts        — XState machine definition
  services/
    audioService.ts         — Thin audio wrapper
  stores/
    playerStore.ts          — Zustand store
  hooks/
    usePlayerMachine.ts     — Wiring hook
```

---

## Section 6: Migration Strategy

### Phases

**Phase 1: Foundation (no behavior change)**
- Install xstate
- Create `playerMachine.ts`, `audioService.ts`, `playerStore.ts`, `usePlayerMachine.ts`
- Unit test machine transitions in isolation

**Phase 2: TTSControls switchover**
- TTSControls uses `usePlayerMachine` + `usePlayerStore`
- Machine drives audioService for playback
- Compatibility shim: machine publishes to eventBus so format readers still work unchanged
- All format readers continue working via eventBus

**Phase 3: Format reader migration (one at a time)**
- PDF: `useCurrentPageNumber` → `playerStore.setCurrentParagraphs`; `pdf.tsx` eventBus.on → `playerStore.subscribe`
- Epub: `epubStore` → `playerStore` for paragraph publishing; `epub.tsx` eventBus.on → `playerStore.subscribe`
- DJVU: `DjvuView` eventBus → playerStore
- MOBI: `MobiView` eventBus → playerStore

**Phase 4: Cleanup**
- Remove eventBus compatibility shim from machine
- Delete `bus.ts`, `PlayerClass.ts`, `Player.ts`, `pdf_player_control.ts`, `epub_player_contol.ts`
- Rewire `stateDump.ts` to read from `playerStore`
- Remove `useDebug.tsx` player.on() subscription

### Files created

- `apps/main/src/machines/playerMachine.ts`
- `apps/main/src/services/audioService.ts`
- `apps/main/src/stores/playerStore.ts`
- `apps/main/src/hooks/usePlayerMachine.ts`

### Files deleted (Phase 4)

- `apps/main/src/models/PlayerClass.ts`
- `apps/main/src/models/Player.ts`
- `apps/main/src/models/pdf_player_control.ts`
- `apps/main/src/models/epub_player_contol.ts`
- `apps/main/src/utils/bus.ts`

### Files modified

- `apps/main/src/components/TTSControls.tsx`
- `apps/main/src/components/pdf/components/pdf.tsx`
- `apps/main/src/components/pdf/hooks/useCurrentPageNumber.tsx`
- `apps/main/src/components/pdf/hooks/useScrolling.tsx`
- `apps/main/src/components/epub.tsx`
- `apps/main/src/stores/epubStore.ts`
- `apps/main/src/components/djvu/DjvuView.tsx`
- `apps/main/src/components/mobi/MobiView.tsx`
- `apps/main/src/hooks/useDebug.tsx`
- `apps/main/src/utils/stateDump.ts`

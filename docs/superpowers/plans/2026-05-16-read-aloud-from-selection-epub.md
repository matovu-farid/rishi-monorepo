# Read Aloud From Selection — Phase 1 (EPUB) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user select text in an EPUB and trigger TTS playback that starts at the sentence containing the selection's first character. Triggered by SelectionPopover play button, native context menu on right-click, or ⌘⇧L. EPUB only — PDF and AZW3/MOBI deferred.

**Architecture:** A pure `read-aloud-from` module computes sentence boundaries; `playerMachine` gains a `PLAY_FROM` event with a partial-first text override; EPUB adapter maps selection CFI → paragraph index + char offset, builds the override, dispatches the event. Three UI surfaces converge on the same adapter call: a play button in SelectionPopover, a native Electron context menu, and the ⌘⇧L global shortcut.

**Tech Stack:** React + TypeScript renderer, XState player machine, epub.js + react-reader, Electron `webContents.on('context-menu')` + `Menu.popup`, vitest unit tests, Playwright e2e.

**Spec:** `docs/superpowers/specs/2026-05-16-read-aloud-from-selection-design.md` (§ 5).

**Amendment to spec § 5.5:** Context menu surface is **Electron native** (via `webContents.on('context-menu')` + `Menu.popup`) for both EPUB and PDF, not a hybrid of native + shadcn. This solves the EPUB iframe contextmenu-bubbling problem natively (Electron fires the event in main with the iframe's frame as `params.frame`) and avoids adding a new dep + iframe-event-forwarding plumbing.

---

## File Structure

**Create:**
- `apps/rishi-electron/src/renderer/src/modules/read-aloud-from/index.ts` — pure sentence-snap helpers
- `apps/rishi-electron/src/renderer/src/modules/read-aloud-from/__tests__/index.test.ts`
- `apps/rishi-electron/src/renderer/src/stores/selectionStore.ts` — tracks the latest reader selection
- `apps/rishi-electron/src/renderer/src/stores/selectionStore.test.ts`
- `apps/rishi-electron/src/renderer/src/modules/cfi-to-paragraph.ts` — pure CFI → paragraph mapping helper
- `apps/rishi-electron/src/renderer/src/modules/cfi-to-paragraph.test.ts`
- `apps/rishi-electron/src/main/contextMenu.ts` — registers `webContents.on('context-menu')` for book windows
- `apps/rishi-electron/e2e/read-aloud-from-selection.spec.ts`

**Modify:**
- `apps/rishi-electron/src/renderer/src/machines/playerMachine.ts` — add `PLAY_FROM` event, 3 context fields, actions, transition wiring
- `apps/rishi-electron/src/renderer/src/machines/playerMachine.test.ts` — extend with `PLAY_FROM` cases
- `apps/rishi-electron/src/renderer/src/hooks/usePlayerMachine.ts` — loading effect uses override text/key when present; prefetch skips override index
- `apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx` — publish selection to store; add `handleReadAloudFrom`; wire popover button + IPC listener
- `apps/rishi-electron/src/renderer/src/components/highlights/SelectionPopover.tsx` — add `onReadAloud?` prop + Play icon button
- `apps/rishi-electron/src/renderer/src/components/highlights/SelectionPopover.test.tsx` *(new file if absent)*
- `apps/rishi-electron/src/preload/ipc-contract.ts` — add `reader:readAloudFromSelection` channel (renderer-handled event)
- `apps/rishi-electron/src/preload/types.ts` — derived type pickup (usually automatic)
- `apps/rishi-electron/src/main/menu/accelerators.ts` — add `readAloudFromSelection: 'CmdOrCtrl+Shift+L'`
- `apps/rishi-electron/src/main/menu/commands.ts` — add `{ command: 'readAloudFromSelection' }` to `MenuCommand` union
- `apps/rishi-electron/src/main/menu/menuBuilder.ts` — wire the new accelerator into the Reader menu
- `apps/rishi-electron/src/renderer/src/hooks/useMenuCommands.ts` — handle `readAloudFromSelection`; fall back to existing readAloudToggle if no selection

---

### Task 1: Pure module `read-aloud-from`

**Files:**
- Create: `src/renderer/src/modules/read-aloud-from/index.ts`
- Create: `src/renderer/src/modules/read-aloud-from/__tests__/index.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// src/renderer/src/modules/read-aloud-from/__tests__/index.test.ts
import { describe, it, expect } from 'vitest'
import { findSentenceStart, buildPartialFirst } from '../index'

describe('findSentenceStart', () => {
  it('returns 0 when offset is 0', () => {
    expect(findSentenceStart('Hello world. Goodbye world.', 0)).toBe(0)
  })

  it('returns 0 when offset is in the first sentence', () => {
    expect(findSentenceStart('Hello world. Goodbye world.', 5)).toBe(0)
  })

  it('returns the start of the second sentence when offset is in it', () => {
    const text = 'Hello world. Goodbye world.'
    // "Goodbye" starts at index 13 (after "Hello world. ")
    expect(findSentenceStart(text, 15)).toBe(13)
  })

  it('returns the start of the sentence containing the offset (mid-sentence)', () => {
    const text = 'First sentence. Second sentence here. Third.'
    // Second sentence starts at index 16
    expect(findSentenceStart(text, 25)).toBe(16)
  })

  it('clamps offsets beyond text length', () => {
    const text = 'One. Two. Three.'
    // Last sentence "Three." starts at index 10
    expect(findSentenceStart(text, 999)).toBe(10)
  })

  it('handles single-sentence text', () => {
    expect(findSentenceStart('A single sentence with no terminator', 10)).toBe(0)
  })

  it('handles empty text', () => {
    expect(findSentenceStart('', 0)).toBe(0)
  })
})

describe('buildPartialFirst', () => {
  it('returns full paragraph text when sentenceStart is 0', () => {
    const result = buildPartialFirst('cfi:1', 'Hello. World.', 0)
    expect(result.partialFirstText).toBe('Hello. World.')
    expect(result.partialFirstKey).toBe('cfi:1#s=0')
    expect(result.sentenceStartChar).toBe(0)
  })

  it('returns only the second sentence when offset is in it', () => {
    const text = 'Hello world. Goodbye world.'
    const result = buildPartialFirst('cfi:p1', text, 15)
    expect(result.partialFirstText).toBe('Goodbye world.')
    expect(result.partialFirstKey).toBe('cfi:p1#s=13')
    expect(result.sentenceStartChar).toBe(13)
  })

  it('returns full paragraph when selection is past the last sentence', () => {
    const text = 'Just one sentence.'
    const result = buildPartialFirst('cfi:p1', text, 999)
    expect(result.partialFirstText).toBe('Just one sentence.')
    expect(result.sentenceStartChar).toBe(0)
  })

  it('handles empty paragraph text', () => {
    const result = buildPartialFirst('cfi:p1', '', 0)
    expect(result.partialFirstText).toBe('')
    expect(result.partialFirstKey).toBe('cfi:p1#s=0')
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test src/renderer/src/modules/read-aloud-from`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

```ts
// src/renderer/src/modules/read-aloud-from/index.ts
export interface PartialFirst {
  /** Text from the sentence-start offset to end of paragraph. */
  partialFirstText: string
  /** Stable TTS cache key: `${paragraphIndex}#s=${sentenceStartChar}` */
  partialFirstKey: string
  /** Char offset of the sentence start. 0 if selection is already at one. */
  sentenceStartChar: number
}

/**
 * Returns the character offset of the start of the sentence containing
 * `charOffset`. Uses Intl.Segmenter when available; falls back to a regex
 * scan otherwise.
 */
export function findSentenceStart(text: string, charOffset: number): number {
  if (text.length === 0) return 0
  const clamped = Math.min(Math.max(charOffset, 0), text.length)

  // Modern browsers (Electron's Chromium 100+): use Intl.Segmenter.
  const Segmenter = (
    Intl as unknown as { Segmenter?: new (locale: string, opts: { granularity: string }) => unknown }
  ).Segmenter
  if (Segmenter) {
    const seg = new Segmenter('en', { granularity: 'sentence' }) as {
      segment(input: string): Iterable<{ index: number; segment: string }>
    }
    let lastStart = 0
    for (const piece of seg.segment(text)) {
      if (piece.index > clamped) break
      lastStart = piece.index
    }
    return lastStart
  }

  // Fallback: scan all sentence-terminator boundaries via matchAll, then
  // pick the latest boundary that is at or before `clamped`.
  let lastStart = 0
  for (const m of text.matchAll(/[.!?]+\s+/g)) {
    const candidate = (m.index ?? 0) + m[0].length
    if (candidate > clamped) break
    lastStart = candidate
  }
  return lastStart
}

/**
 * Builds the partial-first payload from a paragraph and the char offset of
 * the selection's first character.
 */
export function buildPartialFirst(
  paragraphIndex: string,
  paragraphText: string,
  selectionStartChar: number
): PartialFirst {
  const sentenceStartChar = findSentenceStart(paragraphText, selectionStartChar)
  const partialFirstText = paragraphText.slice(sentenceStartChar)
  const partialFirstKey = `${paragraphIndex}#s=${sentenceStartChar}`
  return { partialFirstText, partialFirstKey, sentenceStartChar }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm test src/renderer/src/modules/read-aloud-from`
Expected: PASS (11 tests)

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/modules/read-aloud-from/
git commit -m "feat(read-aloud): pure sentence-snap module"
```

---

### Task 2: `playerMachine` PLAY_FROM event

**Files:**
- Modify: `src/renderer/src/machines/playerMachine.ts`
- Modify: `src/renderer/src/machines/playerMachine.test.ts`

- [ ] **Step 1: Write failing tests**

Read the existing test file to find the right `describe` block (likely top-level `describe('playerMachine', ...)`). Append a new `describe('playerMachine - PLAY_FROM', ...)` block at the end with these tests. The tests use the existing `createActor` pattern from the rest of the file — match its style.

Example (adapt imports/helpers to existing file style):

```ts
import { createActor } from 'xstate'
import { playerMachine } from './playerMachine'

describe('playerMachine - PLAY_FROM', () => {
  const paragraphs = [
    { index: 'p0', text: 'First.' },
    { index: 'p1', text: 'Second.' },
    { index: 'p2', text: 'Third.' }
  ]

  function setupPlayingState() {
    const actor = createActor(playerMachine).start()
    actor.send({ type: 'INITIALIZE', bookId: 'book-1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs })
    return actor
  }

  it('PLAY_FROM from stopped transitions to loading with the target paragraph index', () => {
    const actor = setupPlayingState()
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 2,
      partialFirstText: 'override text',
      partialFirstKey: 'p2#s=0'
    })
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(2)
    expect(actor.getSnapshot().context.partialFirstText).toBe('override text')
    expect(actor.getSnapshot().context.partialFirstKey).toBe('p2#s=0')
    expect(actor.getSnapshot().context.partialFirstParagraphIndex).toBe(2)
  })

  it('PLAY_FROM from playing transitions to loading with new index', () => {
    const actor = setupPlayingState()
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 0,
      partialFirstText: 'p0 full',
      partialFirstKey: 'p0#s=0'
    })
    actor.send({ type: 'AUDIO_LOADED' })
    expect(actor.getSnapshot().value).toBe('playing')

    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 2,
      partialFirstText: 'p2 override',
      partialFirstKey: 'p2#s=5'
    })
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(2)
    expect(actor.getSnapshot().context.partialFirstParagraphIndex).toBe(2)
  })

  it('PLAY_FROM is ignored from idle', () => {
    const actor = createActor(playerMachine).start()
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 1,
      partialFirstText: 'x',
      partialFirstKey: 'p1#s=0'
    })
    expect(actor.getSnapshot().value).toBe('idle')
    expect(actor.getSnapshot().context.partialFirstText).toBeNull()
  })

  it('PLAY_FROM is ignored from pageNavigating', () => {
    const actor = setupPlayingState()
    actor.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
    expect(actor.getSnapshot().value).toBe('pageNavigating')
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 1,
      partialFirstText: 'x',
      partialFirstKey: 'p1#s=0'
    })
    expect(actor.getSnapshot().value).toBe('pageNavigating')
    expect(actor.getSnapshot().context.partialFirstText).toBeNull()
  })

  it('override clears on STOP', () => {
    const actor = setupPlayingState()
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 1,
      partialFirstText: 'override',
      partialFirstKey: 'p1#s=0'
    })
    actor.send({ type: 'STOP' })
    expect(actor.getSnapshot().context.partialFirstText).toBeNull()
    expect(actor.getSnapshot().context.partialFirstParagraphIndex).toBeNull()
  })

  it('override clears on PAGE_NAVIGATING', () => {
    const actor = setupPlayingState()
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 1,
      partialFirstText: 'override',
      partialFirstKey: 'p1#s=0'
    })
    actor.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
    expect(actor.getSnapshot().context.partialFirstText).toBeNull()
  })

  it('override survives RESUME from paused.clean', () => {
    const actor = setupPlayingState()
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 1,
      partialFirstText: 'override',
      partialFirstKey: 'p1#s=0'
    })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'PAUSE' })
    actor.send({ type: 'RESUME' })
    expect(actor.getSnapshot().value).toBe('playing')
    expect(actor.getSnapshot().context.partialFirstText).toBe('override')
  })

  it('override clears after AUDIO_ENDED for the override paragraph', () => {
    const actor = setupPlayingState()
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 0,
      partialFirstText: 'override',
      partialFirstKey: 'p0#s=0'
    })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'AUDIO_ENDED' })
    // Now should advance to next paragraph; override cleared because the
    // override paragraph (index 0) has finished.
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1)
    expect(actor.getSnapshot().context.partialFirstText).toBeNull()
    expect(actor.getSnapshot().context.partialFirstParagraphIndex).toBeNull()
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test src/renderer/src/machines/playerMachine.test.ts`
Expected: FAIL — the new tests fail (PLAY_FROM event not handled).

- [ ] **Step 3: Implement the machine extension**

In `src/renderer/src/machines/playerMachine.ts`:

**3a. Add to `PlayerMachineContext` type:**

```ts
export type PlayerMachineContext = {
  // ... existing fields ...
  partialFirstText: string | null
  partialFirstKey: string | null
  partialFirstParagraphIndex: number | null
}
```

**3b. Add to `PlayerMachineEvent` type union:**

```ts
| { type: 'PLAY_FROM'; paragraphIndex: number; partialFirstText: string; partialFirstKey: string }
```

**3c. Add to `initialContext`:**

```ts
partialFirstText: null,
partialFirstKey: null,
partialFirstParagraphIndex: null
```

**3d. Add three new actions in the `actions` block:**

```ts
setPartialFirst: assign({
  partialFirstText: ({ event }) =>
    event.type === 'PLAY_FROM' ? event.partialFirstText : null,
  partialFirstKey: ({ event }) =>
    event.type === 'PLAY_FROM' ? event.partialFirstKey : null,
  partialFirstParagraphIndex: ({ event }) =>
    event.type === 'PLAY_FROM' ? event.paragraphIndex : null
}),
clearPartialFirst: assign({
  partialFirstText: null,
  partialFirstKey: null,
  partialFirstParagraphIndex: null
}),
setParagraphIndexFromEvent: assign({
  paragraphIndex: ({ event }) =>
    event.type === 'PLAY_FROM' ? event.paragraphIndex : 0
}),
clearPartialFirstIfConsumed: assign({
  partialFirstText: ({ context }) =>
    context.partialFirstParagraphIndex === context.paragraphIndex
      ? null
      : context.partialFirstText,
  partialFirstKey: ({ context }) =>
    context.partialFirstParagraphIndex === context.paragraphIndex
      ? null
      : context.partialFirstKey,
  partialFirstParagraphIndex: ({ context }) =>
    context.partialFirstParagraphIndex === context.paragraphIndex
      ? null
      : context.partialFirstParagraphIndex
})
```

**3e. Update existing `resetAll` action** (it should already spread `initialContext`, so the three new fields auto-reset — verify).

**3f. Add `PLAY_FROM` to the transition table of these states** (target `loading`, actions `setPartialFirst` then `setParagraphIndexFromEvent`):

- `stopped`
- `paused.clean`
- `paused.stale`
- `playing`
- `loading` (re-enter)
- `waitingForParagraphs`
- `error` (also `clearErrors` first)

Specifically NOT accepting `PLAY_FROM`:
- `idle` (no transition at all — event ignored)
- `pageNavigating` (no transition — event ignored)
- `republishingParagraphs` (no transition — event ignored)

**3g. Augment existing `STOP` transitions** in all states that handle STOP — add `'clearPartialFirst'` to their actions array.

**3h. Augment `PAGE_NAVIGATING` global transition** (in the top-level `on` of the machine) — add `'clearPartialFirst'`.

If `PAGE_NAVIGATING` is per-state (not global), augment every per-state `PAGE_NAVIGATING` handler.

**3i. Augment the `playing` state's `AUDIO_ENDED` transitions** — add `'clearPartialFirstIfConsumed'` BEFORE the existing actions. Apply to both branches (hasMoreParagraphs and waitingForParagraphs).

**3j. Augment the `error` state's transition** (final retry exhausted) — add `'clearPartialFirst'`.

**3k. `loading` state's `AUDIO_ERROR` retry branch** — does NOT clear (override should retry).

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm test src/renderer/src/machines/playerMachine.test.ts`
Expected: PASS (all existing + new).

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/machines/playerMachine.ts src/renderer/src/machines/playerMachine.test.ts
git commit -m "feat(player): PLAY_FROM event with partial-first override"
```

---

### Task 3: `usePlayerMachine` override path

**Files:**
- Modify: `src/renderer/src/hooks/usePlayerMachine.ts`

This task is implementation-only with no isolated test — the override behavior is exercised end-to-end via the e2e test in Task 12, and the override-state machine itself is tested in Task 2. We're modifying the audio-side-effect to route through the override fields when present.

- [ ] **Step 1: Modify the `loading` branch of the audio side-effect**

Find the existing block (currently around `usePlayerMachine.ts:164` per Task 7 of Phase 0; re-verify line number with `grep -n "if (state === 'loading')" src/renderer/src/hooks/usePlayerMachine.ts`):

Replace the TTS fetch call to use override fields when present:

```ts
const paragraph = ctx.currentParagraphs[ctx.paragraphIndex]
const useOverride =
  ctx.partialFirstText !== null &&
  ctx.partialFirstParagraphIndex === ctx.paragraphIndex
const ttsText = useOverride ? ctx.partialFirstText! : paragraph.text
const ttsKey = useOverride ? ctx.partialFirstKey! : paragraph.index

// Skip the empty-text early-return when an override is active and non-empty.
if (!useOverride && !paragraph.text.trim()) {
  // existing: NEXT after 2s
} else if (useOverride && !ttsText.trim()) {
  // override resolved to empty (selection at end of paragraph) — advance.
  setTimeout(() => {
    if (gen !== fetchGeneration) return
    actor.send({ type: 'NEXT' })
  }, 0)
} else {
  // Fetch audio with ttsText/ttsKey instead of paragraph.text/index.
  getTtsService()
    .requestAudio({
      bookId: ctx.bookId,
      cfiRange: ttsKey,
      text: ttsText,
      priority: 1
    })
    .then(...)
}
```

Keep all existing retry/error/cancellation logic intact — only the `cfiRange` and `text` arguments change.

- [ ] **Step 2: Modify the prefetch loop** (around `usePlayerMachine.ts:71-86`)

Skip the override paragraph's index in the current-page prefetch (it'd waste a full-paragraph TTS request that will never be played):

```ts
const unsubCurrent = usePlayerStore.subscribe(
  (s) => s.currentParagraphs,
  (paragraphs) => {
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs })
    const ctx = actor.getSnapshot().context
    const machineState = mapStateValue(actor.getSnapshot().value)
    if (machineState === 'playing' || machineState === 'loading') {
      const overrideIdx =
        ctx.partialFirstText !== null ? ctx.partialFirstParagraphIndex : null
      for (let i = 0; i < paragraphs.length; i++) {
        if (i === overrideIdx) continue // skip — playing partial text via override key
        const p = paragraphs[i]
        if (p.text.trim()) {
          void getTtsService()
            .requestAudio({ bookId, cfiRange: p.index, text: p.text, priority: 0 })
            .catch((err: unknown) => console.warn('[player] audio prefetch failed:', err))
        }
      }
    }
  },
  { equalityFn: isEqual }
)
```

- [ ] **Step 3: Run all renderer tests for regressions**

Run: `pnpm test src/renderer`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add src/renderer/src/hooks/usePlayerMachine.ts
git commit -m "feat(player): route TTS through override fields when active"
```

---

### Task 4: Selection store

**Files:**
- Create: `src/renderer/src/stores/selectionStore.ts`
- Create: `src/renderer/src/stores/selectionStore.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// src/renderer/src/stores/selectionStore.test.ts
import { describe, it, expect, beforeEach } from 'vitest'
import { useSelectionStore } from './selectionStore'

describe('selectionStore', () => {
  beforeEach(() => {
    useSelectionStore.getState().clear()
  })

  it('starts with no selection', () => {
    expect(useSelectionStore.getState().current).toBeNull()
  })

  it('stores an EPUB selection', () => {
    useSelectionStore.getState().setEpubSelection({
      cfiRange: 'epubcfi(/6/4!/4/2/1,/1:0,/1:5)',
      text: 'hello'
    })
    const sel = useSelectionStore.getState().current
    expect(sel).not.toBeNull()
    expect(sel!.format).toBe('epub')
    expect(sel!.cfiRange).toBe('epubcfi(/6/4!/4/2/1,/1:0,/1:5)')
    expect(sel!.text).toBe('hello')
  })

  it('clear() removes the selection', () => {
    useSelectionStore.getState().setEpubSelection({
      cfiRange: 'epubcfi(/6/4!/4/2/1,/1:0,/1:5)',
      text: 'hello'
    })
    useSelectionStore.getState().clear()
    expect(useSelectionStore.getState().current).toBeNull()
  })

  it('replacing a selection overwrites the old one', () => {
    const store = useSelectionStore.getState()
    store.setEpubSelection({ cfiRange: 'cfi-a', text: 'first' })
    store.setEpubSelection({ cfiRange: 'cfi-b', text: 'second' })
    expect(useSelectionStore.getState().current?.text).toBe('second')
  })
})
```

- [ ] **Step 2: Run to verify fails**

Run: `pnpm test src/renderer/src/stores/selectionStore.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

```ts
// src/renderer/src/stores/selectionStore.ts
import { create } from 'zustand'

export type EpubSelection = {
  format: 'epub'
  cfiRange: string
  text: string
}

// Future formats (PDF/AZW3/MOBI) will add discriminated variants here.
export type ReaderSelection = EpubSelection

interface SelectionStore {
  current: ReaderSelection | null
  setEpubSelection: (sel: { cfiRange: string; text: string }) => void
  clear: () => void
}

export const useSelectionStore = create<SelectionStore>((set) => ({
  current: null,
  setEpubSelection: (sel) => set({ current: { format: 'epub', ...sel } }),
  clear: () => set({ current: null })
}))
```

- [ ] **Step 4: Run tests to verify pass**

Run: `pnpm test src/renderer/src/stores/selectionStore.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/stores/selectionStore.ts src/renderer/src/stores/selectionStore.test.ts
git commit -m "feat(stores): selectionStore for reader selection tracking"
```

---

### Task 5: CFI → paragraph offset helper

**Files:**
- Create: `src/renderer/src/modules/cfi-to-paragraph.ts`
- Create: `src/renderer/src/modules/cfi-to-paragraph.test.ts`

This helper takes the list of `ParagraphWithIndex` published on the current page (each has a paragraph-spanning `cfiRange` as its `index`) and a selection CFI range, and returns the paragraph index + character offset within the paragraph for the selection's start.

We rely on epub.js's `EpubCFI.compare()` (returns -1/0/1) to determine containment. The helper is pure aside from constructing `EpubCFI` instances.

- [ ] **Step 1: Write failing tests**

```ts
// src/renderer/src/modules/cfi-to-paragraph.test.ts
import { describe, it, expect } from 'vitest'
import { findParagraphForCfi } from './cfi-to-paragraph'

describe('findParagraphForCfi', () => {
  // Synthetic CFIs with well-defined comparison order under EpubCFI.compare.
  // If the real epub.js API differs from this fixture, the implementer
  // should adjust the fixtures using real EPUB-shaped CFIs.
  const paragraphs = [
    { index: 'epubcfi(/6/4!/4/2/1)', text: 'First paragraph.' },
    { index: 'epubcfi(/6/4!/4/4/1)', text: 'Second paragraph.' },
    { index: 'epubcfi(/6/4!/4/6/1)', text: 'Third paragraph.' }
  ]

  it('returns null when no paragraph contains the selection', () => {
    // A CFI in a completely different spine section
    const result = findParagraphForCfi(paragraphs, 'epubcfi(/6/8!/4/2/1,/1:0,/1:5)')
    expect(result).toBeNull()
  })

  it('returns the matching paragraph index when the selection start is inside it', () => {
    // Selection start inside the second paragraph
    const result = findParagraphForCfi(
      paragraphs,
      'epubcfi(/6/4!/4/4/1,/1:3,/1:10)'
    )
    expect(result).not.toBeNull()
    expect(result!.paragraphIndex).toBe(1)
  })

  it('uses the first paragraph when selection is in it', () => {
    const result = findParagraphForCfi(
      paragraphs,
      'epubcfi(/6/4!/4/2/1,/1:0,/1:5)'
    )
    expect(result!.paragraphIndex).toBe(0)
  })

  it('returns the char offset of the selection start within the paragraph text', () => {
    // For an EPUB CFI of the shape epubcfi(spine!path,/1:N,/1:M), the offset
    // is N (the start character index within the text node).
    const result = findParagraphForCfi(
      paragraphs,
      'epubcfi(/6/4!/4/4/1,/1:7,/1:12)'
    )
    expect(result!.charOffsetInParagraph).toBe(7)
  })
})
```

- [ ] **Step 2: Run tests, confirm they fail**

Run: `pnpm test src/renderer/src/modules/cfi-to-paragraph.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

```ts
// src/renderer/src/modules/cfi-to-paragraph.ts
import { EpubCFI } from 'epubjs'

export interface ParagraphLike {
  /** CFI range string spanning the paragraph. */
  index: string
  text: string
}

export interface MatchedParagraph {
  paragraphIndex: number
  /** Character offset of the selection start within paragraph.text. */
  charOffsetInParagraph: number
}

/**
 * Given the paragraphs on the current page and a selection CFI range,
 * returns the matching paragraph index plus the selection-start character
 * offset within that paragraph's text.
 *
 * Returns null when the selection start is not inside any provided paragraph
 * (caller should fall back to playing from paragraph 0).
 */
export function findParagraphForCfi(
  paragraphs: ParagraphLike[],
  selectionCfiRange: string
): MatchedParagraph | null {
  // A range CFI is "epubcfi(base,start,end)". Extract the start.
  let selectionStart: EpubCFI
  try {
    selectionStart = new EpubCFI(selectionCfiRange)
  } catch {
    return null
  }

  for (let i = 0; i < paragraphs.length; i++) {
    const p = paragraphs[i]
    let pRange: EpubCFI
    try {
      pRange = new EpubCFI(p.index)
    } catch {
      continue
    }
    // Range CFIs have `start` and `end` shaped CFIs inside.
    const pStart = (pRange as unknown as { start?: { steps: unknown[] } }).start
    const pEnd = (pRange as unknown as { end?: { steps: unknown[] } }).end
    if (!pStart || !pEnd) continue

    // epub.js compare returns -1 if first < second, 0 if equal, 1 if greater.
    const compare = (a: unknown, b: unknown): number =>
      (EpubCFI as unknown as { prototype: { compare(a: unknown, b: unknown): number } })
        .prototype.compare(a, b)

    const startSide = compare(selectionStart, pStart)
    const endSide = compare(selectionStart, pEnd)
    if (startSide >= 0 && endSide <= 0) {
      return {
        paragraphIndex: i,
        charOffsetInParagraph: extractTextOffset(selectionCfiRange)
      }
    }
  }
  return null
}

/**
 * Extracts the start character offset from an epubcfi range string.
 * Range CFIs end with `,/N:OFFSET,/N:END_OFFSET` — we want the first OFFSET.
 * Returns 0 when no offset can be parsed.
 */
function extractTextOffset(cfiRange: string): number {
  // Match the first text-position step inside the range portion.
  // e.g., "epubcfi(/6/4!/4/4/1,/1:7,/1:12)" should yield 7.
  const m = cfiRange.match(/,\/[\d/]+:(\d+),/)
  if (!m) return 0
  const offset = parseInt(m[1], 10)
  return Number.isFinite(offset) ? offset : 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm test src/renderer/src/modules/cfi-to-paragraph.test.ts`
Expected: PASS (4 tests).

> **If the EpubCFI.compare path doesn't work as expected** (epub.js's CFI shape may differ from these assumptions in practice): the implementer should investigate the actual `EpubCFI` API and adjust. The test for the "no match" case is the most likely to need adjustment. If it becomes blocking, report NEEDS_CONTEXT with what was tried.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/modules/cfi-to-paragraph.ts src/renderer/src/modules/cfi-to-paragraph.test.ts
git commit -m "feat(epub): CFI-to-paragraph mapping helper"
```

---

### Task 6: Wire EpubView to publish selection + add handleReadAloudFrom

**Files:**
- Modify: `src/renderer/src/components/epub/EpubView.tsx`

- [ ] **Step 1: Publish selection to the store inside `handleTextSelected`**

Find the existing `handleTextSelected` callback (currently around `EpubView.tsx:279`). Inside it, immediately after computing `cfiRange` and `selectedText`, publish to the selection store:

```ts
import { useSelectionStore } from '@/stores/selectionStore'
// inside handleTextSelected, after we have cfiRange + selectedText:
useSelectionStore.getState().setEpubSelection({ cfiRange, text: selectedText })

// inside the existing selection-dismissal paths (SelectionPopover.onClose etc.)
// also call useSelectionStore.getState().clear() to keep the store consistent.
```

- [ ] **Step 2: Add a `handleReadAloudFrom` callback**

Below the existing `handleTextSelected`, add:

```ts
import { findParagraphForCfi } from '@/modules/cfi-to-paragraph'
import { buildPartialFirst } from '@/modules/read-aloud-from'
import { usePlayerStore } from '@/stores/playerStore'

const handleReadAloudFrom = useCallback(() => {
  const sel = useSelectionStore.getState().current
  if (!sel || sel.format !== 'epub') return

  const playingState = usePlayerStore.getState().playingState
  if (playingState === 'idle' || playingState === 'pageNavigating') return

  const paragraphs = usePlayerStore.getState().currentParagraphs
  const matched = findParagraphForCfi(paragraphs, sel.cfiRange)

  const send = usePlayerStore.getState().send
  if (!send) return

  if (!matched) {
    // Fall back: play from paragraph 0 of current view, no override.
    send({
      type: 'PLAY_FROM',
      paragraphIndex: 0,
      partialFirstText: paragraphs[0]?.text ?? '',
      partialFirstKey: paragraphs[0]?.index ?? '#fallback'
    })
    return
  }

  const targetParagraph = paragraphs[matched.paragraphIndex]
  const { partialFirstText, partialFirstKey } = buildPartialFirst(
    targetParagraph.index,
    targetParagraph.text,
    matched.charOffsetInParagraph
  )

  requireAuth('tts', () => {
    send({
      type: 'PLAY_FROM',
      paragraphIndex: matched.paragraphIndex,
      partialFirstText,
      partialFirstKey
    })
  })

  // Clear selection store; the popover is still visible and will close on its own.
  useSelectionStore.getState().clear()
}, [requireAuth])
```

- [ ] **Step 3: Typecheck**

Run: `pnpm typecheck:node && pnpm exec tsc --noEmit -p tsconfig.web.json`
Expected: clean (modulo the pre-existing unrelated TS6307).

- [ ] **Step 4: Run renderer tests**

Run: `pnpm test src/renderer`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/components/epub/EpubView.tsx
git commit -m "feat(epub): publish selection + handleReadAloudFrom adapter"
```

---

### Task 7: SelectionPopover play button

**Files:**
- Modify: `src/renderer/src/components/highlights/SelectionPopover.tsx`
- Create: `src/renderer/src/components/highlights/SelectionPopover.test.tsx` (if not present)
- Modify: `src/renderer/src/components/epub/EpubView.tsx` (wire onReadAloud)

- [ ] **Step 1: Write failing test for new button**

```tsx
// src/renderer/src/components/highlights/SelectionPopover.test.tsx
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { SelectionPopover } from './SelectionPopover'

describe('SelectionPopover', () => {
  const baseProps = {
    cfiRange: 'cfi:x',
    selectedText: 'hello',
    position: { x: 100, y: 100 },
    onHighlight: vi.fn(),
    onClose: vi.fn()
  }

  it('does not render a Read Aloud button when onReadAloud is omitted', () => {
    render(<SelectionPopover {...baseProps} />)
    expect(screen.queryByRole('button', { name: /read aloud/i })).toBeNull()
  })

  it('renders a Read Aloud button when onReadAloud is provided', () => {
    render(<SelectionPopover {...baseProps} onReadAloud={vi.fn()} />)
    expect(screen.getByRole('button', { name: /read aloud/i })).toBeInTheDocument()
  })

  it('clicking the Read Aloud button invokes onReadAloud and onClose', () => {
    const onReadAloud = vi.fn()
    const onClose = vi.fn()
    render(
      <SelectionPopover {...baseProps} onReadAloud={onReadAloud} onClose={onClose} />
    )
    fireEvent.click(screen.getByRole('button', { name: /read aloud/i }))
    expect(onReadAloud).toHaveBeenCalledTimes(1)
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})
```

- [ ] **Step 2: Run tests, confirm fails**

Run: `pnpm test src/renderer/src/components/highlights/SelectionPopover.test.tsx`
Expected: FAIL on the new tests.

- [ ] **Step 3: Modify `SelectionPopover.tsx`**

Add the optional `onReadAloud?: () => void` prop. Render a Play-icon button (lucide-react `Play`) BEFORE the highlight color swatches when the prop is provided:

```tsx
import { Play } from 'lucide-react'

interface SelectionPopoverProps {
  cfiRange: string
  selectedText: string
  position: { x: number; y: number }
  onHighlight: (color: HighlightColor) => void
  onReadAloud?: () => void
  onClose: () => void
}

export function SelectionPopover({
  position,
  onHighlight,
  onReadAloud,
  onClose
}: SelectionPopoverProps) {
  // ... existing effects ...
  return (
    <div /* existing container */>
      <div className="flex items-center gap-2">
        {onReadAloud && (
          <button
            className="rounded-full p-1.5 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors focus:outline-none focus:ring-2 focus:ring-blue-500"
            aria-label="Read aloud from here"
            title="Read aloud from here"
            onClick={() => {
              onReadAloud()
              onClose()
            }}
          >
            <Play size={18} className="text-gray-700 dark:text-gray-200" />
          </button>
        )}
        {/* existing color swatch buttons */}
      </div>
    </div>
  )
}
```

- [ ] **Step 4: Wire it from EpubView**

In `EpubView.tsx`, find the existing `<SelectionPopover ...>` JSX and add the prop:

```tsx
<SelectionPopover
  cfiRange={selectionInfo.cfiRange}
  selectedText={selectionInfo.text}
  position={selectionInfo.position}
  onHighlight={handleHighlightColor}
  onReadAloud={handleReadAloudFrom}
  onClose={() => setSelectionInfo(null)}
/>
```

- [ ] **Step 5: Run tests, verify pass**

Run: `pnpm test src/renderer/src/components/highlights src/renderer/src/components/epub`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/src/components/highlights/SelectionPopover.tsx \
        src/renderer/src/components/highlights/SelectionPopover.test.tsx \
        src/renderer/src/components/epub/EpubView.tsx
git commit -m "feat(reader): Read Aloud play button in SelectionPopover"
```

---

### Task 8: IPC contract for read-aloud-from

**Files:**
- Modify: `src/preload/ipc-contract.ts`

Add a renderer-side event channel `reader:readAloudFromSelection`. The main process emits it via `webContents.send`; the renderer listens via whichever preload pattern the codebase uses.

- [ ] **Step 1: Inspect existing event channel patterns**

Run: `grep -n "ipcRenderer.on\|webContents.send\|on:" src/preload/index.ts src/preload/ipc-contract.ts | head -20`

Read what you find. The pattern for renderer-listened events may differ from the invoke/handle map.

- [ ] **Step 2: Add the channel following the existing pattern**

Add `readAloudFromSelection` (no payload — selection is read from the renderer's `selectionStore`). The exact code depends on the existing pattern observed in Step 1.

If the pattern looks like the invoke/handle map, this channel is special — it's main→renderer, not invoke. Look for any existing `webContents.send` cases in the codebase first:

`grep -rn "webContents.send" src/main | head`

Adopt whatever pattern they use. If the codebase uses typed channels for events, add this one to that registry.

- [ ] **Step 3: Typecheck**

Run: `pnpm typecheck:node`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add src/preload/ipc-contract.ts src/preload/index.ts src/preload/types.ts
git commit -m "feat(ipc): add reader:readAloudFromSelection event channel"
```

> **NEEDS_CONTEXT exit:** if the existing event-channel pattern is opaque or inconsistent, report back with what you found so we can decide on a pattern together before extending it.

---

### Task 9: Main-process context menu handler

**Files:**
- Create: `src/main/contextMenu.ts`
- Modify: `src/main/windows/createBrowserWindow.ts` (call the new registrar)

- [ ] **Step 1: Write the handler**

```ts
// src/main/contextMenu.ts
import { Menu, MenuItem, BrowserWindow } from 'electron'

/**
 * Registers a context-menu listener on the given BrowserWindow's webContents
 * that surfaces a single "Read Aloud From Here" item when the user
 * right-clicks on selected text. Sends the
 * `reader:readAloudFromSelection` event to the renderer when chosen.
 *
 * Electron fires `context-menu` for any frame including iframes — the EPUB
 * iframe's right-click is handled by this listener without renderer-side
 * forwarding.
 */
export function registerReaderContextMenu(window: BrowserWindow): void {
  const wc = window.webContents
  wc.on('context-menu', (_event, params) => {
    const hasSelection = params.selectionText && params.selectionText.trim().length > 0
    if (!hasSelection) return

    const menu = new Menu()
    menu.append(
      new MenuItem({
        label: 'Read Aloud From Here',
        click: () => {
          wc.send('reader:readAloudFromSelection')
        }
      })
    )
    menu.popup({ window, x: params.x, y: params.y })
  })
}
```

- [ ] **Step 2: Call it from `createBrowserWindow.ts`**

Find where the book window is created. Right after the window's webContents is ready, call:

```ts
import { registerReaderContextMenu } from '../contextMenu'
// ...
registerReaderContextMenu(window)
```

- [ ] **Step 3: Manual smoke**

Build + run dev. Open an EPUB, select text, right-click. Confirm "Read Aloud From Here" appears. Clicking it should fire the IPC event (won't produce playback yet — Task 10 wires the renderer listener).

- [ ] **Step 4: Commit**

```bash
git add src/main/contextMenu.ts src/main/windows/createBrowserWindow.ts
git commit -m "feat(main): native context menu with Read Aloud From Here"
```

---

### Task 10: Renderer IPC listener

**Files:**
- Modify: `src/renderer/src/components/epub/EpubView.tsx`

- [ ] **Step 1: Subscribe to the IPC event when EpubView mounts**

Add a `useEffect` near the existing menu/IPC subscriptions:

```ts
useEffect(() => {
  const e = (window as unknown as { electron: { on(channel: string, handler: () => void): () => void } }).electron
  const unsub = e.on('reader:readAloudFromSelection', () => {
    handleReadAloudFrom()
  })
  return () => unsub()
}, [handleReadAloudFrom])
```

> If the preload's `electron.on` shape differs, adapt — the goal is to wire a callback to the IPC event registered in Task 8.

- [ ] **Step 2: Manual smoke**

Build + run dev. Open EPUB. Select text. Right-click → "Read Aloud From Here". Expect playback to start from the selected sentence.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/src/components/epub/EpubView.tsx
git commit -m "feat(epub): wire context-menu IPC to handleReadAloudFrom"
```

---

### Task 11: ⌘⇧L keyboard shortcut

**Files:**
- Modify: `src/main/menu/accelerators.ts`
- Modify: `src/main/menu/commands.ts`
- Modify: `src/main/menu/menuBuilder.ts`
- Modify: `src/renderer/src/hooks/useMenuCommands.ts`
- Modify: `src/renderer/src/components/epub/EpubView.tsx`

- [ ] **Step 1: Add accelerator + command type**

`src/main/menu/accelerators.ts`:

```ts
export const ACCELERATORS = {
  // ... existing entries ...
  readAloudFromSelection: 'CmdOrCtrl+Shift+L'
} as const
```

`src/main/menu/commands.ts` — add to the discriminated union:

```ts
| { command: 'readAloudFromSelection' }
```

- [ ] **Step 2: Wire into menuBuilder**

Find the Reader menu section in `menuBuilder.ts`. Add a new MenuItem near `readAloudToggle`:

```ts
{
  label: 'Read Aloud From Selection',
  accelerator: ACCELERATORS.readAloudFromSelection,
  click: () => sendCommand(window, { command: 'readAloudFromSelection' })
}
```

(Match the existing style for how the file dispatches commands.)

- [ ] **Step 3: Handle in useMenuCommands**

In `useMenuCommands.ts` (or wherever menu commands are dispatched to handlers), add:

```ts
readAloudFromSelection: () => {
  const sel = useSelectionStore.getState().current
  if (sel) {
    // Re-use the same IPC channel the context menu uses to keep one code
    // path. The cleanest way: have the renderer dispatch a custom event
    // that EpubView listens to (same listener as Task 10).
    window.dispatchEvent(new CustomEvent('rishi:readAloudFromSelection'))
  } else {
    // Fall back to existing toggle — re-use the same dispatcher.
    menuHandlers.readAloudToggle()
  }
}
```

And in EpubView (Task 10's listener), also subscribe to the `'rishi:readAloudFromSelection'` window event to keep one handler path.

> **Implementer judgment call:** The cleanest wire-up depends on how `useMenuCommands` currently dispatches. The pattern we want is: shortcut → checks `selectionStore` → if present, triggers the same code path as the context menu (preferably by re-using the same IPC event registered in Task 8, or by dispatching a window event). If no selection, fall through to the existing `readAloudToggle`.

- [ ] **Step 4: Manual smoke**

Build + run dev. Open EPUB. Select text. Press ⌘⇧L. Expect playback from the selected sentence. Press ⌘⇧L with no selection. Expect existing Read Aloud toggle behavior.

- [ ] **Step 5: Commit**

```bash
git add src/main/menu/accelerators.ts src/main/menu/commands.ts src/main/menu/menuBuilder.ts \
        src/renderer/src/hooks/useMenuCommands.ts src/renderer/src/components/epub/EpubView.tsx
git commit -m "feat(menu): CmdOrCtrl+Shift+L for Read Aloud From Selection"
```

---

### Task 12: E2E + manual smoke

**Files:**
- Create: `e2e/read-aloud-from-selection.spec.ts`

Native context menus and audio playback are hard to test fully in Playwright. We'll add a thin e2e that simulates the renderer-side IPC trigger and asserts the audio element starts playing — this exercises Tasks 4–7 + 10 (everything except the native menu rendering).

- [ ] **Step 1: Write the e2e test**

```ts
// apps/rishi-electron/e2e/read-aloud-from-selection.spec.ts
import { test, expect, type Page } from '@playwright/test'
import {
  EPUB_FIXTURE,
  closeApp,
  deleteAllBooks,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

test.describe('Read Aloud From Selection', () => {
  let app: LaunchedApp
  let bookId: number
  let bookPage: Page

  test.beforeAll(async () => {
    app = await launchApp()
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'Read Aloud Selection Spec'
    })
    bookId = book.id
  })

  test.afterAll(async () => {
    await bookPage?.close().catch(() => {})
    await deleteAllBooks(app.page).catch(() => {})
    await closeApp(app).catch(() => {})
  })

  test.beforeEach(async () => {
    bookPage = await openBook(app.page, bookId)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
  })

  test('dispatching the readAloudFromSelection window event triggers playback', async () => {
    // Pre-populate the selection store via the window-attached test helper.
    // EpubView publishes the store globally for testing convenience.
    await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi?: { setEpubSelection?: (sel: { cfiRange: string; text: string }) => void }
      }
      w.__rishi?.setEpubSelection?.({
        cfiRange: 'epubcfi(/6/2!/4/2/1,/1:0,/1:5)',
        text: 'sample'
      })
    })

    // Dispatch the same window event the shortcut/IPC path uses.
    await bookPage.evaluate(() => {
      window.dispatchEvent(new CustomEvent('rishi:readAloudFromSelection'))
    })

    // Assert the singleton audioElement transitions to playing.
    await bookPage.waitForFunction(
      () => {
        const audio = document.querySelector('audio')
        return audio && audio.paused === false
      },
      { timeout: 15000 }
    )
  })
})
```

> If exposing `__rishi.setEpubSelection` for tests feels wrong, fall back to firing the rendition's `selected` event inside the iframe to populate the store naturally. Pick the cleanest seam — the test's purpose is to verify the adapter wiring, not the IPC plumbing itself.

- [ ] **Step 2: Run the test**

`pnpm test:e2e read-aloud-from-selection.spec.ts`
Expected: PASS. If it fails, adjust per the inline notes above.

- [ ] **Step 3: Manual smoke (golden path)**

1. `pnpm dev`
2. Open an EPUB.
3. Select a sentence in the middle of a paragraph.
4. Click the play-icon button in the popover. **Expect:** playback starts from the selected sentence.
5. Stop. Select again. Right-click. **Expect:** "Read Aloud From Here" appears in the native context menu.
6. Click it. **Expect:** playback starts from the selected sentence.
7. Stop. Press ⌘⇧L with text selected. **Expect:** same.
8. Stop. Press ⌘⇧L with no selection. **Expect:** existing Read Aloud toggle fires.

- [ ] **Step 4: Commit**

```bash
git add e2e/read-aloud-from-selection.spec.ts
git commit -m "test(e2e): read aloud from selection"
```

---

## Self-Review

**Spec coverage** (against design § 5):

| Spec section | Task |
|---|---|
| 5.1 — Pure module `read-aloud-from` | Task 1 |
| 5.2 — playerMachine PLAY_FROM extension | Task 2 |
| 5.2 — Override clear rules | Task 2 (transition wiring + clear actions) |
| 5.3 — EPUB adapter `handleReadAloudFrom` | Tasks 4, 5, 6 |
| 5.4 — PDF adapter | Deferred (Phase 1c) |
| 5.5 — SelectionPopover play button | Task 7 |
| 5.5 — Native context menu (Electron native, per amendment) | Tasks 8, 9, 10 |
| 5.5 — In-app context menu (PDF / Radix) | Deferred (Phase 1c) |
| 5.5 — ⌘⇧L shortcut + fallback | Task 11 |
| § 7 — TDD coverage | Tasks 1, 2, 4, 5, 7 are red→green TDD; Tasks 3, 6, 8–11 are integration-style with e2e validation in Task 12 |

**Placeholder scan:** Tasks 8 and 11 contain implementer-judgment branches because the existing IPC and menu-command patterns may have project-specific shapes I didn't fully inspect during planning. Both have `NEEDS_CONTEXT` exit instructions for the implementer. Not placeholders in the bad-pattern sense — flagged ambiguities with escalation paths.

**Type consistency:** `PartialFirst.partialFirstKey` is `${paragraphIndex}#s=${sentenceStartChar}` — same format used in machine context, hook override path, and TTS cache key. `ReaderSelection.format: 'epub'` discriminator leaves room for PDF/MOBI/AZW3 variants in Phase 1c+. `MatchedParagraph.paragraphIndex` is the array index in `currentParagraphs`, consistent with `paragraphIndex` in the machine context.

**Known unknowns flagged in tasks:**
- Task 5: `EpubCFI.compare` API shape — fixture-driven test may need adjustment based on epub.js's actual range-CFI internals.
- Task 8: existing IPC event-channel pattern not pre-verified — implementer should match existing convention.
- Task 11: cleanest wire from shortcut → adapter depends on how `useMenuCommands` currently dispatches; multiple acceptable approaches.

---

Plan complete and saved to `docs/superpowers/plans/2026-05-16-read-aloud-from-selection-epub.md`.

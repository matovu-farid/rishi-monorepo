# Repeat Paragraph Button — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Repeat button to the Electron TTS playback pill that restarts the current paragraph and continues forward, mounted only while the player is actively playing.

**Architecture:** A new `REPEAT` event is added to `playerMachine` (XState v5), handled only from the `playing` state, which re-enters `loading` at the same `paragraphIndex` (cache-hit re-fetch via existing TTS service). A new `RotateCcw` button in `TTSControls.tsx` lives between Play/Pause and Next, conditionally mounted via `framer-motion`'s `AnimatePresence` keyed off `playingState === 'playing'`. The pill width animates from 240 → 280 when playing, then back.

**Tech Stack:** XState v5, React, Zustand (`usePlayerStore`), `framer-motion` v12, `lucide-react`, Vitest + happy-dom + `@testing-library/react`.

**Spec:** `docs/superpowers/specs/2026-05-20-repeat-paragraph-button-design.md`

---

## File Structure

- **Modify** `apps/rishi-electron/src/renderer/src/machines/playerMachine.ts` — add `REPEAT` event to `PlayerMachineEvent` union and a transition on the `playing` state.
- **Modify** `apps/rishi-electron/src/renderer/src/machines/playerMachine.test.ts` — append a new `describe('REPEAT', ...)` block.
- **Modify** `apps/rishi-electron/src/renderer/src/components/tts/TTSControls.tsx` — add `RotateCcw` import, `handleRepeat` callback, `AnimatePresence`/`motion.button` block between Play/Pause and Next, and dynamic pill width.
- **Create** `apps/rishi-electron/src/renderer/src/components/tts/TTSControls.test.tsx` — new test file with four cases.

No other files touched. No changes to `playerStore`, `usePlayerMachine`, `chatStore`, `EpubView`, or `PdfView`.

---

## Task 1: Add `REPEAT` event to `playerMachine` (TDD)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/machines/playerMachine.ts`
- Modify: `apps/rishi-electron/src/renderer/src/machines/playerMachine.test.ts`

- [ ] **Step 1.1: Write the failing tests**

Append the following `describe` block to the end of `apps/rishi-electron/src/renderer/src/machines/playerMachine.test.ts` (inside the existing top-level `describe('playerMachine', ...)` — paste before its closing `})`):

```ts
describe('REPEAT', () => {
  it('transitions playing → loading and keeps paragraphIndex unchanged', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    // Advance to paragraph index 1 so we can prove REPEAT does NOT reset to 0.
    actor.send({ type: 'NEXT' })
    actor.send({ type: 'AUDIO_LOADED' })
    expect(actor.getSnapshot().value).toBe('playing')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1)

    actor.send({ type: 'REPEAT' })

    const snap = actor.getSnapshot()
    expect(snap.value).toBe('loading')
    expect(snap.context.paragraphIndex).toBe(1)
  })

  it('clears partialFirstText and partialFirstKey from context', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    // Enter playing via PLAY_FROM with a partial-first override.
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 1,
      partialFirstText: 'half of the paragraph',
      partialFirstKey: 'p-1:0,1:21'
    })
    actor.send({ type: 'AUDIO_LOADED' })
    expect(actor.getSnapshot().context.partialFirstText).toBe('half of the paragraph')
    expect(actor.getSnapshot().context.partialFirstKey).toBe('p-1:0,1:21')

    actor.send({ type: 'REPEAT' })

    const snap = actor.getSnapshot()
    expect(snap.value).toBe('loading')
    expect(snap.context.partialFirstText).toBeNull()
    expect(snap.context.partialFirstKey).toBeNull()
  })

  it('is a no-op from every non-playing state', () => {
    // Helper: drive the machine into each non-playing state, dispatch REPEAT,
    // verify state value and paragraphIndex are unchanged.
    const cases: Array<{ name: string; enter: (a: typeof actor) => void }> = [
      { name: 'idle', enter: () => {} },
      {
        name: 'stopped',
        enter: (a) => {
          a.send({ type: 'INITIALIZE', bookId: 'book1' })
        }
      },
      {
        name: 'loading',
        enter: (a) => {
          a.send({ type: 'INITIALIZE', bookId: 'book1' })
          a.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
          a.send({ type: 'PLAY' })
        }
      },
      {
        name: 'paused.clean',
        enter: (a) => {
          a.send({ type: 'INITIALIZE', bookId: 'book1' })
          a.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
          a.send({ type: 'PLAY' })
          a.send({ type: 'AUDIO_LOADED' })
          a.send({ type: 'PAUSE' })
        }
      },
      {
        name: 'paused.stale',
        enter: (a) => {
          a.send({ type: 'INITIALIZE', bookId: 'book1' })
          a.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
          a.send({ type: 'PLAY' })
          a.send({ type: 'AUDIO_LOADED' })
          a.send({ type: 'PAUSE' })
          a.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(2) })
        }
      },
      {
        name: 'waitingForParagraphs',
        enter: (a) => {
          a.send({ type: 'INITIALIZE', bookId: 'book1' })
          a.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(1) })
          a.send({ type: 'PLAY' })
          a.send({ type: 'AUDIO_LOADED' })
          a.send({ type: 'NEXT' })
        }
      },
      {
        name: 'pageNavigating',
        enter: (a) => {
          a.send({ type: 'INITIALIZE', bookId: 'book1' })
          a.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
          a.send({ type: 'PLAY' })
          a.send({ type: 'AUDIO_LOADED' })
          a.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
        }
      },
      {
        name: 'republishingParagraphs',
        enter: (a) => {
          a.send({ type: 'INITIALIZE', bookId: 'book1' })
          a.send({ type: 'PLAY' })
        }
      },
      {
        name: 'error',
        enter: (a) => {
          a.send({ type: 'INITIALIZE', bookId: 'book1' })
          a.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
          a.send({ type: 'PLAY' })
          a.send({ type: 'AUDIO_LOADED' })
          // From playing, AUDIO_ERROR transitions directly to error (no retry loop).
          a.send({ type: 'AUDIO_ERROR', error: 'boom' })
        }
      }
    ]

    for (const c of cases) {
      const fresh = createActor(playerMachine)
      fresh.start()
      c.enter(fresh)
      const beforeValue = fresh.getSnapshot().value
      const beforeIndex = fresh.getSnapshot().context.paragraphIndex
      fresh.send({ type: 'REPEAT' })
      const afterValue = fresh.getSnapshot().value
      const afterIndex = fresh.getSnapshot().context.paragraphIndex
      expect(afterValue, `state should not change from ${c.name}`).toEqual(beforeValue)
      expect(afterIndex, `paragraphIndex should not change from ${c.name}`).toBe(beforeIndex)
    }
  })

  it('after REPEAT, AUDIO_ENDED advances paragraphIndex by 1 as normal', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'NEXT' })
    actor.send({ type: 'AUDIO_LOADED' })
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1)

    actor.send({ type: 'REPEAT' })
    expect(actor.getSnapshot().value).toBe('loading')

    actor.send({ type: 'AUDIO_LOADED' })
    expect(actor.getSnapshot().value).toBe('playing')

    actor.send({ type: 'AUDIO_ENDED' })
    // After the repeated paragraph finishes, forward progress resumes naturally.
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(2)
  })
})
```

- [ ] **Step 1.2: Run the tests to verify they fail**

Run from `apps/rishi-electron`:

```bash
pnpm test -- src/renderer/src/machines/playerMachine.test.ts
```

Expected: TypeScript error or runtime error in all four new tests because `REPEAT` is not a valid event type yet. Other existing tests in this file continue to pass.

- [ ] **Step 1.3: Add `REPEAT` to the event union**

In `apps/rishi-electron/src/renderer/src/machines/playerMachine.ts`, find the `PlayerMachineEvent` union (line 36) and append a new variant before the closing of the union (after the `PLAY_FROM` line):

```ts
  | { type: 'PLAY_FROM'; paragraphIndex: number; partialFirstText: string; partialFirstKey: string }
  | { type: 'REPEAT' }
```

- [ ] **Step 1.4: Add the `REPEAT` transition to the `playing` state**

In the same file, locate the `playing` state's `on` block (line 389). Find the `PLAY_FROM` handler inside `playing` (around line 466) and insert a `REPEAT` handler immediately after it (before the closing `}` of `playing.on`):

```ts
        PLAY_FROM: {
          target: 'loading',
          actions: ['setPartialFirst', 'setParagraphIndexFromEvent']
        },
        REPEAT: {
          target: 'loading',
          reenter: true,
          actions: 'clearPartialFirst'
        },
        CHAT_STARTED: {
```

The existing `clearPartialFirst` action (defined at line 173) already clears `partialFirstText`, `partialFirstKey`, and `partialFirstParagraphIndex`. Reusing it instead of inlining an assign keeps the code DRY.

- [ ] **Step 1.5: Run the tests to verify they pass**

```bash
pnpm test -- src/renderer/src/machines/playerMachine.test.ts
```

Expected: all tests pass — the four new tests under `describe('REPEAT', ...)` plus every existing test in the file.

- [ ] **Step 1.6: Run typecheck**

```bash
pnpm typecheck
```

Expected: no errors.

- [ ] **Step 1.7: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/machines/playerMachine.ts \
        apps/rishi-electron/src/renderer/src/machines/playerMachine.test.ts
git commit -m "$(cat <<'EOF'
feat(player): add REPEAT event to restart current paragraph

Re-enters loading at the same paragraphIndex with partialFirst cleared.
Audio is fetched again (cache hit) and playback continues forward
naturally on AUDIO_ENDED. Ignored from any non-playing state.
EOF
)"
```

---

## Task 2: Add Repeat button to `TTSControls` (TDD)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/tts/TTSControls.tsx`
- Create: `apps/rishi-electron/src/renderer/src/components/tts/TTSControls.test.tsx`

- [ ] **Step 2.1: Write the failing tests**

Create `apps/rishi-electron/src/renderer/src/components/tts/TTSControls.test.tsx` with the full content below.

The test file mocks `usePlayerStore` and `usePlayerMachine` so we can drive `playingState` directly without spinning up the whole XState actor + audio element. It also mocks `useRequireAuth` to a passthrough and `ContextualHint` to a noop wrapper.

```tsx
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, act, fireEvent, waitFor } from '@testing-library/react'
import type { ReactNode } from 'react'
import type { PlayerStoreState } from '@/stores/playerStore'

// --- Mocks ---

const sendMock = vi.fn()

// Mutable mock state: tests update this between renders to simulate
// transitions between machine states.
let mockPlayingState: PlayerStoreState = 'idle'
let mockErrors: string[] = []

vi.mock('@/stores/playerStore', () => {
  // The component calls usePlayerStore(selector). We return a function that
  // applies the selector to a synthetic state object. We also expose a
  // setState shim so the component compiles if it ever calls it (it doesn't
  // in this file, but the type matches).
  const usePlayerStore = ((selector: (s: { playingState: PlayerStoreState; errors: string[] }) => unknown) =>
    selector({ playingState: mockPlayingState, errors: mockErrors })) as unknown as typeof import('@/stores/playerStore').usePlayerStore
  return { usePlayerStore }
})

vi.mock('@/hooks/usePlayerMachine', () => ({
  usePlayerMachine: () => ({ send: sendMock })
}))

vi.mock('@/hooks/useRequireAuth', () => ({
  useRequireAuth: () => ({
    requireAuth: (_kind: string, fn: () => void) => fn(),
    AuthDialog: null
  })
}))

vi.mock('@/components/tutorial/ContextualHint', () => ({
  ContextualHint: ({ children }: { children: ReactNode }) => <>{children}</>
}))

// Import the component AFTER mocks are declared so the mocked modules are picked up.
import TTSControls from './TTSControls'

function setPlayingState(state: PlayerStoreState): void {
  mockPlayingState = state
}

function expandPill(): void {
  // The collapsed pill is a div with role="button" and aria-label="Expand TTS controls".
  const orb = screen.getByRole('button', { name: /expand tts controls/i })
  fireEvent.click(orb)
}

describe('TTSControls — Repeat button', () => {
  beforeEach(() => {
    sendMock.mockReset()
    mockPlayingState = 'idle'
    mockErrors = []
  })

  it('renders the Repeat button when playingState is "playing"', () => {
    setPlayingState('playing')
    render(<TTSControls bookId="book-1" />)
    act(() => {
      expandPill()
    })
    expect(screen.getByLabelText('Repeat current paragraph')).toBeInTheDocument()
  })

  it.each<PlayerStoreState>([
    'idle',
    'stopped',
    'loading',
    'paused.clean',
    'paused.stale',
    'waitingForParagraphs',
    'pageNavigating',
    'republishingParagraphs',
    'error'
  ])('does not render the Repeat button when playingState is "%s"', async (state) => {
    setPlayingState(state)
    render(<TTSControls bookId="book-1" />)
    act(() => {
      expandPill()
    })
    // AnimatePresence exit may render the node briefly; waitFor lets exit complete.
    await waitFor(() => {
      expect(screen.queryByLabelText('Repeat current paragraph')).not.toBeInTheDocument()
    })
  })

  it('clicking Repeat dispatches { type: "REPEAT" } exactly once', () => {
    setPlayingState('playing')
    render(<TTSControls bookId="book-1" />)
    act(() => {
      expandPill()
    })
    const repeat = screen.getByLabelText('Repeat current paragraph')
    fireEvent.click(repeat)
    expect(sendMock).toHaveBeenCalledTimes(1)
    expect(sendMock).toHaveBeenCalledWith({ type: 'REPEAT' })
  })

  it('Repeat sits between Play/Pause and Next in DOM order', () => {
    setPlayingState('playing')
    render(<TTSControls bookId="book-1" />)
    act(() => {
      expandPill()
    })
    const buttons = screen
      .getAllByRole('button')
      .map((b) => b.getAttribute('aria-label'))
      .filter((label): label is string => label !== null)
    const playIdx = buttons.indexOf('Pause') // playing → button label is "Pause"
    const repeatIdx = buttons.indexOf('Repeat current paragraph')
    const nextIdx = buttons.indexOf('Next')
    expect(playIdx).toBeGreaterThanOrEqual(0)
    expect(repeatIdx).toBeGreaterThanOrEqual(0)
    expect(nextIdx).toBeGreaterThanOrEqual(0)
    expect(playIdx).toBeLessThan(repeatIdx)
    expect(repeatIdx).toBeLessThan(nextIdx)
  })
})
```

- [ ] **Step 2.2: Run the tests to verify they fail**

```bash
pnpm test -- src/renderer/src/components/tts/TTSControls.test.tsx
```

Expected: all four tests fail. The first three because `screen.getByLabelText('Repeat current paragraph')` returns nothing (the button does not exist yet). The fourth because the same label is missing.

- [ ] **Step 2.3: Add the `RotateCcw` import and `framer-motion` imports**

In `apps/rishi-electron/src/renderer/src/components/tts/TTSControls.tsx`, replace the existing `lucide-react` import on line 1 and add a `framer-motion` import on a new line:

```tsx
import {
  Play,
  Pause,
  Square,
  SkipBack,
  SkipForward,
  AlertTriangle,
  Loader2,
  RotateCcw
} from 'lucide-react'
import { AnimatePresence, motion } from 'framer-motion'
```

- [ ] **Step 2.4: Add the `handleRepeat` callback**

In the same file, find `handleNext` (around line 142) and add `handleRepeat` immediately after it:

```tsx
  const handleNext = () => {
    send({ type: 'NEXT' })
  }

  const handleRepeat = () => {
    send({ type: 'REPEAT' })
  }
```

- [ ] **Step 2.5: Make the expanded pill width depend on `playingState`**

Locate the pill `<div>` style block (around line 244) and change the `width` line:

Find:
```tsx
          width: expanded ? 240 : 52,
```

Replace with:
```tsx
          width: expanded ? (isPlaying ? 280 : 240) : 52,
```

`isPlaying` is already computed at line 163 (`const isPlaying = playingState === 'playing'`), so no additional state is needed. The existing `transitionProperty` already animates `width`.

- [ ] **Step 2.6: Insert the Repeat button between Play/Pause and Next**

Find the Play/Pause `<button>` closing tag and the Next `<button>` opening comment (around line 301–303):

```tsx
              {getPlayIcon()}
            </button>

            {/* Next */}
            <button
              onClick={handleNext}
```

Replace with:

```tsx
              {getPlayIcon()}
            </button>

            {/* Repeat current paragraph — mounted only while playing */}
            <AnimatePresence initial={false}>
              {isPlaying && (
                <motion.button
                  key="repeat"
                  initial={{ opacity: 0, width: 0, marginInlineStart: 0, marginInlineEnd: 0 }}
                  animate={{ opacity: 1, width: 42, marginInlineStart: 0, marginInlineEnd: 0 }}
                  exit={{ opacity: 0, width: 0, marginInlineStart: 0, marginInlineEnd: 0 }}
                  transition={{ duration: 0.18, ease: 'easeOut' }}
                  onClick={handleRepeat}
                  disabled={disabled}
                  aria-label="Repeat current paragraph"
                  className="flex items-center justify-center rounded-full cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed hover:scale-105 active:scale-95 overflow-hidden"
                  style={{ ...glassButton, height: 42 }}
                >
                  <RotateCcw size={18} className="text-black/60" />
                </motion.button>
              )}
            </AnimatePresence>

            {/* Next */}
            <button
              onClick={handleNext}
```

Two notes for the engineer:
- We animate `width` to a literal `42` (matching Prev/Next button width) rather than `'auto'` so the exit interpolation has a numeric target — framer-motion can't smoothly animate `auto → 0`.
- We removed the `transition-transform duration-150` Tailwind class on the motion.button because framer-motion drives transitions for the motion component. The other buttons keep their Tailwind transition classes.

- [ ] **Step 2.7: Run the component tests to verify they pass**

```bash
pnpm test -- src/renderer/src/components/tts/TTSControls.test.tsx
```

Expected: all four tests pass.

- [ ] **Step 2.8: Run the full test suite to confirm nothing regressed**

```bash
pnpm test
```

Expected: green across `playerMachine.test.ts`, `TTSControls.test.tsx`, and every existing test.

- [ ] **Step 2.9: Run typecheck and lint**

```bash
pnpm typecheck && pnpm lint
```

Expected: no errors. If ESLint flags the new file, fix the specific complaints — do not blanket-disable rules.

- [ ] **Step 2.10: Manual smoke test in dev**

From `apps/rishi-electron`:

```bash
pnpm dev
```

Open any book, start playback, and verify:

1. The TTS pill expands and shows five buttons: `Prev | Play/Pause | Repeat | Next | Stop`.
2. The Repeat icon (counter-clockwise arrow) appears between Play/Pause and Next when audio is playing.
3. Click Repeat — the current paragraph restarts from the beginning, then playback continues forward to the next paragraph (no stop or pause).
4. Pause playback. The Repeat button animates out; the pill narrows. Press Play again — Repeat animates back in.
5. Stop playback. The pill collapses to an orb. Reopen — Repeat is absent (state is `stopped`).
6. Repeat works in a PDF reader too (open a PDF book, play, click Repeat).

If any of those fail, do not commit — debug the failing case first.

- [ ] **Step 2.11: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/tts/TTSControls.tsx \
        apps/rishi-electron/src/renderer/src/components/tts/TTSControls.test.tsx
git commit -m "$(cat <<'EOF'
feat(tts): add Repeat button to playback pill

A counter-clockwise Repeat button mounts between Play/Pause and Next
while the player is in the playing state. Clicking it sends a REPEAT
event that restarts the current paragraph and continues forward.
Mount/unmount uses framer-motion AnimatePresence and the pill width
animates between 240 and 280px.
EOF
)"
```

---

## Verification Checklist

When both tasks are complete:

- [ ] `pnpm test` passes from `apps/rishi-electron`.
- [ ] `pnpm typecheck` passes.
- [ ] `pnpm lint` passes.
- [ ] Manual smoke test (Step 2.10) passes in EPUB and PDF readers.
- [ ] Two commits exist on the branch with the messages above.
- [ ] No changes outside the four files listed in "File Structure".

# Repeat Paragraph Button — Design

**Date:** 2026-05-20
**App:** `apps/rishi-electron`
**Status:** Approved by user; implementation plan pending.

## Summary

Add a **Repeat** button to the TTS playback pill that restarts the currently-playing paragraph from the beginning and then continues forward to the next paragraph as normal — without stopping. The button only exists while the player is actively playing; it animates in on enter and out on exit.

## Motivation

While listening to TTS, a user who misses or wants to re-hear the paragraph they're currently on has no single-tap way to replay just that paragraph. `Prev` jumps to the *previous* paragraph; there is no "restart current paragraph" affordance. This spec adds one.

## Goals

- One-tap restart of the current paragraph mid-playback.
- After the restart completes, playback continues forward through subsequent paragraphs (no implicit stop or pause).
- Works for both EPUB and PDF readers without format-specific branching.
- No new buttons or visual noise when the action would not apply.

## Non-Goals

- No keyboard shortcut.
- No "repeat N times" or looping behavior.
- No semantic-paragraph regrouping for PDF — PDF will repeat whatever fragment is currently "active" per the existing paragraph-tracking model.
- No changes to other transport controls (Prev, Play/Pause, Next, Stop).

## Architecture

A new `REPEAT` event is added to the `playerMachine` XState v5 state chart. The event is handled **only** from the `playing` state. On receipt:

1. Machine transitions `playing → loading` with `reenter: true`.
2. `context.paragraphIndex` is unchanged.
3. `context.partialFirstText` and `context.partialFirstKey` are cleared (Repeat always starts from the top of a paragraph; partial-first overrides exist only for "Read Aloud From Here" selections that begin mid-paragraph).
4. The existing `loading` entry actions re-run, fetching TTS audio. The TTS service caches by paragraph key (CFI for EPUB, synthetic `pdf-{page}-{idx}` for PDF), so this is a cache hit.
5. `loading → playing` via the existing transition.
6. On `AUDIO_ENDED`, the existing `NEXT_AUTO`-style flow advances to the next paragraph — no special case in the machine.

A `Repeat` button is added to `TTSControls.tsx` between `Play/Pause` and `Next`. The button is **conditionally mounted** (not merely hidden) using `framer-motion`'s `AnimatePresence`. It is present only while `state.matches('playing')` and animates out otherwise. The pill width adjusts smoothly via flex reflow as the button's `width` and `marginInline` animate between `0` and `auto`/`4`.

## State Machine Change

**Event type addition** (in `playerMachine.ts`):

```ts
| { type: 'REPEAT' }
```

**Transition** (added to the `playing` state's `on` map):

```ts
REPEAT: {
  target: 'loading',
  reenter: true,
  actions: assign(() => ({
    partialFirstText: undefined,
    partialFirstKey: undefined,
  })),
}
```

**Guard:** none on the transition. `REPEAT` outside `playing` has no handler defined and is therefore ignored — matches the UX rule that the button is unmounted outside `playing`.

## UI

**File:** `apps/rishi-electron/src/renderer/src/components/tts/TTSControls.tsx`

**Icon:** `RotateCcw` from `lucide-react`.

**Placement:** Source-order between the Play/Pause `<button>` and the Next `<button>`. Final pill order: `Prev | Play/Pause | Repeat | Next | Stop`.

**Mount condition:** `state.matches('playing')`. Computed locally as `isPlaying`.

**Animation:** `framer-motion` (already a dependency, `^12.23.24`).

```tsx
<AnimatePresence initial={false}>
  {isPlaying && (
    <motion.button
      key="repeat"
      initial={{ opacity: 0, width: 0, marginInline: 0 }}
      animate={{ opacity: 1, width: 'auto', marginInline: 4 }}
      exit={{ opacity: 0, width: 0, marginInline: 0 }}
      transition={{ duration: 0.18, ease: 'easeOut' }}
      onClick={() => send({ type: 'REPEAT' })}
      aria-label="Repeat current paragraph"
      className={/* same classes as Prev/Next siblings */}
    >
      <RotateCcw className="h-4 w-4" />
    </motion.button>
  )}
</AnimatePresence>
```

**No keyboard shortcut.** Arrow-key shortcuts remain bound to Prev/Next.

**Accessibility:** `aria-label="Repeat current paragraph"`. Same focus ring/hover styles as sibling transport buttons. When unmounted, no tabstop exists.

## Data Flow

```
user click
    ↓
TTSControls handler  →  send({ type: 'REPEAT' })
    ↓
playerMachine.playing  ── REPEAT ──▶  loading (reenter, paragraphIndex unchanged, partialFirst cleared)
    ↓
loading entry actions  ─→  ttsService.requestAudio(paragraph)   [cache hit]
    ↓
audio element src updated  ─→  AUDIO_READY
    ↓
loading  ─→  playing
    ↓
audio plays to completion  ─→  AUDIO_ENDED  ─→  paragraphIndex + 1  ─→  next paragraph loads
```

## Error Handling

- **Repeat during loading-to-next-paragraph transition:** Button is unmounted because state is `loading`, not `playing`. The user cannot trigger this race.
- **Repeat while paused:** Button is unmounted. To repeat, the user resumes first.
- **TTS service failure on cache miss:** Existing `error` state in `playerMachine` handles this; no new code path.
- **Rapid double-click:** First click transitions to `loading`. Second click arrives in `loading`, where no `REPEAT` handler exists — ignored.

## Testing

All tests are written **failing first** per the repo's TDD convention before any implementation lands.

**`playerMachine.test.ts`** — Vitest + `createActor`, no mocks (existing convention).

1. `REPEAT from playing → state value is 'loading'; context.paragraphIndex unchanged`.
2. `REPEAT clears partialFirstText and partialFirstKey from context`.
3. `REPEAT is a no-op` — parameterized over every non-playing state (`idle`, `stopped`, `paused.clean`, `paused.stale`, `loading`, `waitingForParagraphs`, `pageNavigating`, `republishingParagraphs`, `error`). State value and context unchanged after dispatch.
4. `After REPEAT, audio-end advances paragraphIndex by 1` — chain: `playing → REPEAT → loading → AUDIO_READY → playing → AUDIO_ENDED → paragraphIndex = n+1`.

**`TTSControls.test.tsx`** — new file; React Testing Library + `vi.mock` on `usePlayerMachine`, following `chatStore.test.ts`'s mock pattern.

5. Repeat button renders when machine state matches `playing`.
6. Repeat button does **not** render in every non-playing state — parameterized over `idle`, `stopped`, `paused.clean`, `paused.stale`, `loading`, `waitingForParagraphs`, `pageNavigating`, `republishingParagraphs`, `error`. Use `waitFor` to allow `AnimatePresence` exit to settle.
7. Clicking Repeat calls mocked `send` once with `{ type: 'REPEAT' }`.
8. DOM order assertion: Repeat sits between Play/Pause and Next in the pill (`screen.getAllByRole('button')` index check via aria-label).

**Out of test scope** (deliberately):
- Animation curves and timing — visual, brittle in unit tests.
- TTS cache behavior — covered by existing TTS service tests.
- `AnimatePresence` internals — framework-tested upstream.

## Files Changed

- `apps/rishi-electron/src/renderer/src/machines/playerMachine.ts` — add `REPEAT` event type and transition.
- `apps/rishi-electron/src/renderer/src/machines/playerMachine.test.ts` — add tests 1–4.
- `apps/rishi-electron/src/renderer/src/components/tts/TTSControls.tsx` — add Repeat button with `AnimatePresence` wrapper.
- `apps/rishi-electron/src/renderer/src/components/tts/TTSControls.test.tsx` — new file with tests 5–8.

No changes to `playerStore`, `usePlayerMachine`, `chatStore`, or any reader-view component (`EpubView`, `PdfView`).

## Branch Context

This work lands on `feat/migrate-to-ai-sdk`, which has uncommitted modifications to `playerMachine.ts` and `chatStore.ts` for the OpenAI → Vercel AI SDK migration. Reviewed during research: those changes touch the voice-chat service layer and chat event wiring, not paragraph/playback state. No overlap with the surface area of this spec.

## Open Items for the Implementation Plan

- Confirm `usePlayerMachine`'s `send` function accepts the new `REPEAT` event type without TypeScript widening — the `send` wrapper in `usePlayerMachine.ts` is typed against the machine's event union, so adding `REPEAT` to the union should propagate automatically.
- Verify the exact Tailwind class string used by sibling transport buttons in `TTSControls.tsx` so the Repeat button's `className` matches identically.

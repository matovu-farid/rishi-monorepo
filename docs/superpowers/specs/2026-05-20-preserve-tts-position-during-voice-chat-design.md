# Preserve TTS Position During Voice Chat

**Status:** Draft
**Date:** 2026-05-20
**Scope:** `apps/rishi-electron`

## Problem

When the user is listening to a book via TTS and opens the voice chat to ask a
question, the reader's playback position is lost. Closing the chat and pressing
Play again restarts TTS at the first paragraph of the current page instead of
resuming from where it was interrupted.

Root cause: in `apps/rishi-electron/src/renderer/src/machines/playerMachine.ts`,
the global `CHAT_STARTED` transition (line 194-197) targets `.stopped` and runs
the `resetIndex` action, which assigns `paragraphIndex: 0`. The voice chat is
dispatched from `chatStore.setIsChatting(true)` (line 54-55 of `chatStore.ts`).

## Desired behavior

- Opening voice chat while TTS is **playing** (or loading audio) pauses TTS at
  the current paragraph. No audio overlap with the agent voice.
- Closing voice chat **auto-resumes** TTS from that same paragraph.
- Opening voice chat while TTS is **paused, stopped, or idle** does not start
  TTS when the chat closes. The user was not listening; the chat doesn't change
  that.
- Manually pausing TTS *during* the chat overrides the auto-resume. The user's
  most recent intent wins.

## Design

### 1. State machine changes (`playerMachine.ts`)

**Context** — add one field to `PlayerMachineContext`:

```ts
wantsAutoResumeAfterChat: boolean
```

Default `false` in `initialContext`. Reset by `resetAll`.

**Actions** — add two:

```ts
setWantsAutoResumeAfterChat: assign({ wantsAutoResumeAfterChat: true })
clearWantsAutoResumeAfterChat: assign({ wantsAutoResumeAfterChat: false })
```

**Events** — add one:

```ts
| { type: 'CHAT_ENDED' }
```

**Transition rewrite.** Remove the global `CHAT_STARTED` handler. Add
per-state handlers (and a global `CHAT_ENDED` handler):

| From state | On `CHAT_STARTED` → Target | Actions |
|---|---|---|
| `playing` | `paused.clean` | `setWantsAutoResumeAfterChat`, `clearPartialFirst` |
| `loading` | `paused.clean` | `setWantsAutoResumeAfterChat`, `clearPartialFirst` |
| `waitingForParagraphs` | `paused.clean` | `setWantsAutoResumeAfterChat`, `clearPartialFirst` |
| `paused.*` | (internal, no target) | `clearPartialFirst` |
| `stopped` / `idle` / `error` | (internal, no target) | `clearWantsAutoResumeAfterChat`, `clearPartialFirst` |
| `pageNavigating` | (internal, no target) | `clearWantsAutoResumeAfterChat`, `clearPartialFirst` |

Critically, `paragraphIndex` is **never** reset by `CHAT_STARTED`. The
`resetIndex` action remains in the file (still used by `INITIALIZE`, `STOP`,
etc.) but is dropped from the chat transitions.

| Global `CHAT_ENDED` | Target | Actions |
|---|---|---|
| from `paused.clean` w/ flag=true | `loading` | `clearWantsAutoResumeAfterChat` |
| from any other state | (internal, no target) | `clearWantsAutoResumeAfterChat` |

The auto-resume re-enters `loading` from the same `paragraphIndex` so the audio
engine picks up the current paragraph fresh (same path NEXT/PREV uses).

### 2. `chatStore.ts` wiring

`setIsChatting` fires `CHAT_ENDED` on the falsey transition, mirroring the
existing `CHAT_STARTED` dispatch on the truthy transition:

```ts
setIsChatting: (value) => {
  const newValue = typeof value === 'function' ? value(get().isChatting) : value
  const send = usePlayerStore.getState().send
  if (newValue) {
    if (send) send({ type: 'CHAT_STARTED' })
  } else {
    if (send) send({ type: 'CHAT_ENDED' })
    voice.deactivate()
  }
  set({ isChatting: newValue })
}
```

`stopConversation` is a second exit path (used on errors / explicit teardown)
and must dispatch `CHAT_ENDED` for parity:

```ts
stopConversation: () => {
  const send = usePlayerStore.getState().send
  if (send) send({ type: 'CHAT_ENDED' })
  set({ isChatting: false, chatStatus: 'idle' })
  voice.deactivate()
}
```

No new player-state knowledge leaks into `chatStore` — it stays a dumb
dispatcher.

### 3. Edge cases

- **User pauses TTS manually, then opens chat.** State is `paused.clean`,
  `wantsAutoResumeAfterChat` is `false` (chat fires `clearPartialFirst` only).
  Closing chat → `CHAT_ENDED` is a no-op. User stays paused. ✅
- **Chat opened with TTS idle / stopped.** Flag stays `false`. Chat ends →
  nothing happens. ✅
- **Page navigation while chat is open.** If `PAGE_NAVIGATING` fires while in
  `paused.clean`, the existing `paused → pageNavigating` transition runs and
  clears `wantsAutoResume` (a separate flag). `wantsAutoResumeAfterChat` is not
  touched by `pageNavigating`'s entry actions, but `PARAGRAPHS_UPDATED` from
  `pageNavigating` lands in `stopped` (because `wantsAutoResume` is false), and
  `CHAT_ENDED` from `stopped` is a no-op. **Accepted behavior:** mid-chat page
  navigation drops the auto-resume — safer than auto-playing a new page the
  user might want to read visually.
- **Voice chat ended by the agent (`voice.onEndedByAgent`).** This path calls
  `set({ isChatting: false }); voice.deactivate()` directly *without* going
  through `setIsChatting`. Update this handler to also fire `CHAT_ENDED` so the
  auto-resume works on agent-initiated termination. (See `chatStore.ts:40-43`.)
- **Voice chat error / timeout.** Surfaces via `setIsChatting(false)` or
  `stopConversation`. Both now fire `CHAT_ENDED`. ✅
- **Rapid open/close of chat.** `CHAT_STARTED` → `CHAT_ENDED` with no gap. From
  `playing`: lands in `paused.clean` then bounces to `loading`. End state
  equivalent to no chat occurring. ✅
- **`PLAY_FROM` (text-selection partial-first override) active when chat
  opens.** `clearPartialFirst` still runs (preserves existing test at
  `playerMachine.test.ts:889`). The override is discarded, but
  `paragraphIndex` survives, so resume plays the full paragraph from its
  natural start — better than the current behavior of jumping to paragraph 0.

### 4. Files touched

| File | Change |
|---|---|
| `apps/rishi-electron/src/renderer/src/machines/playerMachine.ts` | Add context field, two actions, `CHAT_ENDED` event. Rewrite `CHAT_STARTED` transitions per-state. |
| `apps/rishi-electron/src/renderer/src/stores/chatStore.ts` | Dispatch `CHAT_ENDED` from `setIsChatting(false)`, `stopConversation`, and `onEndedByAgent` handler. |
| `apps/rishi-electron/src/renderer/src/machines/playerMachine.test.ts` | Replace the single `CHAT_STARTED` test with per-source-state tests; add `CHAT_ENDED` tests. |
| `apps/rishi-electron/src/renderer/src/stores/chatStore.test.ts` | Add `setIsChatting(false)` and `stopConversation` dispatch tests. |

No new files. No changes outside `apps/rishi-electron/src/renderer`.

## Test plan (TDD — red before green)

`playerMachine.test.ts`:

1. Update existing test at line 502 (`should stop on CHAT_STARTED from any
   state`) — replace with the per-state tests below.
2. `CHAT_STARTED from playing transitions to paused.clean and preserves
   paragraphIndex > 0`.
3. `CHAT_STARTED from playing sets wantsAutoResumeAfterChat`.
4. `CHAT_STARTED from loading transitions to paused.clean and sets the flag`.
5. `CHAT_STARTED from waitingForParagraphs transitions to paused.clean and
   sets the flag`.
6. `CHAT_STARTED from stopped does not change state and does not set the flag`.
7. `CHAT_STARTED from paused.clean stays in paused.clean and does not set the
   flag` (user paused manually first).
8. `CHAT_STARTED from idle is a no-op for the flag`.
9. `CHAT_ENDED from paused.clean with flag=true transitions to loading at the
   same paragraphIndex`.
10. `CHAT_ENDED from paused.clean with flag=false stays paused`.
11. `CHAT_ENDED from stopped is a no-op`.
12. `CHAT_ENDED always clears wantsAutoResumeAfterChat`.
13. `CHAT_STARTED still clears partialFirst override` (preserve existing
    behavior from line 889).

`chatStore.test.ts`:

14. `setIsChatting(false) sends CHAT_ENDED to the player`.
15. `stopConversation sends CHAT_ENDED to the player`.
16. `voice.onEndedByAgent handler sends CHAT_ENDED to the player`.

## Out of scope

- Auto-resuming after a mid-chat page navigation. Decision documented above.
- Mobile app (`apps/mobile`) variant of the bug, if any. The mobile reader
  unmounts when navigating to the chat tab; that is a different code path and
  is not changed here.
- Visual indication on the play orb during chat (e.g. "paused, will resume").
  The existing TTS pill already shows paused state correctly once we land in
  `paused.clean`.

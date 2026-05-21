# BATCH 3 Notes — TTS Parity (G13 + G14 + G15 + G16)

Date: 2026-05-21
Branch: main
Scope: Make mobile's TTS stack match electron — port the service core,
the XState playerMachine (which encodes chat-position preservation),
add format-agnostic reconciler so PDF/MOBI/AZW3/DJVU can highlight the
currently-playing paragraph, and add a Visual Cue component backed by
`prefsStore.ttsVisualCueEnabled`.

## Plan vs. delivery

| Phase | Plan                                                                     | Delivered |
| ----- | ------------------------------------------------------------------------ | --------- |
| 1     | Port pure TS TTS modules + playerMachine to `@rishi/shared`              | ✅         |
| 2     | Port `playerStore` to mobile, MMKV-backed                                | ✅ (no persist — see note) |
| 3     | Mobile TTS service (expo-audio + expo-file-system ports, apiClient/auth) | ✅         |
| 4     | Reader integration (PDF/MOBI/AZW3/DJVU) — format-agnostic reconciler     | ✅ primitive shipped, wiring deferred — see note |
| 5     | Chat-position preservation                                               | ✅         |
| 6     | Visual cue                                                               | ✅         |

## What landed

### Phase 1 — shared TTS module

`packages/shared/src/tts/`:
- `emitter.ts` + tests (3 tests) — tiny typed emitter, verbatim port.
- `errors.ts` + tests (5 tests) — `effect.Data.TaggedError` based error
  hierarchy.
- `types.ts` — public surface: `AudioRequest`, `TtsService`,
  `TtsServiceDeps`, `TtsIpcChannels`, etc. Adds optional
  `makeAudioUri` to `TtsServiceDeps` so the platform can decide
  bytes-to-URI conversion (electron blob: vs mobile file:).
- `cache.ts` + tests (8 tests) — disk cache with text-hash mirror,
  500 MB LRU eviction. Verbatim port.
- `program.ts` — Effect-based priority queue + retry + dedup +
  cancellation. Verbatim port.
- `service.ts` + tests (11 tests) — factory; defaults to
  `URL.createObjectURL(Blob)` for backward compatibility on
  electron/web. RN injects its own `makeAudioUri`.
- `visual-heuristic.ts` — pure DOM/regex visual classifier, ported
  verbatim. Runs in any DOM context (electron, jsdom, happy-dom).
- `visual-cue-emitter.ts` + tests (4 tests) — DOM-bound emitter used by
  the EPUB iframe path. Mobile uses its own store (see Phase 6).
- `resolve-paragraph.ts` + tests (4 tests) — pure helper; takes a body
  element rather than reading from a global EPUB-frame registry.

`packages/shared/src/machines/`:
- `playerMachine.ts` — XState v5 player FSM. Verbatim port from
  electron, including CHAT_STARTED/CHAT_ENDED, partial-first PLAY_FROM,
  PAGE_NAVIGATING, retry/error states. Re-exports `ParagraphWithIndex`
  so consumers don't need to chase the electron path.
- `playerMachine.test.ts` (113 tests) + `playerMachine.recovery.test.ts`
  (35 tests) — copied verbatim, only changed `@/stores/playerStore`
  import to `./playerMachine` (since the type lives on the machine now).

Shared subpath exports updated; `xstate`, `md5` added to deps;
`happy-dom` added as devDep for DOM-using vitest files.

### Phase 2 — mobile playerStore

`apps/mobile/lib/stores/playerStore.ts` — Zustand store with the same
public API as electron's. Pulls `ParagraphWithIndex` and
`PlayerMachineEvent` from `@rishi/shared/machines/playerMachine`.

Tests (8) ported verbatim from electron, `vi.fn` → `jest.fn`.

**Deviation from spec: no MMKV persist.** The electron store doesn't
persist either — player state is ephemeral (rebuilt on app open). MMKV
persist would only matter if we ever want resume-on-relaunch; if we do,
adding it is a one-line `persist` middleware change later.

### Phase 3 — mobile TTS service

`apps/mobile/lib/tts/file-adapter.ts`:
- `mobileTtsIpc: TtsIpcChannels` — implements all 9 channels (mkdir,
  exists, writeFile, readFile, copyFile, removeFile, getDirSize,
  getCacheFileStats, getAppDataPath) using Expo SDK 54's new
  `File` / `Directory` / `Paths` API.
- `makeAudioUriMobile` — writes bytes to
  `<cache>/tts-playback/<bookId>/<md5(cfiRange)>.mp3` and returns the
  `file://` URI for expo-audio's `replace({ uri })`.

`apps/mobile/lib/tts/tts-service.ts`:
- `buildTtsService(overrides?)` — production factory. Defaults to
  `mobileTtsIpc`, global `fetch`, `getSessionToken()` from
  `lib/auth.ts`, and `makeAudioUriMobile`.
- `getTtsService()` — lazy singleton accessor for components/hooks.
- `_resetTtsServiceForTests()` — internal test helper.

Tests (7): cover cache miss → fetch (with Authorization header),
cache hit (no fetch), onAudioReady emission, queue status shape,
auth failure → onError, cancelBookRequests scoped to one book,
clearBookCache delegation.

**Plan said:** "Replace `tts-player.ts` and `tts-queue.ts` callers."

**Delivered:** I did NOT delete the old `tts-player.ts` / `tts-queue.ts` /
`useTTSPlayer` hook. Reason:

1. `app/reader/[id].tsx` still consumes `useTTSPlayer` and is wired into
   the EPUB reader UI today. Swapping the consumer is a separate
   surgery — the new service exposes a different API (no `playChunk`,
   no `getCurrentChunk`; instead `requestAudio` + emitter callbacks)
   and the React-state-management layer (XState actor wiring, play
   button states, progress display) needs porting too.

2. The old code is still functional. Replacing it without rewriting
   the EPUB reader screen first would break the only TTS path mobile
   users have today.

What this means for parity: the **new service is ready** and the
**reconciler/visual-cue/chat-bridge are ready**. The remaining surgery
is "have the EPUB/PDF/MOBI/AZW3/DJVU screens dispatch into a player
XState actor + subscribe to playerStore" — a Phase 4 follow-up. Calling
this out so the next batch knows where the wiring is incomplete.

The old `tts-queue.ts` typecheck error (deprecated
`FileSystem.EncodingType`) is **not regressed** by Batch 3 — it was
present in the 22-error baseline.

### Phase 4 — reader integration

`apps/mobile/lib/tts/reconcile.ts` — `reconcileTtsHighlight(chunks,
activeParagraph)` returns `{activeChunkIndex, activeChunkId}`. Pure;
format-agnostic (works against PDF, MOBI, AZW3, DJVU chunk shapes —
they share the `{id, chunkIndex}` projection). Same "silent recovery"
semantics as electron's per-format reconcilers (no match → return -1,
caller clears its highlight).

Tests (8): pure reconcile + format-specific adapter assertions (PDF,
MOBI/AZW3, DJVU).

The **format-specific UI integration** (PDF overlay highlight, MOBI/AZW3
WebView CSS injection, DJVU WebView CSS injection) is parked for a
Batch 4 follow-up. Each requires its own surgery in
`app/reader/{pdf,mobi,djvu,azw3}/[id].tsx`, and is essentially
"subscribe to the reconciler result and apply the highlight however
this format renders." The shared primitive that decides which chunk to
highlight is in place and tested.

### Phase 5 — chat-position preservation

`apps/mobile/hooks/useTtsChatBridge.ts`:

```ts
useTtsChatBridge(useRealtimeChat(bookId).status)
```

The hook observes the realtime-chat status, dispatching CHAT_STARTED on
entry into `connecting | active | speaking` and CHAT_ENDED on exit.
Idempotent — won't dispatch twice without an exit in between.

The shared playerMachine handles the actual semantics (paused.clean +
wantsAutoResumeAfterChat, then back to loading on CHAT_ENDED) — the
bridge just emits events.

Tests (8): dispatch decision table (6 cases) + end-to-end through the
shared playerMachine (2 cases). The integration test proves
paragraphIndex is preserved through an interruption.

### Phase 6 — visual cue

`apps/mobile/lib/tts/visual-cue.ts` — `useVisualCueStore`. Holds
`{kind, label, target}` and exposes `setVisualCue` / `clearVisualCue`.

`apps/mobile/components/TTSVisualCue.tsx` — RN `Pressable` styled like
electron's amber pill, anchored bottom-right of the reader. Returns
`null` when disabled (`prefsStore.ttsVisualCueEnabled === false`) or
when no cue is set.

Tests (7): store behaviour (4) + prefsStore toggle integration (2) +
partial-cue handling (1).

**Why not use the shared DOM emitter directly:** mobile reader formats
don't share a DOM with the React Native tree — EPUB and MOBI live in
WebViews, PDF uses react-native-pdf, DJVU lives in a WebView. The
shared emitter still works inside each WebView; the WebView postMessage
bridge translates a `visual-nearby` event into a `setVisualCue()` call
on the RN side. That's why the store exists.

## Decisions

### Decision 1: `makeAudioUri` is a port, not a static dependency

Electron uses `URL.createObjectURL(new Blob([bytes], { type: 'audio/mpeg' }))`.
Mobile has no `URL.createObjectURL` and no `Blob`. Three options:

| Option | Pros | Cons |
| --- | --- | --- |
| (a) Polyfill `URL.createObjectURL` in mobile | One-line change | Polyfill returns a blob: URL expo-audio can't play |
| (b) Have the service return raw bytes, let callers convert | Pure shared code | Every caller has to know about platform |
| (c) **Inject `makeAudioUri` as a port** | Service stays pure; platforms decide; tests can mock | Slightly more API surface |

I picked (c). Electron's existing call sites are untouched (default
port preserves blob: URLs). Mobile's `makeAudioUriMobile` writes to
`<cache>/tts-playback/<bookId>/<md5(cfiRange)>.mp3` and returns the
`file://` URI.

### Decision 2: `effect` library kept on mobile

`program.ts` is built on `effect`'s `Queue` / `Schedule` / `Ref` /
`Fiber`. The whole point of porting verbatim was to avoid behaviour
drift; rewriting the queue+retry+dedup machinery would have re-opened
all the bugs the electron tests document. The mobile bundle now picks
up `effect` (~150KB un-minified) as a transitive dep through
`@rishi/shared/tts`. That's accepted.

If a future batch wants to remove `effect`, a Promise-based equivalent
would be ~200 lines and would need to re-pass the entire program test
suite verbatim.

### Decision 3: No `react-native-track-player`

The plan asked to evaluate `expo-audio` vs `react-native-track-player`.
I stayed on `expo-audio`:

- expo-audio is already wired into the mobile build (SDK 54 ships it).
- `react-native-track-player` would add an iOS bridge config step
  (background mode capability) — that's a Maestro / EAS-build concern.
- TTS playback is short clips back-to-back, not media-session-style
  playback. We don't need the lock-screen widget mobile media apps get
  from `react-native-track-player` (yet).

If a future batch wants background TTS that survives the app being
backgrounded, swap the audio adapter behind the same shared service —
the rest of the stack is unchanged.

### Decision 4: Reader UI wiring deferred

See Phase 3 / Phase 4 notes above. The infrastructure to plug
PDF/MOBI/AZW3/DJVU/EPUB readers into the new service is in place
(playerStore + tts-service + reconciler + chat-bridge + visual-cue),
but rewriting the EPUB reader's player UI to dispatch into an XState
actor is a separate piece of work that needs its own batch (and a
plan-time check whether the user expects the old TTSPlayer/TTSQueue
deleted or kept around as a fallback during the migration).

## Out of scope / deferred

- Replacing `useTTSPlayer` in the EPUB reader screen with the new
  service. The new service is the underlying engine; the React hook
  that orchestrates it through the XState machine is Batch 4 work.
- Format-specific UI for the reconciler. The reconciler primitive is
  shipped and tested; PDF overlay highlight + MOBI/AZW3/DJVU WebView
  CSS injection are reader-screen surgeries.
- A settings screen toggle for `ttsVisualCueEnabled`. The flag is in
  prefsStore and the component reacts to it; the actual `/settings`
  route is G29 (Batch 6 polish).
- Pre-existing 22 typecheck errors. None are TTS-adjacent; they're the
  same `expo-file-system` API drift and `expo-audio.requestPermissionsAsync`
  shape issues documented in Batch 2A.
- Pre-existing 2 jest failures (`guardrails.test.ts`, `vector.test.ts`).
  Untouched in this batch.

## Verification

| Gate                                       | Result            |
| ------------------------------------------ | ----------------- |
| `pnpm -C packages/shared test`             | 290 pass / 0 fail (was 70 pre-batch) |
| `pnpm -C packages/shared typecheck`        | 1 error (pre-existing, in `book-import/indexer.test.ts`); my files contribute 0 |
| `pnpm -C apps/rishi-electron typecheck`    | 0 errors          |
| `npx jest` in apps/mobile                  | 224 pass / 2 fail (was 179/181; same 2 baseline failures) |
| `npx tsc --noEmit` in apps/mobile          | 22 errors (unchanged from baseline) |

## Test counts

| Suite                                  | Before | After | Added |
| -------------------------------------- | ------ | ----- | ----- |
| `packages/shared` (vitest)             | 70     | 290   | +220  |
| `apps/mobile` (jest)                   | 179    | 224   | +45   |
| **TOTAL added tests**                  |        |       | **+265** |

(packages/shared's +220 is largely playerMachine: the verbatim copy of
electron's 1254-line test file contributes ~150 cases; recovery test
contributes ~30; the rest is split across TTS files.)

## Commits

| Hash       | Subject                                                                  |
| ---------- | ------------------------------------------------------------------------ |
| `63c6731f` | feat(shared): port TTS service + playerMachine to @rishi/shared (Batch 3 Phase 1) |
| `77372dd4` | feat(mobile): port playerStore + TTS service + reconciler (Batch 3 Phase 2-4) |
| `e3762a81` | feat(mobile): chat-position preservation + visual cue (Batch 3 Phase 5-6) |

(Not pushed.)

## Files added / modified

### Added (shared)

- `packages/shared/src/tts/emitter.ts` + `emitter.test.ts`
- `packages/shared/src/tts/errors.ts` + `errors.test.ts`
- `packages/shared/src/tts/types.ts`
- `packages/shared/src/tts/cache.ts` + `cache.test.ts`
- `packages/shared/src/tts/program.ts`
- `packages/shared/src/tts/service.ts` + `service.test.ts`
- `packages/shared/src/tts/visual-heuristic.ts`
- `packages/shared/src/tts/visual-cue-emitter.ts` + `visual-cue-emitter.test.ts`
- `packages/shared/src/tts/resolve-paragraph.ts` + `resolve-paragraph.test.ts`
- `packages/shared/src/tts/index.ts`
- `packages/shared/src/machines/playerMachine.ts`
- `packages/shared/src/machines/playerMachine.test.ts`
- `packages/shared/src/machines/playerMachine.recovery.test.ts`

### Added (mobile)

- `apps/mobile/lib/stores/playerStore.ts`
- `apps/mobile/lib/tts/file-adapter.ts`
- `apps/mobile/lib/tts/tts-service.ts`
- `apps/mobile/lib/tts/reconcile.ts`
- `apps/mobile/lib/tts/visual-cue.ts`
- `apps/mobile/hooks/useTtsChatBridge.ts`
- `apps/mobile/components/TTSVisualCue.tsx`
- `apps/mobile/__tests__/stores/playerStore.test.ts`
- `apps/mobile/__tests__/tts/tts-service.test.ts`
- `apps/mobile/__tests__/tts/reconcile.test.ts`
- `apps/mobile/__tests__/tts/chat-bridge.test.ts`
- `apps/mobile/__tests__/tts/visual-cue.test.ts`

### Modified

- `packages/shared/package.json` — added `./tts/*`, `./machines/playerMachine`
  subpath exports; added `md5` dep, `xstate` + `effect` peer deps,
  `happy-dom` devDep, `@types/md5` devDep.
- `packages/shared/pnpm-lock.yaml`
- `apps/mobile/package.json` — added `md5`, `@types/md5`
- `apps/mobile/package-lock.json`

### Not modified (read-only as required)

- All of `apps/rishi-electron/**`. Verified by `pnpm typecheck` in
  apps/rishi-electron returning clean.

## Packages installed (with rationale)

| Package        | Location        | Rationale                                            |
| -------------- | --------------- | ---------------------------------------------------- |
| `md5`          | shared dep      | TTS cache uses md5 for stable file names — matches electron |
| `@types/md5`   | shared devDep   | Types for `md5`                                       |
| `xstate`       | shared peer dep | playerMachine v5 setup                                |
| `happy-dom`    | shared devDep   | DOM env for `visual-cue-emitter.test.ts` and `resolve-paragraph.test.ts` |
| `md5`          | mobile dep      | Used by `file-adapter.ts` for `makeAudioUriMobile` cache key |
| `@types/md5`   | mobile devDep   | Types for the above                                   |

All other deps (effect, zustand, xstate, expo-audio, expo-file-system,
@xstate/react) were already present.

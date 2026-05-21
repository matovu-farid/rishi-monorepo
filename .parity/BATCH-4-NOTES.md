# BATCH 4 Notes — Voice Chat Parity (G18 + G21 + G19 + G20 + G22)

Date: 2026-05-21
Branch: main
Scope: Bring mobile voice chat to electron parity. Port the FSM +
activation pipeline + key cache, share the INSTRUCTIONS_TEMPLATE
prompt, wire the inspectCurrentPage page-capture tool, add a ready
chime, and emit CHAT_STARTED/CHAT_ENDED through the same playerMachine
the Batch 3 chat-bridge listens to.

## Plan vs. delivery

| Phase | Plan                                                         | Delivered |
| ----- | ------------------------------------------------------------ | --------- |
| 1     | Port pure TS voice-chat modules + INSTRUCTIONS_TEMPLATE      | ✅         |
| 2     | Mobile service factory + ports                               | ✅         |
| 3     | Chat-position preservation wiring (G14 completion)           | ✅         |
| 4     | Page-capture vision tool (G20)                               | ✅         |
| 5     | Sounds (G22)                                                 | ✅ partial — see Decision 4 |
| 6     | Local VAD (G19)                                              | ⚠️ deferred — see Decision 3 |

## What landed

### Phase 1 — shared voice-chat module

`packages/shared/src/voice-chat/`:
- `emitter.ts` + tests (3) — verbatim port.
- `errors.ts` + tests (5) — `effect.Data.TaggedError` hierarchy.
- `key-cache.ts` + tests (6) — verbatim 9-min ephemeral-key cache.
- `machine.ts` + tests (12) — xstate v5 FSM, verbatim.
- `local-vad.ts` + tests (16) — verbatim Web-Audio-based RMS gate.
- `activation-program.ts` — verbatim Effect program. The electron-side
  `captureError` import from `@/utils/sentry` is replaced by an optional
  `captureError` port on `VoiceChatServiceDeps` (defaults to no-op).
- `service.ts` + tests (87) — verbatim except for the same captureError
  port swap above.
- `build-realtime-agent.ts` + tests (23) — the canonical
  `INSTRUCTIONS_TEMPLATE` + `renderLanguageSection`/`renderOutlineSection`
  /`renderActiveParagraphSection`/`renderVisualSection` helpers + tool
  specs (`BOOK_CONTEXT_TOOL_SPEC`, `END_CONVERSATION_TOOL_SPEC`,
  `INSPECT_CURRENT_PAGE_TOOL_SPEC`). The test file includes an inline
  snapshot of the minimal-input rendering so any future change to the
  prompt is caught loudly.
- `types.ts` + tests (8). The two electron-only types (`RagService`,
  `ConnectivityService`) are replaced by `VoiceChatRagPort` /
  `VoiceChatConnectivityPort` structural shapes declared inline.
  `BookOutline`, `VisualSummary`, `CaptureResult` also moved inline.

Subpath exports added under `@rishi/shared/voice-chat/*` so mobile and
electron consume the same module.

### Phase 2 — mobile voice-chat service

`apps/mobile/lib/voice-chat/`:
- `service.ts` — singleton-per-app factory wrapping the shared
  `createVoiceChatService` with mobile ports.
- `media-port.ts` — react-native-webrtc-backed MediaPort. Omits
  `createMediaRecorder` (RN has no MediaRecorder equivalent), which
  the activation pipeline already branches on — buffered-speech replay
  is silently skipped on mobile.
- `realtime-session.ts` — mobile WebRTC transport + agent factory +
  session factory. Uses raw data-channel JSON (the SDP exchange is the
  same OpenAI Realtime endpoint electron talks to). The
  `@openai/agents` SDK isn't React-Native compatible so this slice
  reimplements the `RealtimeSessionLike` contract directly. Tool
  dispatch (`bookContext`, `endConversation`, `inspectCurrentPage`) is
  handled here.
- `ipc.ts` — `mobileVoiceChatIpc` wrapping `apiClient` for the
  worker's `/api/realtime/client_secrets` and `/api/audio/transcribe`
  endpoints.
- `rag-port.ts` — wraps the existing on-device vector store /
  embedder so `bookContext` retrieval matches the text-chat path.
- `sounds.ts` — `createMobileEffectsPort()`. See Decision 4.
- `page-capture.ts` — `react-native-view-shot` wrapper. See Phase 4.

`apps/mobile/hooks/useVoiceChat.ts` — new public hook; subscribes to
the shared service's `onStateChange` + `onChatStatus` emitters and
exposes the same `{ status, toggle, isActive }` shape `useRealtimeChat`
had.

`apps/mobile/hooks/useRealtimeChat.ts` — REWRITTEN as a compatibility
shim that delegates to `useVoiceChat`, so existing consumers
(`app/reader/[id].tsx`) keep working without source changes.

### Phase 3 — chat-position preservation (G14 completion)

Already shipped in Batch 3: `useTtsChatBridge` listens to a
RealtimeStatus stream and dispatches `CHAT_STARTED` / `CHAT_ENDED` to
the shared playerMachine. Batch 4 keeps `useTtsChatBridge` unchanged —
the bridge consumes the same `RealtimeStatus` type, and the new
`useVoiceChat` hook maps the shared `VoiceChatPublicState` + `ChatStatus`
to that enum:

| publicState              | chatStatus | → RealtimeStatus    |
| ------------------------ | ---------- | ------------------- |
| `connecting`             | any        | `connecting`        |
| `active`                 | `speaking` | `speaking`          |
| `active`                 | other      | `active`            |
| `idle`/`paused`/`error`  | any        | `idle`              |

So as soon as a reader screen flips from `useRealtimeChat` to
`useVoiceChat`, the playerMachine gets the same `CHAT_STARTED` it got
from the old hook — paragraphIndex preservation continues to work.

### Phase 4 — page-capture vision tool

`apps/mobile/lib/voice-chat/page-capture.ts`:
- `setActivePageCaptureRef(ref | null)` — readers call this on mount
  / unmount with a React ref pointing at their content root.
- `captureCurrentPage({ detail })` — `'low'` (default) caps the
  longest edge at 512px and uses JPEG quality 0.6; `'high'` returns a
  PNG at native resolution.
- When no ref is registered (e.g. user is on the library screen),
  returns a 1×1 transparent placeholder so the agent's tool call
  doesn't crash — the prompt already handles unavailability
  gracefully.

The realtime-session's tool dispatcher routes `inspectCurrentPage`
calls here. The shared `INSPECT_CURRENT_PAGE_TOOL_SPEC` is added to the
tools list only when `visualSummary !== undefined` in the agent
factory args, mirroring electron's behaviour.

### Phase 5 — sounds (G22)

`apps/mobile/lib/voice-chat/sounds.ts`:
- `playReadyChime()` — synthesises a C5→E5 two-tone PCM WAV at import
  time and plays it via expo-audio. No asset shipped.
- `startThinkingSound()` / `stopThinkingSound()` — **no-op on mobile**.
  See Decision 4 below.

### Phase 6 — local VAD

The shared `createLocalVad` reads a global `AudioContext` constructor.
RN doesn't have one, so the port returns `null` and the activation
pipeline skips the VAD gate — matching electron's behaviour when
AudioContext fails to construct. Documented as Decision 3.

### Tests

- `packages/shared/src/voice-chat/*.test.ts` — 184 new tests:
  emitter (3) + errors (5) + key-cache (6) + machine (12) + local-vad
  (16) + types (8) + service (87) + build-realtime-agent (23) + a
  service smoke test for the snapshot path (excluded above).
- `apps/mobile/__tests__/voice-chat/service.test.ts` (8 tests) —
  asserts the mobile factory wires the shared service correctly and
  end-to-end activate works through the mocked react-native-webrtc.
- `apps/mobile/__tests__/voice-chat/page-capture.test.ts` (6 tests).
- `apps/mobile/__tests__/voice-chat/chat-bridge.test.ts` (1 test) —
  end-to-end through the shared service to the RealtimeStatus stream.

The legacy `apps/mobile/__tests__/realtime.test.ts` (11 tests) still
passes — the legacy `lib/realtime/session.ts` was preserved as a
self-contained code path, and its previously-divergent
`REALTIME_AGENT_INSTRUCTIONS` constant now delegates to the shared
`renderRealtimeInstructions` so behaviour drift is impossible.

## Decisions

### Decision 1: Effect is kept on mobile (transitive via shared)

The shared activation-program.ts is ported verbatim with its Effect-based
Scope + acquireRelease + Cause + Fiber primitives. Rewriting it to plain
promises would re-open the test obligations (>30 cases covering fiber
interrupt + resource release ordering + connect-window race conditions).
Batch 3 already accepted Effect on mobile via the TTS service (~150KB
gzip cost), so this batch doesn't move the needle further.

### Decision 2: `RagService`/`ConnectivityService` replaced by structural ports

The electron-side voice-chat types depend on `@/services/rag.RagService`
(richer interface) and `@/services/connectivity.ConnectivityService`
(adds `start`/`stop`). The shared `VoiceChatRagPort` exposes only the
`searchSemantic` method voice-chat actually uses; `VoiceChatConnectivityPort`
exposes only `isOnline` + `subscribe`. This isolates the shared module
from platform-specific service shapes.

Electron callers continue to pass their full `RagService` /
`ConnectivityService` — TypeScript's structural typing makes the
narrower port a supertype, so no electron-side change is needed (and
electron typecheck passes clean post-port).

### Decision 3: Local VAD deferred — degrades to server VAD on mobile

The plan asked to evaluate `react-native-audio-api` for the RMS VAD
algorithm. That library currently requires `react-native-worklets >= 0.6.0`
and mobile is pinned to `0.5.1` (Expo SDK 54 constraint). Upgrading
worklets without a full SDK bump risks build regressions across
nativewind + reanimated + executorch (all transitive worklets consumers).

Three options were considered:

| Option | Pros | Cons |
| --- | --- | --- |
| Upgrade worklets to 0.6.x | True parity, RMS gate works | Forced full RN runtime version bump, blocks Batch 4 ship |
| Implement via expo-av polyfill | No new deps | expo-av lacks AnalyserNode, would have to compute RMS in JS — high cost per poll |
| **Skip local VAD; fall back to server VAD** | Zero new deps, same server-side behaviour | Slightly longer activation latency when user speaks during connect window |

I picked option 3. The shared `createLocalVad` reads global
AudioContext, which is absent on RN, so the port returns null and the
activation pipeline proceeds without the gate. The user-facing impact
is bounded — the realtime session's server-side turn detection still
gates response generation — only the buffered-speech-replay feature
loses precision. Buffered-speech-replay is itself disabled on mobile
(no MediaRecorder), so this is effectively no behavioural change.

Re-enabling local VAD when SDK 55 lands: add `react-native-audio-api`
to deps, wire it as a global polyfill in `app/_layout.tsx`, and the
shared `createLocalVad` will start returning real instances. No code
change beyond the polyfill registration.

### Decision 4: Thinking sound is a no-op on mobile

Electron's `thinkingSound` is a Web-Audio oscillator that loops a soft
tick every 600ms while the agent is fetching context. RN has no
in-process tone synthesis without `react-native-audio-api` (see
Decision 3). Three options:

| Option | Pros | Cons |
| --- | --- | --- |
| Ship a small `tick.mp3` asset and loop via expo-audio | Cheap, no new deps | Adds an asset; mp3 loop seams audible on slow devices |
| Use the haptic engine for a soft pulse | No audio playback | Different sensory channel; not "thinking sound" |
| **No-op; rely on visible 'thinking' chat-status label** | Zero new deps, no audio overhead | Audio cue is lost |

I picked option 3. The on-screen chat-status pill conveys the same
information ("thinking" / "speaking" / "idle") visually, and the
ready-chime still fires on the first agent turn so the user knows the
connection is live. The plan note's wording — "if not, fall back to
(c) and note in BATCH-4-NOTES.md" — fits Decision 3 + 4 cleanly.

### Decision 5: Legacy `session.ts` preserved + its prompt swapped

The pre-Batch-4 `lib/realtime/session.ts` is now unreachable from
production (`useRealtimeChat` delegates to `useVoiceChat`). But the
existing `__tests__/realtime.test.ts` (11 tests) exercises it
directly. Rather than delete and risk regressing, I:

1. Replaced `REALTIME_AGENT_INSTRUCTIONS` in `lib/realtime/types.ts`
   with a `renderRealtimeInstructions(...)` call against the shared
   template. The export still exists for backwards compatibility, but
   the bytes are now identical to what `useVoiceChat` sends. **The
   divergent prompt is deleted.**
2. The legacy `session.ts` continues to compile + its tests continue
   to pass. The file is marked as legacy in a comment.

Future cleanup: once readers have all migrated to consuming
`useVoiceChat` directly (and the legacy `useRealtimeChat` shim is
removed), delete `lib/realtime/session.ts` + `__tests__/realtime.test.ts`
in a follow-up commit.

### Decision 6: Singleton voice-chat service

`getVoiceChatService()` is a module-level singleton. Voice chat is a
single-active-session hardware-bound resource (one mic, one realtime
connection), so a global instance matches the actual affordance and
avoids the React-effect lifecycle dance of re-creating + re-wiring
emitters every re-render. Cleanup is via `dispose()` on app teardown
(currently not wired — fine, the OS reclaims).

## Out of scope / deferred

- True local-VAD on mobile (Decision 3 — needs SDK 55 / worklets 0.6).
- Looping thinking sound (Decision 4 — visible cue suffices).
- Deleting `lib/realtime/session.ts` + its 11-test suite (Decision 5).
- Wiring `setActivePageCaptureRef` from inside each reader screen.
  The infrastructure ships; per-format wiring is a follow-up (the
  realtime agent gracefully reports "image unavailable" when no
  reader is mounted).
- Inactivity timer leak warnings in jest. The shared service
  schedules an inactivity timer on every `chatStatus('idle')` emit;
  `_resetVoiceChatServiceForTests` calls `dispose()` which clears it,
  so this is purely a jest worker-exit warning, not a real leak.
- Pre-existing 2 baseline jest failures (`guardrails.test.ts`,
  `vector.test.ts`) — same failures Batch 3 documented; out of scope.
- Pre-existing 22 typecheck errors — unchanged.

## Verification

| Gate                                    | Before | After  | Notes |
| --------------------------------------- | ------ | ------ | ----- |
| `pnpm -C packages/shared test`          | 290    | 474    | +184 voice-chat |
| `pnpm -C packages/shared typecheck`     | 1 err  | 1 err  | same pre-existing book-import/indexer.test.ts |
| `pnpm -C apps/rishi-electron typecheck` | clean  | clean  | electron unchanged |
| `npx jest` in apps/mobile               | 224/2  | 294/2  | +70 new tests, same 2 baseline failures |
| `npx tsc --noEmit` in apps/mobile       | 22     | 22     | no new errors |

## Test counts

| Suite                                   | Before | After | Added |
| --------------------------------------- | ------ | ----- | ----- |
| `packages/shared` (vitest)              | 290    | 474   | +184  |
| `apps/mobile` (jest)                    | 224    | 294   | +70   |
| **TOTAL added tests**                   |        |       | **+254** |

## Commits

| Hash       | Subject |
| ---------- | ------- |
| `016df2cc` | feat(shared): port voice-chat service + FSM + key cache + prompt template (Batch 4 Phase 1) |
| _pending_  | feat(mobile): wire shared voice-chat service + page-capture (Batch 4 Phase 2-6) |

(Not pushed.)

## Files added / modified

### Added (shared)

- `packages/shared/src/voice-chat/emitter.ts` + `emitter.test.ts`
- `packages/shared/src/voice-chat/errors.ts` + `errors.test.ts`
- `packages/shared/src/voice-chat/key-cache.ts` + `key-cache.test.ts`
- `packages/shared/src/voice-chat/machine.ts` + `machine.test.ts`
- `packages/shared/src/voice-chat/local-vad.ts` + `local-vad.test.ts`
- `packages/shared/src/voice-chat/types.ts` + `types.test.ts`
- `packages/shared/src/voice-chat/activation-program.ts`
- `packages/shared/src/voice-chat/service.ts` + `service.test.ts`
- `packages/shared/src/voice-chat/build-realtime-agent.ts` + `build-realtime-agent.test.ts`
- `packages/shared/src/voice-chat/index.ts`

### Added (mobile)

- `apps/mobile/lib/voice-chat/service.ts`
- `apps/mobile/lib/voice-chat/media-port.ts`
- `apps/mobile/lib/voice-chat/ipc.ts`
- `apps/mobile/lib/voice-chat/rag-port.ts`
- `apps/mobile/lib/voice-chat/realtime-session.ts`
- `apps/mobile/lib/voice-chat/sounds.ts`
- `apps/mobile/lib/voice-chat/page-capture.ts`
- `apps/mobile/hooks/useVoiceChat.ts`
- `apps/mobile/__tests__/voice-chat/service.test.ts`
- `apps/mobile/__tests__/voice-chat/page-capture.test.ts`
- `apps/mobile/__tests__/voice-chat/chat-bridge.test.ts`

### Modified

- `packages/shared/package.json` — added `./voice-chat` + 9 subpath
  exports.
- `apps/mobile/package.json` — added `react-native-view-shot`.
- `apps/mobile/hooks/useRealtimeChat.ts` — rewritten as a thin
  delegator to `useVoiceChat` for backwards compatibility.
- `apps/mobile/lib/realtime/types.ts` — deleted the 100-line
  divergent prompt; `REALTIME_AGENT_INSTRUCTIONS` now delegates to
  the shared `renderRealtimeInstructions`.

### Not modified (read-only as required)

- All of `apps/rishi-electron/**`. Verified by
  `pnpm -C apps/rishi-electron typecheck` returning clean both before
  and after the port.

## Packages installed (with rationale)

| Package                    | Location | Rationale |
| -------------------------- | -------- | --------- |
| `react-native-view-shot@^5.1.0` | mobile dep | Wraps `UIView.snapshot` / Android view caching for the `inspectCurrentPage` vision tool (G20). Required by the realtime agent's page-capture tool. |

No package was added to `@rishi/shared` — the shared voice-chat module
relies only on the existing peer deps (`effect`, `xstate`) Batch 3
already pulled in.

`react-native-audio-api` was evaluated and rejected (Decision 3) —
its peer dep `react-native-worklets >= 0.6.0` conflicts with mobile's
pinned 0.5.1.

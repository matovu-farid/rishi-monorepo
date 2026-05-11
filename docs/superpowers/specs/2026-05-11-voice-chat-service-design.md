# Voice Chat service — design

**Status:** draft 2026-05-11
**Parent:** [`2026-05-11-services-and-effect-adoption-design.md`](./2026-05-11-services-and-effect-adoption-design.md) (meta-spec)
**Scope:** Wave 2, service #5 of 6 (the final Wave 2 service apart from Book Import). Stage 1 only (plain TypeScript wrapping the committed `voiceChatMachine` xstate machine). `apps/rishi-electron` renderer-side service that consolidates `modules/voiceChatService.ts` + `machines/voiceChatMachine.ts` + the voice-chat-specific subset of `stores/chatStore.ts` into one cohesive module behind a small typed facade.

## Goal

Collapse today's three-paradigm voice chat surface — module-scoped EventEmitter-style service, xstate machine, and zustand store subscriptions — into one cohesive renderer-side service exposed through a small, typed interface. Hide the `RealtimeSession` lifecycle, the WebRTC handshake, mic acquisition, the idle timer, the preconnect coordination, the activate-in-flight guard, the connectivity reflection, and the agent build behind a ~7-method facade. Callers stop subscribing to `voiceChatService.actor` directly and stop reaching into a global `listeners` map; they call `getVoiceChatService().activate(...)` and subscribe via typed events.

## Background

Voice Chat today is split across three files, three paradigms, and a singleton-everywhere model:

- **`src/renderer/src/modules/voiceChatService.ts`** — a 460-line module that owns a module-scoped xstate actor (`createActor(voiceChatMachine).start()` at import time), 10 module-scoped `let` bindings (`session`, `sessionCleanup`, `currentBookId`, `idleTimer`, `mediaStream`, `audioElement`, `listeners`, `lastContextFingerprint`, `hasUsedVoiceInSession`, `activateInFlight`, `preconnectIntent`, `hasFiredReadyChime`, `isAgentSpeaking`), a single shared `listeners: Partial<VoiceChatEvents>` object set via `setListeners(...)`, the realtime session orchestration (mic prompt → WebRTC transport → agent build → key fetch → `connect()`), the warm/cold/preconnect branching, the activate-in-flight promise reuse, the idle-timer scheduler, and the connectivity reflection (calls `getConnectivityService().subscribe(...)` at import time).
- **`src/renderer/src/machines/voiceChatMachine.ts`** — a 90-line xstate machine: 6 states (`idle`, `connecting`, `active`, `paused`, `offline`, `error`), 9 events, error context. **Already committed** (PR #9). It's the right state representation; the wrap pattern keeps it.
- **`src/renderer/src/stores/chatStore.ts`** — a 121-line zustand store that registers itself as a listener with `voiceChatService.setListeners(...)` at create time, subscribes to `voiceChatService.actor` directly to mirror its state into the store, owns the `_chatGeneration` + `_isStarting` guards that prevent stale activations, derives `pageText` from `usePlayerStore`, derives `outline` from `useEpubStore`, and wires up `startChat` / `stopConversation` / `setIsChatting` / `dismissVoiceError`.
- **`src/renderer/src/stores/epubStore.ts`** — the epub-store subscribe block (around lines 220-260) does a `voiceChatService.dispose()` on bookId clear, registers a `voiceChatService.preconnect(...)` on outline arrival, and wires `useChatStore.subscribe((state) => state.isChatting, ...)` to call `startChat()`.

Symptoms that motivated the meta-spec:

- **Three paradigms for one concept.** xstate inside the module; a single mutable `listeners` slot mediating events out; a zustand store that re-subscribes the actor directly and also receives the module's events. Any new caller has to decide which paradigm to use, and existing callers couple to all three.
- **Singletons all the way down.** `voiceChatService` is a frozen object literal. `actor` is module-scoped. `listeners` is a single object; calling `setListeners(...)` *merges* into a global. Two consumers (`chatStore` and `epubStore`) both set listeners; the merge happens to work today because each sets disjoint keys, but the contract is "last writer wins per key" — fragile.
- **Side effects at import time.** `actor.start()` runs at module load. `getConnectivityService().subscribe(...)` runs at module load. The test suite (`voiceChatService.test.ts`) has a `_resetForTests()` hook to shove module state back to zero. Boundary tests are forced to reach into internals via this hook because there's no constructor.
- **`actor` is public.** `voiceChatService.actor` is exported so `chatStore` can `.subscribe(snapshot => ...)` it. Every caller that wants the state value has to know about xstate snapshot shape (`.value`, `.context.error`).
- **`pageText` / `outline` derivation lives at every call site.** `chatStore.startChat()` reads from `playerStore` + `epubStore` to build the context. `epubStore` does the same to build the preconnect context. Duplicated derivation logic.
- **Connectivity is hard-coupled.** The module imports `getConnectivityService` at the top and subscribes at load time. Tests stub `getConnectivityService` via module mock; the dep can't be swapped in a clean factory call.
- **TTS is not consumed.** Voice chat uses the OpenAI Realtime API streaming audio directly through `OpenAIRealtimeWebRTC` — no TTS service involvement. The audio comes from the realtime API; the `<audio>` element is the sink. We confirm this below in "What stays outside."
- **RAG is consumed only inside `buildRealtimeAgent`.** The `bookContext` tool calls `getRagService().searchSemantic(...)`. This is the right shape — the tool implementation is a closure created per session — but the agent-build call lives in a separate `modules/buildRealtimeAgent.ts` file imported by the service.

There is no single owner of "the voice chat session." Activation, state, lifecycle, and event fanout live in three modules with cross-coupling.

This refactor introduces a single renderer-side Voice Chat service that **wraps** the existing xstate machine (no behavior change), absorbs the lifecycle orchestration from `voiceChatService.ts` and the activate-coordination from `chatStore.ts`, exposes a small typed facade plus typed event subscriptions, and replaces every caller's import. The xstate machine stays internal, like Connectivity. The `chatStore` collapses into a thin presentation-state store that subscribes to service events at the wiring site.

## Non-goals

- **Removing the xstate machine.** The committed `voiceChatMachine.ts` stays. Wrap, not replace — same decision as Connectivity.
- **Changing the realtime SDK.** `@openai/agents/realtime` + `OpenAIRealtimeWebRTC` stay. The service consumes them through injected ports.
- **Changing the agent prompt.** `buildRealtimeAgent` stays as-is; it's invoked from inside the service with the current page-text + outline shape. (Stage 2 may move the template into config — out of scope here.)
- **Adding a TTS fallback.** The realtime API streams audio directly; no `TtsService` port is added. (Confirmed by reading `voiceChatService.ts` — `playReadyChime` / `startThinkingSound` / `stopThinkingSound` are local sound effects, not TTS.)
- **Owning the chat *message* history.** Voice chat today doesn't persist messages (the realtime audio stream is not turned into chatStore messages). If/when text-mode chat lands, the service may grow `sendMessage(text)` and message events — flagged below — but persistence stays at the wiring site (open question #1).
- **Migrating to Effect-TS.** Stage 1 is plain TypeScript. Voice Chat is the strongest Stage 2 candidate (resource lifecycle for WebRTC + structured cancellation + retry). See "Stage 2 outlook."
- **Touching `__root.tsx`, `VoiceChatLauncher`, `BackButton`, or the per-format readers.** They consume `useChatStore`, which stays — only `chatStore`'s implementation changes.
- **Multi-session support.** One active session at a time. `activate(bookId)` on a different book disposes the old session and starts a new one (current behavior).

## Decision summary

| Question | Decision |
|---|---|
| xstate internals | **Wrapped, not dropped.** `voiceChatMachine.ts` stays as a pure xstate value; lives at `services/voice-chat/machine.ts` (moved alongside the wrapper for co-location — see "File structure"). |
| Service scope | Realtime session lifecycle + mic + WebRTC + agent build call + ephemeral key fetch + connect timeout + idle timer + preconnect coordination + activate-in-flight dedup + connectivity reflection + typed events. |
| Boundary | One module: `services/voice-chat/`. Single factory `createVoiceChatService(deps)`. |
| Public interface size | 7 methods + 3 typed subscribe APIs (`onStateChange`, `onChatStatus`, `onEndedByAgent`). Plus `getState()` / `getError()` / `dismissError()` snapshots. No actor exposure, no `setListeners` mutable slot, no `EventEmitter`. |
| Return shape | `activate` / `deactivate` / `preconnect` / `dispose` / `prewarmKey` follow today's semantics. `getState()` returns a typed discriminated union string (`VoiceChatPublicState`). `onStateChange(cb)` returns `() => void` unsubscribe. |
| Public state | `'idle' \| 'connecting' \| 'active' \| 'paused' \| 'offline' \| 'error'`. Re-exposes the machine's state value as the public string union (named `VoiceChatPublicState` to keep the boundary visible — the machine's internal type stays internal). |
| Chat status | `'idle' \| 'connecting' \| 'thinking' \| 'speaking'` flows through `onChatStatus` event. Today's `onChatStatusChange` listener becomes a typed subscription. |
| Single active session | Enforced. `activate(bookId, ctx)` auto-disposes any existing session for a different book (current behavior). Concurrent `activate` calls coalesce via in-flight guard (current behavior). Open question #2 ratified. |
| `_chatGeneration` / `_isStarting` guards | Moved **into** the service. The in-flight guard already exists (`activateInFlight`); the generation counter to discard stale activations becomes part of the service's `activate()` implementation. `chatStore` stops owning it. |
| Connectivity | Injected `connectivity: ConnectivityService` port. The service subscribes inside `start()` (or constructor), not at module load. Production wires `getConnectivityService()`. |
| RAG | Injected `rag: RagService` port. The service passes it into `buildRealtimeAgent({ rag, ... })`. `buildRealtimeAgent.ts` stops importing `getRagService` directly. |
| TTS | **Not injected.** Confirmed: voice chat uses the realtime API's streamed audio. No `TtsService` dep. |
| Realtime transport / agent SDK | Injected `webrtcFactory` + `sessionFactory` + `agentFactory` ports. Production wires `OpenAIRealtimeWebRTC` / `RealtimeSession` / `buildRealtimeAgent`. Tests wire fakes. |
| IPC / API | Injected `ipc: VoiceChatIpc` port — narrow set (just `getRealtimeClientSecret` today). |
| Audio context / media | Injected `media: MediaPort` — `getUserMedia` + audio-element factory. Lets tests run in node/jsdom without faking globals. |
| Sound effects | Injected `effects: EffectsPort` — `playReadyChime`, `startThinkingSound`, `stopThinkingSound`. Production wires the existing modules. Tests wire vi.fn()s. |
| Clock | Injected `clock` port — `setTimeout`/`clearTimeout` for the idle timer + connect timeout. Tests pass a virtual clock. |
| Config | Injected `config` port — `{ idleTimeoutMs, connectTimeoutMs, model?, voice? }`. Defaults at wiring site. |
| Error model | Throws typed `Error` subclasses (`OfflineError`, `MicDeniedError`, `AuthFailedError`, `ConnectTimeoutError`, `SessionError`) from `activate()`. Snapshot error on the machine via `getError()`. No typed error channel in Stage 1. |
| `start()` / `stop()` | Yes — service exposes `start()` (registers connectivity subscription, kicks key prefetch if configured) and `stop()` (disposes session, unsubscribes connectivity). Idempotent both ways. `__root.tsx` calls `start()`; tests call neither and rely on direct method calls. |
| Events | Small `createEmitter<T>()` — same primitive duplicated from TTS / Sync / Connectivity emitters (or lifted to `services/_shared/emitter.ts` — open question #4 in Sync, still open). |
| Wiring site | `src/renderer/src/services/index.ts` — adds `getVoiceChatService()` lazy singleton alongside RAG / TTS / Sync / Book Import / Connectivity. |
| `chatStore` after refactor | Stays as a presentation-state store: `isChatting`, `chatStatus`, `voiceState`, `voiceError`. **No longer owns** the activation logic, the listener wiring, or the generation/isStarting guards. Becomes thin: actions call into the service; events flow back via service subscriptions wired at one place. |
| `epubStore` after refactor | Two voice-chat callouts (dispose on bookId clear, preconnect on outline arrival) move to service method calls through `getVoiceChatService()`. |
| Test placement | One file: `src/renderer/src/services/voice-chat/service.test.ts`. Existing tests in `modules/voiceChatService.test.ts` deleted (29 tests reach into internals via `_resetForTests` / `_setSessionForTests`). The machine's tests (`machines/__tests__/voiceChatMachine.test.ts`, 12 tests) stay as internal-implementation coverage — moved to `services/voice-chat/machine.test.ts`. The `chatStore.test.ts` shrinks to cover only the presentation-state logic (likely 3-4 tests). |
| Effect adoption (Stage 2) | Strong yes. Scores 5 of 5 axes. The most likely Stage 2 retrofit second only to TTS. Internal-only adoption; public interface stays plain TS. |

## Boundary

### What the service owns

- Construction + start of the xstate actor (`createActor(voiceChatMachine).start()`).
- Subscription to the actor for state-change fanout to service subscribers (edge-detected on the state value).
- Connectivity reflection: subscribing to `connectivity.subscribe(...)`, sending `OFFLINE` / `ONLINE` to the machine, tearing down the session on offline transitions.
- Mic acquisition via `media.getUserMedia(...)`, mediaStream caching across activate/deactivate cycles.
- Audio element creation via `media.createAudioElement()`, caching.
- WebRTC transport construction (`webrtcFactory({ mediaStream, audioElement })`).
- Agent construction (`agentFactory({ bookId, pageText, outline, onEndConversation, rag })`).
- Realtime session construction (`sessionFactory(agent, { transport, apiKey: '' })`), event wiring (`agent_start`, `audio_start`, `audio_stopped`, `agent_end`, `agent_tool_start`, `agent_tool_end`, `error`), and cleanup closure.
- Ephemeral key fetch via `ipc.getRealtimeClientSecret()` (memoized via `realtime.ts` style logic — collapsed inside the service).
- Connect timeout race (60s default — `clock.setTimeout(...)`).
- Activate-in-flight guard (only one cold path runs at a time; concurrent callers share the promise).
- Activation generation counter (discards stale results when the consumer changes its mind mid-activate).
- Preconnect coordination (the `hasUsedVoiceInSession` flag + the `preconnectIntent` flag + the post-connect mute logic).
- Idle timer (15-min default — auto-dispose on idle in `paused` state).
- Warm-path detection (same `bookId` + session present → `updateAgent` if context fingerprint changed + unmute).
- Cold-path teardown on failure (half-built session must close to avoid hot mic).
- Typed event fanout: `onStateChange(VoiceChatPublicState)`, `onChatStatus('idle'|'connecting'|'thinking'|'speaking')`, `onEndedByAgent(reason)`.
- Sound-effect side calls: `effects.playReadyChime()` on first `agent_start`, `effects.startThinkingSound()` / `effects.stopThinkingSound()` on tool start/end.

### What stays outside

- **The `voiceChatMachine` definition itself.** Pure xstate value; stays at `services/voice-chat/machine.ts` (or `machines/voiceChatMachine.ts` if not moved — see open question #5). Service imports it.
- **The realtime SDK.** `@openai/agents/realtime` + `@openai/agents-realtime`. Injected via factories.
- **The agent prompt template.** `buildRealtimeAgent.ts`'s `INSTRUCTIONS_TEMPLATE` stays inline in that file. The service injects `rag` into the agent factory so the file no longer imports `getRagService` directly.
- **The `RagService`.** Owned by `services/rag/`. Voice Chat consumes the public interface.
- **The `ConnectivityService`.** Owned by `services/connectivity/`. Voice Chat consumes its `isOnline()` + `subscribe()` surface.
- **The ephemeral-key API call.** `getRealtimeClientSecret` from `@/lib/api` is the underlying IPC. The service consumes it through an `ipc` port; the `realtime.ts` 9-min TTL cache logic moves *into* the service (or stays as a thin helper consumed by the service; lean: move in — see open question #3).
- **Chat presentation state.** `isChatting`, `chatStatus` (mirrored from `onChatStatus`), `voiceState` (mirrored from `onStateChange`), `voiceError` (mirrored from snapshot). Stay in `chatStore`, but are fed by service event subscriptions at the wiring site.
- **`pageText` / `outline` derivation.** Stays at the wiring site (or at the caller). The service's `activate(bookId, ctx)` takes `ctx` as a parameter — it doesn't reach into `playerStore` / `epubStore`. Today's `chatStore.startChat` derivation moves into a small helper.
- **The launcher button (`VoiceChatLauncher`).** Unchanged in layout.
- **The `BackButton` `stopConversation` call.** Unchanged — `useChatStore.stopConversation()` still exists; its implementation calls into the service.

### What's hidden behind the interface

Callers don't see: `xstate`, `createActor`, `voiceChatMachine`, the snapshot shape, `RealtimeSession`, `OpenAIRealtimeWebRTC`, `RealtimeAgent`, `getRealtimeClientSecret`, the 9-min key cache, the activate-in-flight promise, the generation counter, the `lastContextFingerprint`, the idle-timer handle, the `hasUsedVoiceInSession` flag, the `preconnectIntent` flag, the `playReadyChime` first-fire guard, the `isAgentSpeaking` flag that coordinates `audio_start` / `agent_end`, the mediaStream / audioElement caches, the connect-timeout race, the connectivity subscription unsubscribe.

## Dependencies

All dependencies categorized per the meta-spec. Voice Chat has more dependencies than any other service — that's the cost of the wide WebRTC surface.

| Dep | Category | What the service uses | Production adapter | Test adapter |
|---|---|---|---|---|
| `rag` | In-process (service consumer) | `RagService` from `getRagService()`. Passed into `agentFactory` so the `bookContext` tool can call `rag.searchSemantic(...)`. | `getRagService()` from `@/services` | `makeRag({ chunks: [...] })` returning fixed chunks |
| `connectivity` | In-process (service consumer) | `ConnectivityService` — `isOnline()` + `subscribe()`. | `getConnectivityService()` from `@/services` | `makeConnectivity({ initialOnline })` with `.setOnline(b)` test helper |
| `ipc` | Remote-but-owned (port + adapter) | `getRealtimeClientSecret(): Promise<string>` | `{ getRealtimeClientSecret: () => getRealtimeClientSecret() }` via `@/lib/api` (which wraps the underlying `window.electron` / Better Auth fetch) | `makeIpc({ key: 'test-key', delayMs?, failWith? })` |
| `webrtcFactory` | External (port + factory) | `({ mediaStream, audioElement }) => RTCTransportLike` | `(opts) => new OpenAIRealtimeWebRTC(opts)` | `makeWebrtc()` returning `{}` (the real session does nothing with the transport object until `.connect`) |
| `agentFactory` | In-process (port + factory) | `({ bookId, pageText, outline, onEndConversation, rag }) => RealtimeAgentLike` | `buildRealtimeAgent` (which receives `rag` as a dep, eliminating its `getRagService` import) | `makeAgent()` returning a fake agent value |
| `sessionFactory` | External (port + factory) | `(agent, opts) => RealtimeSessionLike` (where `RealtimeSessionLike` has `connect`, `mute`, `interrupt`, `close`, `updateAgent`, `on`, `off`) | `(agent, opts) => new RealtimeSession(agent, opts)` | `makeSession({ connectImpl?, ... })` returning a vi.fn()-backed object |
| `media` | External (port + factory) | `getUserMedia(constraints): Promise<MediaStreamLike>` + `createAudioElement(): HTMLAudioElementLike` | `{ getUserMedia: (c) => navigator.mediaDevices.getUserMedia(c), createAudioElement: () => { const a = document.createElement('audio'); a.autoplay = true; return a } }` | `makeMedia({ stream, audioElement })` with controllable `denyMic()` test helper |
| `effects` | In-process (port) | `playReadyChime() / startThinkingSound() / stopThinkingSound()` | The current `@/modules/readyChime` + `@/modules/thinkingSound` functions | `vi.fn()`s |
| `clock` | In-process | `now()`, `setTimeout(fn, ms)`, `clearTimeout(handle)` | The globals (bound at the wiring site) | `makeClock()` with `.tick(ms)` |
| `config` | In-process | `{ idleTimeoutMs, connectTimeoutMs, keyTtlMs, model?, voice? }` | Literal at wiring site | Literal in tests |

The service is testable as plain code under vitest. No real `navigator.mediaDevices`, no real `RTCPeerConnection`, no real `RealtimeSession`, no real `<audio>` element, no real `window`, no real `setTimeout`.

### Connectivity port reuse

Voice Chat consumes the `ConnectivityService` *directly* — the Connectivity service refactor (already merged) exposes `isOnline()` + `subscribe()` exactly matching what Voice Chat needs. No adapter layer required; `getConnectivityService()` is passed straight through.

### RAG port reuse

`buildRealtimeAgent` currently imports `getRagService` from `@/services`. The refactor inverts the dependency: the service injects `rag` into the agent factory. The agent factory becomes a pure function of `({ bookId, pageText, outline, onEndConversation, rag })`. Tests substitute a fake `rag` cleanly.

## Public interface

### Types

```ts
// src/renderer/src/services/voice-chat/types.ts

import type { BookOutline } from '@/lib/api'
import type { RagService } from '@/services/rag'
import type { ConnectivityService } from '@/services/connectivity'

/**
 * Public state surface. Same string union as the internal machine, re-named at
 * the boundary to make the public-vs-internal split visible.
 */
export type VoiceChatPublicState =
  | 'idle'
  | 'connecting'
  | 'active'
  | 'paused'
  | 'offline'
  | 'error'

/** Chat-status surface — finer-grained than VoiceChatPublicState. */
export type ChatStatus = 'idle' | 'connecting' | 'thinking' | 'speaking'

export type VoiceErrorReason =
  | 'timeout'
  | 'mic_denied'
  | 'auth_failed'
  | 'connect_failed'
  | 'session_error'
  | 'unknown'

export interface VoiceError {
  reason: VoiceErrorReason
  message?: string
}

export interface VoiceChatContext {
  pageText: string
  outline?: BookOutline
}

export class OfflineError extends Error {
  readonly name = 'OfflineError'
  constructor() {
    super('You are offline. Voice chat is unavailable until you reconnect.')
  }
}

// --- ports ---

export interface VoiceChatIpc {
  getRealtimeClientSecret(): Promise<string>
}

/** Minimal mic + audio-element factory. Lets tests run in node. */
export interface MediaPort {
  getUserMedia(constraints: MediaStreamConstraints): Promise<MediaStreamLike>
  createAudioElement(): AudioElementLike
}

export interface MediaStreamLike {
  getTracks(): Array<{ stop(): void }>
}

export interface AudioElementLike {
  muted: boolean
  srcObject: unknown
  autoplay: boolean
  pause(): void
}

export interface EffectsPort {
  playReadyChime(): void
  startThinkingSound(): void
  stopThinkingSound(): void
}

export interface ClockPort {
  now(): number
  setTimeout(fn: () => void, ms: number): ReturnType<typeof setTimeout>
  clearTimeout(handle: ReturnType<typeof setTimeout>): void
}

export interface VoiceChatConfig {
  /** Auto-dispose after this many ms in `paused`. Default 15 * 60 * 1000. */
  idleTimeoutMs: number
  /** Reject WebRTC handshake if it stalls beyond this. Default 60 * 1000. */
  connectTimeoutMs: number
  /** Reuse cached ephemeral key within this window. Default 9 * 60 * 1000. */
  keyTtlMs: number
}

// --- session-shape contracts (what the factories must return) ---

export interface RealtimeAgentLike {
  /** Opaque to the service; passed to sessionFactory. */
  readonly _agent: unknown
}

export interface RealtimeSessionLike {
  connect(opts: { apiKey: string }): Promise<void>
  mute(muted: boolean): void
  interrupt(): void
  close(): void
  updateAgent(agent: RealtimeAgentLike | unknown): Promise<void>
  on(event: string, listener: (...args: unknown[]) => void): void
  off(event: string, listener: (...args: unknown[]) => void): void
}

export interface RtcTransportLike {
  /** Opaque to the service. Returned by webrtcFactory; passed to sessionFactory. */
  readonly _transport: unknown
}

export interface AgentFactoryArgs {
  bookId: number
  pageText: string
  outline?: BookOutline
  onEndConversation: (reason: string) => void
  rag: RagService
}

export interface WebrtcFactoryArgs {
  mediaStream: MediaStreamLike
  audioElement: AudioElementLike
}

export interface SessionFactoryOpts {
  transport: RtcTransportLike
  apiKey: string
}

export interface VoiceChatServiceDeps {
  rag: RagService
  connectivity: ConnectivityService
  ipc: VoiceChatIpc
  webrtcFactory: (args: WebrtcFactoryArgs) => RtcTransportLike
  agentFactory: (args: AgentFactoryArgs) => RealtimeAgentLike
  sessionFactory: (agent: RealtimeAgentLike, opts: SessionFactoryOpts) => RealtimeSessionLike
  media: MediaPort
  effects: EffectsPort
  clock: ClockPort
  config: VoiceChatConfig
}
```

### Service interface

```ts
// src/renderer/src/services/voice-chat/index.ts

export interface VoiceChatService {
  /**
   * Lazy lifecycle: register the connectivity subscription, start the idle
   * machinery. Called once at wiring-site setup. Idempotent.
   */
  start(): void

  /**
   * Tear down: dispose any live session, unsubscribe connectivity, clear
   * timers, drop subscribers. Idempotent.
   */
  stop(): void

  /**
   * Start or resume voice chat for the given book. Returns once the session
   * is fully connected (cold path) or unmuted (warm path).
   *
   * Behavior:
   * - Cold: mic prompt → WebRTC handshake → agent build → connect (60s timeout).
   * - Warm (same bookId): refresh agent if context changed, unmute.
   * - Different bookId: dispose old session first, then cold path.
   * - Concurrent callers coalesce via the in-flight promise.
   * - Auto-stop: if a previous session is live for a different bookId, it is
   *   disposed before the new one starts (single active session).
   *
   * @throws OfflineError synchronously if connectivity reports offline.
   * @throws Error with a classified `.message` on mic denial, auth failure,
   *         connect timeout, or transport error. The machine state is set to
   *         `'error'` with a typed reason (see `getError()`).
   */
  activate(bookId: number, ctx: VoiceChatContext): Promise<void>

  /**
   * Pre-warm the WebRTC connection in the background once the user has used
   * voice chat at least once this session. No-op if user has not used voice
   * yet, if offline, or if a session is already live for `bookId`. The
   * service leaves the session in `'paused'` (muted) after preconnect — unless
   * a user-initiated `activate()` raced and won, in which case `'active'`.
   */
  preconnect(bookId: number, ctx: VoiceChatContext): Promise<void>

  /**
   * Move the live session to `'paused'`. Mic + audio muted; session kept open
   * for fast resume. Schedules an idle timer; if not reactivated within
   * `config.idleTimeoutMs`, the service auto-disposes.
   */
  deactivate(): void

  /**
   * Tear down the session entirely. Returns to `'idle'`. Safe to call from any
   * state.
   */
  dispose(): void

  /**
   * Fetch the ephemeral OpenAI key in the background. Safe to call on book
   * open. Does NOT prompt for mic.
   */
  prewarmKey(): void

  /** Snapshot of the current public state. */
  getState(): VoiceChatPublicState

  /** Last error stored on the internal machine, or null. */
  getError(): VoiceError | null

  /** Clear the error in the machine; transitions `'error' → 'idle'`. */
  dismissError(): void

  /**
   * Subscribe to public-state transitions. Listener fires on edges, not on
   * subscribe. Returns an unsubscribe function.
   */
  onStateChange(listener: (state: VoiceChatPublicState) => void): () => void

  /**
   * Subscribe to chat-status updates (finer-grained than state — `'thinking'`
   * / `'speaking'` are not separate machine states).
   */
  onChatStatus(listener: (status: ChatStatus) => void): () => void

  /**
   * Subscribe to the "agent ended the conversation" event. Fires when the
   * agent invokes the `endConversation` tool. Typed string is the agent's
   * reason.
   */
  onEndedByAgent(listener: (reason: string) => void): () => void
}

export function createVoiceChatService(deps: VoiceChatServiceDeps): VoiceChatService
```

### Shape notes

- **`activate` is the single entry point** for both cold and warm paths. The internal branching (cold / warm / different-book / concurrent) is hidden. Caller never decides which path runs.
- **No `setListeners(...)`** mutable slot. Three typed `on*` methods replace it. Each returns an unsubscribe handle. Multiple subscribers supported per channel.
- **`getState()` returns a string union, not the machine snapshot.** Callers don't import xstate, don't see `.value` / `.context`.
- **`getError()` returns the typed `VoiceError`** captured on the machine. Callers don't pull it from `actor.getSnapshot().context.error`.
- **`OfflineError` is the only typed Error export.** Other failure classes (mic-denied, auth-failed, etc.) flow through the machine's `error` state with a typed `reason`; `activate()` throws a plain `Error` whose message matches the classification (so existing callers' `instanceof OfflineError` checks survive verbatim — every other catch path just calls `captureError` today).
- **`onChatStatus` is separate from `onStateChange`** because `'thinking'` and `'speaking'` are emitted by the realtime session's `agent_start` / `audio_start` events — they're a sub-channel inside the machine's `'active'` state, not their own state. Today's `onChatStatusChange` already has this shape; we preserve it.
- **`start()` / `stop()` are exposed** for symmetry with Sync and Connectivity. The wiring site calls `start()` once. Tests skip them and call `activate()` directly (the service's lifecycle handles late `start()` gracefully — if not started, `connectivity.subscribe(...)` hasn't fired yet but the in-method `connectivity.isOnline()` check still gates activation).

### Usage example — wiring site

```ts
// src/renderer/src/services/index.ts (additive — appended after getBookImportService)
import {
  createVoiceChatService,
  type VoiceChatService
} from './voice-chat'
import { buildRealtimeAgent } from '@/modules/buildRealtimeAgent'
import { RealtimeSession } from '@openai/agents/realtime'
import { OpenAIRealtimeWebRTC } from '@openai/agents-realtime'
import { playReadyChime } from '@/modules/readyChime'
import { startThinkingSound, stopThinkingSound } from '@/modules/thinkingSound'
import { getRealtimeClientSecret } from '@/lib/api'

let _voiceChat: VoiceChatService | null = null

export function getVoiceChatService(): VoiceChatService {
  if (!_voiceChat) {
    _voiceChat = createVoiceChatService({
      rag: getRagService(),
      connectivity: getConnectivityService(),
      ipc: { getRealtimeClientSecret },
      webrtcFactory: ({ mediaStream, audioElement }) =>
        new OpenAIRealtimeWebRTC({ mediaStream, audioElement }) as never,
      agentFactory: ({ bookId, pageText, outline, onEndConversation, rag }) =>
        buildRealtimeAgent({ bookId, pageText, outline, onEndConversation, rag }) as never,
      sessionFactory: (agent, opts) =>
        new RealtimeSession(agent as never, { transport: opts.transport as never, apiKey: opts.apiKey }) as never,
      media: {
        getUserMedia: (constraints) => navigator.mediaDevices.getUserMedia(constraints),
        createAudioElement: () => {
          const a = document.createElement('audio')
          a.autoplay = true
          return a
        }
      },
      effects: { playReadyChime, startThinkingSound, stopThinkingSound },
      clock: {
        now: () => Date.now(),
        setTimeout: (fn, ms) => setTimeout(fn, ms),
        clearTimeout: (handle) => clearTimeout(handle)
      },
      config: {
        idleTimeoutMs: 15 * 60 * 1000,
        connectTimeoutMs: 60 * 1000,
        keyTtlMs: 9 * 60 * 1000
      }
    })
    _voiceChat.start()
  }
  return _voiceChat
}
```

### Usage example — chatStore wiring

The `chatStore` shrinks dramatically. It stops mutating service listeners and stops subscribing to `actor`. Instead it subscribes to typed service events.

```ts
// src/renderer/src/stores/chatStore.ts (after refactor)
import { create } from 'zustand'
import { devtools, subscribeWithSelector } from 'zustand/middleware'
import { getVoiceChatService } from '@/services'
import { usePlayerStore } from './playerStore'
import { useEpubStore } from './epubStore'
import { captureError } from '@/utils/sentry'
import { OfflineError } from '@/services/voice-chat'
import type {
  ChatStatus,
  VoiceChatPublicState,
  VoiceError
} from '@/services/voice-chat'

interface ChatState {
  isChatting: boolean
  chatStatus: ChatStatus
  voiceState: VoiceChatPublicState
  voiceError: VoiceError | null

  setIsChatting: (value: boolean | ((prev: boolean) => boolean)) => void
  startChat: (bookId: number) => void
  stopConversation: () => void
  dismissVoiceError: () => void
}

export const useChatStore = create<ChatState>()(
  devtools(
    subscribeWithSelector((set, get) => {
      const voice = getVoiceChatService()

      // One subscription per channel. Each returns an unsubscribe — for the
      // singleton store we let them live forever (process-lifetime).
      voice.onChatStatus((status) => set({ chatStatus: status }))
      voice.onStateChange((state) =>
        set({ voiceState: state, voiceError: voice.getError() })
      )
      voice.onEndedByAgent(() => {
        set({ isChatting: false })
        voice.deactivate()
      })

      return {
        isChatting: false,
        chatStatus: 'idle',
        voiceState: voice.getState(),
        voiceError: voice.getError(),

        setIsChatting: (value) => {
          const newValue = typeof value === 'function' ? value(get().isChatting) : value
          if (newValue) {
            const send = usePlayerStore.getState().send
            if (send) send({ type: 'CHAT_STARTED' })
          } else {
            voice.deactivate()
          }
          set({ isChatting: newValue })
        },

        startChat: (bookId) => {
          const pageText = usePlayerStore
            .getState()
            .currentParagraphs.map((p) => p.text)
            .join('\n')
          const epubState = useEpubStore.getState()
          const outline =
            epubState.bookId === String(bookId) ? (epubState.bookOutline ?? undefined) : undefined

          voice.activate(bookId, { pageText, outline }).catch((err) => {
            if (!(err instanceof OfflineError)) {
              captureError(err, { operation: 'chatStore', step: 'activate' })
            }
            set({ isChatting: false, chatStatus: 'idle' })
          })
        },

        stopConversation: () => {
          set({ isChatting: false, chatStatus: 'idle' })
          voice.deactivate()
        },

        dismissVoiceError: () => {
          voice.dismissError()
        }
      }
    }),
    { name: 'chat-store' }
  )
)
```

**Key collapses in this snippet:**
- `_chatGeneration` and `_isStarting` are gone. The service owns the in-flight guard; concurrent `startChat()` calls hit the service's `activate()` which dedups.
- `voiceChatService.setListeners(...)` is gone; replaced by three typed `on*` subscriptions.
- `voiceChatService.actor.subscribe(snapshot => ...)` is gone; `voiceState` flows via `onStateChange`.
- `voiceError` is read via `voice.getError()` rather than `snapshot.context.error`.
- `OfflineError` is imported from the service public surface, not from `modules/voiceChatService`.

### Usage example — epubStore

```ts
// stores/epubStore.ts (around lines 220-260, after refactor)
import { getVoiceChatService } from '@/services'

// On bookId clear → dispose
useEpubStore.subscribe(
  (state) => state.bookId,
  (bookId) => {
    if (bookId) {
      getVoiceChatService().prewarmKey()
    } else {
      useEpubStore.getState().setBookOutline(null)
      getVoiceChatService().dispose()
    }
  }
)

// On outline arrival → preconnect
useEpubStore.subscribe(
  (state) => state.bookOutline,
  (outline) => {
    const bookId = useEpubStore.getState().bookId
    if (!bookId || !outline) return
    const pageText = usePlayerStore
      .getState()
      .currentParagraphs.map((p) => p.text)
      .join('\n')
    void getVoiceChatService().preconnect(Number(bookId), { pageText, outline })
  }
)
```

Three changes: import path, no `prefetchRealtimeKey` import (folded into `service.prewarmKey()`), same method shapes.

## File structure & module layout

```
src/renderer/src/services/
├── index.ts                          # +getVoiceChatService(); existing services unchanged
└── voice-chat/
    ├── index.ts                      # public re-exports
    ├── types.ts                      # types from "Public interface" above
    ├── service.ts                    # createVoiceChatService — top-level wiring
    ├── machine.ts                    # the voiceChatMachine (moved from machines/)
    ├── machine.test.ts               # the 12 existing machine tests (moved)
    ├── key-cache.ts                  # internal: ephemeral-key TTL cache (absorbs realtime.ts)
    ├── emitter.ts                    # internal: createEmitter<T>() (same shape as TTS/Sync)
    └── service.test.ts               # boundary tests
```

The internal modules (`machine.ts`, `key-cache.ts`, `emitter.ts`) are not re-exported from `index.ts`. They're a refactoring convenience.

**Move decision: `voiceChatMachine.ts` → `services/voice-chat/machine.ts`.** Unlike Connectivity (where the machine stayed in `machines/` because it was a pure value with no service-internal dependencies), Voice Chat's machine is intimately co-evolved with the service — every new event the service emits implies a machine change. Co-location aids readability. The machine's tests move with it. The pure xstate value semantics are unchanged.

**Move decision: `realtime.ts` (the key TTL cache) → `services/voice-chat/key-cache.ts`.** The 9-min TTL cache is a private implementation detail of the service. Nothing else imports `getOrFetchKey` / `prefetchRealtimeKey` — verified by grep. Cleanest absorbed-into-service.

**Keep decision: `buildRealtimeAgent.ts` stays at `modules/buildRealtimeAgent.ts`.** It's *almost* a pure function — it composes the prompt template + binds the RAG / endConversation tools. The service injects `rag` as a parameter. The function is large (~110 lines) and the prompt template is a separate concern from the session lifecycle. Co-location would bloat `services/voice-chat/`. Open question #5 below flags this — the lean is keep-in-modules.

## Internals (orchestration flow)

```ts
// src/renderer/src/services/voice-chat/service.ts (illustrative)

export function createVoiceChatService(deps: VoiceChatServiceDeps): VoiceChatService {
  const {
    rag, connectivity, ipc, webrtcFactory, agentFactory, sessionFactory,
    media, effects, clock, config
  } = deps

  const stateEmitter = createEmitter<VoiceChatPublicState>()
  const chatStatusEmitter = createEmitter<ChatStatus>()
  const endedByAgentEmitter = createEmitter<string>()

  const actor = createActor(voiceChatMachine)
  actor.start()

  const keyCache = createKeyCache({
    fetch: () => ipc.getRealtimeClientSecret(),
    ttlMs: config.keyTtlMs,
    clock
  })

  // Session-scoped mutable state — same as today, but bound in the closure
  // instead of at module scope.
  let session: RealtimeSessionLike | null = null
  let sessionCleanup: (() => void) | null = null
  let currentBookId: number | null = null
  let idleTimer: ReturnType<ClockPort['setTimeout']> | null = null
  let mediaStream: MediaStreamLike | null = null
  let audioElement: AudioElementLike | null = null
  let lastContextFingerprint: string | null = null
  let hasUsedVoiceInSession = false
  let activateInFlight: Promise<void> | null = null
  let activateGeneration = 0
  let preconnectIntent = false
  let hasFiredReadyChime = false
  let isAgentSpeaking = false
  let connectivityUnsub: (() => void) | null = null
  let lastPublicState: VoiceChatPublicState = 'idle'
  let started = false

  // Edge-detected fanout for state
  actor.subscribe(() => {
    const next = actor.getSnapshot().value as VoiceChatPublicState
    if (next === lastPublicState) return
    lastPublicState = next
    stateEmitter.emit(next)
  })

  function classifyError(err: unknown): VoiceErrorReason { /* unchanged */ }
  function fingerprintContext(ctx: VoiceChatContext): string { /* unchanged */ }
  function clearIdleTimer() { /* unchanged */ }
  function scheduleIdleTimer() { /* unchanged */ }
  function disposeInternal() { /* unchanged */ }

  async function doActivate(bookId: number, ctx: VoiceChatContext, gen: number): Promise<void> {
    /* cold + warm + different-book branching, identical to today, except:
       - `gen !== activateGeneration` short-circuits before emitting state changes
       - agent built via `agentFactory({ bookId, pageText, outline, onEndConversation, rag })`
       - session built via `sessionFactory(agent, { transport, apiKey: '' })`
       - transport built via `webrtcFactory({ mediaStream, audioElement })`
       - mic acquired via `media.getUserMedia({ audio: true })`
       - audioElement via `media.createAudioElement()`
       - apiKey via `keyCache.get()`
       - timers via `clock.setTimeout` / `clock.clearTimeout`
       - chat-status fanout via `chatStatusEmitter.emit(...)` (was `listeners.onChatStatusChange?.(...)`)
       - ready-chime via `effects.playReadyChime()`
       - thinking-sound via `effects.startThinkingSound()` / `effects.stopThinkingSound()`
       - end-conversation tool callback fans out via `endedByAgentEmitter.emit(reason)`
    */
  }

  return {
    start() {
      if (started) return
      started = true
      connectivityUnsub = connectivity.subscribe((online) => {
        if (!online) {
          if (session) disposeInternal()
          actor.send({ type: 'OFFLINE' })
        } else if (actor.getSnapshot().value === 'offline') {
          actor.send({ type: 'ONLINE' })
        }
      })
    },

    stop() {
      if (!started) return
      started = false
      disposeInternal()
      if (connectivityUnsub) connectivityUnsub()
      connectivityUnsub = null
      activateGeneration++ // invalidate any in-flight
    },

    async activate(bookId, ctx) {
      if (!connectivity.isOnline()) {
        actor.send({ type: 'OFFLINE' })
        throw new OfflineError()
      }
      preconnectIntent = false
      activateGeneration++
      const gen = activateGeneration
      if (activateInFlight) return activateInFlight
      activateInFlight = doActivate(bookId, ctx, gen)
      try { await activateInFlight }
      finally { activateInFlight = null }
    },

    async preconnect(bookId, ctx) {
      if (!hasUsedVoiceInSession) return
      if (!connectivity.isOnline()) return
      if (session && currentBookId === bookId) return
      if (activateInFlight) return
      preconnectIntent = true
      try {
        await this.activate(bookId, ctx)
        if (preconnectIntent && session) {
          session.interrupt()
          session.mute(true)
          if (audioElement) audioElement.muted = true
          actor.send({ type: 'DEACTIVATE' })
        }
      } catch (err) {
        captureError(err, { operation: 'voiceChatService', step: 'preconnect' })
      } finally {
        preconnectIntent = false
      }
    },

    deactivate() { /* unchanged */ },
    dispose() { disposeInternal(); actor.send({ type: 'DISPOSE' }) },
    prewarmKey() { void keyCache.get() },

    getState() { return actor.getSnapshot().value as VoiceChatPublicState },
    getError() { return actor.getSnapshot().context.error },
    dismissError() { actor.send({ type: 'DISMISS_ERROR' }) },

    onStateChange: stateEmitter.on,
    onChatStatus: chatStatusEmitter.on,
    onEndedByAgent: endedByAgentEmitter.on
  }
}
```

### Behavioral notes baked into the contract

- **Single active session.** `activate(bookIdB)` while session is alive for `bookIdA` disposes the A session first. Same as today.
- **In-flight dedup.** Concurrent `activate(bookId, ctx)` calls share the promise. Today's behavior, lifted into the service.
- **Generation counter discards stale results.** A new `activate()` call bumps the generation; the old activation's `actor.send(...)` calls are short-circuited if the generation no longer matches. Replaces today's `chatStore._chatGeneration` guard.
- **Connectivity hookup in `start()`, not at import.** Tests can construct the service without an immediate `connectivity.subscribe` registration; tests that *do* want the subscription register call `start()` explicitly.
- **`OfflineError` is the *only* synchronously-thrown error class** that callers `instanceof`-check. All other failures go through the typed reason on the machine + a generic `Error` for the rejection.
- **`prewarmKey()` is non-blocking.** Fires off the key fetch; ignores the result. Used on book open.
- **`dispose()` resets `hasFiredReadyChime` and `isAgentSpeaking`.** Same as today.
- **Edge-detected `onStateChange`.** Spurious actor events (no-value-change transitions) are filtered.
- **`onChatStatus` is *not* edge-detected.** Today's status fan-out fires on every `agent_start` / `audio_start` event; UI relies on it to drive the status indicator's animation reset. We preserve.

## Migration

### Caller migration table

| File | Current | After |
|---|---|---|
| `src/renderer/src/stores/chatStore.ts` | `import { voiceChatService, OfflineError } from '@/modules/voiceChatService'`; `setListeners(...)`; `actor.subscribe(...)`; owns `_chatGeneration` / `_isStarting`; calls `voiceChatService.activate/deactivate/dispose/dismissError/getState/getError` | `import { getVoiceChatService } from '@/services'` + `import { OfflineError, type ChatStatus, type VoiceChatPublicState, type VoiceError } from '@/services/voice-chat'`. Subscribe via `voice.onChatStatus(...)` / `onStateChange(...)` / `onEndedByAgent(...)`. Generation/isStarting guards deleted. Method calls swap to `voice.activate(...)` etc. (See full snippet under "chatStore wiring" above.) |
| `src/renderer/src/stores/epubStore.ts` (lines 220-260) | `import { voiceChatService } from '@/modules/voiceChatService'`; `import { prefetchRealtimeKey } from '@/modules/realtime'`; calls `voiceChatService.dispose()` / `voiceChatService.preconnect(...)`; `prefetchRealtimeKey()` for prewarm | `import { getVoiceChatService } from '@/services'`. `prefetchRealtimeKey()` → `getVoiceChatService().prewarmKey()`. `voiceChatService.dispose()` → `getVoiceChatService().dispose()`. `voiceChatService.preconnect(...)` → `getVoiceChatService().preconnect(...)`. Delete the `@/modules/realtime` import. |
| `src/renderer/src/components/BackButton.tsx` | `useChatStore((s) => s.stopConversation)` → calls it | **Unchanged.** `chatStore.stopConversation` still exists; the store now calls into the service. |
| `src/renderer/src/components/chat/VoiceChatLauncher.tsx` | `useChatStore((s) => s.isChatting)` + `setIsChatting` | **Unchanged.** |
| `src/renderer/src/components/{epub,pdf,mobi,djvu}/{EpubView,pdf,MobiView,DjvuView}.{tsx}` | `useChatStore` for `isChatting` + `chatStatus` | **Unchanged.** Presentation-state reads are unaffected. |
| `src/renderer/src/modules/buildRealtimeAgent.ts` | `import { getRagService } from '@/services'`; calls `getRagService().searchSemantic(...)` inside the `bookContext` tool | Function signature gains `rag: RagService` parameter; tool closure captures it. Imports of `@/services` for RAG removed. Caller (wiring site / service) passes `rag` in. |

Total: 3 files with real logic changes (`chatStore.ts`, `epubStore.ts`, `buildRealtimeAgent.ts`). All UI components untouched.

### chatStore wiring — how events become store actions

The wiring happens **once, at chatStore creation time**. The store's `create()` closure calls `getVoiceChatService()` and subscribes to the three event channels. The subscriptions return unsubscribes which the store discards — for a process-lifetime singleton store with a process-lifetime singleton service, leaks are not possible.

```ts
// One-time wiring inside the chatStore factory closure
voice.onChatStatus((status) => set({ chatStatus: status }))
voice.onStateChange((state) =>
  set({ voiceState: state, voiceError: voice.getError() })
)
voice.onEndedByAgent(() => {
  set({ isChatting: false })
  voice.deactivate()
})
```

**Three events, three side effects, all in one place.** This is the wiring-site pattern from the meta-spec: the service exposes typed event channels; the consumer (chatStore) translates events into store actions at one well-known site. The service does *not* know about Zustand. The store does *not* know about xstate.

Tests for the store mock the service (now via `@/services` instead of `@/modules/voiceChatService`); the existing `chatStore.test.ts` shape stays valid with import-path updates.

### epubStore — same pattern, simpler

The two epub-store callouts become:

```ts
if (bookId) {
  getVoiceChatService().prewarmKey()
} else {
  getVoiceChatService().dispose()
}

// ...

void getVoiceChatService().preconnect(Number(bookId), { pageText, outline })
```

No event subscriptions — `epubStore` is a *commander*, not a *consumer*. The service handles the lifecycle on its own.

### Files to delete

| File | Reason |
|---|---|
| `src/renderer/src/modules/voiceChatService.ts` | Absorbed into `services/voice-chat/service.ts`. |
| `src/renderer/src/modules/voiceChatService.test.ts` | Replaced by `services/voice-chat/service.test.ts`. The 29 existing tests reach into `_resetForTests` / `_setSessionForTests` — they describe shallow-module implementation. |
| `src/renderer/src/modules/realtime.ts` | Absorbed into `services/voice-chat/key-cache.ts` (internal). |
| `src/renderer/src/machines/voiceChatMachine.ts` | Moved to `services/voice-chat/machine.ts`. |
| `src/renderer/src/machines/__tests__/voiceChatMachine.test.ts` | Moved to `services/voice-chat/machine.test.ts`. Same 12 tests, no rewrite. |

### Files NOT deleted

| File | Reason |
|---|---|
| `src/renderer/src/modules/buildRealtimeAgent.ts` | Stays. Function gains a `rag: RagService` parameter; the `import { getRagService }` line is removed. The prompt-template logic is unchanged. |
| `src/renderer/src/modules/readyChime.ts` / `thinkingSound.ts` | Stay. Wired into the service via the `effects` port. |
| `src/renderer/src/stores/chatStore.ts` | Stays, but shrinks (~60 lines after refactor, down from 121). |

Per the meta-spec's *no shims* rule: no compatibility re-exports at `@/modules/voiceChatService` or `@/machines/voiceChatMachine`. One PR, one source of truth.

## Test strategy

### Test placement

- **Boundary tests** at the service interface: one file, `src/renderer/src/services/voice-chat/service.test.ts`. Tests construct the service with fakes — no global mocks, no module reset between tests, no `_resetForTests` hook.
- **Internal-implementation tests** for the machine: `services/voice-chat/machine.test.ts` (moved from `machines/__tests__/voiceChatMachine.test.ts`, unchanged). 12 tests covering the state-transition contract.
- **Store tests**: `stores/chatStore.test.ts` shrinks. Only presentation-state actions stay covered — startChat delegation, stopConversation reset, setIsChatting false path. The mock targets `@/services` (or the service factory directly) instead of `@/modules/voiceChatService`.

The split is principled: boundary tests verify the service's contract end-to-end; machine tests verify the state transitions in isolation; store tests verify the store's translation of service events into store state. Each layer is cheap; all three stay.

### Test helpers (planned shape)

```ts
function makeRag(opts?: { chunks?: SemanticChunk[]; throwOn?: 'searchSemantic' }): RagService
function makeConnectivity(opts?: { initialOnline?: boolean }): ConnectivityService & {
  setOnline(b: boolean): void
}
function makeIpc(opts?: { key?: string; delayMs?: number; failWith?: Error }): VoiceChatIpc
function makeWebrtc(): { factory: (args: WebrtcFactoryArgs) => RtcTransportLike; callCount(): number }
function makeAgent(): { factory: (args: AgentFactoryArgs) => RealtimeAgentLike; lastArgs(): AgentFactoryArgs | null }
function makeSession(opts?: {
  connectImpl?: () => Promise<void>
  connectFailWith?: Error
  connectDelayMs?: number
}): {
  factory: (agent: RealtimeAgentLike, opts: SessionFactoryOpts) => RealtimeSessionLike
  session: RealtimeSessionLike
  mute: ReturnType<typeof vi.fn>
  interrupt: ReturnType<typeof vi.fn>
  close: ReturnType<typeof vi.fn>
  updateAgent: ReturnType<typeof vi.fn>
  fireEvent(name: string, ...args: unknown[]): void
}
function makeMedia(opts?: { denyMic?: boolean }): MediaPort & { stream: MediaStreamLike; audioElement: AudioElementLike }
function makeEffects(): EffectsPort
function makeClock(): ClockPort & { tick(ms: number): void }
function makeConfig(overrides?: Partial<VoiceChatConfig>): VoiceChatConfig
```

The fakes are ~200 lines total — larger than other services because the realtime SDK surface is wider. No `vi.mock`, no `vi.resetModules`, no global `navigator` mutation.

### Boundary test scenarios (committed)

Minimum 14 tests at the public interface. Tracks the major behaviors of the existing 29-test suite plus the new typed-event semantics.

1. **`activate` happy path (cold).** Setup: online, fake session connects, fake mic returns a stream. Assert: state transitions `idle → connecting → active`; `getUserMedia` called once; `webrtcFactory`, `agentFactory`, `sessionFactory` each called once; `session.connect({ apiKey: 'test-key' })` called; `session.mute(false)` called; `chatStatus` flows `connecting → idle`.
2. **`activate` while offline rejects with `OfflineError` synchronously.** Setup: `connectivity.setOnline(false)`. Assert: `activate()` rejects with `OfflineError`; state becomes `'offline'`; `getUserMedia` never called.
3. **`activate` warm path on same bookId.** Setup: session pre-installed for bookId 1 via a real `activate(1, ctx1)`; call `activate(1, ctx2)` with different `ctx`. Assert: `session.updateAgent(...)` called once; no new mic prompt; `session.mute(false)` called.
4. **`activate` warm path skips `updateAgent` when context fingerprint is unchanged.** Setup: same as Test 3 but `ctx2 === ctx1` semantically. Assert: `updateAgent` count unchanged from prior call.
5. **`activate` on a different bookId disposes the old session first.** Setup: session for bookId 1; call `activate(2, ctx)`. Assert: old `session.close()` called once; new session built; state ends at `'active'`.
6. **Concurrent `activate` calls share the in-flight promise.** Setup: fire `activate(7, ctx)` twice in parallel. Assert: `session.connect()` called exactly once; both promises resolve to `undefined`.
7. **Activation generation discards stale results.** Setup: `activate(1, ctx)` mid-flight (connect promise pending); call `activate(2, ctx)`. Resolve the first connect. Assert: state ends in whatever the second `activate` reached, not `'active'` from the first; the stale activation does not send `CONNECT_SUCCEEDED` to the machine.
8. **`deactivate` from active → `'paused'` + idle timer scheduled.** Setup: active session. Call `deactivate()`. Assert: `session.interrupt()` called; `session.mute(true)` called; state `'paused'`. Advance clock by `idleTimeoutMs`. Assert: state `'idle'`; `session.close()` called.
9. **Reactivate within idle timeout cancels the timer.** Setup: same as Test 8 then `activate(...)` partway through. Assert: clock advance past original idle does NOT close the session.
10. **Connectivity transition to offline mid-session disposes session + sets state `'offline'`.** Setup: active session. Call `connectivity.setOnline(false)`. Assert: `session.close()` called; state `'offline'`.
11. **Connectivity recovery from offline transitions `'offline' → 'idle'`.** Setup: state `'offline'`. Call `connectivity.setOnline(true)`. Assert: state `'idle'`; `error` cleared on machine.
12. **Mic denial classifies as `'mic_denied'` reason on the machine.** Setup: `makeMedia({ denyMic: true })`. Call `activate(1, ctx)`. Assert: rejection thrown; `getError()` returns `{ reason: 'mic_denied', message: <NotAllowedError msg> }`; state `'error'`.
13. **Connect timeout classifies as `'timeout'`; session half-built is torn down.** Setup: `makeSession({ connectDelayMs: 70_000 })`; `config.connectTimeoutMs = 60_000`. Call `activate(1, ctx)`; advance clock 61s. Assert: rejection; `getError().reason === 'timeout'`; `session.close()` called on the half-built session.
14. **`onStateChange` / `onChatStatus` / `onEndedByAgent` subscribers fire and unsubscribe cleanly.** Setup: subscribe to each with a spy; run a happy-path activate; fire the agent's `endConversation` tool callback via `makeSession`'s event injector. Assert: each spy called with expected payload; after `unsubscribe()`, no further invocations on subsequent transitions.

### Tests we explicitly do NOT add

- **Sentry capture site.** `captureError` is called inside the service; verifying it is not the service's contract.
- **The exact agent prompt template.** Owned by `buildRealtimeAgent`; covered by snapshot tests there.
- **The WebRTC handshake details.** The SDK's responsibility.
- **The 9-min key cache TTL.** Covered indirectly by Test 1 + a focused unit test inside the service test file ("two `prewarmKey()` calls within TTL → one IPC call") if needed; otherwise omitted as internal-only.
- **`buildRealtimeAgent`'s `bookContext` tool execution.** Covered separately at the agent layer; the service test verifies that `rag` is passed in.
- **The store's wiring.** Covered by `chatStore.test.ts`. The boundary test for the service doesn't poke the store.

### What inherited tests get deleted

- `src/renderer/src/modules/voiceChatService.test.ts` — 29 tests, all relying on `_resetForTests` / `_setSessionForTests` / module mocks. Replaced by the 14 boundary tests above.
- The previous `chatStore.test.ts` mock of `voiceChatService.actor` (lines 11-15) — replaced by mocks of the three `on*` subscription methods on `getVoiceChatService()`.

### What inherited tests are kept (moved)

- `machines/__tests__/voiceChatMachine.test.ts` → `services/voice-chat/machine.test.ts`. Same 12 tests, same assertions, file path change only.

## Open questions

These are open design questions the implementation plan should resolve. They are flagged but **not** decided in this spec.

1. **Should the service own conversation persistence?** Today voice chat is realtime-audio-only; no messages flow to `messagesCreate` or any other persistence. If/when text-mode chat lands (a separate feature), should the service emit message events and the wiring site persist them, or should the service call `ipc.messagesCreate` directly? *Lean: emit events; consumer wires persistence.* Rationale: the service should not know about conversation storage; that's the chat store's domain. The events `onAssistantMessage` / `onUserTranscript` flagged in the task description are deferred — they appear once message-emitting features land. Stage 1 ships the three events the realtime API actually needs today: `onStateChange`, `onChatStatus`, `onEndedByAgent`.

2. **Should `activate()` auto-stop a previous session if one is active, or reject?** *Lean: auto-stop (current behavior).* Single active session model. The user's intent in calling `activate(differentBookId)` is unambiguous — they want to chat about the new book. Rejecting would force callers to call `dispose()` first, which is redundant. Decision summary ratifies this lean.

3. **Where does the system prompt come from?** *Lean: config provides nothing; `buildRealtimeAgent` owns the prompt template and renders it inline using the `pageText` + `outline` the caller provides.* The current behavior. The agent factory is injected via the `agentFactory` port; the prompt template lives inside the agent file. If a future feature wants a user-customizable prompt, the config port grows a `systemPromptTemplate: string` field and the agent factory consumes it; no service-internal change. The book outline is not fetched by the service — the caller supplies it (today via `epubStore.bookOutline`). The service does not call `rag.getOutline(bookId)` because RAG has no such method; the outline comes from epubjs's TOC callback. Confirmed by reading `chatStore.startChat` and `buildRealtimeAgent`.

4. **Is the tiny `createEmitter<T>` duplicated or imported from another service?** *Lean: duplicate it inside `services/voice-chat/emitter.ts`* — services should not depend on each other's internals (the same lean stated in Sync open question #4). If a 4th service wants the same primitive, lift to `services/_shared/emitter.ts` then. Same lean as before; no new ground here.

5. **Should `buildRealtimeAgent.ts` move into `services/voice-chat/`?** *Lean: no — keep at `modules/buildRealtimeAgent.ts`.* It's ~110 lines of prompt template + tool-binding logic. Moving inside the service folder would (a) bloat the folder, (b) break the convention that `services/<x>/` contains lifecycle code, not template strings. The service injects `rag` as a parameter, severing the only remaining direct dep. If post-refactor the agent grows tightly coupled to service internals, revisit.

6. **Should `start()` be exposed and called at the wiring site, or fold into the first method call?** *Lean: explicit `start()` called at wiring time, mirrors Sync and Connectivity.* The cost is one extra line at the wiring site; the win is a consistent lifecycle shape across services. Tests that don't want the connectivity subscription skip `start()`. Decision summary ratifies.

## Stage 2 outlook

Stage 2 is explicit Effect-TS adoption *inside* a service, after Stage 1 ships. The meta-spec sets a rubric: Effect goes into a service only if it scores positively on ≥2 of 5 axes.

### Scoring Voice Chat against the rubric

| Axis | Score | Why |
|---|---|---|
| **Concurrency** | YES | Concurrent `activate` dedup, preconnect coordination with user-click race, multiple subscribers per event channel, idle-timer + connect-timeout races. `Effect.race`, `Effect.fork`, `Semaphore` handle all four cleanly. |
| **Retry / scheduling** | YES | Connect timeout (`Schedule.spaced` + `race`), 9-min key cache TTL (`Schedule.fixed`), idle timer (`Schedule.spaced(15min)` + interrupt). Three independent schedule shapes that `Schedule` composes. |
| **Resource lifecycle** | YES | WebRTC peer connection, microphone media stream, audio element, session event listeners — all need acquisition + release. `acquireRelease` + `Scope` is *exactly* this. The hand-rolled `sessionCleanup` closure is what `acquireRelease` replaces. |
| **Typed error channels** | YES | Five typed reasons (`timeout`, `mic_denied`, `auth_failed`, `connect_failed`, `session_error`). `Effect.catchTags` + tagged error classes turn the today-hand-rolled `classifyActivateError` switch into exhaustive pattern matching. Callers don't currently switch on them, but the *service-internal* error handling has five branches today and would benefit. |
| **Composed async pipeline** | YES | The cold-path pipeline is mic → audioElement → transport → agent → session → connect (race with timeout) → mute false → emit chat-status. That's a 7-step async pipeline with branching on `connectTimeout`, the activation generation, and the in-flight guard. `Effect.gen` is dramatically more readable than the current 100-line try/catch. |

**Score:** 5 of 5 axes. **Strongest Stage 2 candidate in the catalog**, beating TTS by one axis. The exception clause in the meta-spec (Effect at the *public* interface) is the only open question — see below.

### Stage 2 sketch

The public interface stays plain TS (`Promise<void>` from `activate`, callback `on*`, plain string state). Internally:

- **Cold-path pipeline → `Effect.gen` with `Scope`.** Mic → audioElement → transport → agent → session → connect → mute. Every resource registered via `acquireRelease`. The 100-line try/catch shrinks to ~30 lines of generator. Cancellation propagates automatically.
- **Activation in-flight + generation guard → `Semaphore.make(1)` + `Ref<number>`.** Concurrent `activate` calls block on the semaphore; if the generation changes mid-await, the current fiber is interrupted.
- **Connect timeout → `Effect.race(connect, sleep(60s).flatMap(() => fail(...)))`.** One line.
- **Idle timer → `Effect.race(stayActive, sleep(15min).flatMap(() => disposeEffect))`.** Replaces the `setTimeout` + manual cancel.
- **Key cache → `Cache.make({ ttl: 9.minutes })`.** Built-in.
- **Event channels → `SubscriptionRef` (state) + `Hub` (chat-status / endedByAgent).** Replaces `createEmitter<T>`.
- **Connectivity subscription → `Stream` consumed by a single fiber.** Offline transitions become a `Stream.filter` + branch.
- **Typed error channels.** Tagged errors per reason (`MicDeniedError`, `ConnectTimeoutError`, `AuthFailedError`, `SessionError`). `Effect.catchTags` at the boundary maps them to the public `Error` + machine event.
- **Public boundary.** Top-level `Effect.runPromise(activateProgram)` at `activate()`. Callers don't change.

### Exception-clause consideration

The meta-spec allows a service to propose Effect at its *public* interface with concrete justification. Voice Chat is the only service in the catalog with a plausible case:

- **Structured cancellation.** A user clicking "stop" mid-activate today fires `dispose()` which races against an in-flight `connect()` promise; the half-built session cleanup is hand-rolled. Effect's `Fiber.interrupt` propagates cancellation through the entire pipeline (mic stream, transport, session, RAG query inside agent-tool calls) automatically. The argument for Effect-at-the-boundary is that *callers* could `Fiber.interrupt(activateFiber)` instead of calling `dispose()` — cleaner contract.

**Lean: stay plain TS at the boundary.** Two reasons. (1) Every direct caller (`chatStore`, `epubStore`) would have to wrap in `Effect.runPromise` — that's two files, both shipping unchanged today. (2) The internal Effect program *can* model interruption without exposing it at the boundary; `dispose()` translates to `Fiber.interrupt` internally, and the externally-visible behavior is identical. The exception clause's bar ("concrete justification naming callers and failure modes") is not cleared.

This decision is **revisited in the Voice Chat Stage 2 spec** when it lands, not earlier.

### Stage 2 trigger

Per the meta-spec, Stage 2 starts only after **all six Stage 1 services have shipped**. This spec commits no Stage 2 work. The sketch above exists so the team can validate the public interface won't need to break when Stage 2 lands.

### Stopping rule

Per the meta-spec: if Stage 2 ergonomics are painful when TTS is retrofitted first, Effect is dropped from Stage 2 entirely and Voice Chat stays plain TS. The Stage 1 service from this spec is *unaffected* by that outcome — its public interface is the durable artifact.

## Definition of done

Per the meta-spec's standard. This service refactor ships when:

1. `src/renderer/src/services/voice-chat/index.ts` is the single public-facing module exporting `createVoiceChatService`, `VoiceChatService`, `OfflineError`, and the public types.
2. `src/renderer/src/services/index.ts` exports a `getVoiceChatService()` lazy singleton that calls `start()` on first construction.
3. All callers use `@/services`:
   - `chatStore.ts` subscribes via the three `on*` methods; activation guards (`_chatGeneration` / `_isStarting`) are deleted.
   - `epubStore.ts` calls `getVoiceChatService().prewarmKey() / dispose() / preconnect(...)`.
   - `buildRealtimeAgent.ts`'s signature gains `rag: RagService`; the `getRagService` import is removed.
4. The 3 old module files are **deleted**, not kept as shims:
   - `src/renderer/src/modules/voiceChatService.ts`
   - `src/renderer/src/modules/voiceChatService.test.ts`
   - `src/renderer/src/modules/realtime.ts`
5. The 2 machine files are **moved** to `services/voice-chat/`, not copied:
   - `machines/voiceChatMachine.ts` → `services/voice-chat/machine.ts`
   - `machines/__tests__/voiceChatMachine.test.ts` → `services/voice-chat/machine.test.ts`
6. The `chatStore.ts` is **shrunk** (~60 lines, down from 121) but not deleted; presentation-state lives there.
7. The `chatStore.test.ts` is updated to mock `@/services` (or the service factory); old `vi.mock('@/modules/voiceChatService', ...)` block removed.
8. All 14 boundary tests pass; all 12 moved machine tests still pass; remaining `chatStore.test.ts` tests pass.
9. `tsc`, `eslint`, `vitest` clean across the app.
10. Manual smoke (per the meta-spec's verification expectation): launch app, open a book, click voice launcher, verify session establishes; click stop, verify clean teardown; toggle airplane mode mid-session, verify offline state; reconnect, verify return to idle.

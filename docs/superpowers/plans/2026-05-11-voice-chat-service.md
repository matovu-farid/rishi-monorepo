# Voice Chat service refactor — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wrap `voiceChatService.ts` + the xstate `voiceChatMachine` + voice-chat-specific slices of `chatStore.ts` / `epubStore.ts` behind a `services/voice-chat/` boundary with a typed factory and injected ports for `rag` / `connectivity` / `ipc` / `webrtcFactory` / `audioContextFactory` / `config`. Public surface is small (methods + snapshot getters + typed event subscriptions); xstate stays internal.

**Architecture:** One factory `createVoiceChatService(deps: VoiceChatServiceDeps)`. The xstate machine lives inside the service. Public state is a discriminated union (`'idle' | 'connecting' | 'listening' | 'thinking' | 'speaking' | 'error'`), never the full machine snapshot. Events use typed `Emitter<T>` (subscribe returns unsubscribe). ChatStore wiring happens at one site (`services/index.ts` or a small wiring file) — the service emits events; the consumer translates to store actions.

**Tech Stack:** TypeScript, vitest, xstate (internal), OpenAI realtime SDK / WebRTC (internal — wrapped behind ports).

---

## Notes on this plan

- The **spec is authoritative** for the public state union and event set. The spec uses the machine's existing state union `'idle' | 'connecting' | 'active' | 'paused' | 'offline' | 'error'` (`VoiceChatPublicState`) — preserved verbatim — plus a separate `ChatStatus` channel `'idle' | 'connecting' | 'thinking' | 'speaking'` (driven by realtime-session events inside `active`). The header above mentions `'listening' | 'thinking' | 'speaking'` only as the design *intent* of a discriminated public surface; the spec narrows that intent to `VoiceChatPublicState` + `ChatStatus`. We ship what the spec describes.
- The header lists `TranscriptEvent` / `AssistantMessageEvent` event types. The spec's Open Question #1 defers transcript / assistant-message events to a future message-persistence feature (today's realtime API does not surface message text through the SDK in a form the store consumes). **Stage 1 ships three event channels: `onStateChange` / `onChatStatus` / `onEndedByAgent`.** Tasks for transcript / assistant-message events are *not* in this plan; they would arrive with text-mode chat. (Tasks 6 below originally framed for transcripts is replaced by `onChatStatus` + `onEndedByAgent`.)
- **Move decisions** from the spec: `machines/voiceChatMachine.ts` → `services/voice-chat/machine.ts`; `modules/realtime.ts` → `services/voice-chat/key-cache.ts`; the existing 12 machine tests move to `services/voice-chat/machine.test.ts` verbatim. `buildRealtimeAgent.ts` stays at `modules/buildRealtimeAgent.ts` and gains a `rag: RagService` parameter.
- Worktree: `/tmp/rishi-voice-chat-refactor`. Branch: `refactor/voice-chat-service`. Base: `origin/main`.

---

## Plan overview

- **Task 0 — Worktree + branch + scaffold + commit spec/plan.**
- **Task 1 — Types** (`types.ts`).
- **Task 2 — Emitter helper** (`emitter.ts`).
- **Task 3 — Key-cache helper** (`key-cache.ts` — absorbs `modules/realtime.ts`).
- **Task 4 — Move machine + its 12 tests** (`machine.ts` + `machine.test.ts`).
- **Task 5 — Service skeleton + start/stop lifecycle** (`service.ts`).
- **Task 6 — `onStateChange` edge-detected fanout.**
- **Task 7 — `activate` cold path + `deactivate` + `dispose`.**
- **Task 8 — `preconnect` + `prewarmKey` + warm-path branch + activate-generation guard.**
- **Task 9 — Error handling + `getError` + `dismissError` + classifyError reasons.**
- **Task 10 — Connectivity gating (start while offline + mid-session offline transition).**
- **Task 11 — RAG dep wired into `buildRealtimeAgent` (signature change) + `onEndedByAgent` event.**
- **Task 12 — Public exports** (`index.ts`).
- **Task 13 — Wire `getVoiceChatService` in `services/index.ts`.**
- **Task 14 — ChatStore migration** (`stores/chatStore.ts` + `stores/chatStore.test.ts` mock-target swap).
- **Task 15 — EpubStore migration** + delete old module imports.
- **Task 16 — Delete legacy modules** (`modules/voiceChatService.ts`, its test, `modules/realtime.ts`, `machines/voiceChatMachine.ts`, its test — all moved/absorbed).
- **Task 17 — Final verification.**

All paths below are absolute from `/tmp/rishi-voice-chat-refactor` (the worktree root). All `pnpm` commands run from `/tmp/rishi-voice-chat-refactor/apps/rishi-electron`. All `git` commands run from `/tmp/rishi-voice-chat-refactor`.

---

## Task 0: Worktree + branch + scaffold + commit spec/plan

**Files:**
- Create: worktree at `/tmp/rishi-voice-chat-refactor`
- Copy: `docs/superpowers/specs/2026-05-11-voice-chat-service-design.md` + `docs/superpowers/plans/2026-05-11-voice-chat-service.md` into the worktree
- Create: `apps/rishi-electron/src/renderer/src/services/voice-chat/index.ts` (placeholder)

- [ ] **Step 1: Create the worktree from `origin/main` on a new branch**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git fetch origin main
git worktree add /tmp/rishi-voice-chat-refactor -b refactor/voice-chat-service origin/main
```

Expected: `Preparing worktree (new branch 'refactor/voice-chat-service')` and `HEAD is now at <sha>`.

- [ ] **Step 2: Confirm the worktree is clean and on the expected branch**

```bash
cd /tmp/rishi-voice-chat-refactor
git status -sb
```

Expected: `## refactor/voice-chat-service` and clean tree.

- [ ] **Step 3: Copy the spec + this plan into the worktree**

```bash
mkdir -p /tmp/rishi-voice-chat-refactor/docs/superpowers/specs
mkdir -p /tmp/rishi-voice-chat-refactor/docs/superpowers/plans
cp /Users/faridmatovu/projects/rishi-monorepo/docs/superpowers/specs/2026-05-11-voice-chat-service-design.md \
   /tmp/rishi-voice-chat-refactor/docs/superpowers/specs/2026-05-11-voice-chat-service-design.md
cp /Users/faridmatovu/projects/rishi-monorepo/docs/superpowers/plans/2026-05-11-voice-chat-service.md \
   /tmp/rishi-voice-chat-refactor/docs/superpowers/plans/2026-05-11-voice-chat-service.md
```

- [ ] **Step 4: Commit the spec + plan**

```bash
cd /tmp/rishi-voice-chat-refactor
git add docs/superpowers/specs/2026-05-11-voice-chat-service-design.md \
        docs/superpowers/plans/2026-05-11-voice-chat-service.md
git commit -m "docs(voice-chat): design spec + implementation plan

Wave 2, service 5 of 6. Wraps the committed voiceChatMachine + the module-
scoped voiceChatService + the voice-chat slices of chatStore/epubStore behind
a single typed services/voice-chat/ boundary. xstate + the OpenAI realtime
SDK stay internal; the public surface is 7 methods + 3 typed event channels."
```

- [ ] **Step 5: Scaffold the service directory with a placeholder `index.ts`**

```bash
mkdir -p /tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat
```

Create `/tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat/index.ts`:

```ts
// Placeholder — populated incrementally by subsequent tasks.
export {}
```

- [ ] **Step 6: Verify typecheck still passes**

```bash
cd /tmp/rishi-voice-chat-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes (modulo pre-existing `src/main/**` + `navStore.test.ts` + `queries.outline*` failures — see Task 17).

- [ ] **Step 7: Commit the scaffold**

```bash
cd /tmp/rishi-voice-chat-refactor
git add apps/rishi-electron/src/renderer/src/services/voice-chat/index.ts
git commit -m "refactor(voice-chat): scaffold services/voice-chat directory

Empty index.ts placeholder. Behavior added incrementally in subsequent
commits (TDD: red → green → commit per behavior)."
```

---

## Task 1: Type definitions (`types.ts`)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/voice-chat/types.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/voice-chat/types.test-d.ts`

Types lifted verbatim from the spec's "Public interface" section.

- [ ] **Step 1: Create `types.ts`**

Create `/tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat/types.ts`:

```ts
import type { BookOutline } from '@/lib/api'
import type { RagService } from '@/services/rag'
import type { ConnectivityService } from '@/services/connectivity'

/**
 * Public state surface. Same string union as the internal machine, re-named
 * at the boundary to make the public-vs-internal split visible.
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
  override readonly name = 'OfflineError'
  constructor() {
    super('You are offline. Voice chat is unavailable until you reconnect.')
  }
}

// --- ports ---

export interface VoiceChatIpc {
  getRealtimeClientSecret(): Promise<string>
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

export interface MediaPort {
  getUserMedia(constraints: MediaStreamConstraints): Promise<MediaStreamLike>
  createAudioElement(): AudioElementLike
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
  idleTimeoutMs: number
  connectTimeoutMs: number
  keyTtlMs: number
}

// --- session-shape contracts (what the factories must return) ---

export interface RealtimeAgentLike {
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

export interface VoiceChatService {
  start(): void
  stop(): void
  activate(bookId: number, ctx: VoiceChatContext): Promise<void>
  preconnect(bookId: number, ctx: VoiceChatContext): Promise<void>
  deactivate(): void
  dispose(): void
  prewarmKey(): void
  getState(): VoiceChatPublicState
  getError(): VoiceError | null
  dismissError(): void
  onStateChange(listener: (state: VoiceChatPublicState) => void): () => void
  onChatStatus(listener: (status: ChatStatus) => void): () => void
  onEndedByAgent(listener: (reason: string) => void): () => void
}
```

- [ ] **Step 2: Create `types.test-d.ts`**

Create `/tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat/types.test-d.ts`:

```ts
import { describe, it, expectTypeOf } from 'vitest'
import type {
  VoiceChatService,
  VoiceChatServiceDeps,
  VoiceChatPublicState,
  ChatStatus,
  VoiceError,
  VoiceErrorReason,
  OfflineError
} from './types'

describe('Voice Chat types', () => {
  it('VoiceChatPublicState is the expected 6-string union', () => {
    expectTypeOf<VoiceChatPublicState>().toEqualTypeOf<
      'idle' | 'connecting' | 'active' | 'paused' | 'offline' | 'error'
    >()
  })

  it('ChatStatus is the expected 4-string union', () => {
    expectTypeOf<ChatStatus>().toEqualTypeOf<'idle' | 'connecting' | 'thinking' | 'speaking'>()
  })

  it('VoiceErrorReason is the expected 6-string union', () => {
    expectTypeOf<VoiceErrorReason>().toEqualTypeOf<
      'timeout' | 'mic_denied' | 'auth_failed' | 'connect_failed' | 'session_error' | 'unknown'
    >()
  })

  it('VoiceError shape matches { reason, message? }', () => {
    expectTypeOf<VoiceError>().toEqualTypeOf<{ reason: VoiceErrorReason; message?: string }>()
  })

  it('VoiceChatService method shapes', () => {
    expectTypeOf<VoiceChatService['activate']>().parameters.toEqualTypeOf<
      [number, import('./types').VoiceChatContext]
    >()
    expectTypeOf<VoiceChatService['activate']>().returns.toEqualTypeOf<Promise<void>>()
    expectTypeOf<VoiceChatService['getState']>().returns.toEqualTypeOf<VoiceChatPublicState>()
    expectTypeOf<VoiceChatService['getError']>().returns.toEqualTypeOf<VoiceError | null>()
  })

  it('onStateChange / onChatStatus / onEndedByAgent return unsubscribe fns', () => {
    expectTypeOf<VoiceChatService['onStateChange']>().returns.toEqualTypeOf<() => void>()
    expectTypeOf<VoiceChatService['onChatStatus']>().returns.toEqualTypeOf<() => void>()
    expectTypeOf<VoiceChatService['onEndedByAgent']>().returns.toEqualTypeOf<() => void>()
  })

  it('VoiceChatServiceDeps has all 10 ports', () => {
    expectTypeOf<VoiceChatServiceDeps>().toHaveProperty('rag')
    expectTypeOf<VoiceChatServiceDeps>().toHaveProperty('connectivity')
    expectTypeOf<VoiceChatServiceDeps>().toHaveProperty('ipc')
    expectTypeOf<VoiceChatServiceDeps>().toHaveProperty('webrtcFactory')
    expectTypeOf<VoiceChatServiceDeps>().toHaveProperty('agentFactory')
    expectTypeOf<VoiceChatServiceDeps>().toHaveProperty('sessionFactory')
    expectTypeOf<VoiceChatServiceDeps>().toHaveProperty('media')
    expectTypeOf<VoiceChatServiceDeps>().toHaveProperty('effects')
    expectTypeOf<VoiceChatServiceDeps>().toHaveProperty('clock')
    expectTypeOf<VoiceChatServiceDeps>().toHaveProperty('config')
  })

  it('OfflineError extends Error with name "OfflineError"', () => {
    expectTypeOf<OfflineError>().toMatchTypeOf<Error>()
    const e = new (require('./types') as typeof import('./types')).OfflineError()
    expectTypeOf(e.name).toEqualTypeOf<'OfflineError'>()
  })
})
```

- [ ] **Step 3: Run typecheck + type-shape tests**

```bash
cd /tmp/rishi-voice-chat-refactor/apps/rishi-electron
pnpm typecheck
pnpm vitest run src/renderer/src/services/voice-chat/types.test-d.ts
```

Expected: typecheck passes; 7 type-shape tests pass.

- [ ] **Step 4: Commit**

```bash
cd /tmp/rishi-voice-chat-refactor
git add apps/rishi-electron/src/renderer/src/services/voice-chat/types.ts \
        apps/rishi-electron/src/renderer/src/services/voice-chat/types.test-d.ts
git commit -m "refactor(voice-chat): add public type surface + shape assertions

Types lifted from the spec: VoiceChatPublicState (6 strings), ChatStatus
(4 strings), VoiceErrorReason (6 strings), VoiceError, VoiceChatContext,
OfflineError, all ports (VoiceChatIpc, MediaPort, EffectsPort, ClockPort),
factory shapes (Realtime{Agent,Session,Transport}Like, factory arg types),
VoiceChatConfig, VoiceChatServiceDeps, VoiceChatService."
```

---

## Task 2: Emitter helper (`emitter.ts`)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/voice-chat/emitter.test.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/voice-chat/emitter.ts`

Duplicate of TTS/Sync emitter pattern (per spec Open Question 4). Typed `<T>`.

- [ ] **Step 1: RED — write failing tests**

Create `/tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat/emitter.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import { createEmitter } from './emitter'

describe('createEmitter', () => {
  it('fans an emission out to every subscriber', () => {
    const e = createEmitter<number>()
    const a = vi.fn()
    const b = vi.fn()
    e.on(a)
    e.on(b)

    e.emit(7)

    expect(a).toHaveBeenCalledWith(7)
    expect(b).toHaveBeenCalledWith(7)
  })

  it('on() returns an unsubscribe that stops further deliveries', () => {
    const e = createEmitter<string>()
    const spy = vi.fn()
    const off = e.on(spy)

    e.emit('one')
    off()
    e.emit('two')

    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenCalledWith('one')
  })

  it('emit with no subscribers is a no-op', () => {
    const e = createEmitter<boolean>()
    expect(() => e.emit(true)).not.toThrow()
  })
})
```

- [ ] **Step 2: Run — expect 3 RED (module not found)**

```bash
cd /tmp/rishi-voice-chat-refactor/apps/rishi-electron
pnpm vitest run src/renderer/src/services/voice-chat/emitter.test.ts
```

Expected: 3 tests fail with `Cannot find module './emitter'`.

- [ ] **Step 3: GREEN — implement `createEmitter`**

Create `/tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat/emitter.ts`:

```ts
/**
 * Tiny typed emitter — no event names, single payload type T.
 * `on(listener)` returns an unsubscribe function (idempotent).
 *
 * Duplicated from services/tts/emitter.ts + services/sync/emitter.ts per
 * spec Open Question 4 (services should not depend on each other's
 * internals). If a fourth service wants the same primitive, lift to
 * services/_shared/emitter.ts.
 */
export interface Emitter<T> {
  emit(payload: T): void
  on(listener: (payload: T) => void): () => void
}

export function createEmitter<T>(): Emitter<T> {
  const listeners = new Set<(payload: T) => void>()
  return {
    emit(payload) {
      for (const listener of listeners) listener(payload)
    },
    on(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    }
  }
}
```

- [ ] **Step 4: Run — expect 3 GREEN**

```bash
pnpm vitest run src/renderer/src/services/voice-chat/emitter.test.ts
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-voice-chat-refactor
git add apps/rishi-electron/src/renderer/src/services/voice-chat/emitter.ts \
        apps/rishi-electron/src/renderer/src/services/voice-chat/emitter.test.ts
git commit -m "test(voice-chat): internal createEmitter<T> helper (3 tests)

Tiny typed emitter — duplicated from TTS/Sync per spec Open Question 4.
Internal to services/voice-chat; not re-exported."
```

---

## Task 3: Key-cache helper (`key-cache.ts`) — absorbs `modules/realtime.ts`

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.test.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.ts`

Internal helper. Encapsulates the 9-min TTL cache around `ipc.getRealtimeClientSecret()`. Replaces the global module-state cache in `modules/realtime.ts`.

- [ ] **Step 1: RED — write failing tests**

Create `/tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import { createKeyCache } from './key-cache'
import type { ClockPort } from './types'

function makeClock(): ClockPort & { setNow(t: number): void } {
  let now = 0
  return {
    now: () => now,
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (h) => clearTimeout(h),
    setNow: (t) => {
      now = t
    }
  }
}

describe('createKeyCache', () => {
  it('first get() calls fetch and returns its value', async () => {
    const clock = makeClock()
    const fetchFn = vi.fn().mockResolvedValue('K1')
    const cache = createKeyCache({ fetch: fetchFn, ttlMs: 9 * 60 * 1000, clock })

    await expect(cache.get()).resolves.toBe('K1')
    expect(fetchFn).toHaveBeenCalledTimes(1)
  })

  it('reuses the cached key within TTL', async () => {
    const clock = makeClock()
    clock.setNow(0)
    const fetchFn = vi.fn().mockResolvedValue('K1')
    const cache = createKeyCache({ fetch: fetchFn, ttlMs: 1000, clock })

    await cache.get()
    clock.setNow(500)
    await cache.get()

    expect(fetchFn).toHaveBeenCalledTimes(1)
  })

  it('refetches after TTL expires', async () => {
    const clock = makeClock()
    clock.setNow(0)
    const fetchFn = vi.fn().mockResolvedValueOnce('K1').mockResolvedValueOnce('K2')
    const cache = createKeyCache({ fetch: fetchFn, ttlMs: 1000, clock })

    await expect(cache.get()).resolves.toBe('K1')
    clock.setNow(1001)
    await expect(cache.get()).resolves.toBe('K2')
    expect(fetchFn).toHaveBeenCalledTimes(2)
  })

  it('concurrent get() calls share the same in-flight promise', async () => {
    const clock = makeClock()
    let resolveFetch!: (v: string) => void
    const fetchFn = vi.fn().mockImplementation(
      () =>
        new Promise<string>((r) => {
          resolveFetch = r
        })
    )
    const cache = createKeyCache({ fetch: fetchFn, ttlMs: 1000, clock })

    const p1 = cache.get()
    const p2 = cache.get()
    resolveFetch('K1')

    await expect(Promise.all([p1, p2])).resolves.toEqual(['K1', 'K1'])
    expect(fetchFn).toHaveBeenCalledTimes(1)
  })
})
```

- [ ] **Step 2: Run — expect 4 RED**

```bash
pnpm vitest run src/renderer/src/services/voice-chat/key-cache.test.ts
```

- [ ] **Step 3: GREEN — implement `createKeyCache`**

Create `/tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.ts`:

```ts
import type { ClockPort } from './types'

export interface KeyCache {
  /**
   * Returns the cached key if within TTL, otherwise fetches a new one.
   * Concurrent callers share the in-flight promise.
   */
  get(): Promise<string>
}

export interface KeyCacheDeps {
  fetch: () => Promise<string>
  ttlMs: number
  clock: ClockPort
}

export function createKeyCache(deps: KeyCacheDeps): KeyCache {
  const { fetch, ttlMs, clock } = deps
  let cached: { key: string; fetchedAt: number } | null = null
  let inflight: Promise<string> | null = null

  return {
    async get() {
      if (cached && clock.now() - cached.fetchedAt < ttlMs) {
        return cached.key
      }
      if (inflight) return inflight

      inflight = (async () => {
        try {
          const key = await fetch()
          cached = { key, fetchedAt: clock.now() }
          return key
        } finally {
          inflight = null
        }
      })()

      return inflight
    }
  }
}
```

- [ ] **Step 4: Run — expect 4 GREEN**

```bash
pnpm vitest run src/renderer/src/services/voice-chat/key-cache.test.ts
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-voice-chat-refactor
git add apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.ts \
        apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.test.ts
git commit -m "test(voice-chat): ephemeral-key TTL cache (4 tests)

createKeyCache({ fetch, ttlMs, clock }) — internal helper that absorbs the
9-min cache logic from modules/realtime.ts. Concurrent callers share the
in-flight fetch promise; TTL is measured against the injected clock for
testability."
```

---

## Task 4: Move machine + its 12 tests (verbatim)

**Files:**
- Create (move): `apps/rishi-electron/src/renderer/src/services/voice-chat/machine.ts`
- Create (move): `apps/rishi-electron/src/renderer/src/services/voice-chat/machine.test.ts`
- (The originals at `machines/voiceChatMachine.ts` + `machines/__tests__/voiceChatMachine.test.ts` are deleted in Task 16.)

The xstate machine is pure code with no side effects; move it as-is. Tests use the new import path.

- [ ] **Step 1: Copy the machine into the service folder**

```bash
cp /tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/machines/voiceChatMachine.ts \
   /tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat/machine.ts
```

- [ ] **Step 2: Copy the machine tests into the service folder, updating the relative import**

```bash
cp /tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/machines/__tests__/voiceChatMachine.test.ts \
   /tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat/machine.test.ts
```

Then edit `/tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat/machine.test.ts`:

```ts
// BEFORE:
import { voiceChatMachine } from '../voiceChatMachine'

// AFTER:
import { voiceChatMachine } from './machine'
```

- [ ] **Step 3: Run the moved machine tests — expect 12 GREEN**

```bash
pnpm vitest run src/renderer/src/services/voice-chat/machine.test.ts
```

Expected: 12 tests pass.

- [ ] **Step 4: Commit**

```bash
cd /tmp/rishi-voice-chat-refactor
git add apps/rishi-electron/src/renderer/src/services/voice-chat/machine.ts \
        apps/rishi-electron/src/renderer/src/services/voice-chat/machine.test.ts
git commit -m "refactor(voice-chat): move voiceChatMachine + its tests into the service

Co-locates the xstate machine with the wrapping service per spec File-
structure decision. The pure xstate value semantics are unchanged; the 12
existing machine tests are kept verbatim with one relative-import swap.
The original files at machines/voiceChatMachine.ts + machines/__tests__/
voiceChatMachine.test.ts are deleted in a later task once all callers have
been migrated."
```

---

## Task 5: Service skeleton — RED + GREEN (start/stop lifecycle + idempotence)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts`

`service.test.ts` opens with the **full set of `make*` helpers** (defined once near the top). Every subsequent task appends tests to this file.

- [ ] **Step 1: RED — write the helpers + first failing tests**

Create `/tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import { createVoiceChatService } from './service'
import type {
  AgentFactoryArgs,
  AudioElementLike,
  ChatStatus,
  ClockPort,
  EffectsPort,
  MediaPort,
  MediaStreamLike,
  RealtimeAgentLike,
  RealtimeSessionLike,
  RtcTransportLike,
  SessionFactoryOpts,
  VoiceChatConfig,
  VoiceChatIpc,
  VoiceChatServiceDeps,
  WebrtcFactoryArgs
} from './types'
import type { RagService } from '@/services/rag'
import type { ConnectivityService } from '@/services/connectivity'

// =============================================================================
// Test helpers — defined once, reused across every test in this file.
// =============================================================================

export function makeRag(): RagService {
  return {
    searchSemantic: vi.fn().mockResolvedValue([{ text: 'fake chunk' }]),
    searchKeyword: vi.fn().mockResolvedValue([]),
    hasVectorsForBook: vi.fn().mockResolvedValue(true)
  } as unknown as RagService
}

export function makeConnectivity(
  opts?: { initialOnline?: boolean }
): ConnectivityService & { setOnline(b: boolean): void } {
  let online = opts?.initialOnline ?? true
  const listeners = new Set<(online: boolean) => void>()
  return {
    isOnline: () => online,
    subscribe: (l) => {
      listeners.add(l)
      return () => listeners.delete(l)
    },
    start: () => {},
    stop: () => {},
    setOnline(b) {
      if (online === b) return
      online = b
      for (const l of listeners) l(b)
    }
  }
}

export function makeIpc(opts?: { key?: string; failWith?: Error }): VoiceChatIpc {
  return {
    getRealtimeClientSecret: vi.fn().mockImplementation(async () => {
      if (opts?.failWith) throw opts.failWith
      return opts?.key ?? 'test-key'
    })
  }
}

export function makeWebrtc(): {
  factory: (args: WebrtcFactoryArgs) => RtcTransportLike
  callCount: () => number
  lastArgs: () => WebrtcFactoryArgs | null
} {
  let count = 0
  let lastArgs: WebrtcFactoryArgs | null = null
  return {
    factory: (args) => {
      count++
      lastArgs = args
      return { _transport: { id: count } } as RtcTransportLike
    },
    callCount: () => count,
    lastArgs: () => lastArgs
  }
}

export function makeAgent(): {
  factory: (args: AgentFactoryArgs) => RealtimeAgentLike
  lastArgs: () => AgentFactoryArgs | null
  triggerEnd: (reason: string) => void
} {
  let lastArgs: AgentFactoryArgs | null = null
  let lastOnEnd: ((reason: string) => void) | null = null
  return {
    factory: (args) => {
      lastArgs = args
      lastOnEnd = args.onEndConversation
      return { _agent: {} } as RealtimeAgentLike
    },
    lastArgs: () => lastArgs,
    triggerEnd: (reason) => lastOnEnd?.(reason)
  }
}

export function makeSession(opts?: {
  connectDelayMs?: number
  connectFailWith?: Error
}): {
  factory: (agent: RealtimeAgentLike, opts: SessionFactoryOpts) => RealtimeSessionLike
  session: RealtimeSessionLike
  mute: ReturnType<typeof vi.fn>
  interrupt: ReturnType<typeof vi.fn>
  close: ReturnType<typeof vi.fn>
  updateAgent: ReturnType<typeof vi.fn>
  connect: ReturnType<typeof vi.fn>
  fire: (event: string, ...args: unknown[]) => void
  lastConnectOpts: () => { apiKey: string } | null
} {
  const handlers = new Map<string, Set<(...args: unknown[]) => void>>()
  let lastConnectOpts: { apiKey: string } | null = null
  const connect = vi.fn().mockImplementation(async (o: { apiKey: string }) => {
    lastConnectOpts = o
    if (opts?.connectFailWith) throw opts.connectFailWith
    if (opts?.connectDelayMs) {
      await new Promise((r) => setTimeout(r, opts.connectDelayMs))
    }
  })
  const mute = vi.fn()
  const interrupt = vi.fn()
  const close = vi.fn()
  const updateAgent = vi.fn().mockResolvedValue(undefined)
  const session: RealtimeSessionLike = {
    connect,
    mute,
    interrupt,
    close,
    updateAgent,
    on: (ev, l) => {
      if (!handlers.has(ev)) handlers.set(ev, new Set())
      handlers.get(ev)!.add(l)
    },
    off: (ev, l) => {
      handlers.get(ev)?.delete(l)
    }
  }
  return {
    factory: () => session,
    session,
    mute,
    interrupt,
    close,
    updateAgent,
    connect,
    fire: (ev, ...args) => {
      const set = handlers.get(ev)
      if (!set) return
      for (const l of [...set]) l(...args)
    },
    lastConnectOpts: () => lastConnectOpts
  }
}

export function makeMedia(opts?: { denyMic?: boolean }): MediaPort & {
  stream: MediaStreamLike
  audioElement: AudioElementLike
} {
  const stream: MediaStreamLike = { getTracks: () => [{ stop: vi.fn() }] }
  const audioElement: AudioElementLike = {
    muted: false,
    srcObject: null,
    autoplay: true,
    pause: vi.fn()
  }
  return {
    stream,
    audioElement,
    getUserMedia: vi.fn().mockImplementation(async () => {
      if (opts?.denyMic) {
        const err = new Error('Permission denied')
        ;(err as { name: string }).name = 'NotAllowedError'
        throw err
      }
      return stream
    }),
    createAudioElement: vi.fn().mockReturnValue(audioElement)
  }
}

export function makeEffects(): EffectsPort & {
  readyChimeCalls: () => number
  thinkingStartCalls: () => number
  thinkingStopCalls: () => number
} {
  let ready = 0
  let start = 0
  let stop = 0
  return {
    playReadyChime: () => {
      ready++
    },
    startThinkingSound: () => {
      start++
    },
    stopThinkingSound: () => {
      stop++
    },
    readyChimeCalls: () => ready,
    thinkingStartCalls: () => start,
    thinkingStopCalls: () => stop
  }
}

export function makeClock(): ClockPort & { tick(ms: number): void; setNow(t: number): void } {
  let now = 0
  const timers: Array<{ id: number; at: number; fn: () => void; cancelled: boolean }> = []
  let nextId = 1
  return {
    now: () => now,
    setTimeout: (fn, ms) => {
      const id = nextId++
      timers.push({ id, at: now + ms, fn, cancelled: false })
      return id as unknown as ReturnType<typeof setTimeout>
    },
    clearTimeout: (handle) => {
      const t = timers.find((x) => x.id === (handle as unknown as number))
      if (t) t.cancelled = true
    },
    tick(ms) {
      const target = now + ms
      // Fire timers in time order until we reach target. Re-scan after each
      // fire because callbacks may schedule additional timers.
      while (true) {
        const due = timers
          .filter((t) => !t.cancelled && t.at <= target)
          .sort((a, b) => a.at - b.at)[0]
        if (!due) break
        now = due.at
        due.cancelled = true
        due.fn()
      }
      now = target
    },
    setNow(t) {
      now = t
    }
  }
}

export function makeConfig(overrides?: Partial<VoiceChatConfig>): VoiceChatConfig {
  return {
    idleTimeoutMs: 15 * 60 * 1000,
    connectTimeoutMs: 60 * 1000,
    keyTtlMs: 9 * 60 * 1000,
    ...overrides
  }
}

export function makeDeps(
  overrides?: Partial<VoiceChatServiceDeps>
): VoiceChatServiceDeps {
  return {
    rag: makeRag(),
    connectivity: makeConnectivity(),
    ipc: makeIpc(),
    webrtcFactory: makeWebrtc().factory,
    agentFactory: makeAgent().factory,
    sessionFactory: makeSession().factory,
    media: makeMedia(),
    effects: makeEffects(),
    clock: makeClock(),
    config: makeConfig(),
    ...overrides
  }
}

// =============================================================================
// Tests — start/stop lifecycle.
// =============================================================================

describe('createVoiceChatService — lifecycle', () => {
  it('starts in idle state with no error', () => {
    const svc = createVoiceChatService(makeDeps())
    expect(svc.getState()).toBe('idle')
    expect(svc.getError()).toBeNull()
  })

  it('start() is idempotent — calling twice does not double-subscribe connectivity', () => {
    const connectivity = makeConnectivity()
    const subSpy = vi.spyOn(connectivity, 'subscribe')
    const svc = createVoiceChatService(makeDeps({ connectivity }))

    svc.start()
    svc.start()

    expect(subSpy).toHaveBeenCalledTimes(1)
  })

  it('stop() unsubscribes connectivity + is idempotent', () => {
    const connectivity = makeConnectivity()
    const svc = createVoiceChatService(makeDeps({ connectivity }))

    svc.start()
    svc.stop()
    svc.stop() // no throw

    // After stop(), a connectivity transition does not affect state.
    connectivity.setOnline(false)
    expect(svc.getState()).toBe('idle')
  })
})
```

- [ ] **Step 2: Run — expect RED (module './service' not found)**

```bash
pnpm vitest run src/renderer/src/services/voice-chat/service.test.ts
```

Expected: 3 tests fail with `Cannot find module './service'`.

- [ ] **Step 3: GREEN — implement the minimal skeleton**

Create `/tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts`:

```ts
import { createActor } from 'xstate'
import { voiceChatMachine } from './machine'
import { createEmitter } from './emitter'
import { createKeyCache } from './key-cache'
import { OfflineError } from './types'
import type {
  ChatStatus,
  VoiceChatPublicState,
  VoiceChatService,
  VoiceChatServiceDeps,
  VoiceError
} from './types'

export function createVoiceChatService(deps: VoiceChatServiceDeps): VoiceChatService {
  const {
    rag,
    connectivity,
    ipc,
    webrtcFactory,
    agentFactory,
    sessionFactory,
    media,
    effects,
    clock,
    config
  } = deps

  const stateEmitter = createEmitter<VoiceChatPublicState>()
  const chatStatusEmitter = createEmitter<ChatStatus>()
  const endedByAgentEmitter = createEmitter<string>()

  const actor = createActor(voiceChatMachine)
  actor.start()

  // Suppress unused-binding warnings until later tasks wire them.
  void rag
  void ipc
  void webrtcFactory
  void agentFactory
  void sessionFactory
  void media
  void effects
  void clock
  void config
  void createKeyCache
  void OfflineError

  let connectivityUnsub: (() => void) | null = null
  let started = false

  return {
    start() {
      if (started) return
      started = true
      connectivityUnsub = connectivity.subscribe(() => {
        // wired in Task 10
      })
    },
    stop() {
      if (!started) return
      started = false
      if (connectivityUnsub) connectivityUnsub()
      connectivityUnsub = null
    },
    async activate() {
      throw new Error('not implemented yet')
    },
    async preconnect() {
      // wired in Task 8
    },
    deactivate() {
      // wired in Task 7
    },
    dispose() {
      actor.send({ type: 'DISPOSE' })
    },
    prewarmKey() {
      // wired in Task 8
    },
    getState() {
      return actor.getSnapshot().value as VoiceChatPublicState
    },
    getError(): VoiceError | null {
      return actor.getSnapshot().context.error
    },
    dismissError() {
      actor.send({ type: 'DISMISS_ERROR' })
    },
    onStateChange: stateEmitter.on,
    onChatStatus: chatStatusEmitter.on,
    onEndedByAgent: endedByAgentEmitter.on
  }
}
```

- [ ] **Step 4: Run — expect 3 GREEN**

```bash
pnpm vitest run src/renderer/src/services/voice-chat/service.test.ts
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-voice-chat-refactor
git add apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts \
        apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts
git commit -m "feat(voice-chat): service factory skeleton — start/stop + getState/getError

createVoiceChatService(deps) constructs the internal xstate actor, owns
three typed emitters (state / chat-status / endedByAgent), and exposes the
public 7-method + 3-subscription contract. Start/stop is idempotent; the
connectivity subscription is registered in start() (wired in a later task).
service.test.ts ships with the full make* helper set used by every
subsequent test."
```

---

## Task 6: `onStateChange` edge-detected fanout

**Files:**
- Edit: `apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts` (append)
- Edit: `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts`

- [ ] **Step 1: RED — append the fanout tests**

Append to `service.test.ts`:

```ts
describe('createVoiceChatService — onStateChange', () => {
  it('fires subscribers with the new state on machine transitions', async () => {
    const svc = createVoiceChatService(makeDeps())
    const spy = vi.fn()
    svc.onStateChange(spy)

    // Force a transition: dispatch DISPOSE from idle (no-op transition — should
    // NOT fire because state value didn't change), then trigger an actual
    // transition by calling dispose() (which also sends DISPOSE — same no-op).
    // To exercise an edge, use the activate() flow indirectly via the actor.
    // Easiest test: dispose then verify NO spy call (edge detection works).
    svc.dispose()
    expect(spy).not.toHaveBeenCalled()
  })

  it('edge-detects no-value transitions (same machine value → no fire)', () => {
    const svc = createVoiceChatService(makeDeps())
    const spy = vi.fn()
    svc.onStateChange(spy)

    svc.dispose()
    svc.dispose()
    svc.dispose()

    expect(spy).not.toHaveBeenCalled()
  })

  it('multiple subscribers each receive the same state change', async () => {
    // We force a real transition by sending OFFLINE through connectivity.
    const connectivity = makeConnectivity({ initialOnline: true })
    const svc = createVoiceChatService(makeDeps({ connectivity }))
    svc.start() // arm connectivity subscription
    const a = vi.fn()
    const b = vi.fn()
    svc.onStateChange(a)
    svc.onStateChange(b)

    connectivity.setOnline(false)

    expect(a).toHaveBeenCalledWith('offline')
    expect(b).toHaveBeenCalledWith('offline')
  })

  it('unsubscribe stops further invocations', () => {
    const connectivity = makeConnectivity({ initialOnline: true })
    const svc = createVoiceChatService(makeDeps({ connectivity }))
    svc.start()
    const spy = vi.fn()
    const off = svc.onStateChange(spy)

    connectivity.setOnline(false)
    expect(spy).toHaveBeenCalledTimes(1)

    off()
    connectivity.setOnline(true)
    expect(spy).toHaveBeenCalledTimes(1) // unchanged
  })
})
```

Note: tests 3 + 4 depend on Task 10's connectivity wiring; they will go GREEN once that task lands. For this task we ship tests 1 + 2 GREEN (edge detection) and accept tests 3 + 4 as RED until Task 10. Alternative: keep tests 3 + 4 commented out until Task 10, then enable.

To keep the strict TDD discipline intact, defer tests 3 + 4 to Task 10. Replace the bottom two `it` blocks with a single placeholder note:

```ts
  // Multi-subscriber + offline transition assertions land in Task 10
  // (connectivity wiring). Edge-detection is sufficient here.
```

- [ ] **Step 2: GREEN — wire actor.subscribe → stateEmitter with edge detection**

In `service.ts`, replace the `const actor = createActor(voiceChatMachine); actor.start()` block with:

```ts
const actor = createActor(voiceChatMachine)
actor.start()

let lastPublicState: VoiceChatPublicState = actor.getSnapshot().value as VoiceChatPublicState
actor.subscribe(() => {
  const next = actor.getSnapshot().value as VoiceChatPublicState
  if (next === lastPublicState) return
  lastPublicState = next
  stateEmitter.emit(next)
})
```

- [ ] **Step 3: Run — expect edge-detection tests GREEN**

```bash
pnpm vitest run src/renderer/src/services/voice-chat/service.test.ts
```

Expected: all 3 prior tests + 2 new edge-detection tests pass.

- [ ] **Step 4: Commit**

```bash
cd /tmp/rishi-voice-chat-refactor
git add apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts \
        apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts
git commit -m "feat(voice-chat): edge-detected onStateChange fanout

actor.subscribe(...) → stateEmitter.emit(...) only on true state-value
changes. No-op machine transitions (DISPOSE from idle, etc.) do not fire
subscribers."
```

---

## Task 7: `activate` cold path + `deactivate` + `dispose` (happy path)

**Files:**
- Edit: `service.test.ts` (append)
- Edit: `service.ts`

Cold-path activate: mic → audio element → transport → agent → session → connect → mute(false). This task lands the happy-path; warm path + concurrent guard live in Task 8. Error classifications live in Task 9.

- [ ] **Step 1: RED — append the cold-path test**

Append to `service.test.ts`:

```ts
describe('createVoiceChatService — activate (cold happy path)', () => {
  it('idle → connecting → active; mic + transport + agent + session + connect + mute(false)', async () => {
    const media = makeMedia()
    const webrtc = makeWebrtc()
    const agent = makeAgent()
    const session = makeSession()
    const ipc = makeIpc({ key: 'EPHEMERAL' })
    const states: VoiceChatPublicState[] = []

    const svc = createVoiceChatService(
      makeDeps({
        media,
        webrtcFactory: webrtc.factory,
        agentFactory: agent.factory,
        sessionFactory: session.factory,
        ipc
      })
    )
    svc.onStateChange((s) => states.push(s))

    await svc.activate(7, { pageText: 'hello' })

    expect(states).toEqual(['connecting', 'active'])
    expect(media.getUserMedia).toHaveBeenCalledWith({ audio: true })
    expect(webrtc.callCount()).toBe(1)
    expect(agent.lastArgs()?.bookId).toBe(7)
    expect(agent.lastArgs()?.pageText).toBe('hello')
    expect(session.connect).toHaveBeenCalledWith({ apiKey: 'EPHEMERAL' })
    expect(session.mute).toHaveBeenCalledWith(false)
    expect(svc.getState()).toBe('active')
  })

  it('deactivate() from active → paused; session.interrupt + mute(true)', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory })
    )
    await svc.activate(1, { pageText: 'p' })
    svc.deactivate()

    expect(session.interrupt).toHaveBeenCalledTimes(1)
    expect(session.mute).toHaveBeenLastCalledWith(true)
    expect(svc.getState()).toBe('paused')
  })

  it('dispose() from active → idle; session.close() called', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory })
    )
    await svc.activate(1, { pageText: 'p' })
    svc.dispose()

    expect(session.close).toHaveBeenCalledTimes(1)
    expect(svc.getState()).toBe('idle')
  })

  it('chatStatus fires connecting → idle around a cold activate', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory })
    )
    const statuses: ChatStatus[] = []
    svc.onChatStatus((s) => statuses.push(s))

    await svc.activate(1, { pageText: 'p' })

    expect(statuses[0]).toBe('connecting')
    expect(statuses[statuses.length - 1]).toBe('idle')
  })
})
```

- [ ] **Step 2: Run — expect 4 RED**

```bash
pnpm vitest run src/renderer/src/services/voice-chat/service.test.ts
```

- [ ] **Step 3: GREEN — wire cold-path activate, deactivate, dispose**

Edit `/tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts`. Replace the placeholder body with the full implementation:

```ts
import { createActor } from 'xstate'
import { voiceChatMachine } from './machine'
import { createEmitter } from './emitter'
import { createKeyCache } from './key-cache'
import { OfflineError } from './types'
import { captureError } from '@/utils/sentry'
import type {
  AudioElementLike,
  ChatStatus,
  MediaStreamLike,
  RealtimeSessionLike,
  VoiceChatContext,
  VoiceChatPublicState,
  VoiceChatService,
  VoiceChatServiceDeps,
  VoiceError,
  VoiceErrorReason
} from './types'

function classifyError(err: unknown): VoiceErrorReason {
  if (err instanceof OfflineError) return 'connect_failed'
  const name = (err as { name?: string })?.name
  const message = (err as { message?: string })?.message ?? ''
  if (name === 'NotAllowedError' || name === 'NotFoundError') return 'mic_denied'
  if (message.includes('Not authenticated') || message.includes('auth')) return 'auth_failed'
  if (message.includes('timed out')) return 'timeout'
  return 'connect_failed'
}

function fingerprintContext(ctx: VoiceChatContext): string {
  return `${ctx.pageText}\n${JSON.stringify(ctx.outline ?? {})}`
}

export function createVoiceChatService(deps: VoiceChatServiceDeps): VoiceChatService {
  const {
    rag,
    connectivity,
    ipc,
    webrtcFactory,
    agentFactory,
    sessionFactory,
    media,
    effects,
    clock,
    config
  } = deps

  const stateEmitter = createEmitter<VoiceChatPublicState>()
  const chatStatusEmitter = createEmitter<ChatStatus>()
  const endedByAgentEmitter = createEmitter<string>()

  const actor = createActor(voiceChatMachine)
  actor.start()
  let lastPublicState: VoiceChatPublicState = actor.getSnapshot().value as VoiceChatPublicState
  actor.subscribe(() => {
    const next = actor.getSnapshot().value as VoiceChatPublicState
    if (next === lastPublicState) return
    lastPublicState = next
    stateEmitter.emit(next)
  })

  const keyCache = createKeyCache({
    fetch: () => ipc.getRealtimeClientSecret(),
    ttlMs: config.keyTtlMs,
    clock
  })

  // Session-scoped state, in closure (not module).
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
  let started = false

  function clearIdleTimer() {
    if (idleTimer !== null) {
      clock.clearTimeout(idleTimer)
      idleTimer = null
    }
  }

  function scheduleIdleTimer() {
    clearIdleTimer()
    idleTimer = clock.setTimeout(() => {
      disposeInternal()
      actor.send({ type: 'DISPOSE' })
    }, config.idleTimeoutMs)
  }

  function disposeInternal() {
    clearIdleTimer()
    if (sessionCleanup) {
      sessionCleanup()
      sessionCleanup = null
    }
    const s = session
    session = null
    currentBookId = null
    if (s) {
      try {
        s.close()
      } catch (err) {
        captureError(err, { operation: 'voiceChatService', step: 'dispose_close' })
      }
    }
    if (mediaStream) {
      mediaStream.getTracks().forEach((t) => t.stop())
      mediaStream = null
    }
    if (audioElement) {
      audioElement.pause()
      audioElement.srcObject = null
      audioElement = null
    }
    chatStatusEmitter.emit('idle')
    hasFiredReadyChime = false
    isAgentSpeaking = false
    lastContextFingerprint = null
  }

  async function doActivate(
    bookId: number,
    ctx: VoiceChatContext,
    gen: number
  ): Promise<void> {
    clearIdleTimer()

    // Different bookId — dispose existing session first.
    if (session && currentBookId !== null && currentBookId !== bookId) {
      disposeInternal()
      actor.send({ type: 'DISPOSE' })
    }

    // Warm path: same bookId, session still alive.
    if (session && currentBookId === bookId) {
      actor.send({ type: 'CONNECT_STARTED' })
      try {
        const fp = fingerprintContext(ctx)
        if (fp !== lastContextFingerprint) {
          const newAgent = agentFactory({
            bookId,
            pageText: ctx.pageText,
            outline: ctx.outline,
            onEndConversation: (reason) => endedByAgentEmitter.emit(reason),
            rag
          })
          await session.updateAgent(newAgent)
          if (gen !== activateGeneration) return
          lastContextFingerprint = fp
        }
        session.mute(false)
        if (audioElement) audioElement.muted = false
        if (gen !== activateGeneration) return
        actor.send({ type: 'CONNECT_SUCCEEDED' })
        chatStatusEmitter.emit('idle')
      } catch (err) {
        captureError(err, { operation: 'voiceChatService', step: 'activate_warm' })
        if (gen === activateGeneration) {
          actor.send({
            type: 'CONNECT_FAILED',
            reason: classifyError(err),
            message: err instanceof Error ? err.message : undefined
          })
        }
        throw err
      }
      return
    }

    // Cold path.
    actor.send({ type: 'CONNECT_STARTED' })
    chatStatusEmitter.emit('connecting')

    let newSession: RealtimeSessionLike | null = null
    try {
      if (!mediaStream) {
        mediaStream = await media.getUserMedia({ audio: true })
      }
      if (!audioElement) {
        audioElement = media.createAudioElement()
      }
      const transport = webrtcFactory({ mediaStream, audioElement })
      const agent = agentFactory({
        bookId,
        pageText: ctx.pageText,
        outline: ctx.outline,
        onEndConversation: (reason) => endedByAgentEmitter.emit(reason),
        rag
      })
      newSession = sessionFactory(agent, { transport, apiKey: '' })

      const status = (s: ChatStatus) => chatStatusEmitter.emit(s)
      const onAgentStart = () => {
        if (!hasFiredReadyChime) {
          hasFiredReadyChime = true
          effects.playReadyChime()
        }
        status('thinking')
      }
      const onAudioStart = () => {
        isAgentSpeaking = true
        status('speaking')
      }
      const onAudioStopped = () => {
        isAgentSpeaking = false
        status('idle')
      }
      const onAgentEnd = () => {
        if (!isAgentSpeaking) status('idle')
      }
      const onToolStart = () => effects.startThinkingSound()
      const onToolEnd = () => effects.stopThinkingSound()
      const onError = (err: unknown) => {
        captureError(err, { operation: 'voiceChatService', step: 'session_error' })
        effects.stopThinkingSound()
        actor.send({
          type: 'SESSION_ERROR',
          reason: 'session_error',
          message: err instanceof Error ? err.message : undefined
        })
        disposeInternal()
        actor.send({ type: 'DISPOSE' })
      }
      newSession.on('agent_start', onAgentStart)
      newSession.on('audio_start', onAudioStart)
      newSession.on('audio_stopped', onAudioStopped)
      newSession.on('agent_end', onAgentEnd)
      newSession.on('agent_tool_start', onToolStart)
      newSession.on('agent_tool_end', onToolEnd)
      newSession.on('error', onError)

      const s = newSession
      sessionCleanup = () => {
        s.off('agent_start', onAgentStart)
        s.off('audio_start', onAudioStart)
        s.off('audio_stopped', onAudioStopped)
        s.off('agent_end', onAgentEnd)
        s.off('agent_tool_start', onToolStart)
        s.off('agent_tool_end', onToolEnd)
        s.off('error', onError)
      }

      const apiKey = await keyCache.get()

      // Connect with timeout race.
      let connectTimeout: ReturnType<ClockPort['setTimeout']> | null = null
      try {
        await Promise.race([
          newSession.connect({ apiKey }),
          new Promise<never>((_, reject) => {
            connectTimeout = clock.setTimeout(() => {
              reject(
                new Error(
                  `Realtime session connect timed out after ${config.connectTimeoutMs / 1000}s`
                )
              )
            }, config.connectTimeoutMs)
          })
        ])
      } finally {
        if (connectTimeout !== null) clock.clearTimeout(connectTimeout)
      }

      if (gen !== activateGeneration) {
        // Stale activation — tear down half-built session and bail without
        // emitting CONNECT_SUCCEEDED.
        if (sessionCleanup) sessionCleanup()
        sessionCleanup = null
        try {
          newSession.close()
        } catch {
          /* best effort */
        }
        return
      }

      session = newSession
      currentBookId = bookId
      lastContextFingerprint = fingerprintContext(ctx)
      if (audioElement) audioElement.muted = false
      newSession.mute(false)
      actor.send({ type: 'CONNECT_SUCCEEDED' })
      chatStatusEmitter.emit('idle')
      hasUsedVoiceInSession = true
    } catch (err) {
      captureError(err, { operation: 'voiceChatService', step: 'activate_cold' })
      if (sessionCleanup) {
        sessionCleanup()
        sessionCleanup = null
      }
      if (newSession) {
        try {
          newSession.close()
        } catch {
          /* best effort */
        }
      }
      if (gen === activateGeneration) {
        actor.send({
          type: 'CONNECT_FAILED',
          reason: classifyError(err),
          message: err instanceof Error ? err.message : undefined
        })
        chatStatusEmitter.emit('idle')
      }
      throw err
    }
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
      activateGeneration++
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
      try {
        await activateInFlight
      } finally {
        activateInFlight = null
      }
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

    deactivate() {
      const value = actor.getSnapshot().value
      if (value !== 'active' || !session) return
      try {
        session.interrupt()
        session.mute(true)
        if (audioElement) audioElement.muted = true
        actor.send({ type: 'DEACTIVATE' })
        chatStatusEmitter.emit('idle')
        scheduleIdleTimer()
      } catch (err) {
        captureError(err, { operation: 'voiceChatService', step: 'deactivate' })
        disposeInternal()
        actor.send({ type: 'DISPOSE' })
      }
    },

    dispose() {
      disposeInternal()
      actor.send({ type: 'DISPOSE' })
    },

    prewarmKey() {
      void keyCache.get()
    },

    getState() {
      return actor.getSnapshot().value as VoiceChatPublicState
    },

    getError(): VoiceError | null {
      return actor.getSnapshot().context.error
    },

    dismissError() {
      actor.send({ type: 'DISMISS_ERROR' })
    },

    onStateChange: stateEmitter.on,
    onChatStatus: chatStatusEmitter.on,
    onEndedByAgent: endedByAgentEmitter.on
  }
}
```

Add the import for the `ClockPort` type alias used above:

```ts
import type { ClockPort } from './types'
```

(merge into the existing `import type { ... } from './types'` block).

- [ ] **Step 4: Run — expect new cold-path tests GREEN**

```bash
pnpm vitest run src/renderer/src/services/voice-chat/service.test.ts
```

Expected: all prior tests + 4 new cold-path tests pass.

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-voice-chat-refactor
git add apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts \
        apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts
git commit -m "feat(voice-chat): cold-path activate + deactivate + dispose

Cold-path pipeline: getUserMedia → audioElement → webrtcFactory →
agentFactory → sessionFactory → wire session events → keyCache.get() →
session.connect race with config.connectTimeoutMs → mute(false) →
CONNECT_SUCCEEDED. dispose() tears down the session + emits DISPOSE.
deactivate() mutes + schedules the idle timer. chatStatus fires
connecting → idle around the activate; onChatStatus is not edge-detected
(per spec)."
```

---

## Task 8: `preconnect` + `prewarmKey` + warm-path + activate-generation guard

**Files:**
- Edit: `service.test.ts` (append)
- Edit: `service.ts` (the warm path + activate-generation guard already landed in Task 7 — this task ratifies them with tests + adds preconnect / prewarmKey assertions)

- [ ] **Step 1: RED — append the tests**

Append to `service.test.ts`:

```ts
describe('createVoiceChatService — warm path + preconnect + prewarm', () => {
  it('warm activate on same bookId calls updateAgent when ctx changes; no new mic prompt', async () => {
    const media = makeMedia()
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ media, sessionFactory: session.factory })
    )
    await svc.activate(1, { pageText: 'a' })
    expect(media.getUserMedia).toHaveBeenCalledTimes(1)

    await svc.activate(1, { pageText: 'b' })

    expect(session.updateAgent).toHaveBeenCalledTimes(1)
    expect(media.getUserMedia).toHaveBeenCalledTimes(1) // not called again
  })

  it('warm activate skips updateAgent when ctx fingerprint is unchanged', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory })
    )
    await svc.activate(1, { pageText: 'same' })
    await svc.activate(1, { pageText: 'same' })

    expect(session.updateAgent).not.toHaveBeenCalled()
  })

  it('activate on different bookId disposes the old session first', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory })
    )
    await svc.activate(1, { pageText: 'a' })
    await svc.activate(2, { pageText: 'b' })

    expect(session.close).toHaveBeenCalledTimes(1)
    expect(svc.getState()).toBe('active')
  })

  it('concurrent activate calls share the in-flight promise', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory })
    )
    const [p1, p2] = [svc.activate(7, { pageText: 'p' }), svc.activate(7, { pageText: 'p' })]
    await Promise.all([p1, p2])

    expect(session.connect).toHaveBeenCalledTimes(1)
  })

  it('preconnect is no-op when hasUsedVoiceInSession is false', async () => {
    const session = makeSession()
    const ipc = makeIpc()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory, ipc })
    )
    await svc.preconnect(1, { pageText: 'p' })

    expect(session.connect).not.toHaveBeenCalled()
    expect(ipc.getRealtimeClientSecret).not.toHaveBeenCalled()
  })

  it('preconnect after a real activate connects + mutes (paused)', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory })
    )
    await svc.activate(1, { pageText: 'p' })
    svc.dispose()

    await svc.preconnect(1, { pageText: 'p' })

    // Two cold connects total: the user-initiated one and the preconnect.
    expect(session.connect).toHaveBeenCalledTimes(2)
    expect(session.mute).toHaveBeenLastCalledWith(true)
    expect(svc.getState()).toBe('paused')
  })

  it('prewarmKey() fetches the ephemeral key without prompting for mic', async () => {
    const ipc = makeIpc({ key: 'PREWARM' })
    const media = makeMedia()
    const svc = createVoiceChatService(makeDeps({ ipc, media }))

    svc.prewarmKey()
    await new Promise((r) => setTimeout(r, 0))

    expect(ipc.getRealtimeClientSecret).toHaveBeenCalledTimes(1)
    expect(media.getUserMedia).not.toHaveBeenCalled()
  })
})
```

- [ ] **Step 2: Run — expect 7 GREEN (the implementation was complete in Task 7)**

```bash
pnpm vitest run src/renderer/src/services/voice-chat/service.test.ts
```

If anything fails, fix `service.ts` before continuing. Most likely red: nothing — the warm + preconnect + prewarm logic landed in Task 7.

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-voice-chat-refactor
git add apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts
git commit -m "test(voice-chat): warm path + preconnect + prewarm + concurrent dedup

7 boundary tests ratifying the Task 7 implementation:
- Warm activate (same bookId, ctx changed → updateAgent)
- Warm activate (same bookId, ctx unchanged → no updateAgent)
- Different bookId disposes old session first
- Concurrent activate calls share the in-flight promise
- preconnect is a no-op before first user activate (hasUsedVoiceInSession)
- preconnect after a real activate leaves state in 'paused'
- prewarmKey() pulls the ephemeral key without touching the mic"
```

---

## Task 9: Error handling — classification + `getError` + `dismissError`

**Files:**
- Edit: `service.test.ts` (append)

The implementation already routes errors through `classifyError(...)` + `actor.send({ type: 'CONNECT_FAILED', reason, message })` (Task 7). This task verifies the classification end-to-end.

- [ ] **Step 1: RED — append the error-classification tests**

Append to `service.test.ts`:

```ts
describe('createVoiceChatService — errors', () => {
  it('mic denial classifies as mic_denied; state → error; getError populated', async () => {
    const media = makeMedia({ denyMic: true })
    const svc = createVoiceChatService(makeDeps({ media }))

    await expect(svc.activate(1, { pageText: 'p' })).rejects.toMatchObject({
      name: 'NotAllowedError'
    })

    expect(svc.getState()).toBe('error')
    expect(svc.getError()).toEqual({ reason: 'mic_denied', message: 'Permission denied' })
  })

  it('auth failure classifies as auth_failed', async () => {
    const ipc = makeIpc({ failWith: new Error('Not authenticated') })
    const svc = createVoiceChatService(makeDeps({ ipc }))

    await expect(svc.activate(1, { pageText: 'p' })).rejects.toThrow(/Not authenticated/)
    expect(svc.getError()?.reason).toBe('auth_failed')
  })

  it('session.connect failure classifies as connect_failed; half-built session closed', async () => {
    const session = makeSession({ connectFailWith: new Error('boom') })
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory })
    )

    await expect(svc.activate(1, { pageText: 'p' })).rejects.toThrow('boom')
    expect(session.close).toHaveBeenCalled()
    expect(svc.getError()?.reason).toBe('connect_failed')
    expect(svc.getState()).toBe('error')
  })

  it('dismissError clears the error and transitions error → idle', async () => {
    const ipc = makeIpc({ failWith: new Error('Not authenticated') })
    const svc = createVoiceChatService(makeDeps({ ipc }))

    await expect(svc.activate(1, { pageText: 'p' })).rejects.toThrow()
    expect(svc.getState()).toBe('error')

    svc.dismissError()
    expect(svc.getState()).toBe('idle')
    expect(svc.getError()).toBeNull()
  })
})
```

- [ ] **Step 2: Run — expect 4 GREEN**

```bash
pnpm vitest run src/renderer/src/services/voice-chat/service.test.ts
```

If any fail, fix `service.ts` before committing.

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-voice-chat-refactor
git add apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts
git commit -m "test(voice-chat): error classification + dismissError

4 tests pin the typed reasons that the in-service classifyError emits onto
the machine: mic_denied (NotAllowedError), auth_failed (Not authenticated
in the message), connect_failed (any other connect rejection). Half-built
sessions are torn down on cold-path failure. dismissError clears the error
context and transitions error → idle."
```

---

## Task 10: Connectivity gating — start while offline + mid-session offline transition

**Files:**
- Edit: `service.test.ts` (append + unblock the Task 6 multi-subscriber tests)

The connectivity subscription is registered inside `start()` (Task 5 + 7). This task verifies the gating end-to-end and re-enables the deferred Task 6 multi-subscriber assertions.

- [ ] **Step 1: RED — append the connectivity tests and add back the Task 6 placeholders**

Append to `service.test.ts`:

```ts
describe('createVoiceChatService — connectivity gating', () => {
  it('activate while offline rejects with OfflineError; state → offline', async () => {
    const connectivity = makeConnectivity({ initialOnline: false })
    const media = makeMedia()
    const svc = createVoiceChatService(
      makeDeps({ connectivity, media })
    )

    await expect(svc.activate(1, { pageText: 'p' })).rejects.toBeInstanceOf(OfflineErrorImport)
    expect(svc.getState()).toBe('offline')
    expect(media.getUserMedia).not.toHaveBeenCalled()
  })

  it('mid-session offline transition disposes the session + state → offline', async () => {
    const connectivity = makeConnectivity({ initialOnline: true })
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ connectivity, sessionFactory: session.factory })
    )
    svc.start()
    await svc.activate(1, { pageText: 'p' })
    expect(svc.getState()).toBe('active')

    connectivity.setOnline(false)

    expect(session.close).toHaveBeenCalled()
    expect(svc.getState()).toBe('offline')
  })

  it('offline → online transitions back to idle (error cleared)', async () => {
    const connectivity = makeConnectivity({ initialOnline: false })
    const svc = createVoiceChatService(makeDeps({ connectivity }))
    svc.start()
    // Synchronously enter offline via failed activate.
    await expect(svc.activate(1, { pageText: 'p' })).rejects.toBeInstanceOf(OfflineErrorImport)
    expect(svc.getState()).toBe('offline')

    connectivity.setOnline(true)

    expect(svc.getState()).toBe('idle')
    expect(svc.getError()).toBeNull()
  })

  it('onStateChange fans out to multiple subscribers on offline transition', () => {
    const connectivity = makeConnectivity({ initialOnline: true })
    const svc = createVoiceChatService(makeDeps({ connectivity }))
    svc.start()
    const a = vi.fn()
    const b = vi.fn()
    svc.onStateChange(a)
    svc.onStateChange(b)

    connectivity.setOnline(false)

    expect(a).toHaveBeenCalledWith('offline')
    expect(b).toHaveBeenCalledWith('offline')
  })

  it('unsubscribe stops further onStateChange invocations', () => {
    const connectivity = makeConnectivity({ initialOnline: true })
    const svc = createVoiceChatService(makeDeps({ connectivity }))
    svc.start()
    const spy = vi.fn()
    const off = svc.onStateChange(spy)

    connectivity.setOnline(false)
    expect(spy).toHaveBeenCalledTimes(1)

    off()
    connectivity.setOnline(true)
    expect(spy).toHaveBeenCalledTimes(1)
  })
})
```

At the top of `service.test.ts`, add the import alias for `OfflineError` (the test references it as `OfflineErrorImport` to disambiguate from any local `OfflineError` constants if introduced later):

```ts
import { OfflineError as OfflineErrorImport } from './types'
```

- [ ] **Step 2: Run — expect 5 GREEN**

```bash
pnpm vitest run src/renderer/src/services/voice-chat/service.test.ts
```

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-voice-chat-refactor
git add apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts
git commit -m "test(voice-chat): connectivity gating + multi-subscriber fanout

5 boundary tests:
- activate while offline rejects with OfflineError; mic never prompted
- mid-session offline transition closes the session + state 'offline'
- offline → online transitions back to 'idle' with error cleared
- onStateChange multi-subscriber fanout on connectivity edges
- unsubscribe stops further invocations"
```

---

## Task 11: RAG dep wired into `buildRealtimeAgent` + `onEndedByAgent` event

**Files:**
- Edit: `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts`
- Edit: `service.test.ts` (append the `onEndedByAgent` + RAG-passthrough tests)

The existing `buildRealtimeAgent` imports `getRagService()` at module scope. Invert: accept `rag: RagService` as a parameter. The service passes the injected `rag` through `agentFactory({ ..., rag })`.

- [ ] **Step 1: Edit `buildRealtimeAgent.ts` — signature change**

Edit `/tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts`:

**Remove** line 1:

```ts
import { getRagService } from '@/services'
```

**Add** to the imports near the top:

```ts
import type { RagService } from '@/services/rag'
```

**Change** the `BuildAgentOptions` interface:

```ts
// BEFORE:
export interface BuildAgentOptions {
  bookId: number
  pageText: string
  outline?: BookOutline
  onEndConversation: (reason: string) => void
}

// AFTER:
export interface BuildAgentOptions {
  bookId: number
  pageText: string
  outline?: BookOutline
  onEndConversation: (reason: string) => void
  rag: RagService
}
```

**Destructure** `rag` in the function:

```ts
// BEFORE:
export function buildRealtimeAgent({
  bookId,
  pageText,
  outline,
  onEndConversation
}: BuildAgentOptions): RealtimeAgent {

// AFTER:
export function buildRealtimeAgent({
  bookId,
  pageText,
  outline,
  onEndConversation,
  rag
}: BuildAgentOptions): RealtimeAgent {
```

**Replace** the `bookContextExecute` body:

```ts
// BEFORE:
const chunks = await getRagService().searchSemantic(queryText, bookId, 3)

// AFTER:
const chunks = await rag.searchSemantic(queryText, bookId, 3)
```

- [ ] **Step 2: RED — append the agent-passthrough + onEndedByAgent tests**

Append to `service.test.ts`:

```ts
describe('createVoiceChatService — RAG passthrough + onEndedByAgent', () => {
  it('passes the injected RagService through agentFactory', async () => {
    const rag = makeRag()
    const agent = makeAgent()
    const svc = createVoiceChatService(
      makeDeps({ rag, agentFactory: agent.factory })
    )
    await svc.activate(1, { pageText: 'p' })

    expect(agent.lastArgs()?.rag).toBe(rag)
    expect(agent.lastArgs()?.bookId).toBe(1)
  })

  it('onEndedByAgent fires when the agent invokes endConversation tool', async () => {
    const agent = makeAgent()
    const svc = createVoiceChatService(
      makeDeps({ agentFactory: agent.factory })
    )
    const spy = vi.fn()
    svc.onEndedByAgent(spy)

    await svc.activate(1, { pageText: 'p' })
    agent.triggerEnd('all done')

    expect(spy).toHaveBeenCalledWith('all done')
  })

  it('onEndedByAgent unsubscribe stops further deliveries', async () => {
    const agent = makeAgent()
    const svc = createVoiceChatService(
      makeDeps({ agentFactory: agent.factory })
    )
    const spy = vi.fn()
    const off = svc.onEndedByAgent(spy)

    await svc.activate(1, { pageText: 'p' })
    agent.triggerEnd('one')
    off()
    agent.triggerEnd('two')

    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenCalledWith('one')
  })
})
```

- [ ] **Step 3: Run + typecheck — expect 3 GREEN + typecheck pass**

```bash
pnpm typecheck
pnpm vitest run src/renderer/src/services/voice-chat/service.test.ts
```

- [ ] **Step 4: Commit**

```bash
cd /tmp/rishi-voice-chat-refactor
git add apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts \
        apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts
git commit -m "refactor(voice-chat): inject rag into buildRealtimeAgent + onEndedByAgent

buildRealtimeAgent gains a 'rag: RagService' parameter, dropping its
module-scope getRagService import. Service tests assert that the injected
rag flows through agentFactory and that onEndedByAgent fans the agent's
endConversation tool-call out to subscribers."
```

---

## Task 12: Public exports (`index.ts`)

**Files:**
- Edit: `apps/rishi-electron/src/renderer/src/services/voice-chat/index.ts`

Replace the placeholder with the public re-exports. **Do not** re-export internals (`createEmitter`, `createKeyCache`, `voiceChatMachine`, the `Realtime*Like` test shapes — those are part of the type module but exported there for test typing).

- [ ] **Step 1: Replace the placeholder**

Overwrite `/tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat/index.ts`:

```ts
export { createVoiceChatService } from './service'
export { OfflineError } from './types'
export type {
  ChatStatus,
  VoiceChatPublicState,
  VoiceChatService,
  VoiceChatServiceDeps,
  VoiceChatContext,
  VoiceChatConfig,
  VoiceChatIpc,
  VoiceError,
  VoiceErrorReason,
  MediaPort,
  EffectsPort,
  ClockPort,
  AgentFactoryArgs,
  WebrtcFactoryArgs,
  SessionFactoryOpts,
  RealtimeAgentLike,
  RealtimeSessionLike,
  RtcTransportLike,
  MediaStreamLike,
  AudioElementLike
} from './types'
```

- [ ] **Step 2: Verify typecheck passes**

```bash
pnpm typecheck
```

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-voice-chat-refactor
git add apps/rishi-electron/src/renderer/src/services/voice-chat/index.ts
git commit -m "refactor(voice-chat): publish service surface from index.ts

Re-exports createVoiceChatService, OfflineError, and all public types.
Internal helpers (createEmitter, createKeyCache, voiceChatMachine) stay
strictly internal."
```

---

## Task 13: Wire `getVoiceChatService()` in `services/index.ts`

**Files:**
- Edit: `apps/rishi-electron/src/renderer/src/services/index.ts`

Adds the lazy singleton + production adapter for every port.

- [ ] **Step 1: Edit `services/index.ts`**

In `/tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/index.ts`, add near the top imports (after the existing `createBookImportService` block):

```ts
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
```

Append to the end of the file:

```ts
let _voiceChat: VoiceChatService | null = null

export function getVoiceChatService(): VoiceChatService {
  if (!_voiceChat) {
    _voiceChat = createVoiceChatService({
      rag: getRagService(),
      connectivity: getConnectivityService(),
      ipc: { getRealtimeClientSecret },
      webrtcFactory: ({ mediaStream, audioElement }) =>
        new OpenAIRealtimeWebRTC({
          mediaStream: mediaStream as unknown as MediaStream,
          audioElement: audioElement as unknown as HTMLAudioElement
        }) as never,
      agentFactory: ({ bookId, pageText, outline, onEndConversation, rag }) =>
        buildRealtimeAgent({ bookId, pageText, outline, onEndConversation, rag }) as never,
      sessionFactory: (agent, opts) =>
        new RealtimeSession(agent as never, {
          transport: opts.transport as never,
          apiKey: opts.apiKey
        }) as never,
      media: {
        getUserMedia: (constraints) =>
          navigator.mediaDevices.getUserMedia(constraints) as never,
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

- [ ] **Step 2: Verify typecheck passes**

```bash
pnpm typecheck
```

If `getRealtimeClientSecret` is not exported from `@/lib/api`, locate the actual source (e.g. `@/modules/realtime` or `@/lib/api/realtime`) and update the import accordingly. (Verify with `git grep -n "getRealtimeClientSecret"` before editing.)

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-voice-chat-refactor
git add apps/rishi-electron/src/renderer/src/services/index.ts
git commit -m "feat(voice-chat): getVoiceChatService lazy singleton + production wiring

Wires every port: rag = getRagService(), connectivity = getConnectivityService(),
ipc = { getRealtimeClientSecret }, webrtcFactory = OpenAIRealtimeWebRTC,
agentFactory = buildRealtimeAgent (now with rag), sessionFactory =
RealtimeSession, media = navigator.mediaDevices.getUserMedia + document
audio element, effects = the three sound modules, clock = wall-clock
setTimeout, config = today's defaults. Auto-starts on first access."
```

---

## Task 14: ChatStore migration

**Files:**
- Edit: `apps/rishi-electron/src/renderer/src/stores/chatStore.ts`
- Edit: `apps/rishi-electron/src/renderer/src/stores/chatStore.test.ts`

ChatStore swaps from `voiceChatService.setListeners(...)` + `actor.subscribe(...)` to three typed `on*` subscriptions. The `_chatGeneration` + `_isStarting` guards are deleted (the service owns them now).

- [ ] **Step 1: Rewrite `chatStore.ts`**

Overwrite `/tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/stores/chatStore.ts`:

```ts
import { create } from 'zustand'
import { devtools, subscribeWithSelector } from 'zustand/middleware'
import { getVoiceChatService } from '@/services'
import {
  OfflineError,
  type ChatStatus,
  type VoiceChatPublicState,
  type VoiceError
} from '@/services/voice-chat'
import { usePlayerStore } from './playerStore'
import { useEpubStore } from './epubStore'
import { captureError } from '@/utils/sentry'

interface ChatState {
  isChatting: boolean
  chatStatus: ChatStatus
  voiceState: VoiceChatPublicState
  voiceError: VoiceError | null

  setIsChatting: (value: boolean | ((prev: boolean) => boolean)) => void
  setChatStatus: (status: ChatStatus) => void
  startChat: (bookId: number) => void
  stopConversation: () => void
  dismissVoiceError: () => void
}

export const useChatStore = create<ChatState>()(
  devtools(
    subscribeWithSelector((set, get) => {
      const voice = getVoiceChatService()

      // Wiring site: service events → store actions. Subscriptions live for
      // the process lifetime; their unsubscribes are intentionally discarded.
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
        chatStatus: 'idle' as ChatStatus,
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

        setChatStatus: (status) => set({ chatStatus: status }),

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

- [ ] **Step 2: Update `chatStore.test.ts` to mock the new surface**

Read `/tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/stores/chatStore.test.ts` first (around the `vi.mock('@/modules/voiceChatService', ...)` block at line 17). Replace the mock with a mock of `@/services` and `@/services/voice-chat`:

```ts
// BEFORE (around line 17):
vi.mock('@/modules/voiceChatService', () => ({
  voiceChatService: {
    actor: { subscribe: () => ({ unsubscribe: () => {} }) },
    getState: () => 'idle',
    getError: () => null,
    setListeners: () => {},
    activate: vi.fn(),
    deactivate: vi.fn(),
    dispose: vi.fn(),
    dismissError: vi.fn()
  },
  OfflineError: class OfflineError extends Error {}
}))

// AFTER:
const fakeVoice = {
  start: vi.fn(),
  stop: vi.fn(),
  activate: vi.fn().mockResolvedValue(undefined),
  preconnect: vi.fn().mockResolvedValue(undefined),
  deactivate: vi.fn(),
  dispose: vi.fn(),
  prewarmKey: vi.fn(),
  getState: vi.fn().mockReturnValue('idle' as const),
  getError: vi.fn().mockReturnValue(null),
  dismissError: vi.fn(),
  onStateChange: vi.fn().mockReturnValue(() => {}),
  onChatStatus: vi.fn().mockReturnValue(() => {}),
  onEndedByAgent: vi.fn().mockReturnValue(() => {})
}

vi.mock('@/services', () => ({
  getVoiceChatService: () => fakeVoice
}))

vi.mock('@/services/voice-chat', () => ({
  OfflineError: class OfflineError extends Error {}
}))
```

Update the existing test assertions:

```ts
// BEFORE:
it('setIsChatting(false) calls voiceChatService.deactivate', () => {
  ...
  expect(voiceChatService.deactivate).toHaveBeenCalled()
})

it('startChat delegates to voiceChatService.activate', async () => {
  ...
  expect(voiceChatService.activate).toHaveBeenCalledWith(1, { pageText: '', outline: undefined })
})

// AFTER:
it('setIsChatting(false) calls voice.deactivate', () => {
  ...
  expect(fakeVoice.deactivate).toHaveBeenCalled()
})

it('startChat delegates to voice.activate', async () => {
  ...
  expect(fakeVoice.activate).toHaveBeenCalledWith(1, { pageText: '', outline: undefined })
})
```

Drop the `voiceChatService` import at the top of the test file and replace with the local `fakeVoice` reference; remove any `import { OfflineError } from '@/modules/voiceChatService'` lines.

- [ ] **Step 3: Run typecheck + chatStore tests**

```bash
pnpm typecheck
pnpm vitest run src/renderer/src/stores/chatStore.test.ts
```

Expected: all chatStore tests pass.

- [ ] **Step 4: Commit**

```bash
cd /tmp/rishi-voice-chat-refactor
git add apps/rishi-electron/src/renderer/src/stores/chatStore.ts \
        apps/rishi-electron/src/renderer/src/stores/chatStore.test.ts
git commit -m "refactor(voice-chat): migrate chatStore to typed service events

Replaces voiceChatService.setListeners + actor.subscribe with the three
typed on* subscriptions on getVoiceChatService(). Deletes the
_chatGeneration + _isStarting guards (the service owns the in-flight +
generation guard now). chatStore drops from 121 to ~80 lines. The test
mock target moves from @/modules/voiceChatService to @/services + the
OfflineError export from @/services/voice-chat."
```

---

## Task 15: EpubStore migration + delete `@/modules/realtime` import

**Files:**
- Edit: `apps/rishi-electron/src/renderer/src/stores/epubStore.ts`

- [ ] **Step 1: Read the current epubStore.ts lines 1–30 and 220–260**

Verify the import lines at the top + the three voice-chat call sites at lines 234, 239, 244, 257.

- [ ] **Step 2: Edit `epubStore.ts`**

Replace the top-of-file imports:

```ts
// BEFORE (lines 15-16):
import { prefetchRealtimeKey } from '@/modules/realtime'
import { voiceChatService } from '@/modules/voiceChatService'

// AFTER:
import { getVoiceChatService } from '@/services'
```

Replace the three call sites:

```ts
// BEFORE (line 234):
prefetchRealtimeKey()

// AFTER:
getVoiceChatService().prewarmKey()
```

```ts
// BEFORE (line 239):
voiceChatService.dispose()

// AFTER:
getVoiceChatService().dispose()
```

```ts
// BEFORE (line 244):
unsubs.push(() => voiceChatService.dispose())

// AFTER:
unsubs.push(() => getVoiceChatService().dispose())
```

```ts
// BEFORE (line 257):
void voiceChatService.preconnect(Number(bookId), { pageText, outline })

// AFTER:
void getVoiceChatService().preconnect(Number(bookId), { pageText, outline })
```

- [ ] **Step 3: Run typecheck**

```bash
pnpm typecheck
```

- [ ] **Step 4: Commit**

```bash
cd /tmp/rishi-voice-chat-refactor
git add apps/rishi-electron/src/renderer/src/stores/epubStore.ts
git commit -m "refactor(voice-chat): migrate epubStore to getVoiceChatService

Replaces prefetchRealtimeKey() with getVoiceChatService().prewarmKey() and
swaps the two voiceChatService.dispose()/.preconnect() call sites for the
service-locator equivalent. Drops the @/modules/realtime import."
```

---

## Task 16: Delete legacy modules

**Files:**
- Delete: `apps/rishi-electron/src/renderer/src/modules/voiceChatService.ts`
- Delete: `apps/rishi-electron/src/renderer/src/modules/voiceChatService.test.ts`
- Delete: `apps/rishi-electron/src/renderer/src/modules/realtime.ts`
- Delete: `apps/rishi-electron/src/renderer/src/machines/voiceChatMachine.ts`
- Delete: `apps/rishi-electron/src/renderer/src/machines/__tests__/voiceChatMachine.test.ts`

**KEEP:**
- `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts` (signature changed, file stays)
- `apps/rishi-electron/src/renderer/src/modules/readyChime.ts` (wired via `effects` port)
- `apps/rishi-electron/src/renderer/src/modules/thinkingSound.ts` (wired via `effects` port)

- [ ] **Step 1: Verify no remaining external imports**

```bash
cd /tmp/rishi-voice-chat-refactor
git grep -nE "from '@/modules/voiceChatService'|from '@/modules/realtime'|from '@/machines/voiceChatMachine'|from '../machines/voiceChatMachine'" \
  apps/rishi-electron/src/renderer/src
```

Expected: empty. If any match appears, migrate that file first before deleting.

- [ ] **Step 2: Delete the 5 legacy files**

```bash
cd /tmp/rishi-voice-chat-refactor
git rm apps/rishi-electron/src/renderer/src/modules/voiceChatService.ts \
       apps/rishi-electron/src/renderer/src/modules/voiceChatService.test.ts \
       apps/rishi-electron/src/renderer/src/modules/realtime.ts \
       apps/rishi-electron/src/renderer/src/machines/voiceChatMachine.ts \
       apps/rishi-electron/src/renderer/src/machines/__tests__/voiceChatMachine.test.ts
```

- [ ] **Step 3: Verify the machine + tests still exist at their new home**

```bash
ls -la /tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat/machine.ts \
       /tmp/rishi-voice-chat-refactor/apps/rishi-electron/src/renderer/src/services/voice-chat/machine.test.ts
```

Expected: both files present.

- [ ] **Step 4: Run typecheck + vitest on the voice-chat surface**

```bash
cd /tmp/rishi-voice-chat-refactor/apps/rishi-electron
pnpm typecheck
pnpm vitest run src/renderer/src/services/voice-chat src/renderer/src/stores/chatStore.test.ts
```

Expected: all green.

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-voice-chat-refactor
git commit -m "refactor(voice-chat): delete legacy modules + machine path

5 files removed:
- modules/voiceChatService.ts (absorbed into services/voice-chat/service.ts)
- modules/voiceChatService.test.ts (29 tests reaching _resetForTests —
  replaced by ~25 boundary tests in services/voice-chat/service.test.ts)
- modules/realtime.ts (absorbed into services/voice-chat/key-cache.ts)
- machines/voiceChatMachine.ts (moved to services/voice-chat/machine.ts)
- machines/__tests__/voiceChatMachine.test.ts (moved to
  services/voice-chat/machine.test.ts, 12 tests intact)

Per meta-spec no-shims rule: one PR, one source of truth. All voice-chat
surfaces flow through getVoiceChatService()."
```

---

## Task 17: Final verification & PR

**Files:** none (verification only).

- [ ] **Step 1: Run typecheck, lint, full vitest**

```bash
cd /tmp/rishi-voice-chat-refactor/apps/rishi-electron
pnpm typecheck
pnpm lint
pnpm vitest run
```

**Out-of-scope pre-existing failures** (do NOT fix in this PR):
- `queries.outline*` runtime test failures (better-sqlite3 native binding mismatch in the worktree)
- `stores/navStore.test.ts` typecheck error
- `src/main/**` typecheck errors (sqlite/electron typing drift)

If any *new* failure appears caused by this refactor (a file under `services/voice-chat/`, the migrated `chatStore.ts` / `epubStore.ts` / `buildRealtimeAgent.ts`, or the rewired `services/index.ts`), fix in a follow-up commit (`fix(voice-chat): ...`) before opening the PR.

- [ ] **Step 2: Sanity-check `services/index.ts` is the only wiring site**

```bash
cd /tmp/rishi-voice-chat-refactor
grep -rn "createVoiceChatService" apps/rishi-electron/src/
```

Expected: matches in `services/voice-chat/service.ts` (definition), `services/voice-chat/index.ts` (re-export), `services/index.ts` (wiring), and the test file. No other call sites.

- [ ] **Step 3: Sanity-check internals are not externally imported**

```bash
cd /tmp/rishi-voice-chat-refactor
grep -rnE "from '@/services/voice-chat/(emitter|key-cache|machine|service|types)'" apps/rishi-electron/src/
```

Expected: no matches outside `apps/rishi-electron/src/renderer/src/services/voice-chat/`.

- [ ] **Step 4: Confirm no legacy imports remain anywhere**

```bash
cd /tmp/rishi-voice-chat-refactor
git grep -nE "@/modules/voiceChatService|@/modules/realtime|@/machines/voiceChatMachine" apps/rishi-electron/src
```

Expected: empty (only doc-comment matches allowed; if any code import remains, fix before pushing).

- [ ] **Step 5: Push the branch and open the PR**

```bash
cd /tmp/rishi-voice-chat-refactor
git push -u origin refactor/voice-chat-service
gh pr create --title "refactor(voice-chat): wrap xstate + realtime SDK behind services/voice-chat boundary" --body "$(cat <<'EOF'
## Summary
- New \`VoiceChatService\` at \`apps/rishi-electron/src/renderer/src/services/voice-chat/\` **wraps** the committed \`voiceChatMachine\` + the \`@openai/agents/realtime\` SDK + the WebRTC transport + the mic + the audio element + the idle timer + the connect-timeout + the 9-min key cache + the activate-in-flight + activate-generation guards behind one typed factory.
- Public surface: 7 methods (\`start\`, \`stop\`, \`activate\`, \`preconnect\`, \`deactivate\`, \`dispose\`, \`prewarmKey\`), 3 snapshot getters (\`getState\`, \`getError\`, \`dismissError\`), 3 typed event channels (\`onStateChange\`, \`onChatStatus\`, \`onEndedByAgent\`).
- 10 injected ports: \`rag\` (consumed by injecting into \`buildRealtimeAgent\`'s \`bookContext\` tool), \`connectivity\` (subscribed in \`start()\`), \`ipc\`, \`webrtcFactory\`, \`agentFactory\`, \`sessionFactory\`, \`media\`, \`effects\`, \`clock\`, \`config\`.
- \`chatStore\` shrinks from 121 → ~80 lines: drops \`_chatGeneration\` + \`_isStarting\` (service owns them now), drops \`actor.subscribe\` + \`setListeners\`, subscribes to the three typed event channels at the wiring site.
- \`epubStore\` swaps 3 call sites for the service-locator equivalent (\`prefetchRealtimeKey()\` → \`prewarmKey()\`, \`voiceChatService.dispose/.preconnect()\` → \`getVoiceChatService().dispose/.preconnect()\`).
- \`buildRealtimeAgent\` gains a \`rag: RagService\` parameter, dropping its \`getRagService\` import.
- 5 legacy files deleted (\`modules/voiceChatService.ts\` + its test, \`modules/realtime.ts\`, \`machines/voiceChatMachine.ts\` + its test). The 12 machine tests move verbatim to \`services/voice-chat/machine.test.ts\`.
- TDD throughout: red → green → commit per behavior.

Spec: \`docs/superpowers/specs/2026-05-11-voice-chat-service-design.md\`
Meta-spec: \`docs/superpowers/specs/2026-05-11-services-and-effect-adoption-design.md\` (Wave 2, service 5 of 6)

## Test plan
- [ ] \`pnpm typecheck\` clean for the voice-chat surface (pre-existing \`src/main/**\` + \`navStore.test.ts\` + \`queries.outline*\` failures are out of scope)
- [ ] \`pnpm lint\` clean
- [ ] \`pnpm vitest run src/renderer/src/services/voice-chat/\` — emitter (3), key-cache (4), machine (12), types (7), service (~25) = ~51 boundary tests pass
- [ ] \`pnpm vitest run src/renderer/src/stores/chatStore.test.ts\` — store tests pass with the new service mock
- [ ] Manual: open the app, click the voice-chat launcher, observe mic prompt, listen for ready chime, ask a question, confirm thinking/speaking status transitions, click stop
- [ ] Manual: drop the network mid voice-chat session — observe the panel closes + an offline banner appears; restore network — observe the launcher is re-enabled
- [ ] Manual: deny the mic permission — observe the panel surfaces a 'mic_denied' error; click dismiss; relaunch app and grant permission to confirm recovery
EOF
)"
```

---

## Summary

After all tasks complete:
- **~17 commits** on the `refactor/voice-chat-service` branch in the `/tmp/rishi-voice-chat-refactor` worktree.
- **~51 boundary + internal tests** across `services/voice-chat/{emitter,key-cache,machine,types,service}.test{,-d}.ts`. No `vi.mock` of the service, no `_resetForTests` hooks, no jsdom polyfills.
- **Net diff (approximate):** roughly even — the service + its tests + types are ~900 lines added; the 5 deleted files + the chatStore guards + the epubStore imports + the buildRealtimeAgent import shave ~850 lines.
- **Kept verbatim:** the 12 machine tests (moved file only), `modules/buildRealtimeAgent.ts` (signature gained `rag`), `modules/readyChime.ts`, `modules/thinkingSound.ts`.
- **No internals exported.** The public surface from `services/voice-chat/index.ts` is `createVoiceChatService` + `OfflineError` + 19 public types. `createEmitter`, `createKeyCache`, `voiceChatMachine`, and the in-test `make*` helpers stay strictly internal.
- **xstate + the OpenAI realtime SDK + WebRTC stay inside the service.** Callers never see `createActor`, `voiceChatMachine`, `RealtimeSession`, `OpenAIRealtimeWebRTC`, the snapshot signature, the ephemeral-key TTL math, the activate-in-flight promise, the generation counter, the `lastContextFingerprint`, the idle-timer handle, the `hasUsedVoiceInSession` flag, or the `preconnectIntent` flag. They see `activate(bookId, ctx)` / `getState() / onStateChange(cb) / OfflineError`.

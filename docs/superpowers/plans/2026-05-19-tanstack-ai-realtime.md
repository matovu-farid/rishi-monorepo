# TanStack AI Realtime Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `@openai/agents/realtime` + `@openai/agents-realtime` with `@tanstack/ai-client` + `@tanstack/ai-openai` for the voice-chat realtime flow in `apps/rishi-electron`, preserving the `VoiceChatService` public interface.

**Architecture:** The `voiceChatService` facade keeps its public interface and its cross-cutting policies (inactivity timer, key cache, connectivity gate, sound effects), but its internals are rewritten to delegate to `RealtimeClient` from `@tanstack/ai-client`. The xstate machine and Effect-TS activation pipeline are deleted as redundant — `RealtimeClient` owns WebRTC, mic, audio-element wiring, and exposes `onStatusChange`/`onModeChange` events we map to our public state.

**Tech Stack:** TypeScript, vitest, Electron renderer (React), `@tanstack/ai-client`, `@tanstack/ai-openai`, `@tanstack/ai`, zod, `effect` (kept for `runToolCall` only).

**Reference spec:** `docs/superpowers/specs/2026-05-19-tanstack-ai-realtime-design.md`

**Working directory for all commands:** `apps/rishi-electron`

**Test runner:** `pnpm test -- <pattern>` (vitest). Type check: `pnpm typecheck`.

---

## File Structure

### Files to create

| Path | Responsibility |
|---|---|
| `src/renderer/src/services/voice-chat/buildRealtimeConfig.ts` | Pure function: build `{ instructions, tools, voice }` from book context. Includes Effect-wrapped `runToolCall` for tool observability. |
| `src/renderer/src/services/voice-chat/buildRealtimeConfig.test.ts` | Tests instruction templating, language/outline/active-paragraph sections, tool execute behavior (ok/empty/error). |
| `src/renderer/src/services/voice-chat/realtime-token.ts` | `fetchRealtimeToken(language)` — wraps existing worker string in TanStack AI's `RealtimeToken` envelope. |
| `src/renderer/src/services/voice-chat/realtime-token.test.ts` | Envelope shape, expiry math, error propagation from worker. |
| `src/renderer/src/services/voice-chat/status-mapper.ts` | Pure mapper: `(RealtimeStatus, RealtimeMode) → (VoiceChatPublicState, ChatStatus)`. |
| `src/renderer/src/services/voice-chat/status-mapper.test.ts` | Table-driven mapping tests. |
| `src/renderer/src/services/voice-chat/fake-adapter.ts` | Test-only `RealtimeAdapter` implementation for the wiring-truth integration test. |
| `src/renderer/src/services/voice-chat/wiring-integration.test.ts` | T2: real `RealtimeClient` against `fake-adapter`, validates connect/updateSession/tool-result round-trip. |

### Files to modify

| Path | Change |
|---|---|
| `src/renderer/src/services/voice-chat/types.ts` | Replace `webrtcFactory/agentFactory/sessionFactory/media` ports with `clientFactory/adapter`. Public unions unchanged. |
| `src/renderer/src/services/voice-chat/service.ts` | Internals rewritten — drops xstate `createActor`, drops `effect` import for activation, instantiates `RealtimeClient` directly. Public interface unchanged. |
| `src/renderer/src/services/voice-chat/service.test.ts` | Replace `makeWebrtc/makeAgent/makeSession/makeMedia` helpers with single `makeFakeClient` helper. Re-target assertions. |
| `src/renderer/src/services/voice-chat/key-cache.ts` | Fetcher signature `() => Promise<string>` → `() => Promise<RealtimeToken>`. TTL math uses `token.expiresAt` instead of fixed `ttlMs`. |
| `src/renderer/src/services/voice-chat/key-cache.test.ts` | Update fixtures for new token shape and expiry-based TTL. |
| `src/renderer/src/services/voice-chat/errors.ts` | Keep all 5 tagged errors and `toPublicError`. No change needed — they survive as plain tagged classes. |
| `src/renderer/src/services/voice-chat/index.ts` | Update exports: drop `WebrtcFactoryArgs/SessionFactoryOpts/RealtimeAgentLike/RealtimeSessionLike/RtcTransportLike/MediaStreamLike/AudioElementLike/AgentFactoryArgs/MediaPort`. Add new port types. |
| `src/renderer/src/services/index.ts` | Composition root: replace `OpenAIRealtimeWebRTC`/`RealtimeSession`/`buildRealtimeAgent` wiring with `openaiRealtime()` adapter + `clientFactory`. |
| `package.json` | Add `@tanstack/ai-client`, `@tanstack/ai-openai`, `@tanstack/ai`. Remove `@openai/agents` (and `@openai/agents-realtime` if present as a separate top-level dep). |

### Files to delete

- `src/renderer/src/services/voice-chat/machine.ts`
- `src/renderer/src/services/voice-chat/machine.test.ts`
- `src/renderer/src/services/voice-chat/activation-program.ts`
- `src/renderer/src/modules/buildRealtimeAgent.ts`
- `src/renderer/src/modules/buildRealtimeAgent.test.ts`

### Files unchanged

- `src/renderer/src/services/voice-chat/emitter.ts` (+ test)
- `src/renderer/src/services/voice-chat/types.test.ts`
- `src/renderer/src/lib/api.ts` (`getRealtimeClientSecret` keeps its string return type)
- `src/renderer/src/stores/chatStore.ts`
- `src/renderer/src/components/FileComponent.tsx`
- All other consumers — they use only the `VoiceChatService` public interface which doesn't change.

---

## Task Sequence

Tasks are ordered so the codebase compiles between every task (no broken intermediate states). New modules are built first as pure functions, then the facade is rewritten, then the composition root is switched over, then dead code is deleted.

---

### Task 1: Install TanStack AI dependencies

**Files:**
- Modify: `apps/rishi-electron/package.json`

- [ ] **Step 1: Install the three new packages**

Run from `apps/rishi-electron`:

```bash
pnpm add @tanstack/ai @tanstack/ai-client @tanstack/ai-openai
```

- [ ] **Step 2: Verify install**

```bash
pnpm list @tanstack/ai @tanstack/ai-client @tanstack/ai-openai
```

Expected: all three resolve to a version.

- [ ] **Step 3: Verify TypeScript can resolve `RealtimeClient`**

Create a throwaway file `apps/rishi-electron/src/renderer/src/services/voice-chat/_probe.ts`:

```typescript
import { RealtimeClient } from '@tanstack/ai-client'
import { openaiRealtime } from '@tanstack/ai-openai'
import { toolDefinition } from '@tanstack/ai'

// eslint-disable-next-line @typescript-eslint/no-unused-vars
const _: { RealtimeClient: typeof RealtimeClient; openaiRealtime: typeof openaiRealtime; toolDefinition: typeof toolDefinition } = {
  RealtimeClient,
  openaiRealtime,
  toolDefinition
}
```

Run: `pnpm typecheck`

Expected: PASS. Note the public surface of `RealtimeClient` (hover/inspect) — required for Task 6 mock.

Delete `_probe.ts` before committing.

- [ ] **Step 4: Commit**

```bash
git add apps/rishi-electron/package.json apps/rishi-electron/pnpm-lock.yaml
git commit -m "chore(electron): add @tanstack/ai{,-client,-openai} deps"
```

---

### Task 2: `status-mapper.ts` — pure mapping function

**Files:**
- Create: `src/renderer/src/services/voice-chat/status-mapper.ts`
- Create: `src/renderer/src/services/voice-chat/status-mapper.test.ts`

The mapper translates TanStack AI's `RealtimeStatus` (`'idle' | 'connecting' | 'connected' | 'reconnecting' | 'error'`) and `RealtimeMode` (`'idle' | 'listening' | 'thinking' | 'speaking'`) into our two public unions, plus two derived signals (`'isOffline'` and `'lastError'`) that the facade owns.

- [ ] **Step 1: Write `status-mapper.test.ts`**

```typescript
import { describe, it, expect } from 'vitest'
import { mapStatus, mapChatStatus } from './status-mapper'

describe('mapStatus — RealtimeStatus → VoiceChatPublicState', () => {
  it('idle → idle', () => {
    expect(mapStatus('idle', { isOffline: false, hasError: false })).toBe('idle')
  })
  it('connecting → connecting', () => {
    expect(mapStatus('connecting', { isOffline: false, hasError: false })).toBe('connecting')
  })
  it('reconnecting → connecting', () => {
    expect(mapStatus('reconnecting', { isOffline: false, hasError: false })).toBe('connecting')
  })
  it('connected → active', () => {
    expect(mapStatus('connected', { isOffline: false, hasError: false })).toBe('active')
  })
  it('error → error', () => {
    expect(mapStatus('error', { isOffline: false, hasError: true })).toBe('error')
  })
  it('isOffline overrides any non-error state', () => {
    expect(mapStatus('idle', { isOffline: true, hasError: false })).toBe('offline')
    expect(mapStatus('connected', { isOffline: true, hasError: false })).toBe('offline')
  })
  it('error wins over offline (failure should be diagnosable)', () => {
    expect(mapStatus('error', { isOffline: true, hasError: true })).toBe('error')
  })
})

describe('mapChatStatus — RealtimeStatus + RealtimeMode → ChatStatus', () => {
  it('not connected → connecting', () => {
    expect(mapChatStatus('connecting', 'idle')).toBe('connecting')
    expect(mapChatStatus('reconnecting', 'idle')).toBe('connecting')
  })
  it('connected + listening/idle → idle', () => {
    expect(mapChatStatus('connected', 'idle')).toBe('idle')
    expect(mapChatStatus('connected', 'listening')).toBe('idle')
  })
  it('connected + thinking → thinking', () => {
    expect(mapChatStatus('connected', 'thinking')).toBe('thinking')
  })
  it('connected + speaking → speaking', () => {
    expect(mapChatStatus('connected', 'speaking')).toBe('speaking')
  })
  it('disconnected → idle', () => {
    expect(mapChatStatus('idle', 'idle')).toBe('idle')
  })
})
```

- [ ] **Step 2: Run the test — expect FAIL ("not defined")**

```bash
pnpm test -- status-mapper
```

Expected: FAIL with module-not-found.

- [ ] **Step 3: Implement `status-mapper.ts`**

```typescript
import type { ChatStatus, VoiceChatPublicState } from './types'

export type RealtimeStatus = 'idle' | 'connecting' | 'connected' | 'reconnecting' | 'error'
export type RealtimeMode = 'idle' | 'listening' | 'thinking' | 'speaking'

export interface StatusFlags {
  isOffline: boolean
  hasError: boolean
}

export function mapStatus(rt: RealtimeStatus, flags: StatusFlags): VoiceChatPublicState {
  if (flags.hasError || rt === 'error') return 'error'
  if (flags.isOffline) return 'offline'
  if (rt === 'connecting' || rt === 'reconnecting') return 'connecting'
  if (rt === 'connected') return 'active'
  return 'idle'
}

export function mapChatStatus(rt: RealtimeStatus, mode: RealtimeMode): ChatStatus {
  if (rt === 'connecting' || rt === 'reconnecting') return 'connecting'
  if (rt !== 'connected') return 'idle'
  if (mode === 'thinking') return 'thinking'
  if (mode === 'speaking') return 'speaking'
  return 'idle'
}
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
pnpm test -- status-mapper
```

Expected: all 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/services/voice-chat/status-mapper.ts src/renderer/src/services/voice-chat/status-mapper.test.ts
git commit -m "feat(voice-chat): add status-mapper for TanStack AI realtime states"
```

---

### Task 3: `realtime-token.ts` — token envelope

**Files:**
- Create: `src/renderer/src/services/voice-chat/realtime-token.ts`
- Create: `src/renderer/src/services/voice-chat/realtime-token.test.ts`

Wraps the bare client_secret string returned by the existing worker into TanStack AI's `RealtimeToken` envelope. The 9-minute cushion under the worker's 10-minute TTL means the cache's expiry check trips before any actual key expiry.

- [ ] **Step 1: Write `realtime-token.test.ts`**

```typescript
import { describe, it, expect, vi } from 'vitest'
import { createRealtimeTokenFetcher } from './realtime-token'

describe('createRealtimeTokenFetcher', () => {
  it('wraps the worker string in a RealtimeToken envelope', async () => {
    const getSecret = vi.fn().mockResolvedValue('SECRET_123')
    const now = () => 1_000_000
    const fetcher = createRealtimeTokenFetcher({ getSecret, clock: { now } })

    const token = await fetcher('en')

    expect(token).toEqual({
      token: 'SECRET_123',
      provider: 'openai',
      expiresAt: 1_000_000 + 9 * 60 * 1000,
      config: {}
    })
    expect(getSecret).toHaveBeenCalledWith('en')
  })

  it('propagates worker errors unchanged', async () => {
    const fetcher = createRealtimeTokenFetcher({
      getSecret: vi.fn().mockRejectedValue(new Error('Not authenticated')),
      clock: { now: () => 0 }
    })
    await expect(fetcher('en')).rejects.toThrow('Not authenticated')
  })

  it('passes language through to the secret fetcher', async () => {
    const getSecret = vi.fn().mockResolvedValue('X')
    const fetcher = createRealtimeTokenFetcher({ getSecret, clock: { now: () => 0 } })
    await fetcher('es')
    expect(getSecret).toHaveBeenCalledWith('es')
  })
})
```

- [ ] **Step 2: Run — expect FAIL**

```bash
pnpm test -- realtime-token
```

- [ ] **Step 3: Implement `realtime-token.ts`**

```typescript
import type { RealtimeToken } from '@tanstack/ai-client'

const TTL_MS = 9 * 60 * 1000

export interface RealtimeTokenFetcherDeps {
  getSecret: (language: string) => Promise<string>
  clock: { now(): number }
}

export type RealtimeTokenFetcher = (language: string) => Promise<RealtimeToken>

export function createRealtimeTokenFetcher(deps: RealtimeTokenFetcherDeps): RealtimeTokenFetcher {
  return async (language: string) => {
    const secret = await deps.getSecret(language)
    return {
      token: secret,
      provider: 'openai',
      expiresAt: deps.clock.now() + TTL_MS,
      config: {}
    }
  }
}
```

- [ ] **Step 4: Run — expect PASS**

```bash
pnpm test -- realtime-token
```

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/services/voice-chat/realtime-token.ts src/renderer/src/services/voice-chat/realtime-token.test.ts
git commit -m "feat(voice-chat): add realtime-token envelope wrapper"
```

---

### Task 4: `buildRealtimeConfig.ts` — instructions + tools

**Files:**
- Create: `src/renderer/src/services/voice-chat/buildRealtimeConfig.ts`
- Create: `src/renderer/src/services/voice-chat/buildRealtimeConfig.test.ts`
- Reference (do not modify yet): `src/renderer/src/modules/buildRealtimeAgent.ts:1-243`

Replaces `buildRealtimeAgent` but does not delete it yet — the old module stays until the composition root switches over (Task 9). The new module returns a plain config object (no `RealtimeAgent` class). The `runToolCall` Effect wrapper is kept verbatim — it provides three-channel observability (console + dumpError + Sentry on error) that's still wanted.

- [ ] **Step 1: Write `buildRealtimeConfig.test.ts`**

```typescript
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { buildRealtimeConfig } from './buildRealtimeConfig'
import type { RagService } from '@/services/rag'

vi.mock('@/utils/sentry', () => ({ captureError: vi.fn() }))
vi.mock('@/services', () => ({
  getRagService: vi.fn(),
  getBookImportService: () => ({ isIndexing: vi.fn().mockReturnValue(false) })
}))

const dumpError = vi.fn().mockResolvedValue(undefined)
const electronMock = { dumpError }

beforeEach(() => {
  ;(globalThis as unknown as { window: { electron: typeof electronMock } }).window = {
    electron: electronMock
  }
  dumpError.mockClear()
})

function makeRag(): RagService {
  return {
    searchSemantic: vi.fn().mockResolvedValue([{ text: 'chunk-1' }, { text: 'chunk-2' }]),
    searchKeyword: vi.fn().mockResolvedValue([]),
    hasVectorsForBook: vi.fn().mockResolvedValue(true)
  } as unknown as RagService
}

describe('buildRealtimeConfig — shape', () => {
  it('returns instructions, tools, voice', () => {
    const cfg = buildRealtimeConfig({
      bookId: 1,
      pageText: 'page',
      onEndConversation: vi.fn(),
      rag: makeRag(),
      language: 'en'
    })
    expect(typeof cfg.instructions).toBe('string')
    expect(Array.isArray(cfg.tools)).toBe(true)
    expect(cfg.tools.map((t) => t.name)).toEqual(['bookContext', 'endConversation'])
    expect(cfg.voice).toBe('alloy')
  })

  it('includes language section', () => {
    const cfg = buildRealtimeConfig({
      bookId: 1, pageText: '', onEndConversation: vi.fn(), rag: makeRag(), language: 'es'
    })
    expect(cfg.instructions).toMatch(/Spanish/i)
  })

  it('includes outline section when outline provided', () => {
    const cfg = buildRealtimeConfig({
      bookId: 1,
      pageText: '',
      outline: { title: 'TT', author: 'AA', chapters: ['Ch1', 'Ch2'] },
      onEndConversation: vi.fn(),
      rag: makeRag(),
      language: 'en'
    })
    expect(cfg.instructions).toMatch(/Title:\*\* TT/)
    expect(cfg.instructions).toMatch(/- Ch1/)
  })

  it('includes activeParagraphText section when provided', () => {
    const cfg = buildRealtimeConfig({
      bookId: 1, pageText: '', activeParagraphText: 'PARAGRAPH', onEndConversation: vi.fn(),
      rag: makeRag(), language: 'en'
    })
    expect(cfg.instructions).toMatch(/PARAGRAPH/)
  })
})

describe('buildRealtimeConfig — bookContext tool', () => {
  it('returns chunk text on success', async () => {
    const rag = makeRag()
    const cfg = buildRealtimeConfig({
      bookId: 1, pageText: '', onEndConversation: vi.fn(), rag, language: 'en'
    })
    const bookContext = cfg.tools.find((t) => t.name === 'bookContext')!
    const out = await bookContext.execute({ queryText: 'q' })
    expect(out).toEqual(['chunk-1', 'chunk-2'])
    expect(rag.searchSemantic).toHaveBeenCalledWith('q', 1, 3)
  })

  it('returns fallback + dumpError on rag failure', async () => {
    const rag = {
      searchSemantic: vi.fn().mockRejectedValue(new Error('rag boom')),
      searchKeyword: vi.fn(),
      hasVectorsForBook: vi.fn()
    } as unknown as RagService
    const cfg = buildRealtimeConfig({
      bookId: 1, pageText: '', onEndConversation: vi.fn(), rag, language: 'en'
    })
    const bookContext = cfg.tools.find((t) => t.name === 'bookContext')!
    const out = await bookContext.execute({ queryText: 'q' })
    expect(out).toEqual(['Unable to retrieve book context at this time.'])
    expect(dumpError).toHaveBeenCalled()
  })

  it('emits dumpError on empty result (semantic warn, no Sentry)', async () => {
    const rag = {
      searchSemantic: vi.fn().mockResolvedValue([]),
      searchKeyword: vi.fn(),
      hasVectorsForBook: vi.fn()
    } as unknown as RagService
    const cfg = buildRealtimeConfig({
      bookId: 1, pageText: '', onEndConversation: vi.fn(), rag, language: 'en'
    })
    const bookContext = cfg.tools.find((t) => t.name === 'bookContext')!
    const out = await bookContext.execute({ queryText: 'q' })
    expect(out).toEqual([])
    expect(dumpError).toHaveBeenCalledWith(
      expect.objectContaining({ error: 'empty result' })
    )
  })
})

describe('buildRealtimeConfig — endConversation tool', () => {
  it('calls onEndConversation and resolves', async () => {
    const onEnd = vi.fn()
    const cfg = buildRealtimeConfig({
      bookId: 1, pageText: '', onEndConversation: onEnd, rag: makeRag(), language: 'en'
    })
    const endTool = cfg.tools.find((t) => t.name === 'endConversation')!
    await endTool.execute({ reason: 'user_done' })
    expect(onEnd).toHaveBeenCalledWith('user_done')
  })
})
```

- [ ] **Step 2: Run — expect FAIL**

```bash
pnpm test -- buildRealtimeConfig
```

- [ ] **Step 3: Implement `buildRealtimeConfig.ts`**

Port the entire body of `modules/buildRealtimeAgent.ts` into the new file, with these specific substitutions:

```typescript
import { getBookImportService } from '@/services'
import type { BookOutline } from '@/lib/api'
import type { RagService } from '@/services/rag'
import { toolDefinition } from '@tanstack/ai'
import { z } from 'zod'
import { Effect } from 'effect'
import { captureError } from '@/utils/sentry'
import { LANGUAGE_LABELS, isAllowedLanguage, DEFAULT_LANGUAGE } from '@/lib/languages'

// runToolCall is copied verbatim from modules/buildRealtimeAgent.ts:32-84 — no behavior change.
function runToolCall<T>(
  toolName: string,
  fallback: T,
  task: () => Promise<T>,
  inspect?: { isEmpty: (result: T) => boolean; contextOnEmpty: () => string }
): Promise<T> {
  const program = Effect.tryPromise({
    try: task,
    catch: (err) => (err instanceof Error ? err : new Error(String(err)))
  }).pipe(
    Effect.tap((result) =>
      Effect.sync(() => {
        if (inspect?.isEmpty(result)) {
          console.warn(`[voice-chat] tool '${toolName}' returned empty result. context:`, inspect.contextOnEmpty())
          void window.electron.dumpError({
            source: 'voice-chat-agent',
            location: `realtimeAgent.tools.${toolName}`,
            error: 'empty result',
            stack: null,
            context: inspect.contextOnEmpty()
          }).catch(() => undefined)
        } else {
          console.info(`[voice-chat] tool '${toolName}' ok`)
        }
      })
    ),
    Effect.catchAll((err) =>
      Effect.sync(() => {
        console.error(`[voice-chat] tool '${toolName}' failed:`, err)
        void window.electron.dumpError({
          source: 'voice-chat-agent',
          location: `realtimeAgent.tools.${toolName}`,
          error: err.message,
          stack: err.stack ?? null,
          context: null
        }).catch(() => undefined)
        captureError(err, { operation: 'realtime', step: `${toolName}_tool` })
        return fallback
      })
    )
  )
  return Effect.runPromise(program)
}

// Instructions renderers — port verbatim from modules/buildRealtimeAgent.ts:104-173.
function renderOutlineSection(outline: BookOutline | undefined): string { /* … verbatim … */ }
function renderActiveParagraphSection(activeParagraphText: string | undefined): string { /* … verbatim … */ }
function renderLanguageSection(language: string): string { /* … verbatim … */ }
const INSTRUCTIONS_TEMPLATE = (
  pageText: string,
  language: string,
  outline?: BookOutline,
  activeParagraphText?: string
): string => `/* … verbatim from modules/buildRealtimeAgent.ts:140-173 … */`

export interface BuildConfigOptions {
  bookId: number
  pageText: string
  outline?: BookOutline
  activeParagraphText?: string
  onEndConversation: (reason: string) => void
  language: string
  rag: RagService
}

export interface RealtimeConfig {
  instructions: string
  tools: ReadonlyArray<{
    name: string
    execute: (input: never) => Promise<unknown>
    definition: ReturnType<typeof toolDefinition>
  }>
  voice: string
}

export function buildRealtimeConfig(opts: BuildConfigOptions): RealtimeConfig {
  const { bookId, pageText, outline, activeParagraphText, onEndConversation, language, rag } = opts

  const bookContextExecute = ({ queryText }: { queryText: string }): Promise<string[]> =>
    runToolCall<string[]>(
      'bookContext',
      ['Unable to retrieve book context at this time.'],
      async () => {
        if (getBookImportService().isIndexing(bookId)) {
          return ["I'm still indexing this book — please give me a moment and try asking again."]
        }
        const chunks = await rag.searchSemantic(queryText, bookId, 3)
        return chunks.map((c) => c.text)
      },
      {
        isEmpty: (chunks) => chunks.length === 0,
        contextOnEmpty: () => `bookId=${bookId} queryText=${JSON.stringify(queryText)}`
      }
    )

  const bookContextDef = toolDefinition({
    name: 'bookContext',
    description:
      'Retrieve information from OTHER parts of the book beyond the current page. Only use this when the user asks about content NOT visible on their current page. Do NOT call this tool if the answer is already in the current page content provided in your instructions.',
    inputSchema: z.object({ queryText: z.string() })
  })

  const endConversationExecute = ({ reason }: { reason: string }): Promise<void> =>
    runToolCall<void>('endConversation', undefined, () => {
      onEndConversation(reason)
      return Promise.resolve()
    })

  const endConversationDef = toolDefinition({
    name: 'endConversation',
    description: 'End the conversation with the user.',
    inputSchema: z.object({ reason: z.string() })
  })

  return {
    instructions: INSTRUCTIONS_TEMPLATE(pageText, language, outline, activeParagraphText),
    tools: [
      { name: 'bookContext', execute: bookContextExecute as never, definition: bookContextDef.client(bookContextExecute) },
      { name: 'endConversation', execute: endConversationExecute as never, definition: endConversationDef.client(endConversationExecute) }
    ],
    voice: 'alloy'
  }
}
```

**Note for implementer:** the three render helpers and `INSTRUCTIONS_TEMPLATE` are copied verbatim from `modules/buildRealtimeAgent.ts:104-173`. Copy line-for-line; do not edit content.

- [ ] **Step 4: Run — expect PASS**

```bash
pnpm test -- buildRealtimeConfig
```

- [ ] **Step 5: Run typecheck**

```bash
pnpm typecheck
```

Expected: PASS. If `toolDefinition`'s exact return shape differs from the `RealtimeConfig.tools` element type, adjust the type to match what `RealtimeClient` accepts via `updateSession({ tools })`.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/src/services/voice-chat/buildRealtimeConfig.ts src/renderer/src/services/voice-chat/buildRealtimeConfig.test.ts
git commit -m "feat(voice-chat): add buildRealtimeConfig (replaces buildRealtimeAgent)"
```

---

### Task 5: Update `types.ts` port shape

**Files:**
- Modify: `src/renderer/src/services/voice-chat/types.ts`
- Modify: `src/renderer/src/services/voice-chat/types.test.ts` (re-verify if it asserts shape)

Replace SDK-specific ports with TanStack-AI-shaped ports. Public unions (`VoiceChatPublicState`, `ChatStatus`, `VoiceErrorReason`, `VoiceError`, `OfflineError`) remain unchanged so consumers don't break.

- [ ] **Step 1: Edit `types.ts`**

Remove these exports:
- `MediaStreamLike`, `AudioElementLike`, `MediaPort`
- `RealtimeAgentLike`, `RealtimeSessionLike`, `RtcTransportLike`
- `AgentFactoryArgs`, `WebrtcFactoryArgs`, `SessionFactoryOpts`

Add these new types:

```typescript
import type { RealtimeAdapter, RealtimeClient, RealtimeToken } from '@tanstack/ai-client'

export interface VoiceChatContext {
  pageText: string
  outline?: import('@/lib/api').BookOutline
  activeParagraphText?: string
}

export interface RealtimeClientOptions {
  adapter: RealtimeAdapter
  getToken: () => Promise<RealtimeToken>
  instructions: string
  voice: string
  tools: ReadonlyArray<unknown>
  onStatusChange?: (status: import('./status-mapper').RealtimeStatus) => void
  onModeChange?: (mode: import('./status-mapper').RealtimeMode) => void
  onMessage?: (message: unknown) => void
}

export type ClientFactory = (opts: RealtimeClientOptions) => RealtimeClient
```

Update `VoiceChatServiceDeps`:

```typescript
export interface VoiceChatServiceDeps {
  rag: RagService
  connectivity: ConnectivityService
  ipc: VoiceChatIpc
  adapter: RealtimeAdapter
  clientFactory: ClientFactory
  buildConfig: (args: {
    bookId: number
    pageText: string
    outline?: import('@/lib/api').BookOutline
    activeParagraphText?: string
    onEndConversation: (reason: string) => void
    rag: RagService
    language: string
  }) => import('./buildRealtimeConfig').RealtimeConfig
  effects: EffectsPort
  clock: ClockPort
  config: VoiceChatConfig
  getLanguage(): string
}
```

Keep unchanged:
- `VoiceChatPublicState`, `ChatStatus`, `VoiceErrorReason`, `VoiceError`, `OfflineError`
- `EffectsPort`, `ClockPort`
- `VoiceChatService`

Will change in Task 7 (left as-is here, intentionally producing a broken intermediate):
- `VoiceChatIpc.getRealtimeClientSecret(...) => Promise<string>` becomes `getRealtimeToken(...) => Promise<RealtimeToken>`
- `VoiceChatConfig.keyTtlMs` is removed (expiry now from the token envelope)

- [ ] **Step 2: Run typecheck**

```bash
pnpm typecheck
```

Expected: FAIL — references in `service.ts`, `index.ts` (services/index.ts and voice-chat/index.ts), `service.test.ts`, and `activation-program.ts` to removed ports.

These are addressed in Tasks 6-10. Leave them broken for now; **do not commit yet**.

---

### Task 6: Replace fake client helper in `service.test.ts`

**Files:**
- Modify: `src/renderer/src/services/voice-chat/service.test.ts`

Replace `makeWebrtc`, `makeAgent`, `makeSession`, `makeMedia` with a single `makeFakeClient` helper that mirrors `RealtimeClient`'s public surface. Replace `makeDeps` overrides accordingly.

- [ ] **Step 1: Add `makeFakeClient` helper at the top of the file (alongside existing helpers)**

```typescript
import type { RealtimeClient } from '@tanstack/ai-client'
import type { RealtimeStatus, RealtimeMode } from './status-mapper'
import type { ClientFactory, RealtimeClientOptions } from './types'

export interface FakeClientControl {
  client: RealtimeClient
  factory: ClientFactory
  lastOpts: () => RealtimeClientOptions | null
  connect: ReturnType<typeof vi.fn>
  disconnect: ReturnType<typeof vi.fn>
  updateSession: ReturnType<typeof vi.fn>
  destroy: ReturnType<typeof vi.fn>
  fireStatus: (status: RealtimeStatus) => void
  fireMode: (mode: RealtimeMode) => void
  fireMessage: (msg: unknown) => void
}

export function makeFakeClient(opts?: {
  connectDelayMs?: number
  connectFailWith?: Error
}): FakeClientControl {
  let lastOpts: RealtimeClientOptions | null = null
  let statusHandler: ((s: RealtimeStatus) => void) | null = null
  let modeHandler: ((m: RealtimeMode) => void) | null = null
  let messageHandler: ((m: unknown) => void) | null = null

  const connect = vi.fn().mockImplementation(async () => {
    if (opts?.connectFailWith) throw opts.connectFailWith
    if (opts?.connectDelayMs) await new Promise((r) => setTimeout(r, opts.connectDelayMs))
  })
  const disconnect = vi.fn().mockResolvedValue(undefined)
  const updateSession = vi.fn().mockResolvedValue(undefined)
  const destroy = vi.fn()

  const client = {
    connect,
    disconnect,
    updateSession,
    destroy,
    sendText: vi.fn(),
    onStateChange: () => () => undefined
  } as unknown as RealtimeClient

  const factory: ClientFactory = (o) => {
    lastOpts = o
    statusHandler = o.onStatusChange ?? null
    modeHandler = o.onModeChange ?? null
    messageHandler = o.onMessage ?? null
    return client
  }

  return {
    client, factory,
    lastOpts: () => lastOpts,
    connect, disconnect, updateSession, destroy,
    fireStatus: (s) => statusHandler?.(s),
    fireMode: (m) => modeHandler?.(m),
    fireMessage: (m) => messageHandler?.(m)
  }
}
```

- [ ] **Step 2: Replace `makeDeps` body**

```typescript
export function makeDeps(overrides?: Partial<VoiceChatServiceDeps>): VoiceChatServiceDeps {
  const fake = makeFakeClient()
  return {
    rag: makeRag(),
    connectivity: makeConnectivity(),
    ipc: makeIpc(),
    adapter: { provider: 'openai' } as unknown as import('@tanstack/ai-client').RealtimeAdapter,
    clientFactory: fake.factory,
    buildConfig: ({ language }) => ({
      instructions: `LANG=${language}`,
      tools: [],
      voice: 'alloy'
    }),
    effects: makeEffects(),
    clock: makeClock(),
    config: makeConfig(),
    getLanguage: () => 'en',
    ...overrides
  }
}
```

- [ ] **Step 3: Delete `makeWebrtc`, `makeAgent`, `makeSession`, `makeMedia`** from this file. They are no longer referenced.

- [ ] **Step 4: Run tests — expect MANY failures**

```bash
pnpm test -- service.test
```

Expected: most tests fail. They reference deleted helpers and the as-yet-unwritten new `service.ts` internals. Tasks 7-8 fix these.

- [ ] **Step 5: Do not commit yet.** This task leaves the file in a broken state intentionally — committing happens at the end of Task 7 after the facade rewrite is complete.

---

### Task 7: Rewrite `service.ts` cold path against `RealtimeClient`

**Files:**
- Modify: `src/renderer/src/services/voice-chat/service.ts`

Rewrite the facade in place. Delete xstate machine usage and Effect activation pipeline. Use plain TS for state tracking. The cold path becomes: connectivity check → token cache → buildConfig → clientFactory → `client.connect()` with timeout.

- [ ] **Step 1: Replace the top imports**

```typescript
import { captureError } from '@/utils/sentry'
import { createEmitter } from './emitter'
import { createKeyCache } from './key-cache'
import { OfflineError } from './types'
import { mapStatus, mapChatStatus } from './status-mapper'
import type { RealtimeStatus, RealtimeMode } from './status-mapper'
import type { RealtimeClient } from '@tanstack/ai-client'
import type {
  ChatStatus,
  ClockPort,
  VoiceChatContext,
  VoiceChatPublicState,
  VoiceChatService,
  VoiceChatServiceDeps,
  VoiceError,
  VoiceErrorReason
} from './types'
```

Remove imports of: `Effect`, `Fiber`, `createActor`, `voiceChatMachine`, `makeActivationProgram`, `isInterruptCause`, `SessionHandle`, `ActivationError`, anything from `./errors` except what's reused below.

- [ ] **Step 2: Replace the body of `createVoiceChatService` with the new implementation**

Key differences vs. the existing implementation:
- No xstate `actor`. Public state is a plain variable `currentState: VoiceChatPublicState` plus `currentError: VoiceError | null`. Both are written by `setState(next)` / `setError(err)` which emit through `stateEmitter`.
- `fingerprintContext` unchanged — preserve the `activeParagraphText` exclusion.
- Cold path: `keyCache.get()` → `buildConfig(...)` → `clientFactory({ adapter, getToken, instructions, voice, tools, onStatusChange, onModeChange })` → `Promise.race(client.connect(), timeout)`.
- `onStatusChange` callback: map → public state, reset inactivity timer on any emit.
- `onModeChange` callback: map → chat status. First `mode === 'speaking'` plays ready chime. `mode === 'thinking'` start thinking sound. Any transition out of `thinking` → stop thinking sound.
- Warm path: same `bookId` + fingerprint differs → `await client.updateSession({ instructions, tools })`. Same fingerprint → no-op beyond emitting `'idle'`.
- Different `bookId` → `disposeInternal()` then cold path.
- Errors: classify in the `connect()` catch using existing rules (NotAllowedError/NotFoundError → `mic_denied`; timeout race → `timeout`; "Not authenticated" or "auth" in message → `auth_failed`; otherwise `connect_failed`).

Full new file body (replace the entire `createVoiceChatService` export):

```typescript
export function createVoiceChatService(deps: VoiceChatServiceDeps): VoiceChatService {
  const {
    rag, connectivity, ipc, adapter, clientFactory, buildConfig,
    effects, clock, config, getLanguage
  } = deps

  const stateEmitter = createEmitter<VoiceChatPublicState>()
  const chatStatusEmitter = createEmitter<ChatStatus>()
  const endedByAgentEmitter = createEmitter<string>()

  let currentState: VoiceChatPublicState = 'idle'
  let currentError: VoiceError | null = null
  let isOffline = false
  function setState(next: VoiceChatPublicState): void {
    if (currentState === next) return
    currentState = next
    stateEmitter.emit(next)
  }
  function setError(err: VoiceError | null): void {
    currentError = err
  }

  const keyCache = createKeyCache({
    fetch: () => ipc.getRealtimeToken(getLanguage()),
    clock
  })

  let client: RealtimeClient | null = null
  let currentBookId: number | null = null
  let lastContextFingerprint: string | null = null
  let inactivityTimer: ReturnType<ClockPort['setTimeout']> | null = null
  let connectivityUnsub: (() => void) | null = null
  let started = false
  let lastRealtimeStatus: RealtimeStatus = 'idle'
  let lastRealtimeMode: RealtimeMode = 'idle'
  let hasFiredReadyChime = false

  function fingerprintContext(ctx: VoiceChatContext): string {
    return `${ctx.pageText}\n${JSON.stringify(ctx.outline ?? {})}`
  }

  function clearInactivityTimer(): void {
    if (inactivityTimer !== null) {
      clock.clearTimeout(inactivityTimer)
      inactivityTimer = null
    }
  }
  function scheduleInactivityTimer(): void {
    clearInactivityTimer()
    inactivityTimer = clock.setTimeout(() => {
      endedByAgentEmitter.emit('inactivity_timeout')
      disposeInternal()
    }, config.inactivityTimeoutMs)
  }
  function emitChatStatus(s: ChatStatus): void {
    if (client) scheduleInactivityTimer()
    chatStatusEmitter.emit(s)
  }

  function recomputePublicState(): void {
    setState(mapStatus(lastRealtimeStatus, { isOffline, hasError: currentError !== null }))
  }

  function onClientStatus(s: RealtimeStatus): void {
    lastRealtimeStatus = s
    if (s === 'error') {
      setError({ reason: 'session_error' })
    }
    recomputePublicState()
    emitChatStatus(mapChatStatus(s, lastRealtimeMode))
  }
  function onClientMode(m: RealtimeMode): void {
    lastRealtimeMode = m
    if (m === 'speaking' && !hasFiredReadyChime) {
      hasFiredReadyChime = true
      effects.playReadyChime()
    }
    if (m === 'thinking') effects.startThinkingSound()
    else effects.stopThinkingSound()
    emitChatStatus(mapChatStatus(lastRealtimeStatus, m))
  }

  function disposeInternal(): void {
    clearInactivityTimer()
    const c = client
    client = null
    currentBookId = null
    lastContextFingerprint = null
    hasFiredReadyChime = false
    lastRealtimeStatus = 'idle'
    lastRealtimeMode = 'idle'
    if (c) {
      try {
        c.destroy()
      } catch (err) {
        captureError(err, { operation: 'voiceChatService', step: 'dispose_destroy' })
      }
    }
    chatStatusEmitter.emit('idle')
    recomputePublicState()
  }

  function classifyError(err: unknown): VoiceErrorReason {
    if (err instanceof OfflineError) return 'connect_failed'
    const name = (err as { name?: string }).name
    const message = (err as { message?: string }).message ?? ''
    if (name === 'NotAllowedError' || name === 'NotFoundError') return 'mic_denied'
    if (message.includes('Not authenticated') || message.includes('auth')) return 'auth_failed'
    if (message.includes('timed out')) return 'timeout'
    return 'connect_failed'
  }

  async function doActivate(bookId: number, ctx: VoiceChatContext): Promise<void> {
    if (client && currentBookId !== null && currentBookId !== bookId) {
      disposeInternal()
    }

    // Warm path
    if (client && currentBookId === bookId) {
      setState('connecting')
      try {
        const fp = fingerprintContext(ctx)
        if (fp !== lastContextFingerprint) {
          const newConfig = buildConfig({
            bookId, pageText: ctx.pageText, outline: ctx.outline,
            activeParagraphText: ctx.activeParagraphText,
            onEndConversation: (r) => endedByAgentEmitter.emit(r),
            rag, language: getLanguage()
          })
          await client.updateSession({ instructions: newConfig.instructions, tools: newConfig.tools as never })
          lastContextFingerprint = fp
        }
        recomputePublicState()
        emitChatStatus('idle')
      } catch (err) {
        captureError(err, { operation: 'voiceChatService', step: 'activate_warm' })
        setError({ reason: classifyError(err), message: err instanceof Error ? err.message : undefined })
        recomputePublicState()
        throw err
      }
      return
    }

    // Cold path
    setState('connecting')
    chatStatusEmitter.emit('connecting')
    try {
      const token = await keyCache.get()
      const cfg = buildConfig({
        bookId, pageText: ctx.pageText, outline: ctx.outline,
        activeParagraphText: ctx.activeParagraphText,
        onEndConversation: (r) => endedByAgentEmitter.emit(r),
        rag, language: getLanguage()
      })
      client = clientFactory({
        adapter,
        getToken: () => keyCache.get(),
        instructions: cfg.instructions,
        voice: cfg.voice,
        tools: cfg.tools as never,
        onStatusChange: onClientStatus,
        onModeChange: onClientMode
      })

      const connectPromise = client.connect()
      const timeoutPromise = new Promise<never>((_, reject) => {
        const t = clock.setTimeout(
          () => reject(new Error(`Realtime session connect timed out after ${config.connectTimeoutMs / 1000}s`)),
          config.connectTimeoutMs
        )
        connectPromise.finally(() => clock.clearTimeout(t))
      })
      await Promise.race([connectPromise, timeoutPromise])
      void token

      currentBookId = bookId
      lastContextFingerprint = fingerprintContext(ctx)
      recomputePublicState()
      emitChatStatus('idle')
    } catch (err) {
      const reason = classifyError(err)
      setError({ reason, message: err instanceof Error ? err.message : undefined })
      if (client) {
        try { client.destroy() } catch { /* */ }
        client = null
      }
      recomputePublicState()
      chatStatusEmitter.emit('idle')
      throw err
    }
  }

  const svc: VoiceChatService = {
    start() {
      if (started) return
      started = true
      connectivityUnsub = connectivity.subscribe((online) => {
        if (!online) {
          isOffline = true
          if (client) disposeInternal()
          recomputePublicState()
        } else if (currentState === 'offline') {
          isOffline = false
          recomputePublicState()
        } else {
          isOffline = false
        }
      })
    },
    stop() {
      if (!started) return
      started = false
      disposeInternal()
      if (connectivityUnsub) connectivityUnsub()
      connectivityUnsub = null
    },
    async activate(bookId, ctx) {
      if (!connectivity.isOnline()) {
        isOffline = true
        recomputePublicState()
        throw new OfflineError()
      }
      isOffline = false
      await doActivate(bookId, ctx)
    },
    preconnect: () => Promise.resolve(),
    deactivate() {
      if (currentState === 'idle' || currentState === 'offline' || currentState === 'error') return
      disposeInternal()
    },
    dispose() { disposeInternal() },
    prewarmKey() { void keyCache.get() },
    invalidateKey() { keyCache.invalidate() },
    getState() { return currentState },
    getError() { return currentError },
    dismissError() {
      setError(null)
      recomputePublicState()
    },
    onStateChange: stateEmitter.on,
    onChatStatus: chatStatusEmitter.on,
    onEndedByAgent: endedByAgentEmitter.on
  }

  return svc
}
```

- [ ] **Step 3: Update `VoiceChatIpc` and the IPC port shape**

In `types.ts`:

```typescript
import type { RealtimeToken } from '@tanstack/ai-client'

export interface VoiceChatIpc {
  getRealtimeToken(language: string): Promise<RealtimeToken>
}
```

And update `service.test.ts`'s `makeIpc`:

```typescript
export function makeIpc(opts?: { key?: string; failWith?: Error; expiresAt?: number }): VoiceChatIpc {
  return {
    getRealtimeToken: vi.fn().mockImplementation(async (_language: string) => {
      if (opts?.failWith) throw opts.failWith
      return {
        token: opts?.key ?? 'test-key',
        provider: 'openai' as const,
        expiresAt: opts?.expiresAt ?? Date.now() + 9 * 60 * 1000,
        config: {}
      }
    })
  }
}
```

- [ ] **Step 4: Remove `keyTtlMs` from `VoiceChatConfig` in `types.ts`**

```typescript
export interface VoiceChatConfig {
  inactivityTimeoutMs: number
  connectTimeoutMs: number
  // keyTtlMs removed — expiry now comes from RealtimeToken.expiresAt
}
```

Update `makeConfig` in `service.test.ts` accordingly (drop the `keyTtlMs` field).

- [ ] **Step 5: Update `key-cache.ts` for new fetcher signature + expiry-based TTL**

```typescript
import type { ClockPort } from './types'
import type { RealtimeToken } from '@tanstack/ai-client'

export interface KeyCache {
  get(): Promise<RealtimeToken>
  invalidate(): void
}

export interface KeyCacheDeps {
  fetch: () => Promise<RealtimeToken>
  clock: ClockPort
}

export function createKeyCache(deps: KeyCacheDeps): KeyCache {
  const { fetch, clock } = deps
  let cached: RealtimeToken | null = null
  let inflight: Promise<RealtimeToken> | null = null
  let generation = 0

  return {
    async get() {
      if (cached && clock.now() < cached.expiresAt) return cached
      if (inflight) return inflight
      const myGen = generation
      inflight = (async () => {
        try {
          const token = await fetch()
          if (myGen === generation) cached = token
          return token
        } finally {
          if (myGen === generation) inflight = null
        }
      })()
      return inflight
    },
    invalidate() {
      cached = null
      inflight = null
      generation++
    }
  }
}
```

Update `key-cache.test.ts` correspondingly: fetcher returns `RealtimeToken` shape; "past TTL" tests advance `clock.now()` past `token.expiresAt` instead of `fetchedAt + ttlMs`. The `VoiceChatConfig.keyTtlMs` field becomes unused — remove it from `types.ts` and any test fixtures.

- [ ] **Step 6: Rewrite/re-target the test bodies in `service.test.ts`**

Apply these transformation rules across the existing test bodies:

| Before | After |
|---|---|
| `webrtc.callCount()` | `fake.factory` call count (track via spy or override) |
| `agent.lastArgs()?.bookId === N` | `fake.lastOpts()?.instructions.includes('N-marker')` (or via `buildConfig` mock) |
| `session.connect` was called with `{ apiKey }` | `fake.connect` was called (no args) and `fake.lastOpts()?.getToken` returned a token |
| `session.fire('agent_start')` | `fake.fireMode('thinking')` then `fake.fireMode('speaking')` |
| `session.fire('audio_start')` | `fake.fireMode('speaking')` |
| `session.fire('audio_stopped')` | `fake.fireMode('idle')` |
| `session.fire('agent_tool_start')` | `fake.fireMode('thinking')` |
| `session.fire('agent_tool_end')` | `fake.fireMode('speaking' \| 'idle')` |
| `session.fire('error', err)` | `fake.fireStatus('error')` |
| `session.updateAgent` | `fake.updateSession` |
| `session.close` | `fake.destroy` |
| `mute(false)` assertions | drop — client owns mute internally |
| Mic-denied test using `makeMedia({ denyMic: true })` | `makeFakeClient({ connectFailWith: Object.assign(new Error('denied'), { name: 'NotAllowedError' }) })` |
| Connect timeout test relying on `connectDelayMs` | same `connectDelayMs` on the fake client, plus `clock.tick(config.connectTimeoutMs + 1)` |

Tests to delete (no analogue under the new architecture):
- Any test of `Fiber.interrupt` supersede semantics
- Any test of "warm preconnect" (now a no-op)
- Tests asserting on `webrtcFactory`/`agentFactory`/`sessionFactory` call counts directly
- Tests asserting on `RealtimeAgentLike`-shaped values

Tests to keep (re-targeted via the table above):
- All `lifecycle` describe blocks
- `activate (cold happy path)` — assert states `['connecting', 'active']`, `fake.connect` called, `lastOpts.getToken` returned the seeded token
- Warm path — same bookId + ctx fingerprint differs → `fake.updateSession` called; same fingerprint → not called
- Different bookId → `fake.destroy` called then new client created
- Inactivity timer → `clock.tick(180_001)` after activate → `endedByAgent` fires, state returns to `idle`
- Connectivity → `connectivity.setOnline(false)` while active → `destroy` + state `'offline'`
- Mic denied / auth failed / timeout / generic connect failed — assert `getError().reason`
- Tool call observability — moved to `buildRealtimeConfig.test.ts` (Task 4); delete from this file

- [ ] **Step 7: Run tests — expect PASS**

```bash
pnpm test -- service.test
```

If any test fails because the fake-client mock differs from the real `RealtimeClient` signature, **do not adjust the mock to "match" the test** — adjust the test to call the right method. The wiring-truth test in Task 9 catches the inverse mismatch.

- [ ] **Step 8: Run typecheck**

```bash
pnpm typecheck
```

Expected: PASS once `activation-program.ts` and `machine.ts` are no longer imported. If `services/index.ts` (composition root) still references old ports, that's Task 10; either temporarily stub the composition root or accept the error in `services/index.ts` only.

- [ ] **Step 9: Commit**

```bash
git add src/renderer/src/services/voice-chat/types.ts \
        src/renderer/src/services/voice-chat/service.ts \
        src/renderer/src/services/voice-chat/service.test.ts \
        src/renderer/src/services/voice-chat/key-cache.ts \
        src/renderer/src/services/voice-chat/key-cache.test.ts
git commit -m "refactor(voice-chat): drive realtime session via @tanstack/ai-client"
```

---

### Task 8: Update `services/voice-chat/index.ts` re-exports

**Files:**
- Modify: `src/renderer/src/services/voice-chat/index.ts`

- [ ] **Step 1: Replace the exports block**

```typescript
export { createVoiceChatService } from './service'
export { OfflineError } from './types'
export { buildRealtimeConfig } from './buildRealtimeConfig'
export { createRealtimeTokenFetcher } from './realtime-token'
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
  EffectsPort,
  ClockPort,
  RealtimeClientOptions,
  ClientFactory
} from './types'
```

- [ ] **Step 2: Run typecheck**

```bash
pnpm typecheck
```

Expected: errors only in `services/index.ts` (composition root) — fixed in Task 10.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/src/services/voice-chat/index.ts
git commit -m "refactor(voice-chat): update barrel exports for new port shape"
```

---

### Task 9: Wiring-truth test with `fake-adapter.ts`

**Files:**
- Create: `src/renderer/src/services/voice-chat/fake-adapter.ts`
- Create: `src/renderer/src/services/voice-chat/wiring-integration.test.ts`

A test-only `RealtimeAdapter` implementation that runs through a real `RealtimeClient`. Catches drift between our `makeFakeClient` mock and the actual `RealtimeClient` API.

- [ ] **Step 1: Discover the real `RealtimeAdapter` interface**

Run:

```bash
grep -r "export interface RealtimeAdapter\|export type RealtimeAdapter" node_modules/@tanstack/ai-client/dist
```

Note the exact method signatures expected. Build `fake-adapter.ts` to satisfy that contract.

- [ ] **Step 2: Implement `fake-adapter.ts`**

The adapter is minimal: it records `connect/disconnect/updateSession/tool-result` calls and exposes triggers for status/mode/message events flowing back to the client. The exact shape depends on the discovered interface — implementer fills in the methods. Example skeleton:

```typescript
import type { RealtimeAdapter } from '@tanstack/ai-client'

export interface FakeAdapterControl {
  adapter: RealtimeAdapter
  calls: {
    connect: number
    disconnect: number
    updateSession: Array<{ instructions?: string }>
  }
  // … plus triggers to push status/mode/message events back to the client
}

export function createFakeAdapter(): FakeAdapterControl {
  // Implementer fills this in after reading the real RealtimeAdapter interface.
  // Goal: minimal stub that lets RealtimeClient.connect() / updateSession() /
  // tool-call round-trip complete without a real WebRTC connection.
  throw new Error('TODO: implement against the real RealtimeAdapter contract')
}
```

- [ ] **Step 3: Write `wiring-integration.test.ts`**

```typescript
import { describe, it, expect, vi } from 'vitest'
import { RealtimeClient } from '@tanstack/ai-client'
import { createFakeAdapter } from './fake-adapter'

describe('RealtimeClient wiring (truth test against fake adapter)', () => {
  it('connect() calls getToken and then adapter.connect', async () => {
    const fake = createFakeAdapter()
    const getToken = vi.fn().mockResolvedValue({
      token: 'T', provider: 'openai', expiresAt: Date.now() + 60_000, config: {}
    })
    const client = new RealtimeClient({
      adapter: fake.adapter,
      getToken,
      instructions: 'hi',
      voice: 'alloy'
    })
    await client.connect()
    expect(getToken).toHaveBeenCalledTimes(1)
    expect(fake.calls.connect).toBe(1)
  })

  it('updateSession({ instructions }) reaches the adapter', async () => {
    const fake = createFakeAdapter()
    const client = new RealtimeClient({
      adapter: fake.adapter,
      getToken: vi.fn().mockResolvedValue({
        token: 'T', provider: 'openai', expiresAt: Date.now() + 60_000, config: {}
      }),
      instructions: 'hi',
      voice: 'alloy'
    })
    await client.connect()
    await client.updateSession({ instructions: 'new instructions' })
    expect(fake.calls.updateSession).toContainEqual(expect.objectContaining({ instructions: 'new instructions' }))
  })
})
```

- [ ] **Step 4: Run — implement until tests pass**

```bash
pnpm test -- wiring-integration
```

If the wiring test reveals our `service.ts` calls `updateSession` with a shape `RealtimeClient` doesn't accept, fix `service.ts` (not the test).

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/services/voice-chat/fake-adapter.ts src/renderer/src/services/voice-chat/wiring-integration.test.ts
git commit -m "test(voice-chat): add wiring-truth integration test for RealtimeClient"
```

---

### Task 10: Switch composition root in `services/index.ts`

**Files:**
- Modify: `src/renderer/src/services/index.ts`

- [ ] **Step 1: Replace the voice-chat imports**

Remove:
```typescript
import { buildRealtimeAgent } from '@/modules/buildRealtimeAgent'
import { RealtimeSession } from '@openai/agents/realtime'
import { OpenAIRealtimeWebRTC } from '@openai/agents-realtime'
```

Add:
```typescript
import { RealtimeClient } from '@tanstack/ai-client'
import { openaiRealtime } from '@tanstack/ai-openai'
import { buildRealtimeConfig, createRealtimeTokenFetcher } from './voice-chat'
```

- [ ] **Step 2: Rewrite `getVoiceChatService` body**

```typescript
export function getVoiceChatService(): VoiceChatService {
  if (!_voiceChat) {
    const tokenFetcher = createRealtimeTokenFetcher({
      getSecret: getRealtimeClientSecret,
      clock: { now: () => Date.now() }
    })

    _voiceChat = createVoiceChatService({
      rag: getRagService(),
      connectivity: getConnectivityService(),
      ipc: { getRealtimeToken: tokenFetcher },
      adapter: openaiRealtime(),
      clientFactory: (opts) => new RealtimeClient(opts),
      buildConfig: buildRealtimeConfig,
      effects: { playReadyChime, startThinkingSound, stopThinkingSound },
      clock: {
        now: () => Date.now(),
        setTimeout: (fn, ms) => setTimeout(fn, ms),
        clearTimeout: (handle) => clearTimeout(handle)
      },
      config: {
        inactivityTimeoutMs: 3 * 60 * 1000,
        connectTimeoutMs: 60 * 1000
        // keyTtlMs removed — expiry now comes from the token envelope
      },
      getLanguage: () => usePrefsStore.getState().voiceChatLanguage
    })
    _voiceChat.start()
    void usePrefsStore.getState().hydrate().catch((err) => {
      console.warn('[prefs] hydrate failed', err)
    })
  }
  return _voiceChat
}
```

- [ ] **Step 3: Run typecheck**

```bash
pnpm typecheck
```

Expected: PASS. If `RealtimeClient` constructor rejects the `tools` shape from `buildRealtimeConfig`, adjust `buildRealtimeConfig.ts`'s `tools` element type to whatever `RealtimeClient` accepts (likely `RealtimeToolConfig[]` — the `.client(execute)` result type from `toolDefinition`).

- [ ] **Step 4: Run the whole test suite**

```bash
pnpm test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/services/index.ts
git commit -m "refactor(voice-chat): wire openaiRealtime adapter at composition root"
```

---

### Task 11: Delete dead code

**Files:**
- Delete: `src/renderer/src/services/voice-chat/machine.ts`
- Delete: `src/renderer/src/services/voice-chat/machine.test.ts`
- Delete: `src/renderer/src/services/voice-chat/activation-program.ts`
- Delete: `src/renderer/src/modules/buildRealtimeAgent.ts`
- Delete: `src/renderer/src/modules/buildRealtimeAgent.test.ts`
- Modify: `src/renderer/src/services/voice-chat/errors.ts` — keep only `MicDeniedError`, `AuthFailedError`, `ConnectTimeoutError`, `ConnectFailedError`, `SessionError`, `toPublicError`, `reasonOf`. Drop `ActivationError` re-export if it's no longer referenced.

- [ ] **Step 1: Delete the four files**

```bash
rm src/renderer/src/services/voice-chat/machine.ts
rm src/renderer/src/services/voice-chat/machine.test.ts
rm src/renderer/src/services/voice-chat/activation-program.ts
rm src/renderer/src/modules/buildRealtimeAgent.ts
rm src/renderer/src/modules/buildRealtimeAgent.test.ts
```

- [ ] **Step 2: Verify no remaining imports**

```bash
grep -rn "modules/buildRealtimeAgent\|voice-chat/machine\|voice-chat/activation-program" src/
```

Expected: no matches.

- [ ] **Step 3: Run the full test suite + typecheck**

```bash
pnpm test && pnpm typecheck
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add -u src/
git commit -m "chore(voice-chat): remove xstate machine and Effect activation pipeline"
```

---

### Task 12: Remove `@openai/agents` deps

**Files:**
- Modify: `apps/rishi-electron/package.json`

- [ ] **Step 1: Verify no remaining imports from `@openai/agents`**

```bash
grep -rn "@openai/agents" src/
```

Expected: no matches.

- [ ] **Step 2: Uninstall**

```bash
pnpm remove @openai/agents
# Only run the next line if `@openai/agents-realtime` is in deps:
pnpm remove @openai/agents-realtime 2>/dev/null || true
```

- [ ] **Step 3: Verify type check + tests still pass**

```bash
pnpm typecheck && pnpm test
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add package.json pnpm-lock.yaml
git commit -m "chore(voice-chat): remove @openai/agents{,-realtime} dependencies"
```

---

### Task 13: E2E smoke test (manual)

Per repo policy (UI changes require a real browser/app smoke before completion).

- [ ] **Step 1: Launch the app**

```bash
pnpm dev
```

- [ ] **Step 2: Smoke checklist**

Open a book. Then verify:

- [ ] **Voice chat activates.** Hit the voice button. Status transitions: `idle → connecting → active`. Mic permission prompt appears on first run. Audio output works.
- [ ] **Tool call works.** Ask a question about content NOT on the current page ("What happens in chapter 5?"). Expect a brief preamble + retrieval + answer.
- [ ] **`endConversation` tool fires.** Say "thanks, that's all". Agent gives a closing line; chat returns to `idle`; `onEndedByAgent` is observed (sound effect cessation).
- [ ] **Warm path on page turn.** While voice is active and idle, turn the page. Confirm no reconnect — status stays `active`, no mic-permission flicker. Ask a question — agent's reply reflects the new page content.
- [ ] **Cold path on book switch.** Open a different book while voice is active. Confirm full dispose + reconnect.
- [ ] **Inactivity timeout.** Activate, then wait > 3 minutes without interaction. Confirm auto-disconnect with `inactivity_timeout` reason.
- [ ] **Offline behavior.** Disable network. Confirm active session disposes and state transitions to `offline`. Re-enable; confirm next activation works.
- [ ] **Error UX.** Force mic denial via OS settings. Confirm `getError().reason === 'mic_denied'` and the existing error UI surfaces it.

- [ ] **Step 3: Capture findings**

If anything regressed, fix in a new commit before declaring the migration complete. Verification items from the spec (token `config` shape, `onModeChange` semantics for tool calls) should each have a confirmation note in the commit message.

- [ ] **Step 4: Tag the migration complete**

```bash
git log --oneline -15
```

Confirm the migration tasks (1-12) are all present. No commit needed for this task — the smoke test is a gate, not an artifact.

---

## Self-review notes

**Spec coverage:**
- Architecture (spec §Architecture) — Tasks 2, 3, 4, 7
- File list (spec §File-level changes) — exhaustive mapping in this plan's File Structure
- Data flow cold path (spec §Data and control flow) — Task 7 Step 2
- Data flow warm path — Task 7 Step 2
- Lifecycle event mapping — Task 2 (mapper) + Task 7 Step 2 (handlers)
- Tools migration (spec §Section 5) — Task 4
- Token shape (spec §Section 4) — Task 3
- Provider seam (spec §Section 5) — Task 10 (single call site for `openaiRealtime()`)
- Error handling (spec §Section 7) — Task 7 Step 2 `classifyError`
- Test plan T3 (spec §Section 8) — Task 7 (mock client unit tests) + Task 9 (fake-adapter integration)
- Verification items (token `config`, `onModeChange` semantics) — Task 13 smoke checklist

**Type consistency:** `ClientFactory`, `RealtimeClientOptions`, `RealtimeConfig` referenced in Tasks 5-10 use the same names throughout. `getRealtimeToken` (vs old `getRealtimeClientSecret`) renamed consistently in Tasks 5, 7, 10.

**No placeholders flagged** — every step has runnable code or commands. Two exceptions deliberately marked: Task 4 Step 3's "verbatim port" of `INSTRUCTIONS_TEMPLATE` and the three render helpers (acceptable — they're a literal copy from a referenced file at a referenced line range) and Task 9 Step 2's "implementer fills in" for `fake-adapter.ts` (acceptable — we can't know the exact `RealtimeAdapter` interface without reading the installed package source, which Step 1 of that task does).

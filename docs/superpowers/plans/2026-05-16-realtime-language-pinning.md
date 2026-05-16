# Realtime API Language Pinning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pin the OpenAI Realtime voice-chat conversation to a user-chosen language (default English) so accent-driven misclassification stops causing wrong-language responses.

**Architecture:** A single user pref `voiceChatLanguage` (ISO-639-1) lives in a new Zustand `prefsStore`, persisted via the existing `window.electron.getStoreValue` / `setStoreValue` IPC. The language is read at activation time and applied at two sites: (1) the worker's `/api/realtime/client_secrets` endpoint takes a `?language=xx` query param and injects it into `audio.input.transcription.language` of the OpenAI session, and (2) the renderer's `buildRealtimeAgent` adds a "Respond in {LANGUAGE}" line to the system instructions. A settings dropdown in `routes/settings/account.tsx` lets the user change it; changing the pref invalidates the cached realtime ephemeral key.

**Tech Stack:** Electron 30+, React 19, Zustand, TanStack Router, vitest, OpenAI `@openai/agents/realtime`, Hono on Cloudflare Workers. Tests use vitest with `vi.fn()` mocks throughout the renderer.

---

## File Structure

**New files:**
- `apps/rishi-electron/src/renderer/src/stores/prefsStore.ts` — single-key Zustand store for `voiceChatLanguage`
- `apps/rishi-electron/src/renderer/src/stores/prefsStore.test.ts` — tests
- `apps/rishi-electron/src/renderer/src/lib/languages.ts` — `ALLOWED_LANGUAGES` + `LANGUAGE_LABELS` map (shared by agent prompt, settings UI, and pref validation)

**Modified files:**
- `apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.ts` — add `invalidate()` method
- `apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.test.ts` — extend
- `apps/rishi-electron/src/renderer/src/services/voice-chat/types.ts` — add `language` to `AgentFactoryArgs`; add `invalidateKey()` to `VoiceChatService`; add `getLanguage` port to `VoiceChatServiceDeps`
- `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts` — read language from `getLanguage()` dep at activation, pass to factory and key fetch; expose `invalidateKey()`
- `apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts` — extend
- `apps/rishi-electron/src/renderer/src/lib/api.ts` — `getRealtimeClientSecret(language?: string)` appends `?language=xx`
- `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts` — add `language` to `BuildAgentOptions`, insert language section in instructions
- `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.test.ts` — extend
- `apps/rishi-electron/src/renderer/src/services/index.ts` — wire `language` source into voice-chat factory; hydrate prefs at boot
- `apps/rishi-electron/src/renderer/src/routes/settings/account.tsx` — language `<select>` section
- `workers/worker/src/index.ts` — accept and validate `?language=`, inject into OpenAI request

---

## Task 1: Create the language allow-list module

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/lib/languages.ts`

This module is the single source of truth for which language codes are valid and how they map to human-readable names (used in the agent system prompt and the settings dropdown). It's imported by the prefs store, the agent builder, the worker request, and the settings UI — so getting this in first unblocks everything else.

- [ ] **Step 1: Write the file**

```ts
// apps/rishi-electron/src/renderer/src/lib/languages.ts

/**
 * ISO-639-1 codes for languages the realtime voice chat supports.
 *
 * Kept short on purpose — each entry must (a) be supported by OpenAI's
 * Realtime API transcription, and (b) be a language we expect a real
 * user to want voice chat in. Adding a code here also requires adding a
 * matching label below.
 *
 * The worker (`workers/worker/src/index.ts`) maintains a parallel list and
 * coerces unknown codes to 'en'. Keep them in sync.
 */
export const ALLOWED_LANGUAGES = [
  'en',
  'es',
  'fr',
  'de',
  'it',
  'pt',
  'ja',
  'ko',
  'zh',
  'ar',
  'hi',
  'ru'
] as const

export type AllowedLanguage = (typeof ALLOWED_LANGUAGES)[number]

export const DEFAULT_LANGUAGE: AllowedLanguage = 'en'

/**
 * Human-readable language names. The realtime model handles language *names*
 * better than ISO codes in instructions, so we pass these into the system
 * prompt rather than the codes themselves.
 */
export const LANGUAGE_LABELS: Record<AllowedLanguage, string> = {
  en: 'English',
  es: 'Spanish',
  fr: 'French',
  de: 'German',
  it: 'Italian',
  pt: 'Portuguese',
  ja: 'Japanese',
  ko: 'Korean',
  zh: 'Chinese',
  ar: 'Arabic',
  hi: 'Hindi',
  ru: 'Russian'
}

export function isAllowedLanguage(value: unknown): value is AllowedLanguage {
  return typeof value === 'string' && (ALLOWED_LANGUAGES as readonly string[]).includes(value)
}
```

- [ ] **Step 2: Verify it compiles**

Run: `pnpm --filter rishi-electron exec tsc -p tsconfig.web.json --noEmit`
Expected: no errors related to the new file.

- [ ] **Step 3: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/lib/languages.ts
git commit -m "feat(electron): add language allow-list for realtime voice chat"
```

---

## Task 2: Add `invalidate()` to key-cache (test first)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.ts`
- Test: `apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.test.ts`

The realtime ephemeral-key cache holds onto a key minted with whatever language was active at fetch time. When the user changes their language pref, we need to drop that cached key so the next chat fetches a new one with the new language. Add a single `invalidate()` method.

- [ ] **Step 1: Add the failing test**

Append to `apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.test.ts` (inside the `describe('createKeyCache', ...)` block, after the existing `it(...)` blocks):

```ts
  it('invalidate() forces the next get() to refetch', async () => {
    const clock = makeClock()
    clock.setNow(0)
    const fetchFn = vi.fn().mockResolvedValueOnce('K1').mockResolvedValueOnce('K2')
    const cache = createKeyCache({ fetch: fetchFn, ttlMs: 60_000, clock })

    await expect(cache.get()).resolves.toBe('K1')
    cache.invalidate()
    await expect(cache.get()).resolves.toBe('K2')
    expect(fetchFn).toHaveBeenCalledTimes(2)
  })
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter rishi-electron vitest run src/renderer/src/services/voice-chat/key-cache.test.ts`
Expected: FAIL — `cache.invalidate is not a function`.

- [ ] **Step 3: Add `invalidate()` to the `KeyCache` interface and implementation**

In `apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.ts`:

Replace the existing `KeyCache` interface:

```ts
export interface KeyCache {
  /**
   * Returns the cached key if within TTL, otherwise fetches a new one.
   * Concurrent callers share the in-flight promise.
   */
  get(): Promise<string>
  /**
   * Drop any cached key so the next `get()` refetches. Used when a setting
   * that affects the minted key (e.g., language) changes.
   */
  invalidate(): void
}
```

Then in the `return { ... }` of `createKeyCache`, add `invalidate` after `get`:

```ts
  return {
    async get() {
      // ... unchanged ...
    },
    invalidate() {
      cached = null
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter rishi-electron vitest run src/renderer/src/services/voice-chat/key-cache.test.ts`
Expected: PASS for all five tests (four existing + one new).

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.ts apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.test.ts
git commit -m "feat(voice-chat): add invalidate() to key-cache"
```

---

## Task 3: Extend `AgentFactoryArgs` and `VoiceChatService` types

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/voice-chat/types.ts`

Type-only change. Adds the `language` property the agent factory will receive, the `getLanguage` port the service uses to read from the pref store, and the `invalidateKey()` method the prefs store will call. Pure compile-time; no runtime change yet.

- [ ] **Step 1: Add `language` to `AgentFactoryArgs`**

In `apps/rishi-electron/src/renderer/src/services/voice-chat/types.ts`, replace the `AgentFactoryArgs` interface:

```ts
export interface AgentFactoryArgs {
  bookId: number
  pageText: string
  outline?: BookOutline
  activeParagraphText?: string
  onEndConversation: (reason: string) => void
  rag: RagService
  /** ISO-639-1 code for the language the agent must respond in. */
  language: string
}
```

- [ ] **Step 2: Add `getLanguage` port to `VoiceChatServiceDeps`**

In the same file, replace the `VoiceChatServiceDeps` interface:

```ts
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
  /**
   * Read the user's chosen voice-chat language at activation time. Synchronous
   * because the value lives in a hydrated Zustand store. Returns an ISO-639-1
   * code; callers must accept any string and validate downstream.
   */
  getLanguage(): string
}
```

- [ ] **Step 3: Update `VoiceChatIpc` to accept a language**

In the same file, replace the `VoiceChatIpc` interface:

```ts
export interface VoiceChatIpc {
  getRealtimeClientSecret(language: string): Promise<string>
}
```

- [ ] **Step 4: Add `invalidateKey()` to `VoiceChatService`**

Replace the `VoiceChatService` interface, adding `invalidateKey` after `prewarmKey`:

```ts
export interface VoiceChatService {
  start(): void
  stop(): void
  activate(bookId: number, ctx: VoiceChatContext): Promise<void>
  preconnect(bookId: number, ctx: VoiceChatContext): Promise<void>
  deactivate(): void
  dispose(): void
  prewarmKey(): void
  /**
   * Drop the cached realtime ephemeral key. Call after changing a setting
   * (e.g., language) that's baked into the minted key — the next activate()
   * will refetch with the new value.
   */
  invalidateKey(): void
  getState(): VoiceChatPublicState
  getError(): VoiceError | null
  dismissError(): void
  onStateChange(listener: (state: VoiceChatPublicState) => void): () => void
  onChatStatus(listener: (status: ChatStatus) => void): () => void
  onEndedByAgent(listener: (reason: string) => void): () => void
}
```

- [ ] **Step 5: Verify it does NOT yet compile (we want consumers to break)**

Run: `pnpm --filter rishi-electron exec tsc -p tsconfig.web.json --noEmit`
Expected: errors in `service.ts`, `services/index.ts`, `buildRealtimeAgent.ts`, `service.test.ts`. These are intentional — the next tasks fix them.

Do NOT commit yet — the next tasks fix the breakage atomically with this type change.

---

## Task 4: Implement `invalidateKey()` and `language` plumbing in service.ts (test first)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts`
- Test: `apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts`

Wire `getLanguage()` and pass language into both the agent factory and the IPC `getRealtimeClientSecret(language)` call. Surface `invalidateKey()` on the public interface.

- [ ] **Step 1: Find the existing service test setup**

Open `apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts` and locate the helper that builds the `deps` object passed to `createVoiceChatService`. (Look for a function like `makeDeps` near line 60-200.) Note the current shape so the new tests follow the same pattern.

- [ ] **Step 2: Add `getLanguage` to the test deps helper**

In `service.test.ts`, find the helper that constructs `VoiceChatServiceDeps` for tests. Add a `getLanguage` field that defaults to `() => 'en'`. If the helper takes overrides via a partial-options arg, allow `getLanguage` to be overridden.

Example (adapt to existing structure):

```ts
function makeDeps(overrides: Partial<VoiceChatServiceDeps> = {}): VoiceChatServiceDeps {
  // ... existing setup ...
  return {
    // ... existing fields ...
    getLanguage: overrides.getLanguage ?? (() => 'en'),
    ...overrides
  }
}
```

Also update the existing `ipc.getRealtimeClientSecret` mock so it accepts the new `language` argument:

```ts
const ipc: VoiceChatIpc = {
  getRealtimeClientSecret: vi.fn().mockImplementation(async (_language: string) => {
    // ... existing return ...
    return 'EPHEMERAL'
  })
}
```

- [ ] **Step 3: Add the failing test for `invalidateKey()`**

Append to `service.test.ts` inside the main `describe(...)` block:

```ts
  it('invalidateKey() drops the cached ephemeral key so next activate() refetches', async () => {
    const ipc = makeIpc({ key: 'EPHEMERAL' })
    const svc = createVoiceChatService(makeDeps({ ipc }))
    svc.start()

    await svc.activate(1, { pageText: 'p' })
    expect(ipc.getRealtimeClientSecret).toHaveBeenCalledTimes(1)
    svc.deactivate()

    // Without invalidate, the key cache (TTL 9min) would skip the second fetch.
    svc.invalidateKey()

    await svc.activate(1, { pageText: 'p' })
    expect(ipc.getRealtimeClientSecret).toHaveBeenCalledTimes(2)
  })
```

> Note: if `makeIpc` doesn't exist in the test file, use the existing pattern that constructs the `ipc` mock — adapt the test to the actual helpers available. The point is that `getRealtimeClientSecret` is called twice once `invalidateKey()` is in between.

- [ ] **Step 4: Add the failing test for language plumbing**

Append to `service.test.ts`:

```ts
  it('passes language from getLanguage() to agentFactory and getRealtimeClientSecret', async () => {
    const ipc = makeIpc({ key: 'EPHEMERAL' })
    const agentFactory = vi.fn().mockImplementation((args: AgentFactoryArgs) => ({ _agent: args }))
    const svc = createVoiceChatService(
      makeDeps({
        ipc,
        agentFactory,
        getLanguage: () => 'es'
      })
    )
    svc.start()

    await svc.activate(1, { pageText: 'p' })

    expect(ipc.getRealtimeClientSecret).toHaveBeenCalledWith('es')
    expect(agentFactory).toHaveBeenCalledWith(
      expect.objectContaining({ language: 'es' })
    )
  })
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `pnpm --filter rishi-electron vitest run src/renderer/src/services/voice-chat/service.test.ts`
Expected: the two new tests fail (compile errors and/or assertions). Existing tests may also fail because of the type change in Task 3.

- [ ] **Step 6: Update service.ts — destructure `getLanguage`**

In `apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts`, line ~44:

```ts
export function createVoiceChatService(deps: VoiceChatServiceDeps): VoiceChatService {
  const { rag, connectivity, ipc, agentFactory, effects, clock, config, getLanguage } = deps
```

- [ ] **Step 7: Update the keyCache fetch to pass language**

In `service.ts`, line ~60:

```ts
  const keyCache = createKeyCache({
    fetch: () => ipc.getRealtimeClientSecret(getLanguage()),
    ttlMs: config.keyTtlMs,
    clock
  })
```

- [ ] **Step 8: Pass `language` into the warm-path agent rebuild**

In `service.ts`, locate the warm-path block in `doActivate` (around line 167-189) where `agentFactory({...})` is called. Add `language: getLanguage()` to the args:

```ts
        if (fp !== lastContextFingerprint) {
          const newAgent = agentFactory({
            bookId,
            pageText: ctx.pageText,
            outline: ctx.outline,
            activeParagraphText: ctx.activeParagraphText,
            onEndConversation: (reason) => endedByAgentEmitter.emit(reason),
            rag,
            language: getLanguage()
          })
          await session.updateAgent(newAgent)
```

- [ ] **Step 9: Pass `language` into the cold-path agent build**

In `service.ts` cold-path the agent is built inside the activation program. Locate where `agentFactory` is invoked (it's threaded through `program.activate({ bookId, ctx })`). Update the activation-program call site if it builds the agent there. Open `apps/rishi-electron/src/renderer/src/services/voice-chat/activation-program.ts` and find the `agentFactory(...)` call.

Update that call to include `language: deps.getLanguage()`:

```ts
        const agent = deps.agentFactory({
          bookId,
          pageText: ctx.pageText,
          outline: ctx.outline,
          activeParagraphText: ctx.activeParagraphText,
          onEndConversation: (reason) => emit.endedByAgent(reason),
          rag: deps.rag,
          language: deps.getLanguage()
        })
```

(The exact structure depends on how the activation-program currently calls the factory. Read the file to find the call site, then add `language: deps.getLanguage()` to the arg object.)

- [ ] **Step 10: Add `invalidateKey()` to the public service object**

In `service.ts`, in the `const svc: VoiceChatService = { ... }` literal (line ~259), add after `prewarmKey`:

```ts
    invalidateKey() {
      keyCache.invalidate()
    },
```

- [ ] **Step 11: Run tests to verify they pass**

Run: `pnpm --filter rishi-electron vitest run src/renderer/src/services/voice-chat/service.test.ts`
Expected: PASS for all tests, including the two new ones.

- [ ] **Step 12: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/services/voice-chat/types.ts \
        apps/rishi-electron/src/renderer/src/services/voice-chat/service.ts \
        apps/rishi-electron/src/renderer/src/services/voice-chat/activation-program.ts \
        apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts
git commit -m "feat(voice-chat): plumb language through service and expose invalidateKey()"
```

---

## Task 5: Update `getRealtimeClientSecret(language)` (test via integration above)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/lib/api.ts:331-359`

The renderer-side IPC wrapper needs to accept and forward the language. The integration test added in Task 4 already asserts `ipc.getRealtimeClientSecret` was called with `'es'`, so this task is a pure plumbing change — no separate test file.

- [ ] **Step 1: Update the function signature**

In `apps/rishi-electron/src/renderer/src/lib/api.ts`, replace the `getRealtimeClientSecret` function (currently lines 331-359):

```ts
export async function getRealtimeClientSecret(language: string): Promise<string> {
  const authHeaders = await getAuthHeaders()
  const headers: Record<string, string> = { ...authHeaders }

  if (Object.keys(authHeaders).length === 0) {
    const devBypass = await api().getDevBypassSecret()
    if (devBypass) {
      headers['X-Dev-Bypass'] = devBypass
    } else {
      throw new Error('Not authenticated')
    }
  }

  const url = new URL(`${WORKER_URL}/api/realtime/client_secrets`)
  url.searchParams.set('language', language)

  const response = await fetch(url.toString(), {
    method: 'GET',
    headers
  })

  if (!response.ok) {
    throw new Error(`Worker API responded with status ${response.status}`)
  }

  const data = (await response.json()) as { client_secret?: { value?: string } }
  const secret = data.client_secret?.value
  if (!secret) {
    throw new Error('No client_secret in worker response')
  }
  return secret
}
```

- [ ] **Step 2: Verify typecheck and existing tests pass**

Run: `pnpm --filter rishi-electron exec tsc -p tsconfig.web.json --noEmit`
Expected: any callers of the old zero-arg signature show a type error. The only caller should be `service.ts:62` (the keyCache fetch), which Task 4 already updated to pass `getLanguage()`.

Run: `pnpm --filter rishi-electron vitest run src/renderer/src/services/voice-chat`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/lib/api.ts
git commit -m "feat(api): accept language param in getRealtimeClientSecret"
```

---

## Task 6: Add language section to `buildRealtimeAgent` (test first)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts`
- Test: `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.test.ts`

Insert a "Respond in {LANGUAGE_NAME}" block into the agent's system instructions. Use the human-readable label, not the raw code.

- [ ] **Step 1: Add the failing tests**

Append to `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.test.ts`, inside `describe('buildRealtimeAgent', ...)`:

```ts
  it('embeds the chosen language label into instructions (English)', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn(),
      language: 'en'
    })
    expect(agent.instructions).toMatch(/Always respond in English/)
  })

  it('embeds the chosen language label into instructions (Spanish)', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn(),
      language: 'es'
    })
    expect(agent.instructions).toMatch(/Always respond in Spanish/)
  })

  it('falls back to English label for an unknown language code', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn(),
      language: 'xx'
    })
    expect(agent.instructions).toMatch(/Always respond in English/)
  })
```

Also update the *existing* tests in this file (they construct `buildRealtimeAgent({...})` without a `language`). Add `language: 'en'` to each existing call so they keep compiling. Use a global find-and-add — there are about 6 existing tests.

- [ ] **Step 2: Run tests to verify the new tests fail and existing tests still pass**

Run: `pnpm --filter rishi-electron vitest run src/renderer/src/modules/buildRealtimeAgent.test.ts`
Expected: 3 new tests FAIL ("Always respond in English" not found); existing tests PASS.

- [ ] **Step 3: Update `BuildAgentOptions`**

In `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts:85-99`:

```ts
export interface BuildAgentOptions {
  bookId: number
  pageText: string
  outline?: BookOutline
  /** The paragraph TTS was reading aloud at chat-start. Helps the model resolve deictic references. */
  activeParagraphText?: string
  onEndConversation: (reason: string) => void
  /** ISO-639-1 code for the language the agent must respond in. */
  language: string
  /**
   * Optional RAG service for bookContext tool calls. When omitted, falls
   * back to `getRagService()` for backwards compatibility with the legacy
   * module-scoped `voiceChatService.ts`. The new `services/voice-chat/`
   * factory always supplies this dep explicitly.
   */
  rag?: RagService
}
```

- [ ] **Step 4: Add the import and the language section renderer**

At the top of `buildRealtimeAgent.ts`, add the languages import:

```ts
import { LANGUAGE_LABELS, isAllowedLanguage, DEFAULT_LANGUAGE } from '@/lib/languages'
```

Then, near `renderActiveParagraphSection` (around line 116), add:

```ts
function renderLanguageSection(language: string): string {
  const code = isAllowedLanguage(language) ? language : DEFAULT_LANGUAGE
  const label = LANGUAGE_LABELS[code]
  return `## Language
Always respond in ${label} regardless of the user's accent or pronunciation. Treat all input as ${label} unless the user explicitly switches mid-conversation.

`
}
```

- [ ] **Step 5: Update the instructions template**

Update `INSTRUCTIONS_TEMPLATE` (around line 128) to take and use `language`:

```ts
const INSTRUCTIONS_TEMPLATE = (
  pageText: string,
  language: string,
  outline?: BookOutline,
  activeParagraphText?: string
) => `## Role
You are a teaching assistant helping the user understand the book they're reading. Make complex ideas accessible and answer questions in a way that aids comprehension.

${renderLanguageSection(language)}${renderOutlineSection(outline)}## Current Page Content
"""
${pageText || '(No page text available)'}
"""
If the question is answerable from this page, answer directly. Use the bookContext tool only for content outside this page.

${renderActiveParagraphSection(activeParagraphText)}

## Rules
- Vary phrasing — never repeat the same sentence verbatim in a single response.
- Stay conversational; avoid scripted-sounding language.
- Before calling a tool, say one short line previewing what you're doing (5-12 words).
- Stay focused on the book, but allow natural chat flow.

## Tools

### bookContext
For content NOT visible on the current page. Provide a brief preamble before calling. Do not call if the answer is already in the current page text.

### endConversation
When the user clearly signals they're done (e.g., "thanks, that's all", "goodbye"), respond with a warm closing and call this tool. If the signal is ambiguous, confirm first. Provide a clear \`reason\` describing why the conversation is ending.

## Style notes
- First message: if the user asks a question, answer it directly. If they greet, respond briefly and ask how you can help.
- When explaining concepts, break down complexity and use analogies. Briefly check understanding before moving on.
- Keep responses concise unless depth is requested.`
```

- [ ] **Step 6: Update `buildRealtimeAgent` to destructure and pass `language`**

In `buildRealtimeAgent.ts:162-228`, update the function:

```ts
export function buildRealtimeAgent({
  bookId,
  pageText,
  outline,
  activeParagraphText,
  onEndConversation,
  language,
  rag
}: BuildAgentOptions): RealtimeAgent {
  // ... existing body unchanged through the tool definitions ...

  return new RealtimeAgent({
    name: 'Assistant',
    voice: 'alloy',
    instructions: INSTRUCTIONS_TEMPLATE(pageText, language, outline, activeParagraphText),
    tools: [bookContextTool, endConversationTool]
  })
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `pnpm --filter rishi-electron vitest run src/renderer/src/modules/buildRealtimeAgent.test.ts`
Expected: PASS for all tests.

- [ ] **Step 8: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts \
        apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.test.ts
git commit -m "feat(voice-chat): pin response language in agent instructions"
```

---

## Task 7: Create `prefsStore` (test first)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/stores/prefsStore.ts`
- Test: `apps/rishi-electron/src/renderer/src/stores/prefsStore.test.ts`

Single-key Zustand store. Hydrates from `window.electron.getStoreValue('voiceChatLanguage')` on first call to `hydrate()`. `setVoiceChatLanguage` writes through and invalidates the realtime ephemeral key.

- [ ] **Step 1: Write the test file**

```ts
// apps/rishi-electron/src/renderer/src/stores/prefsStore.test.ts
import { describe, it, expect, vi, beforeEach } from 'vitest'

const invalidateKeyMock = vi.fn()
vi.mock('@/services', () => ({
  getVoiceChatService: () => ({
    invalidateKey: invalidateKeyMock
  })
}))

describe('prefsStore', () => {
  beforeEach(() => {
    invalidateKeyMock.mockClear()
    vi.resetModules()
    ;(window.electron.getStoreValue as ReturnType<typeof vi.fn>).mockReset()
    ;(window.electron.setStoreValue as ReturnType<typeof vi.fn>).mockReset()
    ;(window.electron.setStoreValue as ReturnType<typeof vi.fn>).mockResolvedValue(undefined)
  })

  it('default voiceChatLanguage is "en"', async () => {
    const { usePrefsStore } = await import('./prefsStore')
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('en')
  })

  it('hydrate() reads voiceChatLanguage from the store IPC', async () => {
    ;(window.electron.getStoreValue as ReturnType<typeof vi.fn>).mockResolvedValue('es')
    const { usePrefsStore } = await import('./prefsStore')
    await usePrefsStore.getState().hydrate()
    expect(window.electron.getStoreValue).toHaveBeenCalledWith('voiceChatLanguage')
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('es')
  })

  it('hydrate() falls back to "en" when the IPC returns null', async () => {
    ;(window.electron.getStoreValue as ReturnType<typeof vi.fn>).mockResolvedValue(null)
    const { usePrefsStore } = await import('./prefsStore')
    await usePrefsStore.getState().hydrate()
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('en')
  })

  it('hydrate() falls back to "en" when the IPC returns an unknown code', async () => {
    ;(window.electron.getStoreValue as ReturnType<typeof vi.fn>).mockResolvedValue('xx')
    const { usePrefsStore } = await import('./prefsStore')
    await usePrefsStore.getState().hydrate()
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('en')
  })

  it('setVoiceChatLanguage writes via setStoreValue, invalidates the key, and updates state', async () => {
    const { usePrefsStore } = await import('./prefsStore')
    await usePrefsStore.getState().setVoiceChatLanguage('fr')
    expect(window.electron.setStoreValue).toHaveBeenCalledWith('voiceChatLanguage', 'fr')
    expect(invalidateKeyMock).toHaveBeenCalledTimes(1)
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('fr')
  })

  it('setVoiceChatLanguage rejects an unknown code (no-op)', async () => {
    const { usePrefsStore } = await import('./prefsStore')
    await usePrefsStore.getState().setVoiceChatLanguage('xx' as never)
    expect(window.electron.setStoreValue).not.toHaveBeenCalled()
    expect(invalidateKeyMock).not.toHaveBeenCalled()
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('en')
  })
})
```

> If `window.electron.getStoreValue` / `setStoreValue` are not pre-mocked in the test setup, find the existing test setup file (e.g. `vitest.setup.ts` or `vitest-setup.ts` under `apps/rishi-electron/`) and add stubs there. Search: `grep -rn "window.electron" apps/rishi-electron/src --include="*.setup.ts" --include="*.config.ts"`.

- [ ] **Step 2: Run tests to verify they fail (module doesn't exist yet)**

Run: `pnpm --filter rishi-electron vitest run src/renderer/src/stores/prefsStore.test.ts`
Expected: FAIL — `Cannot find module './prefsStore'`.

- [ ] **Step 3: Write the store**

```ts
// apps/rishi-electron/src/renderer/src/stores/prefsStore.ts
import { create } from 'zustand'
import { devtools } from 'zustand/middleware'
import { getVoiceChatService } from '@/services'
import {
  ALLOWED_LANGUAGES,
  DEFAULT_LANGUAGE,
  isAllowedLanguage,
  type AllowedLanguage
} from '@/lib/languages'

interface PrefsState {
  voiceChatLanguage: AllowedLanguage
  /**
   * Read the persisted value from the main-process store. Safe to call
   * multiple times; later calls overwrite the in-memory value.
   */
  hydrate: () => Promise<void>
  /**
   * Persist a new language choice and invalidate the realtime ephemeral
   * key so the next voice-chat activation uses the new language.
   *
   * Note: changes do NOT apply to a currently-active voice chat session.
   * The user must close and reopen the chat for the new language to take
   * effect mid-stream.
   */
  setVoiceChatLanguage: (lang: AllowedLanguage) => Promise<void>
}

export const usePrefsStore = create<PrefsState>()(
  devtools((set, get) => ({
    voiceChatLanguage: DEFAULT_LANGUAGE,

    async hydrate() {
      const raw = await window.electron.getStoreValue('voiceChatLanguage')
      const next: AllowedLanguage = isAllowedLanguage(raw) ? raw : DEFAULT_LANGUAGE
      set({ voiceChatLanguage: next })
    },

    async setVoiceChatLanguage(lang) {
      if (!isAllowedLanguage(lang)) return
      if (get().voiceChatLanguage === lang) return
      await window.electron.setStoreValue('voiceChatLanguage', lang)
      // Invalidate AFTER the write succeeds so a failed write doesn't
      // leave the cache in an inconsistent state.
      getVoiceChatService().invalidateKey()
      set({ voiceChatLanguage: lang })
    }
  }))
)

// Re-export so consumers don't need a second import for the allow-list.
export { ALLOWED_LANGUAGES }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm --filter rishi-electron vitest run src/renderer/src/stores/prefsStore.test.ts`
Expected: PASS for all six tests.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/stores/prefsStore.ts \
        apps/rishi-electron/src/renderer/src/stores/prefsStore.test.ts
git commit -m "feat(stores): add prefsStore for voice-chat language"
```

---

## Task 8: Wire `getLanguage` into the voice-chat factory and hydrate at boot

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/index.ts:222-272`

`getVoiceChatService` constructs the service with deps. Add `getLanguage: () => usePrefsStore.getState().voiceChatLanguage` and trigger `hydrate()` once at boot so the value is available on first activation.

- [ ] **Step 1: Open the file**

Read `apps/rishi-electron/src/renderer/src/services/index.ts` and find the `getVoiceChatService` function.

- [ ] **Step 2: Add the import**

At the top of the file, add:

```ts
import { usePrefsStore } from '@/stores/prefsStore'
```

- [ ] **Step 3: Pass `getLanguage` into the deps and trigger hydrate**

In `getVoiceChatService` (around line 222), update the `createVoiceChatService` call to include `getLanguage`. Add the line that kicks off hydration just after `_voiceChat.start()`.

```ts
export function getVoiceChatService(): VoiceChatService {
  if (!_voiceChat) {
    _voiceChat = createVoiceChatService({
      rag: getRagService(),
      connectivity: getConnectivityService(),
      ipc: { getRealtimeClientSecret },
      // ... unchanged: webrtcFactory, agentFactory, sessionFactory, media, effects, clock, config ...
      getLanguage: () => usePrefsStore.getState().voiceChatLanguage
    })
    _voiceChat.start()
    // Fire-and-forget: hydration is sub-50ms; if a chat starts before it
    // resolves, the store returns the default 'en'. Catch logs but does
    // not surface — a failure here just leaves the user on the default.
    void usePrefsStore
      .getState()
      .hydrate()
      .catch((err) => {
        console.warn('[prefs] hydrate failed', err)
      })
  }
  return _voiceChat
}
```

> The exact placement of `getLanguage` in the deps object literal depends on field ordering — put it next to `agentFactory` for readability, or at the end. Either is fine.

- [ ] **Step 4: Verify typecheck and full test suite pass**

Run: `pnpm --filter rishi-electron exec tsc -p tsconfig.web.json --noEmit`
Expected: no errors.

Run: `pnpm --filter rishi-electron vitest run`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/services/index.ts
git commit -m "feat(services): wire prefsStore into voice-chat factory"
```

---

## Task 9: Add the language dropdown to the settings page

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/routes/settings/account.tsx`

A simple `<section>` above the danger-zone block. No save button — change commits on `onChange`.

- [ ] **Step 1: Add imports at the top**

In `apps/rishi-electron/src/renderer/src/routes/settings/account.tsx`, add after the existing imports:

```ts
import { usePrefsStore } from '@/stores/prefsStore'
import { ALLOWED_LANGUAGES, LANGUAGE_LABELS } from '@/lib/languages'
```

- [ ] **Step 2: Read the pref inside the component**

Inside `AccountSettings`, after the existing `useState` lines (around line 23-24):

```ts
  const voiceChatLanguage = usePrefsStore((s) => s.voiceChatLanguage)
  const setVoiceChatLanguage = usePrefsStore((s) => s.setVoiceChatLanguage)
```

- [ ] **Step 3: Insert the new section**

In the JSX `return`, between the "Sign out" `<section>` and the "Danger zone" `<section>` (around line 60-61), add:

```tsx
      <section className="space-y-3">
        <h2 className="text-lg font-semibold">Voice chat language</h2>
        <p className="text-sm text-gray-600">
          The voice assistant will respond in this language. Change applies the next
          time you start a chat.
        </p>
        <select
          value={voiceChatLanguage}
          onChange={(e) => {
            void setVoiceChatLanguage(e.target.value as (typeof ALLOWED_LANGUAGES)[number])
          }}
          className="px-3 py-2 border border-gray-300 rounded-lg bg-white"
        >
          {ALLOWED_LANGUAGES.map((code) => (
            <option key={code} value={code}>
              {LANGUAGE_LABELS[code]}
            </option>
          ))}
        </select>
      </section>
```

- [ ] **Step 4: Verify typecheck and tests pass**

Run: `pnpm --filter rishi-electron exec tsc -p tsconfig.web.json --noEmit`
Expected: no errors.

Run: `pnpm --filter rishi-electron vitest run`
Expected: PASS.

- [ ] **Step 5: Manual smoke test**

Start the renderer dev server (use the project's existing dev command, e.g. `pnpm --filter rishi-electron dev`). Open the app, navigate to `/settings/account`, confirm:
- The dropdown renders 12 languages.
- Default selection is "English".
- Changing the dropdown does not throw in the console.
- After changing, opening DevTools and inspecting `localStorage` / network shows no extra requests until voice chat is started.

- [ ] **Step 6: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/routes/settings/account.tsx
git commit -m "feat(settings): add voice-chat language selector"
```

---

## Task 10: Update the Cloudflare worker to accept and inject language

**Files:**
- Modify: `workers/worker/src/index.ts:165-198`

Accept `?language=xx`, validate against the allow-list, inject into `audio.input.transcription.language` of the OpenAI session config. No new tests (worker package has no test infra; out of scope).

- [ ] **Step 1: Add the allow-list constant near the top of the file**

In `workers/worker/src/index.ts`, near the other top-level constants, add:

```ts
// Must stay in sync with apps/rishi-electron/src/renderer/src/lib/languages.ts
const ALLOWED_REALTIME_LANGUAGES = [
  'en',
  'es',
  'fr',
  'de',
  'it',
  'pt',
  'ja',
  'ko',
  'zh',
  'ar',
  'hi',
  'ru'
] as const

function coerceLanguage(raw: string | undefined): string {
  if (!raw) return 'en'
  return (ALLOWED_REALTIME_LANGUAGES as readonly string[]).includes(raw) ? raw : 'en'
}
```

- [ ] **Step 2: Update the route handler to read and inject the language**

Replace the body of the `/api/realtime/client_secrets` handler (currently lines 165-198):

```ts
app.get("/api/realtime/client_secrets", requireAuth, async (c) => {
  try {
    const language = coerceLanguage(c.req.query("language"));
    const response = await axios.post(
      "https://api.openai.com/v1/realtime/client_secrets",
      {
        expires_after: {
          anchor: "created_at",
          seconds: 600,
        },
        session: {
          type: "realtime",
          model: "gpt-realtime",
          instructions: "You are a friendly assistant.",
          audio: {
            input: {
              transcription: { language },
            },
          },
        },
      },
      {
        headers: {
          Authorization: `Bearer ${c.env.OPENAI_API_KEY}`,
          "Content-Type": "application/json",
        },
        timeout: 30_000,
      }
    );
    const responseSchema = z.object({
      value: z.string(),
      expires_at: z.number(),
    });
    const parsedResponse = responseSchema.parse(response.data);
    return c.json({ client_secret: { value: parsedResponse.value } });
  } catch (error) {
    console.error("Failed to get client secrets:", error instanceof Error ? error.message : "unknown");
    return c.json({ error: "Failed to get client secrets" }, 500);
  }
});
```

- [ ] **Step 3: Verify the worker typechecks**

Run: `pnpm --filter rishi-worker exec wrangler deploy --dry-run` (or whatever local typecheck the worker has — `pnpm --filter rishi-worker exec tsc --noEmit` if a tsconfig exists).
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add workers/worker/src/index.ts
git commit -m "feat(worker): accept ?language= and pin realtime transcription"
```

---

## Task 11: End-to-end manual verification

**Files:** None modified.

Confirm the full feature works against a real OpenAI Realtime session.

- [ ] **Step 1: Deploy the worker change to a non-prod environment**

Use whatever the project's worker deploy flow is (likely `pnpm --filter rishi-worker deploy` to a preview env, or wrangler with a non-prod env). Note the deployed URL if it differs from `https://api.fidexa.org`.

- [ ] **Step 2: Start the renderer in dev mode**

Run: `pnpm --filter rishi-electron dev`

- [ ] **Step 3: Verify English (default) path**

1. Open a book, start voice chat, speak with whatever accent you have.
2. Confirm the model responds in English. Check the realtime session metadata in network DevTools — the worker call should include `?language=en`.
3. Stop the chat.

- [ ] **Step 4: Verify Spanish path**

1. Navigate to `/settings/account`. Change the dropdown to "Spanish". Close settings.
2. Open a book, start voice chat, speak (in any language).
3. Confirm the model responds in Spanish. Confirm the worker call shows `?language=es`.

- [ ] **Step 5: Verify cache invalidation on change**

1. Start a chat and end it (so a key is cached).
2. Change the language in settings.
3. Start a new chat. Open DevTools network panel — confirm `/api/realtime/client_secrets` is fetched again (not served from the 9-min in-memory cache).

- [ ] **Step 6: Verify mid-session non-effect**

1. Start a chat.
2. While the chat is active, change the language in settings.
3. Confirm the active session keeps its original language (this is expected and documented).
4. End the chat, start a new one — the new language now applies.

If any step fails, file follow-up tasks. Otherwise, the feature is complete.

---

## Self-review notes (informational)

The plan covers each section of the spec:

- Allow-list constants → Task 1, mirrored in Task 10
- Persistence reuse of `store:get`/`store:set` → Task 7
- `prefsStore` Zustand store → Task 7
- `key-cache.invalidate()` and service `invalidateKey()` → Tasks 2, 3, 4
- Worker `?language=` + `audio.input.transcription.language` → Task 10
- `getRealtimeClientSecret(language)` → Task 5
- `buildRealtimeAgent` language section → Task 6
- Settings UI dropdown → Task 9
- Hydrate at boot → Task 8
- Manual verification (replaces worker unit tests, which are out of scope) → Task 11

No "TBD" / "TODO" / "implement later" placeholders remain. All function and method names used are consistent across tasks (`invalidate()` on the cache, `invalidateKey()` on the service, `setVoiceChatLanguage`, `hydrate`, `getLanguage`).

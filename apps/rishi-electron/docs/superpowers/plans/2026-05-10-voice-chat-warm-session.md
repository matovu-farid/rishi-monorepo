# Voice Chat Warm-Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the 600–1500 ms voice-chat init delay on re-activation by keeping one `RealtimeSession` connected (muted) across toggles, with zero added OpenAI cost.

**Architecture:** Introduce `voiceChatService` — a module-singleton that owns a persistent `OpenAIRealtimeWebRTC` transport, mic `MediaStream`, and `<audio>` element. On chat-stop, the service calls `session.interrupt()` + `session.mute(true)` (no audio frames sent → $0). On chat-restart, it calls `session.updateAgent(...)` with fresh page text + `session.mute(false)` — near-instant. The session is fully closed only on book switch, idle timeout (15 min), or app exit. `chatStore` becomes a thin facade delegating to the service.

**Tech Stack:** `@openai/agents-realtime@0.3.9` (WebRTC transport), Zustand, Vitest, Electron renderer (Chromium 124+), TypeScript.

**Cost guarantee:** OpenAI Realtime billing is purely per audio-token. A muted WebRTC connection with no `sendAudio` calls bills $0. Verified against [OpenAI pricing](https://openai.com/api/pricing/) and [gpt-realtime announcement](https://openai.com/index/introducing-gpt-realtime/). The 15-minute idle close is a politeness guardrail, not a cost guardrail.

---

## File Structure

**Create:**
- `src/renderer/src/modules/voiceChatService.ts` — persistent-session singleton; public API: `prewarmKey`, `activate`, `deactivate`, `dispose`, `_resetForTests`.
- `src/renderer/src/modules/voiceChatService.test.ts` — vitest unit tests with mocked transport + session.
- `src/renderer/src/modules/buildRealtimeAgent.ts` — pure factory: `(bookId, pageText, onEndConversation) => RealtimeAgent`. Extracted from `realtime.ts` so it can be reused for `updateAgent()` calls.
- `src/renderer/src/modules/buildRealtimeAgent.test.ts` — vitest test that the agent's instructions contain the page text.

**Modify:**
- `src/renderer/src/modules/realtime.ts` — delete the inline agent construction (now in `buildRealtimeAgent.ts`); keep `getOrFetchKey` + `prefetchRealtimeKey` exports; delete `startRealtime` (replaced by service).
- `src/renderer/src/stores/chatStore.ts` — replace direct session management with calls to `voiceChatService`. Remove `realtimeSession` from state (no longer leaked outside the service).
- `src/renderer/src/stores/chatStore.test.ts` — update mocks to mock `voiceChatService` instead of `startRealtime`.
- `src/renderer/src/stores/epubStore.ts` — on book unload (bookId → null), call `voiceChatService.dispose()`.

**No change needed:**
- `src/renderer/src/components/chat/VoiceChatLauncher.tsx` — keeps using `setIsChatting`.
- `src/renderer/src/components/BackButton.tsx` — keeps calling `stopConversation()` (now translates to `deactivate()`).

---

## Design Decisions (locked)

1. **Page text refresh strategy**: On every `activate()`, call `session.updateAgent(buildRealtimeAgent(bookId, freshPageText, ...))`. This is a config-only message over the existing data channel (~50 ms). We await this before unmuting so the user never gets a stale-context response.

2. **Mute semantics**: `session.mute(true)` flips `MediaStreamTrack.enabled = false` on the WebRTC transport — confirmed in `node_modules/@openai/agents-realtime/dist/openaiRealtimeWebRtc.d.ts:105`. Zero outgoing audio frames → zero input tokens billed.

3. **Pre-warming**: We do NOT call `getUserMedia` until the user clicks voice-chat for the first time, to avoid an unsolicited mic-permission prompt on book-open. We DO continue to prefetch the API key on book-open (current behavior preserved). After the first activation, the `MediaStream` is cached for the lifetime of the service.

4. **Book switch**: When `activate(bookId)` is called with a `bookId` different from the cached one, the service disposes the old session and builds a new one. The `bookContext` tool closes over `bookId`, so we can't just swap the agent — the tool definition itself must change.

5. **Idle timeout**: 15 minutes from `deactivate()`. On expiry, `dispose()` (close session, release mic). Re-activation after that pays the full cold-start cost — acceptable trade-off.

6. **Audio output during deactivation**: On `deactivate()`, call `session.interrupt()` first to stop any in-progress agent speech, then `session.mute(true)`. The `<audio>` element is reused across activations (no need to detach).

---

### Task 0: Create the plan file and confirm working tree

**Files:**
- This file (already saved by the planning step).

- [ ] **Step 1: Verify branch is clean enough to proceed**

Run: `git status`
Expected: working tree has the pre-existing modifications listed at session start; nothing else from earlier tasks.

- [ ] **Step 2: Confirm vitest works**

Run: `npm test -- --run src/renderer/src/stores/chatStore.test.ts`
Expected: PASS, 5 tests.

---

### Task 1: Extract `buildRealtimeAgent` as a pure factory

**Files:**
- Create: `src/renderer/src/modules/buildRealtimeAgent.ts`
- Create: `src/renderer/src/modules/buildRealtimeAgent.test.ts`
- Modify: `src/renderer/src/modules/realtime.ts` (remove the inline agent construction once the new module is in place — done in Task 2 to keep this task pure refactor).

- [ ] **Step 1: Write the failing test**

Create `src/renderer/src/modules/buildRealtimeAgent.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import { buildRealtimeAgent } from './buildRealtimeAgent'

vi.mock('@/lib/api', () => ({
  getContextForQuery: vi.fn().mockResolvedValue(['stub'])
}))

describe('buildRealtimeAgent', () => {
  it('embeds the current page text into the instructions', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'The quick brown fox jumped over the lazy dog.',
      onEndConversation: vi.fn()
    })
    expect(agent.instructions).toContain('The quick brown fox jumped over the lazy dog.')
  })

  it('uses a placeholder when page text is empty', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: '',
      onEndConversation: vi.fn()
    })
    expect(agent.instructions).toContain('(No page text available)')
  })

  it('exposes two tools: bookContext and endConversation', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn()
    })
    const toolNames = agent.tools.map((t: { name: string }) => t.name)
    expect(toolNames).toContain('bookContext')
    expect(toolNames).toContain('endConversation')
  })

  it('endConversation tool invokes the provided callback', async () => {
    const onEnd = vi.fn()
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: onEnd
    })
    const endTool = agent.tools.find((t: { name: string }) => t.name === 'endConversation') as {
      execute: (args: { reason: string }) => Promise<unknown>
    }
    await endTool.execute({ reason: 'user said bye' })
    expect(onEnd).toHaveBeenCalledWith('user said bye')
  })
})
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test -- --run src/renderer/src/modules/buildRealtimeAgent.test.ts`
Expected: FAIL with `Cannot find module './buildRealtimeAgent'`.

- [ ] **Step 3: Create the module**

Create `src/renderer/src/modules/buildRealtimeAgent.ts`. Copy the agent + tools construction from the current `src/renderer/src/modules/realtime.ts:59-215` verbatim, wrapped in a factory function:

```ts
import { getContextForQuery } from '@/lib/api'
import { RealtimeAgent, tool } from '@openai/agents/realtime'
import { z } from 'zod'
import { captureError } from '@/utils/sentry'

export interface BuildAgentOptions {
  bookId: number
  pageText: string
  onEndConversation: (reason: string) => void
}

const INSTRUCTIONS_TEMPLATE = (pageText: string) => `## Role and Goal
You are a teacher and educational assistant whose role is to help the user understand the book they are reading. Your goal is to make complex concepts accessible and answer questions in a way that enhances their comprehension of the material.

## Current Page Content
The user is currently looking at this page:
"""
${pageText || '(No page text available)'}
"""
If the user's question can be answered from the page content above, answer directly WITHOUT using the bookContext tool. Only use bookContext when the user asks about content from other parts of the book that isn't shown above.

## Rules (CRITICAL - FOLLOW THESE)
- DO NOT repeat the same sentence verbatim within a single response or immediately after using it. Vary your phrasing across responses to avoid sounding robotic.
- Keep responses natural and conversational—avoid sounding scripted or mechanical.
- When using tools, always provide a brief preamble before calling the tool.
- Stay focused on helping with the book content, but be friendly and allow for natural conversation flow.

## Conversation Flow

Note: These phases represent different conversation states. The agent transitions between them based on user input and conversation context.

### Phase 1: First Interaction
Goal: Respond quickly and helpfully to whatever the user says first.

How to respond:
- If the user starts with a question, answer it directly — do not greet first.
- If the user starts with a greeting or casual remark, respond warmly and briefly, then ask what you can help with.
- Keep it concise. Do not introduce yourself with a long preamble.

### Phase 2: Question Handling
Goal: Understand the user's question and answer it.

How to respond:
- Listen carefully to understand what they're asking.
- If the answer is in the current page content provided above, answer directly from it. Do NOT use the bookContext tool.
- If the question is about other parts of the book not on the current page, use the bookContext tool.
- If it's small talk or a casual comment, respond naturally without using any tool.

### Phase 3: Tool Usage
Goal: Retrieve book context when needed.

Before calling bookContext tool, say one short line (5-12 words; vary these):
- "Let me check the book for that."
- "I'll look that up in the book for you."
- "Let me find the relevant section."
- "Checking the book now."
- "Looking that up for you."

Then call the tool immediately. While the tool runs, keep responses concise and natural—no obvious stalling.

### Phase 4: Explanation
Goal: Provide clear, simplified explanations that enhance comprehension.

How to respond:
- Break down complex concepts into simpler terms.
- Use examples and analogies when helpful.
- Check for understanding by asking a brief follow-up question like "Does that make sense?" or "Would you like me to clarify anything?" and offer to explain further.
- Keep explanations focused and relevant to what was asked.

### Phase 5: Conversation Ending
Goal: Gracefully end the conversation when the user indicates they're done.

When to detect natural conversation endings:
- User says goodbye, thanks you, and indicates they're done (e.g., "thanks, that's all", "I'm good now", "that's everything")
- User explicitly asks to end the conversation (e.g., "we can stop now", "end the conversation")
- User indicates they're finished with their questions and don't need further help

How to respond:
- If the user's signal is clear and unambiguous, respond warmly with a closing phrase, then use the endConversation tool.
- If the signal is ambiguous or unclear, briefly confirm with the user before ending (e.g., "Sounds good! Are you all set, or do you have any other questions?").
- After confirmation (or if the signal was clear), use the endConversation tool with an appropriate reason describing why the conversation is ending.

Sample closing phrases (vary these):
- "You're welcome! Happy reading!"
- "Glad I could help! Enjoy the rest of your book!"
- "Anytime! Feel free to ask if you have more questions later."
- "Great! I'm here whenever you need help with your book."

## Sample Phrases for Common Interactions

Greetings:
- "Hi! I'm here to help with your book. What's on your mind?"
- "Hello! What would you like to explore in your book today?"

Acknowledging questions:
- "That's a great question. Let me find that for you."
- "I can help with that. Let me check the book."
- "Sure thing! Looking that up now."

Providing explanations:
- "Based on what I found in the book..."
- "The book explains this as..."
- "Here's what the author is saying..."

Small talk responses:
- "That's nice to hear!"
- "I'm glad to help!"
- "Absolutely! What else would you like to know?"

Ending conversations:
- "You're welcome! Happy reading!"
- "Glad I could help! Enjoy the rest of your book!"
- "Anytime! Feel free to ask if you have more questions later."
- "Great! I'm here whenever you need help with your book."
- "Perfect! Happy to help anytime."

## Tool Usage Guidelines

### bookContext Tool
- ALWAYS provide a brief preamble (one sentence) before calling bookContext. Use the sample phrases above as inspiration, but vary the wording to keep responses natural.
- Call the tool immediately after the preamble—don't delay.
- While waiting for tool results, keep any interim responses very brief and natural.

### endConversation Tool
- Use endConversation when the user indicates the conversation is over (goodbye, thanks, "that's all", explicit request to end, etc.).
- If the user's signal is ambiguous, briefly confirm before ending (e.g., "Are you all set, or do you have more questions?").
- After confirmation or when the signal is clear, respond with a warm closing phrase, then call endConversation.
- Provide a clear reason in the tool call describing why the conversation is ending (e.g., "User thanked me and indicated they're done", "User explicitly requested to end the conversation", "User confirmed they have no more questions").
- DO NOT end conversations abruptly without user indication—only use this tool when the user has clearly signaled they're done.`

export function buildRealtimeAgent({ bookId, pageText, onEndConversation }: BuildAgentOptions): RealtimeAgent {
  const bookContextTool = tool({
    name: 'bookContext',
    description:
      'Retrieve information from OTHER parts of the book beyond the current page. Only use this when the user asks about content NOT visible on their current page. Do NOT call this tool if the answer is already in the current page content provided in your instructions.',
    parameters: z.object({
      queryText: z.string()
    }),
    execute: async ({ queryText }) => {
      try {
        const context = await getContextForQuery({ bookId, queryText, k: 3 })
        return context
      } catch (err) {
        captureError(err, { operation: 'realtime', step: 'bookContext_tool' })
        return ['Unable to retrieve book context at this time.']
      }
    }
  })

  const endConversationTool = tool({
    name: 'endConversation',
    description: 'End the conversation with the user.',
    parameters: z.object({
      reason: z.string()
    }),
    execute: async ({ reason }) => {
      onEndConversation(reason)
    }
  })

  return new RealtimeAgent({
    name: 'Assistant',
    voice: 'alloy',
    instructions: INSTRUCTIONS_TEMPLATE(pageText),
    tools: [bookContextTool, endConversationTool]
  })
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test -- --run src/renderer/src/modules/buildRealtimeAgent.test.ts`
Expected: PASS, 4 tests.

- [ ] **Step 5: Type-check**

Run: `npx tsc --noEmit -p src/renderer/tsconfig.json`
Expected: no errors. (If `tsconfig.json` is elsewhere, use the appropriate path — typically `tsconfig.web.json` or root `tsconfig.json`. Confirm with `cat package.json | grep typecheck` or `ls tsconfig*.json`.)

- [ ] **Step 6: Commit**

```bash
git add src/renderer/src/modules/buildRealtimeAgent.ts src/renderer/src/modules/buildRealtimeAgent.test.ts
git commit -m "refactor(voice-chat): extract buildRealtimeAgent as pure factory"
```

---

### Task 2: Create `voiceChatService` skeleton with state machine + key prewarm

**Files:**
- Create: `src/renderer/src/modules/voiceChatService.ts`
- Create: `src/renderer/src/modules/voiceChatService.test.ts`

This task lays down the state machine, the API surface, and idle-timer logic. WebRTC wiring is deferred to Task 3.

- [ ] **Step 1: Write the failing tests**

Create `src/renderer/src/modules/voiceChatService.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

const mockMute = vi.fn()
const mockInterrupt = vi.fn()
const mockClose = vi.fn()
const mockUpdateAgent = vi.fn().mockResolvedValue(undefined)
const mockConnect = vi.fn().mockResolvedValue(undefined)
const mockSessionOn = vi.fn()
const mockSessionOff = vi.fn()

vi.mock('@openai/agents/realtime', () => ({
  RealtimeSession: vi.fn().mockImplementation(() => ({
    mute: mockMute,
    interrupt: mockInterrupt,
    close: mockClose,
    updateAgent: mockUpdateAgent,
    connect: mockConnect,
    on: mockSessionOn,
    off: mockSessionOff
  })),
  RealtimeAgent: vi.fn(),
  tool: vi.fn()
}))

vi.mock('@/modules/realtime', () => ({
  getOrFetchKey: vi.fn().mockResolvedValue('test-key'),
  prefetchRealtimeKey: vi.fn()
}))

vi.mock('@/modules/buildRealtimeAgent', () => ({
  buildRealtimeAgent: vi.fn().mockReturnValue({ /* fake agent */ })
}))

vi.mock('@/utils/sentry', () => ({
  captureError: vi.fn()
}))

// Stub out the WebRTC transport — we test the orchestration, not the transport itself
vi.mock('@openai/agents-realtime', async () => {
  const actual = await vi.importActual<object>('@openai/agents-realtime')
  return {
    ...actual,
    OpenAIRealtimeWebRTC: vi.fn().mockImplementation(() => ({}))
  }
})

import { voiceChatService } from './voiceChatService'

describe('voiceChatService', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.useFakeTimers()
    voiceChatService._resetForTests()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('starts in idle state', () => {
    expect(voiceChatService.getState()).toBe('idle')
  })

  it('deactivate from idle is a no-op', () => {
    voiceChatService.deactivate()
    expect(voiceChatService.getState()).toBe('idle')
    expect(mockMute).not.toHaveBeenCalled()
  })

  it('schedules idle timeout on deactivate when active', async () => {
    // Set internal state to a "fake-connected" state via test hook
    voiceChatService._setSessionForTests({
      mute: mockMute,
      interrupt: mockInterrupt,
      close: mockClose
    } as never, 1)

    voiceChatService.deactivate()
    expect(mockInterrupt).toHaveBeenCalledTimes(1)
    expect(mockMute).toHaveBeenCalledWith(true)
    expect(voiceChatService.getState()).toBe('paused')

    // Idle timer not yet fired
    expect(mockClose).not.toHaveBeenCalled()

    // Advance past 15 minutes
    vi.advanceTimersByTime(15 * 60 * 1000 + 100)
    expect(mockClose).toHaveBeenCalledTimes(1)
    expect(voiceChatService.getState()).toBe('idle')
  })

  it('cancels idle timer when reactivated within timeout', async () => {
    voiceChatService._setSessionForTests({
      mute: mockMute,
      interrupt: mockInterrupt,
      close: mockClose,
      updateAgent: mockUpdateAgent
    } as never, 1)

    voiceChatService.deactivate()
    vi.advanceTimersByTime(10 * 60 * 1000)

    await voiceChatService.activate(1, 'fresh page text')
    expect(mockMute).toHaveBeenLastCalledWith(false)
    expect(mockUpdateAgent).toHaveBeenCalledTimes(1)

    vi.advanceTimersByTime(10 * 60 * 1000)
    // Still active — close should not have been called
    expect(mockClose).not.toHaveBeenCalled()
  })

  it('disposes existing session when activating with a different bookId', async () => {
    voiceChatService._setSessionForTests({
      mute: mockMute,
      interrupt: mockInterrupt,
      close: mockClose,
      updateAgent: mockUpdateAgent
    } as never, 1)

    // Note: activate(2, ...) should detect bookId mismatch and dispose old session.
    // It will then try to create a new one via the (stubbed) transport — that
    // path is exercised more fully in Task 3 tests. Here we only verify the
    // dispose-on-mismatch happens.
    await voiceChatService.activate(2, 'text for book 2').catch(() => {
      /* expected: new-session path not fully wired in this task */
    })
    expect(mockClose).toHaveBeenCalledTimes(1)
  })

  it('dispose() closes session and returns to idle', () => {
    voiceChatService._setSessionForTests({
      mute: mockMute,
      interrupt: mockInterrupt,
      close: mockClose
    } as never, 1)

    voiceChatService.dispose()
    expect(mockClose).toHaveBeenCalledTimes(1)
    expect(voiceChatService.getState()).toBe('idle')
  })

  it('prewarmKey delegates to realtime module', async () => {
    const { prefetchRealtimeKey } = await import('@/modules/realtime')
    voiceChatService.prewarmKey()
    expect(prefetchRealtimeKey).toHaveBeenCalledTimes(1)
  })
})
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test -- --run src/renderer/src/modules/voiceChatService.test.ts`
Expected: FAIL with `Cannot find module './voiceChatService'`.

- [ ] **Step 3: Create `voiceChatService.ts`**

Create `src/renderer/src/modules/voiceChatService.ts`:

```ts
import type { RealtimeSession } from '@openai/agents/realtime'
import { getOrFetchKey, prefetchRealtimeKey } from './realtime'
import { buildRealtimeAgent } from './buildRealtimeAgent'
import { captureError } from '@/utils/sentry'

export type VoiceChatState = 'idle' | 'connecting' | 'active' | 'paused' | 'disposing'

export interface VoiceChatEvents {
  onStateChange: (state: VoiceChatState) => void
  onChatStatusChange: (status: 'idle' | 'connecting' | 'thinking' | 'speaking') => void
  onEndedByAgent: () => void
}

const IDLE_TIMEOUT_MS = 15 * 60 * 1000

// Module-level singleton state
let state: VoiceChatState = 'idle'
let session: RealtimeSession | null = null
let currentBookId: number | null = null
let idleTimer: ReturnType<typeof setTimeout> | null = null
let mediaStream: MediaStream | null = null
let audioElement: HTMLAudioElement | null = null
let listeners: Partial<VoiceChatEvents> = {}

function setState(next: VoiceChatState) {
  if (state === next) return
  state = next
  listeners.onStateChange?.(state)
}

function clearIdleTimer() {
  if (idleTimer) {
    clearTimeout(idleTimer)
    idleTimer = null
  }
}

function scheduleIdleTimer() {
  clearIdleTimer()
  idleTimer = setTimeout(() => {
    voiceChatService.dispose()
  }, IDLE_TIMEOUT_MS)
}

export const voiceChatService = {
  getState(): VoiceChatState {
    return state
  },

  setListeners(next: Partial<VoiceChatEvents>) {
    listeners = { ...listeners, ...next }
  },

  /** Prefetch the OpenAI ephemeral key — safe to call on book open. Does NOT prompt for mic. */
  prewarmKey() {
    prefetchRealtimeKey()
  },

  /**
   * Start or resume voice chat for the given book.
   * - First call: full setup (mic prompt + WebRTC handshake + agent build) — Task 3 wires this.
   * - Subsequent call on same book: updateAgent + unmute (near-instant).
   * - Call on different book: dispose old session, then full setup for new book.
   */
  async activate(bookId: number, pageText: string): Promise<void> {
    clearIdleTimer()

    // Book switched while a session is alive — fully dispose first
    if (session && currentBookId !== null && currentBookId !== bookId) {
      this.dispose()
    }

    if (session && currentBookId === bookId) {
      // Warm path: refresh agent with new page text, then unmute
      setState('connecting')
      try {
        const newAgent = buildRealtimeAgent({
          bookId,
          pageText,
          onEndConversation: () => listeners.onEndedByAgent?.()
        })
        await session.updateAgent(newAgent as never)
        session.mute(false)
        if (audioElement) audioElement.muted = false
        setState('active')
      } catch (err) {
        captureError(err, { operation: 'voiceChatService', step: 'activate_warm' })
        setState('idle')
        throw err
      }
      return
    }

    // Cold path — wired in Task 3. For now, throw so tests are clear.
    throw new Error('voiceChatService.activate cold path not yet implemented')
  },

  deactivate() {
    if (!session) return
    try {
      session.interrupt()
      session.mute(true)
      if (audioElement) audioElement.muted = true
    } catch (err) {
      captureError(err, { operation: 'voiceChatService', step: 'deactivate' })
    }
    setState('paused')
    listeners.onChatStatusChange?.('idle')
    scheduleIdleTimer()
  },

  dispose() {
    clearIdleTimer()
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
    audioElement = null
    setState('idle')
    listeners.onChatStatusChange?.('idle')
  },

  // --- test hooks ---
  _resetForTests() {
    clearIdleTimer()
    session = null
    currentBookId = null
    mediaStream = null
    audioElement = null
    listeners = {}
    state = 'idle'
  },
  _setSessionForTests(fakeSession: RealtimeSession, bookId: number) {
    session = fakeSession
    currentBookId = bookId
    state = 'active'
  }
}

// Re-export for convenience
export { getOrFetchKey }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test -- --run src/renderer/src/modules/voiceChatService.test.ts`
Expected: PASS, 7 tests. (Note: the "different bookId" test asserts only that `close()` is called on the old session — it catches the rejection from the cold path since that's not yet implemented.)

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/modules/voiceChatService.ts src/renderer/src/modules/voiceChatService.test.ts
git commit -m "feat(voice-chat): add voiceChatService skeleton with idle timer + mute/unmute"
```

---

### Task 3: Wire WebRTC transport with pre-injected mic + audio element

**Files:**
- Modify: `src/renderer/src/modules/voiceChatService.ts` — fill in cold-path connect logic.
- Modify: `src/renderer/src/modules/voiceChatService.test.ts` — add tests for cold-path orchestration.

- [ ] **Step 1: Add the failing tests**

Append to `src/renderer/src/modules/voiceChatService.test.ts`:

```ts
describe('voiceChatService cold path', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    voiceChatService._resetForTests()

    // Stub getUserMedia globally
    const fakeStream = {
      getTracks: () => [{ stop: vi.fn() }]
    }
    ;(global.navigator as unknown as { mediaDevices: { getUserMedia: typeof vi.fn } }).mediaDevices = {
      getUserMedia: vi.fn().mockResolvedValue(fakeStream)
    }
  })

  it('cold activate: getUserMedia + transport + session.connect, then unmute', async () => {
    const { OpenAIRealtimeWebRTC } = await import('@openai/agents-realtime')

    await voiceChatService.activate(7, 'fresh text')

    expect(navigator.mediaDevices.getUserMedia).toHaveBeenCalledWith({ audio: true })
    expect(OpenAIRealtimeWebRTC).toHaveBeenCalledTimes(1)
    expect(mockConnect).toHaveBeenCalledWith({ apiKey: 'test-key' })
    expect(mockMute).toHaveBeenCalledWith(false)
    expect(voiceChatService.getState()).toBe('active')
  })

  it('cold activate caches mediaStream and audio element across activate/deactivate cycles', async () => {
    await voiceChatService.activate(7, 'text 1')
    const firstGetUserMediaCount = (navigator.mediaDevices.getUserMedia as ReturnType<typeof vi.fn>)
      .mock.calls.length

    voiceChatService.deactivate()
    await voiceChatService.activate(7, 'text 2')

    // No new mic prompt — same stream reused
    expect(
      (navigator.mediaDevices.getUserMedia as ReturnType<typeof vi.fn>).mock.calls.length
    ).toBe(firstGetUserMediaCount)
  })

  it('disposes mediaStream tracks on dispose()', async () => {
    const stopSpy = vi.fn()
    ;(navigator.mediaDevices.getUserMedia as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
      getTracks: () => [{ stop: stopSpy }]
    })

    await voiceChatService.activate(7, 'x')
    voiceChatService.dispose()
    expect(stopSpy).toHaveBeenCalledTimes(1)
  })
})
```

- [ ] **Step 2: Run the new tests to confirm they fail**

Run: `npm test -- --run src/renderer/src/modules/voiceChatService.test.ts`
Expected: the three new tests FAIL with `voiceChatService.activate cold path not yet implemented`.

- [ ] **Step 3: Implement the cold path in `voiceChatService.ts`**

Replace the `throw new Error('voiceChatService.activate cold path not yet implemented')` line and the `import` block at the top with the following:

```ts
import { RealtimeSession } from '@openai/agents/realtime'
import { OpenAIRealtimeWebRTC } from '@openai/agents-realtime'
import { getOrFetchKey, prefetchRealtimeKey } from './realtime'
import { buildRealtimeAgent } from './buildRealtimeAgent'
import { captureError } from '@/utils/sentry'
import { useChatStore } from '@/stores/chatStore'
import { playReadyChime } from '@/modules/readyChime'
import { startThinkingSound, stopThinkingSound } from '@/modules/thinkingSound'
```

Then replace the cold-path branch in `activate()`:

```ts
    // Cold path: first-time activation or after dispose
    setState('connecting')
    listeners.onChatStatusChange?.('connecting')

    try {
      // 1. Acquire mic (cached after first call)
      if (!mediaStream) {
        mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true })
      }

      // 2. Create audio element (cached after first call)
      if (!audioElement) {
        audioElement = document.createElement('audio')
        audioElement.autoplay = true
      }

      // 3. Build the WebRTC transport with pre-injected media
      const transport = new OpenAIRealtimeWebRTC({
        mediaStream,
        audioElement
      })

      // 4. Build the agent with current page text
      const agent = buildRealtimeAgent({
        bookId,
        pageText,
        onEndConversation: () => listeners.onEndedByAgent?.()
      })

      // 5. Create the session
      const newSession = new RealtimeSession(agent, { transport, apiKey: '' })

      // 6. Wire status events (forwarded to chat-status listener)
      const status = (next: 'idle' | 'connecting' | 'thinking' | 'speaking') =>
        listeners.onChatStatusChange?.(next)

      const onAgentStart = () => {
        if (useChatStore.getState().chatStatus === 'connecting') {
          playReadyChime()
        }
        status('thinking')
      }
      const onAudioStart = () => status('speaking')
      const onAudioStopped = () => status('idle')
      const onAgentEnd = () => {
        if (useChatStore.getState().chatStatus === 'thinking') status('idle')
      }
      const onToolStart = () => startThinkingSound()
      const onToolEnd = () => stopThinkingSound()
      const onError = (err: unknown) => {
        captureError(err, { operation: 'voiceChatService', step: 'session_error' })
        stopThinkingSound()
        voiceChatService.dispose()
      }

      newSession.on('agent_start', onAgentStart)
      newSession.on('audio_start', onAudioStart)
      newSession.on('audio_stopped', onAudioStopped)
      newSession.on('agent_end', onAgentEnd)
      newSession.on('agent_tool_start', onToolStart)
      newSession.on('agent_tool_end', onToolEnd)
      newSession.on('error', onError)

      // 7. Fetch ephemeral key + connect
      const apiKey = await getOrFetchKey()
      await newSession.connect({ apiKey })

      session = newSession
      currentBookId = bookId
      if (audioElement) audioElement.muted = false
      newSession.mute(false)
      setState('active')
    } catch (err) {
      captureError(err, { operation: 'voiceChatService', step: 'activate_cold' })
      setState('idle')
      listeners.onChatStatusChange?.('idle')
      throw err
    }
```

- [ ] **Step 4: Run all `voiceChatService` tests**

Run: `npm test -- --run src/renderer/src/modules/voiceChatService.test.ts`
Expected: PASS, all tests including the three cold-path tests.

- [ ] **Step 5: Type-check**

Run: `npx tsc --noEmit -p src/renderer/tsconfig.json` (or appropriate config — same as Task 1 step 5).
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/src/modules/voiceChatService.ts src/renderer/src/modules/voiceChatService.test.ts
git commit -m "feat(voice-chat): wire WebRTC transport with pre-warmed mic + audio element"
```

---

### Task 4: Refactor `chatStore` to delegate to `voiceChatService`

**Files:**
- Modify: `src/renderer/src/stores/chatStore.ts`
- Modify: `src/renderer/src/stores/chatStore.test.ts`
- Modify: `src/renderer/src/modules/realtime.ts` (remove now-unused `startRealtime`)

- [ ] **Step 1: Update `chatStore.test.ts` to match new behavior**

Replace `src/renderer/src/stores/chatStore.test.ts` with:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { useChatStore } from './chatStore'

const mockActivate = vi.fn().mockResolvedValue(undefined)
const mockDeactivate = vi.fn()
const mockDispose = vi.fn()
const mockSetListeners = vi.fn()
const mockGetState = vi.fn().mockReturnValue('idle')

vi.mock('@/modules/voiceChatService', () => ({
  voiceChatService: {
    activate: mockActivate,
    deactivate: mockDeactivate,
    dispose: mockDispose,
    setListeners: mockSetListeners,
    getState: mockGetState,
    prewarmKey: vi.fn()
  }
}))

vi.mock('@/stores/playerStore', () => ({
  usePlayerStore: { getState: () => ({ send: vi.fn(), currentParagraphs: [] }) }
}))

vi.mock('@/utils/sentry', () => ({ captureError: vi.fn() }))

describe('chatStore', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    useChatStore.setState({
      isChatting: false,
      chatStatus: 'idle',
      _chatGeneration: 0,
      _isStarting: false
    })
  })

  it('starts in idle state', () => {
    expect(useChatStore.getState().chatStatus).toBe('idle')
    expect(useChatStore.getState().isChatting).toBe(false)
  })

  it('setIsChatting(false) calls voiceChatService.deactivate', () => {
    useChatStore.setState({ isChatting: true })
    useChatStore.getState().setIsChatting(false)
    expect(mockDeactivate).toHaveBeenCalledTimes(1)
    expect(useChatStore.getState().isChatting).toBe(false)
  })

  it('startChat delegates to voiceChatService.activate', async () => {
    useChatStore.setState({ isChatting: true })
    useChatStore.getState().startChat(42)
    // activate is async — await microtask flush
    await Promise.resolve()
    expect(mockActivate).toHaveBeenCalledWith(42, expect.any(String))
  })

  it('stopConversation resets state and calls deactivate', () => {
    useChatStore.setState({ isChatting: true, chatStatus: 'speaking' })
    useChatStore.getState().stopConversation()
    expect(useChatStore.getState().isChatting).toBe(false)
    expect(useChatStore.getState().chatStatus).toBe('idle')
    expect(mockDeactivate).toHaveBeenCalledTimes(1)
  })

  it('prevents concurrent startChat calls', () => {
    useChatStore.setState({ _isStarting: true, isChatting: true })
    useChatStore.getState().startChat(1)
    expect(mockActivate).not.toHaveBeenCalled()
  })
})
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test -- --run src/renderer/src/stores/chatStore.test.ts`
Expected: FAIL — store still calls `startRealtime`, not `voiceChatService.activate`.

- [ ] **Step 3: Rewrite `chatStore.ts`**

Replace `src/renderer/src/stores/chatStore.ts` with:

```ts
import { create } from 'zustand'
import { devtools, subscribeWithSelector } from 'zustand/middleware'
import { voiceChatService } from '@/modules/voiceChatService'
import { usePlayerStore } from './playerStore'
import { captureError } from '@/utils/sentry'

export type ChatStatus = 'idle' | 'connecting' | 'thinking' | 'speaking'

interface ChatState {
  isChatting: boolean
  chatStatus: ChatStatus
  /** Incremented on each startChat, checked on resolve to discard stale activations */
  _chatGeneration: number
  /** True while activate() is in flight — prevents concurrent starts */
  _isStarting: boolean

  setIsChatting: (value: boolean | ((prev: boolean) => boolean)) => void
  setChatStatus: (status: ChatStatus) => void
  startChat: (bookId: number) => void
  stopConversation: () => void
}

export const useChatStore = create<ChatState>()(
  devtools(
    subscribeWithSelector((set, get) => {
      // Wire service → store listeners once on module init
      voiceChatService.setListeners({
        onChatStatusChange: (status) => set({ chatStatus: status }),
        onEndedByAgent: () => {
          set({ isChatting: false, chatStatus: 'idle' })
          voiceChatService.deactivate()
        }
      })

      return {
        isChatting: false,
        chatStatus: 'idle' as ChatStatus,
        _chatGeneration: 0,
        _isStarting: false,

        setIsChatting: (value) => {
          const newValue = typeof value === 'function' ? value(get().isChatting) : value
          if (newValue) {
            const send = usePlayerStore.getState().send
            if (send) send({ type: 'CHAT_STARTED' })
          } else {
            voiceChatService.deactivate()
          }
          set({ isChatting: newValue })
        },

        setChatStatus: (status) => set({ chatStatus: status }),

        startChat: (bookId: number) => {
          if (get()._isStarting) return
          const gen = get()._chatGeneration + 1
          set({ _chatGeneration: gen, _isStarting: true, chatStatus: 'connecting' })

          const pageText = usePlayerStore
            .getState()
            .currentParagraphs.map((p) => p.text)
            .join('\n')

          voiceChatService
            .activate(bookId, pageText)
            .then(() => {
              if (get()._chatGeneration !== gen || !get().isChatting) {
                voiceChatService.deactivate()
              }
              set({ _isStarting: false })
            })
            .catch((err) => {
              captureError(err, { operation: 'chatStore', step: 'activate' })
              set({ isChatting: false, chatStatus: 'idle', _isStarting: false })
            })
        },

        stopConversation: () => {
          const { _chatGeneration } = get()
          set({
            isChatting: false,
            chatStatus: 'idle',
            _chatGeneration: _chatGeneration + 1
          })
          voiceChatService.deactivate()
        }
      }
    }),
    { name: 'chat-store' }
  )
)
```

- [ ] **Step 4: Clean up `realtime.ts`**

Edit `src/renderer/src/modules/realtime.ts` to remove `startRealtime` and `sessionCleanupMap` (now dead code). Keep only the key-caching helpers:

```ts
import { getRealtimeClientSecret } from '@/lib/api'

const KEY_TTL_MS = 9 * 60 * 1000
let _cachedKey: string | null = null
let _cachedKeyTime = 0
let _prefetchPromise: Promise<string> | null = null

export async function getOrFetchKey(): Promise<string> {
  if (_cachedKey && Date.now() - _cachedKeyTime < KEY_TTL_MS) {
    return _cachedKey
  }
  if (_prefetchPromise) return _prefetchPromise
  _prefetchPromise = getRealtimeClientSecret()
    .then((key) => {
      _cachedKey = key
      _cachedKeyTime = Date.now()
      _prefetchPromise = null
      return key
    })
    .catch((err) => {
      _prefetchPromise = null
      throw err
    })
  return _prefetchPromise
}

export function prefetchRealtimeKey() {
  void getOrFetchKey()
}
```

- [ ] **Step 5: Run all renderer tests**

Run: `npm test -- --run src/renderer`
Expected: PASS for `chatStore.test.ts`, `voiceChatService.test.ts`, `buildRealtimeAgent.test.ts`, and any other tests that touch these modules.

If any other test imports `startRealtime` or `sessionCleanupMap` directly, update the import or mock — do NOT re-export those names from `realtime.ts`.

- [ ] **Step 6: Type-check**

Run: `npx tsc --noEmit -p src/renderer/tsconfig.json`
Expected: no errors. If there are unused-import warnings in files that previously used `startRealtime`, remove the imports.

- [ ] **Step 7: Commit**

```bash
git add src/renderer/src/stores/chatStore.ts src/renderer/src/stores/chatStore.test.ts src/renderer/src/modules/realtime.ts
git commit -m "refactor(voice-chat): delegate chatStore to voiceChatService"
```

---

### Task 5: Dispose voice session when the user leaves the book

**Files:**
- Modify: `src/renderer/src/stores/epubStore.ts`

The book-open subscription already calls `prefetchRealtimeKey()` — keep that. Add a sibling that disposes the voice session when `bookId` transitions to `null`. Without this, the muted session for book A would still be alive when the user opens book B, then `voiceChatService.activate(B, ...)` would correctly detect the bookId mismatch and dispose — but only on next activation. Disposing eagerly on book-close is cleaner and releases the mic indicator.

- [ ] **Step 1: Read the current subscription block**

Read: `src/renderer/src/stores/epubStore.ts` lines 220–250 to confirm the surrounding context.

- [ ] **Step 2: Edit the subscription block**

In `src/renderer/src/stores/epubStore.ts`, find this block (around line 224–232):

```ts
  // Side effect: pre-fetch the realtime API key when a book is opened so voice chat starts faster
  unsubs.push(
    useEpubStore.subscribe(
      (state) => state.bookId,
      (bookId) => {
        if (bookId) prefetchRealtimeKey()
      }
    )
  )
```

Replace with:

```ts
  // Side effect: pre-fetch the realtime API key when a book is opened (faster voice chat start);
  // dispose the voice session when the book closes (release mic + close WebRTC).
  unsubs.push(
    useEpubStore.subscribe(
      (state) => state.bookId,
      (bookId) => {
        if (bookId) {
          prefetchRealtimeKey()
        } else {
          voiceChatService.dispose()
        }
      }
    )
  )
```

Add the import at the top of the file (near the other module imports):

```ts
import { voiceChatService } from '@/modules/voiceChatService'
```

- [ ] **Step 3: Type-check**

Run: `npx tsc --noEmit -p src/renderer/tsconfig.json`
Expected: no errors.

- [ ] **Step 4: Run all renderer tests**

Run: `npm test -- --run src/renderer`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/stores/epubStore.ts
git commit -m "feat(voice-chat): dispose voice session on book close"
```

---

### Task 6: Manual verification in the running app

**Goal:** Confirm the warm-session optimization actually delivers near-instant re-activation, and that no audio leaks while muted.

Automated tests cover the orchestration; the WebRTC + mic + agent-talking parts require real-app verification.

- [ ] **Step 1: Start the dev app**

Run: `npm run dev` (or whatever the project's dev command is — check `package.json` scripts).
Expected: app launches, library opens.

- [ ] **Step 2: Open a book and time the first voice-chat activation**

In DevTools console, set up a quick timer:

```js
const t0 = performance.now()
// then click the voice chat orb
// observe `chatStatus` transitions in the chat-store devtools panel
```

Record: time from click → `chatStatus === 'thinking'` (ready chime plays). Expected: ~600–1500 ms (same as today, that's fine — first activation always pays).

- [ ] **Step 3: Toggle off, then immediately toggle on**

Record: time from second click → `chatStatus === 'thinking'`. **Expected: under 300 ms** — this is the main win. If it's still ≥ 600 ms, something is wrong; check DevTools network panel for a new `client_secrets` request or a new WebRTC offer (there should be neither).

- [ ] **Step 4: Verify zero traffic while muted**

After deactivating, open DevTools → Network → WS (or chrome://webrtc-internals). Confirm the connection is alive but no audio frames are being sent. The data-channel "bytesSent" should plateau.

- [ ] **Step 5: Verify $0 OpenAI usage while muted (sanity)**

Wait 60 seconds in the muted state. Check OpenAI dashboard usage for the API key — there should be no incremental input-audio-token usage during that window.

- [ ] **Step 6: Verify page-text refresh on re-activation**

Read a page, start chat, ask "what does this page say?", confirm correct answer. Stop chat. Turn the page. Restart chat, ask the same question. The agent should answer based on the NEW page (proves `updateAgent` ran).

- [ ] **Step 7: Verify book switch disposes the session**

Open book A, start chat, stop chat (now muted). Back-button to library. Open book B. The previous session should be disposed (mic light off briefly), then re-acquired on first activation in book B. The `bookContext` tool inside the new session must query book B, not book A — confirm by asking about content unique to book B.

- [ ] **Step 8: Verify idle timeout**

Start a session, deactivate, set the system clock forward 16 minutes (or temporarily lower `IDLE_TIMEOUT_MS` to 30 seconds for this test, then revert). Confirm session is closed (next activation is a cold start again).

- [ ] **Step 9: Verify no audio leaks while toggled off**

Start chat, ask a long-winded question that causes a long response. Mid-response, toggle off. Expected: agent stops speaking immediately (because `session.interrupt()` runs before `mute(true)`). No audio should leak from the `<audio>` element.

- [ ] **Step 10: Commit any tweaks**

If any step revealed a bug, fix and add tests, then:

```bash
git add -p
git commit -m "fix(voice-chat): <specific fix>"
```

If nothing needed fixing, skip this step.

---

### Task 7: Final cleanup and PR

- [ ] **Step 1: Run full lint + typecheck + tests**

Run: `npm run lint && npx tsc --noEmit -p src/renderer/tsconfig.json && npm test -- --run`
Expected: all green.

- [ ] **Step 2: Verify diff is scoped to the planned files**

Run: `git diff --stat main`
Expected files changed:
- `src/renderer/src/modules/buildRealtimeAgent.ts` (new)
- `src/renderer/src/modules/buildRealtimeAgent.test.ts` (new)
- `src/renderer/src/modules/voiceChatService.ts` (new)
- `src/renderer/src/modules/voiceChatService.test.ts` (new)
- `src/renderer/src/modules/realtime.ts` (slimmed)
- `src/renderer/src/stores/chatStore.ts` (rewritten)
- `src/renderer/src/stores/chatStore.test.ts` (updated)
- `src/renderer/src/stores/epubStore.ts` (one block changed)
- `docs/superpowers/plans/2026-05-10-voice-chat-warm-session.md` (this plan)

No other files should be modified. If they are, investigate.

- [ ] **Step 3: Stop here and ask the user before pushing or opening a PR**

Per project convention, do not push or open a PR without explicit instruction.

---

## Risks & Polish Items (do NOT implement now)

These are noted for future work or troubleshooting, not part of this plan:

1. **Network drops / system sleep**: WebRTC connection will die if laptop sleeps. Current code didn't handle this either; if it becomes a real issue, add an `error` listener that triggers `dispose()` + cold-restart on next activate.
2. **Multiple windows / tabs**: voiceChatService is module-singleton scoped to one renderer process — fine for Electron's single-window model.
3. **Mic permission denied**: if `getUserMedia` rejects, `activate()` throws. The store catches it and resets to idle, but the user sees no explanation. A toast/dialog could improve UX — out of scope here.
4. **Page-text size**: very long pages mean a large `updateAgent` payload. Current behavior already sends the whole page as instructions — no regression here.
5. **Concurrent activate calls**: protected by `_isStarting` flag in the store, plus `voiceChatService` state checks. Should be robust, but worth re-verifying in code review.

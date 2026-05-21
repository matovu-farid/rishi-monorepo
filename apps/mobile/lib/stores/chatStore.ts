/**
 * Mobile chatStore — ported (in spirit) from
 * `apps/rishi-electron/src/renderer/src/stores/chatStore.ts`.
 *
 * The electron chatStore is a thin facade over the voice-chat service.
 * Mobile preserves the same *public surface* — `isChatting`, `chatStatus`,
 * `voiceState`, `voiceError`, plus the actions `setIsChatting`,
 * `setChatStatus`, `startChat`, `stopConversation`, `dismissVoiceError` —
 * but routes voice operations through an injectable `VoiceChatPort`.
 *
 * Until the mobile voice-chat service lands (Batch 2+), the default port
 * is a no-op so the store can be imported and exercised in tests / UI
 * without forcing the consumer to wire a real implementation.
 *
 * Wiring to `playerStore` / `epubStore` / `prefsStore` / `pageCapture`
 * (which the electron store does) is deferred until those stores land
 * on mobile — see `.parity/BATCH-1B-NOTES.md` (#1).
 */
import { create } from 'zustand'
import type { Conversation, Message } from '@rishi/shared/types/conversation'

// Re-export shared Conversation / Message so future thread-state code on
// mobile imports them through this store (matches the spec intent).
export type { Conversation, Message }

// ── Public types (mirror electron's voice-chat type surface) ─────────────────
export type ChatStatus = 'idle' | 'connecting' | 'thinking' | 'speaking'

export type VoiceState =
  | 'idle'
  | 'connecting'
  | 'listening'
  | 'thinking'
  | 'speaking'
  | 'error'

export interface VoiceError {
  code: string
  message: string
}

/**
 * Activation context — shape kept loose to match electron's call sites.
 * Mobile callers can fill in whatever subset they have.
 */
export interface ActivationContext {
  pageText?: string
  outline?: unknown
  activeParagraphText?: string
  visualSummary?: { equations: number; figures: number; images: number }
}

export interface VoiceChatPort {
  activate(bookId: number, ctx: ActivationContext): Promise<void>
  deactivate(): void
  getState(): VoiceState
  getError(): VoiceError | null
  dismissError(): void
  onStateChange(cb: (state: VoiceState) => void): () => void
  onChatStatus(cb: (status: ChatStatus) => void): () => void
  onEndedByAgent(cb: () => void): () => void
}

const noopPort: VoiceChatPort = {
  activate: () => Promise.resolve(),
  deactivate: () => undefined,
  getState: () => 'idle',
  getError: () => null,
  dismissError: () => undefined,
  onStateChange: () => () => undefined,
  onChatStatus: () => () => undefined,
  onEndedByAgent: () => () => undefined,
}

let port: VoiceChatPort = noopPort

/**
 * Inject the real voice-chat service implementation. Call this once at
 * app startup after the service is constructed. Subsequent state-change /
 * chat-status subscriptions are re-bound on injection so the store stays
 * in sync with the live service.
 */
export function setChatVoicePort(next: VoiceChatPort): void {
  port = next
  // Wire newly-injected port's events into store state. Subscriptions live
  // for the process lifetime — their unsubscribes are intentionally dropped
  // (same pattern as electron).
  port.onChatStatus((status) => useChatStore.setState({ chatStatus: status }))
  port.onStateChange((state) =>
    useChatStore.setState({ voiceState: state, voiceError: port.getError() }),
  )
  port.onEndedByAgent(() => {
    useChatStore.setState({ isChatting: false })
    port.deactivate()
  })
  // Sync initial snapshot from the freshly-injected port.
  useChatStore.setState({
    voiceState: port.getState(),
    voiceError: port.getError(),
  })
}

// ── Store ────────────────────────────────────────────────────────────────────
interface ChatState {
  isChatting: boolean
  chatStatus: ChatStatus
  voiceState: VoiceState
  voiceError: VoiceError | null

  setIsChatting: (value: boolean | ((prev: boolean) => boolean)) => void
  setChatStatus: (status: ChatStatus) => void
  startChat: (bookId: number) => void
  stopConversation: () => void
  dismissVoiceError: () => void
}

export const useChatStore = create<ChatState>()((set, get) => ({
  isChatting: false,
  chatStatus: 'idle',
  voiceState: 'idle',
  voiceError: null,

  setIsChatting: (value) => {
    const newValue = typeof value === 'function' ? value(get().isChatting) : value
    if (!newValue) {
      port.deactivate()
    }
    set({ isChatting: newValue })
  },

  setChatStatus: (status) => set({ chatStatus: status }),

  startChat: (bookId) => {
    // ActivationContext is intentionally minimal on mobile until the
    // playerStore / epubStore / pageCapture modules are ported — they
    // own the data the electron version reads.
    const ctx: ActivationContext = {}
    port.activate(bookId, ctx).catch(() => {
      set({ isChatting: false, chatStatus: 'idle' })
    })
  },

  stopConversation: () => {
    set({ isChatting: false, chatStatus: 'idle' })
    port.deactivate()
  },

  dismissVoiceError: () => {
    port.dismissError()
  },
}))

import { create } from 'zustand'
import { devtools, subscribeWithSelector } from 'zustand/middleware'
import { voiceChatService, OfflineError } from '@/modules/voiceChatService'
import { usePlayerStore } from './playerStore'
import { useEpubStore } from './epubStore'
import { captureError } from '@/utils/sentry'
import type { VoiceChatStateValue, VoiceErrorReason } from '@/machines/voiceChatMachine'

export type ChatStatus = 'idle' | 'connecting' | 'thinking' | 'speaking'

interface ChatState {
  isChatting: boolean
  chatStatus: ChatStatus
  /** Typed voice-chat lifecycle state from the xstate machine */
  voiceState: VoiceChatStateValue
  /** Set when voice chat enters 'error' state (timeout, mic, auth, etc.) */
  voiceError: { reason: VoiceErrorReason; message?: string } | null
  /** Incremented on each startChat, checked on resolve to discard stale activations */
  _chatGeneration: number
  /** True while activate() is in flight — prevents concurrent starts */
  _isStarting: boolean

  setIsChatting: (value: boolean | ((prev: boolean) => boolean)) => void
  setChatStatus: (status: ChatStatus) => void
  startChat: (bookId: number) => void
  stopConversation: () => void
  dismissVoiceError: () => void
}

export const useChatStore = create<ChatState>()(
  devtools(
    subscribeWithSelector((set, get) => {
      // Wire service → store: chat status events (thinking/speaking) and
      // agent-initiated end. Voice machine state flows via actor subscription.
      voiceChatService.setListeners({
        onChatStatusChange: (status) => set({ chatStatus: status }),
        onEndedByAgent: () => {
          set({ isChatting: false })
          voiceChatService.deactivate()
        }
      })

      // Mirror voice machine state into the store so React components can
      // subscribe to typed states (offline/error/etc.) without touching the actor.
      voiceChatService.actor.subscribe((snapshot) => {
        set({
          voiceState: snapshot.value as VoiceChatStateValue,
          voiceError: snapshot.context.error
        })
      })

      return {
        isChatting: false,
        chatStatus: 'idle' as ChatStatus,
        voiceState: voiceChatService.getState(),
        voiceError: voiceChatService.getError(),
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
          // Read outline from epubStore — guard against stale outline by
          // verifying epubStore's bookId still matches the one we're starting for
          const epubState = useEpubStore.getState()
          const outline =
            epubState.bookId === String(bookId) ? (epubState.bookOutline ?? undefined) : undefined

          voiceChatService
            .activate(bookId, { pageText, outline })
            .then(() => {
              if (get()._chatGeneration !== gen || !get().isChatting) {
                voiceChatService.deactivate()
              }
              set({ _isStarting: false })
            })
            .catch((err) => {
              if (!(err instanceof OfflineError)) {
                captureError(err, { operation: 'chatStore', step: 'activate' })
              }
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
        },

        dismissVoiceError: () => {
          voiceChatService.dismissError()
        }
      }
    }),
    { name: 'chat-store' }
  )
)

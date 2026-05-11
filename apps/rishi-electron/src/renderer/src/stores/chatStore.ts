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

export type { ChatStatus }

interface ChatState {
  isChatting: boolean
  chatStatus: ChatStatus
  /** Typed voice-chat lifecycle state from the service. */
  voiceState: VoiceChatPublicState
  /** Set when voice chat enters 'error' state (timeout, mic, auth, etc.). */
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
          // Read outline from epubStore — guard against stale outline by
          // verifying epubStore's bookId still matches the one we're starting for.
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

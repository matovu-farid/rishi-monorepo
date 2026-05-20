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
import { summarizeCurrentPage } from '@/modules/pageCapture'

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
      voice.onStateChange((state) => set({ voiceState: state, voiceError: voice.getError() }))
      voice.onEndedByAgent(() => {
        const send = usePlayerStore.getState().send
        if (send) send({ type: 'CHAT_ENDED' })
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
          const send = usePlayerStore.getState().send
          if (newValue) {
            if (send) send({ type: 'CHAT_STARTED' })
          } else {
            if (send) send({ type: 'CHAT_ENDED' })
            voice.deactivate()
          }
          set({ isChatting: newValue })
        },

        setChatStatus: (status) => set({ chatStatus: status }),

        startChat: (bookId) => {
          const playerState = usePlayerStore.getState()
          const pageText = playerState.currentParagraphs.map((p) => p.text).join('\n')
          const activeParagraphText = playerState.activeParagraph?.text
          // Read outline from epubStore — guard against stale outline by
          // verifying epubStore's bookId still matches the one we're starting for.
          const epubState = useEpubStore.getState()
          const outline =
            epubState.bookId === String(bookId) ? (epubState.bookOutline ?? undefined) : undefined

          const visualSummary = summarizeCurrentPage()

          voice
            .activate(bookId, { pageText, outline, activeParagraphText, visualSummary })
            .catch((err: unknown) => {
              if (!(err instanceof OfflineError)) {
                captureError(err, { operation: 'chatStore', step: 'activate' })
              }
              const send = usePlayerStore.getState().send
              if (send) send({ type: 'CHAT_ENDED' })
              set({ isChatting: false, chatStatus: 'idle' })
            })
        },

        stopConversation: () => {
          const send = usePlayerStore.getState().send
          if (send) send({ type: 'CHAT_ENDED' })
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

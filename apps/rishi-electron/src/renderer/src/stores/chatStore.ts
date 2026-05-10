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
          set({ isChatting: false })
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

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

  let lastPublicState: VoiceChatPublicState = actor.getSnapshot().value as VoiceChatPublicState
  actor.subscribe(() => {
    const next = actor.getSnapshot().value as VoiceChatPublicState
    if (next === lastPublicState) return
    lastPublicState = next
    stateEmitter.emit(next)
  })

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

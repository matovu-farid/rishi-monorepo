import { describe, it, expectTypeOf } from 'vitest'
import { OfflineError } from './types'
import type {
  VoiceChatService,
  VoiceChatServiceDeps,
  VoiceChatPublicState,
  ChatStatus,
  VoiceError,
  VoiceErrorReason
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
    const e = new OfflineError()
    expectTypeOf(e.name).toEqualTypeOf<'OfflineError'>()
  })
})

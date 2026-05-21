import { setup, assign } from 'xstate'

/**
 * Voice chat finite-state machine. Verbatim port from
 * `apps/rishi-electron/src/renderer/src/services/voice-chat/machine.ts`.
 */

export type VoiceErrorReason =
  | 'timeout'
  | 'mic_denied'
  | 'auth_failed'
  | 'connect_failed'
  | 'session_error'
  | 'unknown'

export interface VoiceChatMachineContext {
  error: { reason: VoiceErrorReason; message?: string } | null
}

export type VoiceChatMachineEvent =
  | { type: 'CONNECT_STARTED' }
  | { type: 'CONNECT_SUCCEEDED' }
  | { type: 'CONNECT_FAILED'; reason: VoiceErrorReason; message?: string }
  | { type: 'DEACTIVATE' }
  | { type: 'DISPOSE' }
  | { type: 'OFFLINE' }
  | { type: 'ONLINE' }
  | { type: 'SESSION_ERROR'; reason: VoiceErrorReason; message?: string }
  | { type: 'DISMISS_ERROR' }

export const voiceChatMachine = setup({
  types: {
    context: {} as VoiceChatMachineContext,
    events: {} as VoiceChatMachineEvent
  },
  actions: {
    storeError: assign({
      error: ({ event }) => {
        if (event.type === 'CONNECT_FAILED' || event.type === 'SESSION_ERROR') {
          return { reason: event.reason, message: event.message }
        }
        return null
      }
    }),
    clearError: assign({ error: null })
  }
}).createMachine({
  id: 'voiceChat',
  initial: 'idle',
  context: { error: null },
  // Global handlers — apply from any state
  on: {
    DISPOSE: { target: '.idle', actions: 'clearError' },
    // OFFLINE forces the machine into offline regardless of where we were.
    // The service is responsible for tearing down any live session.
    OFFLINE: '.offline'
  },
  states: {
    idle: {
      on: {
        CONNECT_STARTED: 'connecting',
        DISMISS_ERROR: { actions: 'clearError' }
      }
    },
    connecting: {
      on: {
        CONNECT_SUCCEEDED: { target: 'active', actions: 'clearError' },
        CONNECT_FAILED: { target: 'error', actions: 'storeError' }
      }
    },
    active: {
      on: {
        DEACTIVATE: 'paused',
        SESSION_ERROR: { target: 'error', actions: 'storeError' }
      }
    },
    paused: {
      on: {
        CONNECT_STARTED: 'connecting'
      }
    },
    offline: {
      // Connectivity restored → user can retry. We land in 'idle' so the UI
      // shows the launcher again; old session (if any) was torn down by service.
      on: { ONLINE: { target: 'idle', actions: 'clearError' } }
    },
    error: {
      on: {
        CONNECT_STARTED: 'connecting',
        DISMISS_ERROR: { target: 'idle', actions: 'clearError' }
      }
    }
  }
})

export type VoiceChatStateValue =
  | 'idle'
  | 'connecting'
  | 'active'
  | 'paused'
  | 'offline'
  | 'error'

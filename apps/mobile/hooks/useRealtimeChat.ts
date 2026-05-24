/**
 * Compatibility shim — delegates to the Batch 4 `useVoiceChat` hook.
 *
 * Prior to Batch 4 this hook owned an ad-hoc state machine wrapping
 * `react-native-webrtc` directly. Batch 4 replaces that with the
 * shared `@rishi/shared/voice-chat` service (FSM + key cache +
 * activation pipeline + shared prompts). The hook signature stays the
 * same so existing callers (`app/reader/[id].tsx`) keep working
 * without source changes.
 */
import { useVoiceChat } from './useVoiceChat'

export interface UseRealtimeChatResult {
  status: ReturnType<typeof useVoiceChat>['status']
  showGuardrailWarning: boolean
  toggle: () => void
  isActive: boolean
  /**
   * CHT-016 (#63) — Activation-error fields forwarded from the
   * underlying `useVoiceChat` hook. Reader screens read these to
   * render a non-blocking snackbar when voice-chat activation fails
   * (mic denied, network drop, etc.). Prior to this wiring the shim
   * silently swallowed the fields, regressing the user-facing AC of
   * issue #63 from a modal Alert to a silent no-op.
   */
  voiceError: string | null
  isMicPermissionError: boolean
  retryStart: () => Promise<void>
  dismissError: () => void
}

export function useRealtimeChat(bookId: string): UseRealtimeChatResult {
  const {
    status,
    toggle,
    isActive,
    voiceError,
    isMicPermissionError,
    retryStart,
    dismissError,
  } = useVoiceChat(bookId)
  // Guardrail UI was wired into the old hook via a callback fired by
  // the off-topic classifier. Batch 4 keeps the classifier
  // (`lib/realtime/guardrails.ts`) but moves the "show banner"
  // signaling into the shared voice-chat service's
  // `onEndedByAgent('guardrail_tripwire')` event. Until the reader
  // surfaces that, we keep the flag false — the off-topic banner is
  // a UI affordance, not a safety control.
  const showGuardrailWarning = false

  return {
    status,
    showGuardrailWarning,
    toggle: () => {
      void toggle()
    },
    isActive,
    voiceError,
    isMicPermissionError,
    retryStart,
    dismissError,
  }
}

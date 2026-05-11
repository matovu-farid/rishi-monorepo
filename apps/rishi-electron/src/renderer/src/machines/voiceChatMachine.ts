// Re-export shim: the machine has moved to services/voice-chat/machine.ts.
// This file remains until Task 15+ migrates the legacy voiceChatService and
// chatStore off the old import path. Delete in Task 16.
export {
  voiceChatMachine,
  type VoiceChatMachineContext,
  type VoiceChatMachineEvent,
  type VoiceChatStateValue,
  type VoiceErrorReason
} from '@/services/voice-chat/machine'

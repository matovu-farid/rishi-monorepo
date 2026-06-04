/**
 * T-P2.1 — WIRING-001 (RED phase placeholder).
 *
 * Factory that assembles all mobile voice-chat deps and returns a
 * `VoiceChatService` ready for `setChatVoicePort`. Wired in
 * `app/_layout.tsx` (via `startup-wiring.ts`) after Better-Auth session
 * hydration completes.
 *
 * Currently unimplemented — `runStartupWiring` is a no-op stub that
 * makes the WIRING-001 red tests fail for "not implemented" rather than
 * "module not resolvable". See `.parity-v2/PLAN.md` T-P2.1 for the
 * concrete dep list.
 */
import type { VoiceChatPort } from '@/lib/stores/chatStore'

export function buildMobileVoiceChatService(): VoiceChatPort {
  throw new Error(
    'buildMobileVoiceChatService not implemented (T-P2.1 / WIRING-001).',
  )
}

/**
 * T-P2.1 — WIRING-001 mobile voice-chat factory.
 *
 * Thin wrapper around `getVoiceChatService()` exposed as a named export so
 * the startup wiring (and tests) can spy on / mock the construction step
 * without dragging the whole singleton lifecycle into the call site.
 *
 * The returned object satisfies the `VoiceChatPort` contract declared in
 * `lib/stores/chatStore.ts` — `createVoiceChatService` already returns a
 * superset of that surface (`activate`, `deactivate`, `getState`,
 * `getError`, `dismissError`, `onStateChange`, `onChatStatus`,
 * `onEndedByAgent`), so no adapter layer is needed.
 *
 * Wired into `app/_layout.tsx` via `startup-wiring.ts` after Better-Auth
 * session hydration completes. See SPEC §3.9 for the auth-gated wiring
 * contract.
 */
import type { VoiceChatPort } from '@/lib/stores/chatStore'
import { getVoiceChatService, type BuildOpts } from './service'

export function buildMobileVoiceChatService(opts: BuildOpts = {}): VoiceChatPort {
  return getVoiceChatService(opts) as unknown as VoiceChatPort
}

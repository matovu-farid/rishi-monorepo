/**
 * T-P2.1 — WIRING-001 startup voice-chat wiring (auth-gated).
 *
 * Subscribes to the authStore and calls `setChatVoicePort` exactly once
 * after Better-Auth session hydration completes (per SPEC §3.9).
 *
 * Behaviour:
 *   - State A (unauthenticated at startup): no port wired.
 *   - State B (authenticated at startup): build the service synchronously
 *     and wire it.
 *   - Null → authed transition: build + wire once when the transition
 *     fires.
 *   - Idempotent under Fast-Refresh / repeated `runStartupWiring()`
 *     invocations via a module-level `wired` guard.
 *
 * The auth subscription is intentionally NEVER torn down — the wiring
 * lives for the process lifetime. `setChatVoicePort` is a one-shot per
 * auth session; signing out does not reset the wired flag (the service
 * itself handles deactivation when `clearSession` cascades through the
 * UI's `stopConversation()` calls). This matches the electron contract
 * which constructs the service unconditionally at renderer mount.
 */
import { useAuthStore } from '@/lib/stores/authStore'
import { setChatVoicePort } from '@/lib/stores/chatStore'
import { buildMobileVoiceChatService } from './buildService'

let wired = false
let unsubscribe: (() => void) | null = null

interface AuthSnapshot {
  user: { id: string } | null
  sessionToken: string | null
}

function isAuthed(state: AuthSnapshot): boolean {
  return state.user != null && state.sessionToken != null
}

function tryWire(state: AuthSnapshot): void {
  if (wired) return
  if (!isAuthed(state)) return
  wired = true
  const service = buildMobileVoiceChatService()
  setChatVoicePort(service)
}

export function runStartupWiring(): void {
  // Idempotent — Fast-Refresh / a second mount should not re-subscribe
  // nor re-wire. If we're already authed AND already wired, this is a
  // pure no-op.
  if (wired) return

  // Sync attempt against the current snapshot.
  tryWire(useAuthStore.getState() as AuthSnapshot)
  if (wired) return

  // Not authed yet — subscribe so the null → authed transition wires
  // the port exactly once. Re-entrant calls before the first transition
  // should not stack subscriptions.
  if (unsubscribe) return
  unsubscribe = useAuthStore.subscribe((state) => {
    tryWire(state as AuthSnapshot)
    if (wired && unsubscribe) {
      unsubscribe()
      unsubscribe = null
    }
  })
}

/** Internal: reset module state for tests. Not exported from index. */
export function _resetStartupWiringForTests(): void {
  wired = false
  if (unsubscribe) {
    unsubscribe()
    unsubscribe = null
  }
}

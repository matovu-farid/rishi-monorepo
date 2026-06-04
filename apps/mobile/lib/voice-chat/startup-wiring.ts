/**
 * T-P2.1 — WIRING-001 (RED phase placeholder).
 *
 * Subscribes to the authStore and calls `setChatVoicePort` exactly once
 * after Better-Auth session hydration completes (per SPEC §3.9). Idempotent
 * under Fast-Refresh via a module-level `wired` guard.
 *
 * Currently a no-op stub so the integration tests fail for "not
 * implemented" (incorrect behaviour) rather than "module not resolvable"
 * (test infrastructure broken). The real implementation lands in T-P2.1.
 */

/** No-op placeholder — see SPEC §3.9 for the auth-gated wiring contract. */
export function runStartupWiring(): void {
  // Intentionally empty (red phase).
}

// Trial rules per docs/superpowers/specs/2026-07-17-no-card-credit-trial-design.md:
// each account gets 300 non-expiring credits at signup; a non-cached TTS
// generation costs exactly 1 credit regardless of text length.
export const TRIAL_INITIAL_CREDITS = 300;
/** Pre–3× voice allowance bump; used to idempotently upgrade existing trial rows. */
export const TRIAL_LEGACY_INITIAL_CREDITS = 100;
export const TRIAL_TTS_COST_CREDITS = 1;

// How long a `"tts"` reservation may sit `status: "pending"` before the
// ledger's alarm-driven reconciliation treats it as abandoned (the
// request that should have committed or released it crashed, or the
// client disconnected mid-stream) and returns its held allowance to the
// pool. See `UserUsageLedger.reconcileStaleReservations()`.
export const RESERVATION_STALE_TIMEOUT_MS = 5 * 60_000;

// Matches the "Authoritative entitlement model" states in
// docs/superpowers/specs/2026-07-17-rishi-pricing-trial-launch-prerequisites-design.md.
// `periodEnd` is epoch milliseconds (DO-local storage's native unit for
// every other timestamp this ledger tracks) — callers that need an ISO
// string (e.g. the `/api/billing/me` route, Part E of this plan) convert
// at the boundary, not here.
export type EntitlementSnapshot =
  | { state: "trial_active"; remainingCredits: number }
  | { state: "trial_exhausted" }
  | {
      state: "reader_active" | "voice_active";
      periodEnd: number;
      remainingNarrationSeconds: number;
      remainingVoiceChatSeconds: number;
    }
  | { state: "subscription_expired" };

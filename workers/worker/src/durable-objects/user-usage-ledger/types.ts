// Trial rules per docs/superpowers/specs/2026-07-17-no-card-credit-trial-design.md:
// each account gets 100 non-expiring credits at signup; a non-cached TTS
// generation costs exactly 1 credit regardless of text length.
export const TRIAL_INITIAL_CREDITS = 100;
export const TRIAL_TTS_COST_CREDITS = 1;

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

// Trial rules per docs/superpowers/specs/2026-07-17-no-card-credit-trial-design.md:
// each account gets 100 non-expiring credits at signup; a non-cached TTS
// generation costs exactly 1 credit regardless of text length.
export const TRIAL_INITIAL_CREDITS = 100;
export const TRIAL_TTS_COST_CREDITS = 1;

// Matches the "Authoritative entitlement model" states in
// docs/superpowers/specs/2026-07-17-rishi-pricing-trial-launch-prerequisites-design.md.
// Only the two trial states are modeled here — `reader_active`,
// `voice_active`, and `subscription_expired` are added by a later plan once
// paid-plan allowance periods exist (see `allowancePeriod` in the shared
// schema, intentionally unused by this plan).
export type EntitlementSnapshot =
  | { state: "trial_active"; remainingCredits: number }
  | { state: "trial_exhausted" };

import type { ApplePlan } from "./apple-product-plans";

/**
 * A minimal view of the user's most recent allowance-period D1 row, as far
 * as the transition classifier needs to know. Callers build this from an
 * `allowancePeriod` SELECT plus a follow-up `appleSubscriptions` lookup for
 * `sourceTransactionId` (see `entitlement-sync.ts`'s `applyAppleTransaction`)
 * -- this module has no DB access itself, matching the pure-function
 * convention `handleEntitlementSync` (plan 6) already uses for testability.
 */
export interface CurrentPeriodInfo {
  id: string;
  plan: ApplePlan;
  /**
   * Apple product ID that produced this period, resolved via its
   * `sourceTransactionId`. Null only for a legacy row created before this
   * plan landed (every period this plan creates always sets it) -- treated
   * defensively as "not the same product" so a same-tier legacy row is
   * classified as a crossgrade rather than incorrectly matched as a
   * renewal.
   */
  productId: string | null;
  periodEnd: number; // epoch ms
}

const PLAN_TIER: Record<ApplePlan, number> = { reader: 1, voice: 2 };

export type TransitionClassification =
  | { kind: "first_period" }
  | { kind: "renewed"; priorPeriodId: string }
  | { kind: "upgraded"; priorPeriodId: string }
  | { kind: "downgraded_deferred"; priorPeriodId: string }
  | { kind: "downgraded_applied"; priorPeriodId: string }
  | { kind: "crossgrade_deferred"; priorPeriodId: string }
  | { kind: "crossgrade_applied"; priorPeriodId: string };

/**
 * Classifies a freshly-verified, NOT-YET-PROCESSED Apple transaction
 * against the user's most recent allowance-period D1 row (active or
 * lapsed -- see "Design decisions" #2 for why callers must pass the single
 * latest row regardless of whether it has expired).
 *
 * Callers MUST only invoke this for a transaction that hasn't already had
 * its allowance-period side effects applied (see `entitlement-sync.ts`'s
 * `applyAppleTransaction` -- it checks `allowancePeriod.sourceTransactionId`
 * for an existing row before calling this function at all). That
 * precondition is what makes the same-tier/same-product branch below safe
 * to treat as an unconditional "renewed": a distinct, not-yet-seen Apple
 * transaction for the same product while the current period is active can
 * only mean Apple has renewed it. Comparing `expiresDate` against the
 * current period's `periodEnd` is deliberately NOT done here -- for an
 * annual product `expiresDate` is far beyond the 1-month `periodEnd` on
 * every sync, which is what caused the entitlement-sync-idempotency bug
 * this function was rewritten to fix.
 *
 * Tier ranking is Voice (2) > Reader (1), per the design doc's "Subscription
 * transitions" section ("Voice monthly and yearly products are level 1;
 * Reader monthly and yearly products are level 2" in StoreKit's own
 * ranking, i.e. Voice outranks Reader). Product-ID equality (not just plan
 * equality) distinguishes a same-tier "renewal" (identical product) from a
 * same-tier "crossgrade" (different product = a monthly<->annual duration
 * change within the same tier).
 *
 * `"_deferred"` vs `"_applied"` for downgrade/crossgrade is decided purely
 * by whether the CURRENT period is still active: while it is, the change
 * is deferred (design doc: "Keep Voice access and its current allowance
 * period through renewal"); once it has lapsed, the very next sync call
 * for the new (lower-tier or different-duration) product applies it.
 */
export function classifyTransition(input: {
  currentPeriod: CurrentPeriodInfo | null;
  newPlan: ApplePlan;
  newProductId: string;
  now: number; // epoch ms
}): TransitionClassification {
  const { currentPeriod, newPlan, newProductId, now } = input;

  if (!currentPeriod) {
    return { kind: "first_period" };
  }

  const currentTier = PLAN_TIER[currentPeriod.plan];
  const newTier = PLAN_TIER[newPlan];
  const currentPeriodIsActive = currentPeriod.periodEnd > now;
  const sameProduct =
    currentPeriod.productId !== null && currentPeriod.productId === newProductId;

  if (!currentPeriodIsActive) {
    // The old period has already lapsed -- nothing left to defer against,
    // so any new transaction opens a fresh period immediately. The
    // classification still reflects the tier relationship for audit
    // purposes, reusing the enum values that mean "a period just started."
    if (newTier > currentTier) return { kind: "upgraded", priorPeriodId: currentPeriod.id };
    if (newTier < currentTier) {
      return { kind: "downgraded_applied", priorPeriodId: currentPeriod.id };
    }
    if (sameProduct) return { kind: "renewed", priorPeriodId: currentPeriod.id };
    return { kind: "crossgrade_applied", priorPeriodId: currentPeriod.id };
  }

  // Current period is still active.
  if (newTier > currentTier) {
    return { kind: "upgraded", priorPeriodId: currentPeriod.id };
  }
  if (newTier < currentTier) {
    return { kind: "downgraded_deferred", priorPeriodId: currentPeriod.id };
  }
  if (sameProduct) {
    return { kind: "renewed", priorPeriodId: currentPeriod.id };
  }
  return { kind: "crossgrade_deferred", priorPeriodId: currentPeriod.id };
}

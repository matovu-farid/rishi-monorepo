/**
 * Apple product-ID -> Rishi plan mapping for the four StoreKit subscription
 * products (2026-07-17 pricing/trial-launch design doc, "Paid-plan product
 * policy"). `entitlement-sync.ts` imports this table to verify an incoming
 * transaction's product ID and to look up full plan allowances; it lives in
 * its own module (rather than inline in `entitlement-sync.ts`) so any future
 * billing file (e.g. a receipt-mapping route) can reuse it without pulling in
 * `entitlement-sync.ts`'s other imports, and so it can never form an import
 * cycle with the file that consumes it.
 *
 * Naming follows the existing `org.fidexa.rishi.pro.monthly` /
 * `org.fidexa.rishi.pro.annual` convention (apps/apple/scripts/
 * setup_storekit_products.rb) -- `.annual`, not `.yearly` -- so App Store
 * Connect product creation (the iOS "storekit-products" plan) and this
 * table use byte-identical strings.
 *
 * `durationMonths` is NOT consumed by this plan's allowance-period logic
 * (every plan gets a 1-month allowance period regardless of billing
 * duration, per the design doc: "annual subscriptions ... receive the same
 * allowance every monthly allowance period"). It is retained here as
 * metadata for the "subscription-transitions" follow-up plan, which needs
 * to distinguish a monthly<->annual crossgrade of the SAME plan from a
 * Reader<->Voice upgrade/downgrade.
 */

export type ApplePlan = "reader" | "voice";

export interface ApplePlanMapping {
  plan: ApplePlan;
  durationMonths: 1 | 12;
}

export const APPLE_BUNDLE_ID = "org.fidexa.rishi";

export const APPLE_PRODUCT_PLAN_MAP: Record<string, ApplePlanMapping> = {
  "org.fidexa.rishi.reader.monthly": { plan: "reader", durationMonths: 1 },
  "org.fidexa.rishi.reader.annual": { plan: "reader", durationMonths: 12 },
  "org.fidexa.rishi.voice.monthly": { plan: "voice", durationMonths: 1 },
  "org.fidexa.rishi.voice.annual": { plan: "voice", durationMonths: 12 },
};

/**
 * Full monthly allowance-period totals per plan (design doc's paid-plan
 * product policy table): Reader gets 2h narration / 10m Voice Chat; Voice
 * gets 4h narration / 30m Voice Chat. Units are seconds, matching
 * `allowancePeriod.narrationSecondsTotal` / `.voiceChatSecondsTotal`
 * (workers/worker/src/db/schema.ts).
 */
export const PLAN_ALLOWANCES: Record<
  ApplePlan,
  { narrationSecondsTotal: number; voiceChatSecondsTotal: number }
> = {
  reader: { narrationSecondsTotal: 2 * 60 * 60, voiceChatSecondsTotal: 10 * 60 },
  voice: { narrationSecondsTotal: 4 * 60 * 60, voiceChatSecondsTotal: 30 * 60 },
};

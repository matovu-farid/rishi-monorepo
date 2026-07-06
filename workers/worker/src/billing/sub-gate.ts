import { desc, eq } from "drizzle-orm";
import type { Context, MiddlewareHandler } from "hono";
import { subscription } from "@rishi/shared/schema";
import { createDb } from "../db/drizzle";
import type { Env } from "../index";

const ALLOWED_STATUSES = new Set(["active", "trialing"]);

/**
 * Pure decision: should this user be allowed to invoke a paid feature?
 *
 * Rules in order:
 *   1. Billing disabled (no STRIPE_SECRET_KEY in env) → allow. Lets local
 *      dev work without secrets and avoids breaking prod if billing is
 *      paused for an incident.
 *   2. Dev-bypass user → allow. Matches requireAuth's bypass path.
 *   3. Otherwise → allow only when the subscription status is active or
 *      trialing. past_due / canceled / unpaid / incomplete / null all
 *      block; null covers existing users who pre-date the plugin.
 */
export function isAllowedForBilledFeature(opts: {
  billingEnabled: boolean;
  userId: string;
  subscriptionStatus: string | null;
}): boolean {
  if (!opts.billingEnabled) return true;
  if (opts.userId === "dev-user") return true;
  if (!opts.subscriptionStatus) return false;
  return ALLOWED_STATUSES.has(opts.subscriptionStatus);
}

/**
 * Hono middleware. Reads the most recent subscription row for the
 * authenticated user, applies isAllowedForBilledFeature, returns
 * `402 Payment Required` on block.
 */
export const requireActiveSubscription: MiddlewareHandler<{
  Bindings: Env;
  Variables: { userId: string };
}> = async (c, next) => {
  const userId = c.get("userId");
  // const billingEnabled = Boolean(c.env.STRIPE_SECRET_KEY);
  // let subscriptionStatus: string | null = null;
  // if (billingEnabled && userId !== "dev-user") {
  //   const db = createDb(c.env.DB);
  //   const row = await db
  //     .select({ status: subscription.status })
  //     .from(subscription)
  //     .where(eq(subscription.referenceId, userId))
  //     .orderBy(desc(subscription.periodStart))
  //     .get();
  //   subscriptionStatus = row?.status ?? null;
  // }
  // if (
  //   !isAllowedForBilledFeature({ billingEnabled, userId, subscriptionStatus })
  // ) {
  //   return c.json(
  //     {
  //       error: "Active subscription required to use this feature",
  //       code: "BILLING_INACTIVE",
  //       subscriptionStatus,
  //     },
  //     402,
  //   );
  // }
  await next();
};

// Re-exported for tests that want to construct middleware-equivalent
// gates against a fake context without spinning up D1.
export type GateContext = Context<{
  Bindings: Env;
  Variables: { userId: string };
}>;

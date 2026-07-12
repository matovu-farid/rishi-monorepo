import type Stripe from "stripe";
import { eq } from "drizzle-orm";
import {
  METER_EVENT_NAME,
  usdToMicroDollars,
} from "@rishi/shared/billing/stripe-config";
import { user } from "@rishi/shared/schema";
import {
  computeOpenAiCostUsd,
  type OpenAiUsage,
} from "@rishi/shared/billing/cost";
import { DEFAULT_RATES } from "@rishi/shared/billing/default-rates";
import { createDb } from "../db/drizzle";
import { createStripeClient } from "./stripe";


/**
 * Report a usage event to the Stripe meter. Fire-and-forget; callers
 * should wrap with `c.executionCtx.waitUntil` to keep the response path
 * fast.
 *
 * No-ops when:
 *   - stripe client is null (local dev without STRIPE_SECRET_KEY)
 *   - customer id is missing (anonymous / dev-bypass requests)
 *   - microDollarsCost is non-positive (nothing to bill)
 */
export async function reportMeterEvent(
  stripe: Stripe | null,
  stripeCustomerId: string | null,
  microDollarsCost: number,
): Promise<void> {
  if (!stripe) return;
  if (!stripeCustomerId) return;
  if (microDollarsCost <= 0) return;
  await stripe.billing.meterEvents.create({
    event_name: METER_EVENT_NAME,
    payload: {
      stripe_customer_id: stripeCustomerId,
      value: String(microDollarsCost),
    },
  });
}

/**
 * Endpoint-level convenience: resolve the stripe customer for `userId`,
 * compute the OpenAI cost from `usage`, and emit the meter event. Designed
 * to be passed to `c.executionCtx.waitUntil` from a Hono handler. Silently
 * no-ops when STRIPE_SECRET_KEY is not configured, when the user has no
 * stripeCustomerId yet (e.g. pre-plugin signups, dev-bypass), or when the
 * computed cost rounds to zero.
 */
export async function meterFromContext(
  env: Env,
  userId: string,
  usage: OpenAiUsage,
): Promise<void> {
  if (!env.STRIPE_SECRET_KEY) return;
  const stripe = createStripeClient(env.STRIPE_SECRET_KEY);
  const db = createDb(env.DB);
  const row = await db
    .select({ stripeCustomerId: user.stripeCustomerId })
    .from(user)
    .where(eq(user.id, userId))
    .get();
  if (!row?.stripeCustomerId) return;
  const microDollars = usdToMicroDollars(
    computeOpenAiCostUsd(usage, DEFAULT_RATES),
  );
  await reportMeterEvent(stripe, row.stripeCustomerId, microDollars);
}

import type Stripe from "stripe";
import { createPortalSession } from "./portal";

export interface EnsureCustomerAndPortalDeps {
  stripe: Stripe;
  priceId: string;
  userId: string;
  returnUrl: string;
  ip: string | null;
  getUserRow: (
    userId: string,
  ) => Promise<{ stripeCustomerId: string | null; email: string | null } | null>;
  updateUserStripeCustomerId: (stripeCustomerId: string) => Promise<void>;
  ensureCreditAndSubscription: (
    stripe: Stripe,
    stripeCustomerId: string,
    priceId: string,
    ip: string | null,
  ) => Promise<unknown>;
}

/**
 * Unified billing entry: guarantees the user has a Stripe customer +
 * subscription, then returns a portal URL. Never surfaces the 409
 * "no stripe customer" case that /api/billing/portal has — that's the
 * whole point of this helper.
 */
export async function ensureCustomerAndPortal(
  deps: EnsureCustomerAndPortalDeps,
): Promise<{ url: string }> {
  const row = await deps.getUserRow(deps.userId);
  if (!row) {
    throw new Error("ensureCustomerAndPortal: user not found");
  }

  let customerId = row.stripeCustomerId;
  if (!customerId) {
    const customer = await deps.stripe.customers.create({
      email: row.email ?? undefined,
      metadata: { userId: deps.userId },
    });
    customerId = customer.id;
    // Persist before sub create so the customer.subscription.created webhook
    // can map customer -> user via the Better-Auth Stripe plugin.
    await deps.updateUserStripeCustomerId(customerId);
    // Idempotent — safe even if a prior partial signup already left grants/subs.
    await deps.ensureCreditAndSubscription(
      deps.stripe,
      customerId,
      deps.priceId,
      deps.ip,
    );
  }

  const url = await createPortalSession(deps.stripe, customerId, deps.returnUrl);
  return { url };
}

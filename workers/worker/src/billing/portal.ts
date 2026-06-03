import type Stripe from "stripe";

/**
 * Mint a one-time Customer Portal URL for `stripeCustomerId`. Users land
 * on Stripe-hosted UI to add/update payment methods, view invoices, and
 * cancel/resume subscriptions. The URL is single-use; callers should
 * redirect immediately, not cache it.
 */
export async function createPortalSession(
  stripe: Stripe,
  stripeCustomerId: string,
  returnUrl: string,
): Promise<string> {
  if (!stripeCustomerId) {
    throw new Error("createPortalSession: stripeCustomerId is required");
  }
  const session = await stripe.billingPortal.sessions.create({
    customer: stripeCustomerId,
    return_url: returnUrl,
  });
  return session.url;
}

import Stripe from "stripe";
import { STRIPE_TEST_IDS } from "@rishi/shared/billing/stripe-config";

// Per-process memo. Cloudflare Workers re-instantiate this module on cold
// start; the Stripe client is just an HTTP wrapper so the cost is small.
let cachedStripe: Stripe | null = null;
let cachedKey: string | null = null;

export function createStripeClient(secretKey: string): Stripe {
  if (cachedStripe && cachedKey === secretKey) return cachedStripe;
  cachedStripe = new Stripe(secretKey, {
    // Workers runtime uses fetch, not Node http.
    httpClient: Stripe.createFetchHttpClient(),
  });
  cachedKey = secretKey;
  return cachedStripe;
}

const WELCOME_CREDIT_CENTS = 100;

export async function applyWelcomeCreditAndSubscription(
  stripe: Stripe,
  stripeCustomerId: string,
  customerIpAddress: string | null,
): Promise<{ subscriptionId: string }> {
  if (customerIpAddress) {
    await stripe.customers.update(stripeCustomerId, {
      tax: { ip_address: customerIpAddress, validate_location: "auto" },
    });
  }
  await stripe.customers.createBalanceTransaction(stripeCustomerId, {
    amount: -WELCOME_CREDIT_CENTS,
    currency: "usd",
    description: "Welcome credit ($1.00 of included usage)",
  });
  const subscription = await stripe.subscriptions.create({
    customer: stripeCustomerId,
    items: [{ price: STRIPE_TEST_IDS.priceId }],
    automatic_tax: { enabled: true },
  });
  return { subscriptionId: subscription.id };
}

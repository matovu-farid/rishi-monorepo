import Stripe from "stripe";

export type BackfillStep =
  | "reused-customer"
  | "created-customer"
  | "skipped-credit"
  | "applied-credit"
  | "skipped-sub"
  | "created-sub";

export type BackfillResult = {
  userId: string;
  stripeCustomerId: string;
  subscriptionId: string;
  steps: BackfillStep[];
};

export type EnsureCreditAndSubResult = {
  subscriptionId: string;
  steps: BackfillStep[];
};

const WELCOME_CREDIT_CENTS = 100;
const WELCOME_CREDIT_METADATA_KEY = "type";
const WELCOME_CREDIT_METADATA_VALUE = "welcome";
const ACTIVE_SUB_STATUSES = new Set([
  "active",
  "past_due",
  "trialing",
  "incomplete",
]);

export async function ensureCreditAndSubscription(
  stripe: Stripe,
  stripeCustomerId: string,
  priceId: string,
  customerIpAddress: string | null,
): Promise<EnsureCreditAndSubResult> {
  const steps: BackfillStep[] = [];

  if (customerIpAddress) {
    await stripe.customers.update(stripeCustomerId, {
      tax: { ip_address: customerIpAddress, validate_location: "auto" },
    });
  }

  // Welcome credit, modeled as a promotional Billing Credit Grant. Applies
  // pre-tax against any metered price, expires never, and shows up in the
  // dashboard's "Credit grants" section. Idempotent via metadata.type.
  const existingGrants = await stripe.billing.creditGrants.list({
    customer: stripeCustomerId,
    limit: 100,
  });
  const hasWelcomeGrant = existingGrants.data.some(
    (g) =>
      g.metadata?.[WELCOME_CREDIT_METADATA_KEY] ===
        WELCOME_CREDIT_METADATA_VALUE && !g.voided_at,
  );
  if (hasWelcomeGrant) {
    steps.push("skipped-credit");
  } else {
    await stripe.billing.creditGrants.create({
      customer: stripeCustomerId,
      amount: {
        type: "monetary",
        monetary: { currency: "usd", value: WELCOME_CREDIT_CENTS },
      },
      applicability_config: { scope: { price_type: "metered" } },
      category: "promotional",
      name: "Welcome credit",
      metadata: {
        [WELCOME_CREDIT_METADATA_KEY]: WELCOME_CREDIT_METADATA_VALUE,
      },
    });
    steps.push("applied-credit");
  }

  const subs = await stripe.subscriptions.list({
    customer: stripeCustomerId,
    status: "all",
    limit: 100,
  });
  const existing = subs.data.find(
    (s) =>
      ACTIVE_SUB_STATUSES.has(s.status) &&
      s.items.data.some((it) => it.price.id === priceId),
  );

  let subscriptionId: string;
  if (existing) {
    subscriptionId = existing.id;
    steps.push("skipped-sub");
  } else {
    const created = await stripe.subscriptions.create({
      customer: stripeCustomerId,
      items: [{ price: priceId }],
      automatic_tax: { enabled: true },
    });
    subscriptionId = created.id;
    steps.push("created-sub");
  }

  return { subscriptionId, steps };
}

export type BackfillOptions = {
  onCustomerEnsured?: (stripeCustomerId: string) => Promise<void>;
};

export async function backfillOneUser(
  stripe: Stripe,
  userId: string,
  email: string,
  priceId: string,
  options: BackfillOptions = {},
): Promise<BackfillResult> {
  const steps: BackfillStep[] = [];

  const search = await stripe.customers.search({
    query: `metadata['userId']:'${userId}'`,
  });
  let customerId: string;
  if (search.data.length >= 1) {
    customerId = (search.data[0] as unknown as { id: string }).id;
    steps.push("reused-customer");
  } else {
    const created = (await stripe.customers.create({
      email,
      metadata: { userId },
      address: { country: "US" },
    })) as unknown as { id: string };
    customerId = created.id;
    steps.push("created-customer");
  }

  // Hook for callers to persist user.stripe_customer_id BEFORE we create
  // the subscription — otherwise the customer.subscription.created webhook
  // fires while the user row still has stripe_customer_id IS NULL, and the
  // Better-Auth Stripe plugin can't map customer -> user.
  if (options.onCustomerEnsured) {
    await options.onCustomerEnsured(customerId);
  }

  const ensured = await ensureCreditAndSubscription(
    stripe,
    customerId,
    priceId,
    null,
  );
  steps.push(...ensured.steps);

  return {
    userId,
    stripeCustomerId: customerId,
    subscriptionId: ensured.subscriptionId,
    steps,
  };
}

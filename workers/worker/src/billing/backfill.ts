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

const WELCOME_CREDIT_CENTS = 100;
const ACTIVE_SUB_STATUSES = new Set([
  "active",
  "past_due",
  "trialing",
  "incomplete",
]);

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
  let customer: { id: string; balance: number };
  if (search.data.length >= 1) {
    const found = search.data[0] as unknown as { id: string; balance: number };
    customer = { id: found.id, balance: found.balance };
    steps.push("reused-customer");
  } else {
    const created = (await stripe.customers.create({
      email,
      metadata: { userId },
      address: { country: "US" },
    })) as unknown as { id: string; balance: number };
    customer = { id: created.id, balance: created.balance };
    steps.push("created-customer");
  }

  // Hook for callers to persist user.stripe_customer_id BEFORE we create
  // the subscription — otherwise the customer.subscription.created webhook
  // fires while the user row still has stripe_customer_id IS NULL, and the
  // Better-Auth Stripe plugin can't map customer -> user.
  if (options.onCustomerEnsured) {
    await options.onCustomerEnsured(customer.id);
  }

  if (customer.balance <= -WELCOME_CREDIT_CENTS) {
    steps.push("skipped-credit");
  } else {
    await stripe.customers.createBalanceTransaction(customer.id, {
      amount: -WELCOME_CREDIT_CENTS,
      currency: "usd",
      description: "Welcome credit ($1.00 of included usage)",
    });
    steps.push("applied-credit");
  }

  const subs = await stripe.subscriptions.list({
    customer: customer.id,
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
      customer: customer.id,
      items: [{ price: priceId }],
      automatic_tax: { enabled: true },
    });
    subscriptionId = created.id;
    steps.push("created-sub");
  }

  return { userId, stripeCustomerId: customer.id, subscriptionId, steps };
}

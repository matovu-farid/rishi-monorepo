# Stripe Tax — Design Spec

Smallest possible change to enable automatic tax calculation on the
metered subscription invoices created by `workers/worker/src/billing/stripe.ts`.
Slots in between the existing 8-commit Stripe billing build (through
`65090285`) and the original `BILLING-HANDOFF.md` roadmap (test clock,
realtime client wiring, etc., still outstanding).

This is the first of two pieces of work agreed in this session:

1. **Stripe Tax** (this spec) — quick, small.
2. **Test clock script** — Phase 1 of the original roadmap; spec to be
   re-created from this session's conversation history.

## Goal

When a Stripe customer accrues meter-event usage and Stripe generates
an invoice at period-end, the invoice carries a correctly calculated
tax line item based on the customer's location (derived from their IP
at signup), without us having to collect a billing address up front.

## Locked decisions

1. **Customer location source: IP geolocation.** Set
   `customer.tax.ip_address` to `CF-Connecting-IP` at customer-create
   time. Stripe combines IP + `customer.tax.validate_location` (=
   `"auto"` by default for new customers) to compute the location.
   Customers can correct via the Customer Portal later (Portal exposes
   address + tax ID collection when configured).

2. **Standalone change.** One spec, one commit, no bundling with the
   test-clock work. Test-clock spec will get rewritten separately after
   this lands.

## Code change

`workers/worker/src/billing/stripe.ts` — two modifications inside
`applyWelcomeCreditAndSubscription`:

```ts
export async function applyWelcomeCreditAndSubscription(
  stripe: Stripe,
  stripeCustomerId: string,
+ customerIpAddress: string | null,
): Promise<{ subscriptionId: string }> {
+ if (customerIpAddress) {
+   await stripe.customers.update(stripeCustomerId, {
+     tax: { ip_address: customerIpAddress, validate_location: "auto" },
+   });
+ }
  await stripe.customers.createBalanceTransaction(stripeCustomerId, {
    amount: -WELCOME_CREDIT_CENTS,
    currency: "usd",
    description: "Welcome credit ($1.00 of included usage)",
  });
  const subscription = await stripe.subscriptions.create({
    customer: stripeCustomerId,
    items: [{ price: STRIPE_TEST_IDS.priceId }],
+   automatic_tax: { enabled: true },
  });
  return { subscriptionId: subscription.id };
}
```

The caller in `workers/worker/src/auth.ts` (the `@better-auth/stripe`
plugin's `onCustomerCreate` hook) must pass the IP. Better Auth's
hook signature gives us `request: Request`; the IP is at
`request.headers.get("cf-connecting-ip")` on Cloudflare Workers.

```ts
// In auth.ts, inside the betterAuthStripe({ onCustomerCreate, ... }) block:
onCustomerCreate: async ({ stripeCustomer, user }, request) => {
+ const ip = request?.headers.get("cf-connecting-ip") ?? null;
- await applyWelcomeCreditAndSubscription(stripeClient, stripeCustomer.id);
+ await applyWelcomeCreditAndSubscription(stripeClient, stripeCustomer.id, ip);
  // ... persist customerId to D1 user row (existing code, unchanged)
},
```

## Test changes

`workers/worker/src/billing/stripe.test.ts` adds two cases:

1. When `customerIpAddress` is provided, asserts that
   `stripe.customers.update` is called with the expected
   `tax.ip_address` payload **before** the subscription is created.
2. The existing test that asserts the subscription is created gets
   extended to assert `automatic_tax: { enabled: true }` in the
   subscription create call.
3. When `customerIpAddress` is null, asserts that
   `stripe.customers.update` is **not** called (we skip the tax-config
   step for unknown IPs; Stripe falls back to its own heuristics).

## Dashboard setup (user-side, one time)

These steps must happen in the Stripe Dashboard before tax is
actually calculated. The code change can ship without them — Stripe
will accept `automatic_tax: enabled = true` and silently skip tax
when no jurisdictions are registered.

1. **Stripe Dashboard → Tax → Get started.** Accept the terms; enable
   Stripe Tax.
2. **Tax → Registrations.** Add registrations for each jurisdiction
   where you have nexus (US states, EU countries, UK, etc.). Stripe
   guides you through this and lets you defer registrations you're
   not yet required to file in.
3. **Tax → Settings → Default tax behavior.** Pick "exclusive" or
   "inclusive" pricing. (Recommend "exclusive" so the $1.20 per $1.00
   of OpenAI cost stays as the headline price and tax shows as a
   separate invoice line item.)
4. **Customer Portal → Information collected.** Enable "Tax IDs" so
   EU/UK business customers can enter their VAT ID via the Portal
   (zero-rates B2B sales). This is a separate Portal config switch.

## Verification

Two layers:

1. **Unit:** the three test assertions above run on `pnpm test --run
   src/billing/stripe.test.ts` and prove the SDK is called with the
   right shapes.
2. **Manual sandbox smoke:** after the dashboard setup, sign up a test
   user via `/test/sign-in` from a non-US IP (use a VPN or curl through
   a proxy), confirm in the Stripe Dashboard's customer detail page
   that the customer's tax location is set to the correct country.
   Then trigger an invoice (either by waiting for period-end or by
   using a test clock — which is exactly what the next phase of work
   delivers). The resulting invoice should carry a "Tax" line item
   for the correct jurisdiction.

## Out of scope

- Test clock end-to-end verification of tax line items — gets folded
  into the test-clock spec (Phase 5 acceptance criteria, "card-on-file
  flow", can be extended to assert `invoice.tax > 0` for non-US
  scenarios).
- Tax ID collection at signup — Portal handles it post-signup.
- Reverse charge / B2B logic — Stripe handles automatically once the
  customer enters a VAT ID via Portal.
- Invoice PDF customization — out of scope; Stripe's default template
  is fine.

## Acceptance criteria

1. `pnpm test --run workers/worker/src/billing/stripe.test.ts` is
   green with the three new assertions.
2. A `grep "automatic_tax" workers/worker/src/billing/stripe.ts`
   returns one hit (in `applyWelcomeCreditAndSubscription`).
3. A `grep "cf-connecting-ip" workers/worker/src/auth.ts` returns one
   hit (the IP extraction in `onCustomerCreate`).
4. Existing 25 billing-related worker tests stay green.
5. `BILLING.md` gets a one-paragraph "Stripe Tax" subsection under
   "Local dev" explaining the dashboard setup is required for tax to
   actually appear on invoices.

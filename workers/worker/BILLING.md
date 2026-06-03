# Billing runbook

Usage-based Stripe billing for the worker. See `src/billing/` for code and
`packages/shared/src/billing/` for shared types/constants.

## How it bills

1. Sign-up flow runs through `createAuth` in `src/auth.ts`. When
   `STRIPE_SECRET_KEY` + `STRIPE_WEBHOOK_SECRET` are both set, the
   `@better-auth/stripe` plugin attaches.
2. On signup, the plugin creates a Stripe customer and writes
   `user.stripe_customer_id`.
3. `onCustomerCreate` calls `applyWelcomeCreditAndSubscription`, which
   applies a `-$1.00` customer balance credit and starts a metered
   subscription on the configured price.
4. Every successful OpenAI call (speech, completions, embed) fires a
   meter event via `c.executionCtx.waitUntil(meterFromContext(...))`.
   Realtime is metered separately via `POST /api/billing/realtime-usage`.
5. At end of period, Stripe sums the meter, applies the markup
   (`0.00012¢` per micro-dollar = +20%), subtracts the credit, and
   invoices the rest. No card on file → invoice fails → dunning kicks
   in.

## Required worker secrets

```bash
# Both required to enable billing. Worker no-ops billing without them.
wrangler secret put STRIPE_SECRET_KEY      # sk_test_... or sk_live_...
wrangler secret put STRIPE_WEBHOOK_SECRET  # whsec_... from webhook registration
```

Local dev: drop into `.dev.vars` (not committed). Worker reads via the
same `env.STRIPE_SECRET_KEY` path.

## Promoting test mode → live mode

The current code points at the test-mode IDs in
`packages/shared/src/billing/stripe-config.ts` (`STRIPE_TEST_IDS`). Live
mode needs its own meter, product, and price.

1. **Create live-mode Stripe resources.** Run each command with
   `--live`:

   ```bash
   stripe billing meters create \
     --display-name "OpenAI cost (micro-dollars)" \
     --event-name "openai_cost_micros" \
     --default-aggregation.formula sum \
     --value-settings.event-payload-key value \
     --customer-mapping.type by_id \
     --customer-mapping.event-payload-key stripe_customer_id \
     --live -c
   # → meter id  mtr_...

   stripe products create \
     --name "Rishi Usage" \
     --description "Pay-as-you-go AI usage. 20% markup on OpenAI cost." \
     --live -c
   # → product id  prod_...

   stripe prices create \
     --product <product-id> \
     --currency usd \
     -d "unit_amount_decimal=0.00012" \
     -d "recurring[interval]=month" \
     -d "recurring[usage_type]=metered" \
     -d "recurring[meter]=<meter-id>" \
     --nickname "Rishi Usage — 20% markup on OpenAI cost" \
     --live -c
   # → price id  price_...
   ```

2. **Pin the IDs.** Update `STRIPE_LIVE_IDS` in
   `packages/shared/src/billing/stripe-config.ts`:

   ```ts
   export const STRIPE_LIVE_IDS: StripeBillingIds = {
     meterId: "mtr_...",
     productId: "prod_...",
     priceId: "price_...",
   };
   ```

   Code that currently imports `STRIPE_TEST_IDS` directly
   (`workers/worker/src/billing/stripe.ts:applyWelcomeCreditAndSubscription`,
   `workers/worker/src/auth.ts` subscription plan declaration) should
   switch to `getStripeIds(env.STRIPE_MODE)` and `STRIPE_MODE=live`
   becomes a wrangler env var.

3. **Register the webhook.** Once the live-mode `STRIPE_SECRET_KEY` is
   set on the worker:

   ```bash
   stripe webhook_endpoints create \
     --url https://api.fidexa.org/api/auth/stripe/webhook \
     --enabled-events customer.subscription.created \
     --enabled-events customer.subscription.updated \
     --enabled-events customer.subscription.deleted \
     --enabled-events invoice.payment_failed \
     --live -c
   # → whsec_...
   ```

   Set the worker secret:

   ```bash
   wrangler secret put STRIPE_WEBHOOK_SECRET  # paste the whsec_
   ```

4. **Verify with a test signup.** In a fresh browser, sign up a new
   user. Check:

   ```bash
   stripe customers list --live -L 1                  # expect new customer
   stripe subscriptions list --live -L 1              # expect status active
   stripe billing meter_events list --meter <id>      # expect events after AI use
   ```

5. **(Optional) Adjust markup.** The 20% markup is encoded as
   `unit_amount_decimal: "0.00012"` (cents per micro-dollar). Change the
   live Price's unit amount to shift it — no code change needed.

## Realtime metering caveat

`/api/realtime/client_secrets` mints a client credential; the actual
audio stream goes client → OpenAI directly, so the worker never sees the
tokens. The client is responsible for posting the final session
counters to `POST /api/billing/realtime-usage` when the conversation
ends. Trust is bounded by `requireAuth` plus the per-report cap in
`parseRealtimeUsageBody` (`REALTIME_MAX_TOKENS_PER_REPORT = 500_000`).
A per-day soft cap and reconciliation against `client_secrets` mint
events are open follow-ups.

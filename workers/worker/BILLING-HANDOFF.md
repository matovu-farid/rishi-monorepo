# Billing implementation — handoff

Pickup point as of `65090285` on `main`. Read alongside `BILLING.md`
(the live-mode runbook) and `packages/shared/src/billing/` (the
shared types + cost calculator).

## TL;DR

Usage-based Stripe billing is wired end-to-end **in test mode**
through both local dev and the production worker at
`api.fidexa.org`. Every code path on the happy path is verified.
What's missing is the "unhappy path" coverage — what happens at
end-of-month, when cards decline, when realtime audio is used,
and when existing pre-plugin users hit a billed endpoint. **Do
not flip to live mode until those gaps are closed.**

## Commits (since `ac7d0783`)

| Hash | What |
|---|---|
| `21a1fe05` | Stripe primitives (meter, product, price) + cost calculator + DEFAULT_RATES + 10 tests |
| `9c17bd50` | Drift fix — caught D1 up with bookmarks + 3 books columns |
| `58fd5119` | Schema — `user.stripe_customer_id` + `subscription` table per Better Auth Stripe plugin |
| `58fd31cf` | Wired `@better-auth/stripe` into `src/auth.ts` (customer + $1 credit + metered sub on signup) |
| `db5a797c` | Meter event reporting on speech / completions / embed via `executionCtx.waitUntil` |
| `2f76a65e` | Customer Portal + realtime usage client-report endpoints |
| `0e25b3d5` | `BILLING.md` runbook |
| `65090285` | `requireActiveSubscription` middleware gating 4 AI endpoints on subscription status |

## What lives where

```
packages/shared/src/billing/
  stripe-config.ts         — meter/product/price IDs + 20% markup constants
  cost.ts                  — computeOpenAiCostUsd over discriminated union
  default-rates.ts         — OpenAI per-1M rates (snapshot 2026-06-03)

workers/worker/src/billing/
  stripe.ts                — createStripeClient + applyWelcomeCreditAndSubscription
  meter.ts                 — reportMeterEvent + meterFromContext orchestrator
  portal.ts                — Stripe Customer Portal session minting
  realtime-usage.ts        — body validation + per-report cap
  sub-gate.ts              — requireActiveSubscription middleware + pure decision fn
  *.test.ts                — TDD coverage for each

workers/worker/src/auth.ts — Better Auth Stripe plugin wiring
workers/worker/src/index.ts — 4 gated AI endpoints + 2 billing endpoints + bindings
workers/worker/BILLING.md  — live-mode promotion runbook
```

## Verified in test mode (proven E2E)

| Capability | Evidence |
|---|---|
| Signup → Stripe customer with `userId` metadata | `cus_UdMTaAEUd4csNC` (and others), confirmed via `stripe customers list` |
| `-$1.00` welcome credit applied at signup | customer `balance: -100` |
| Metered subscription started, status `active` immediately | `sub_1Te5kIC...` etc., no payment method gate needed |
| `D1.user.stripe_customer_id` populated | direct query |
| `D1.subscription` row populated on signup | direct query — status `active`, references our price + meter |
| Meter events flow into Stripe and aggregate correctly | aggregated_value `64_000` for `{audioInputTokens: 1000, audioOutputTokens: 500}` — exact rate-card math |
| Customer Portal endpoint returns real Stripe URL | `https://billing.stripe.com/p/session/test_...` |
| Realtime usage validation + per-report cap | `audioInputTokens: 999999999` → 400 with `exceeds per-report cap` |
| **Webhook signature verification** | `pending_webhooks: 0` on triggered event in production |
| **Webhook lifecycle → D1 persistence** | `stripe subscriptions cancel <id>` → `customer.subscription.deleted` 200 → D1 row updated to `canceled` |
| **Sub-status gate blocks canceled users** | After cancel, `/api/embed` returns `402 BILLING_INACTIVE` with `subscriptionStatus: "canceled"` |

## Production deploy state

- Worker version `0b9d5a9c-d310-41ee-bdbd-d2957a9c263c` deployed to `api.fidexa.org`
- Wrangler secrets set on production worker:
  - `STRIPE_SECRET_KEY` (test mode — user confirmed)
  - `STRIPE_WEBHOOK_SECRET` (test mode, tied to webhook `we_1Te5KaCcIfMF2dQAnPHP1959`)
- Test-mode webhook `we_1Te5KaCcIfMF2dQAnPHP1959` registered, receiving 4 event types:
  - `customer.subscription.created`
  - `customer.subscription.updated`
  - `customer.subscription.deleted`
  - `invoice.payment_failed`
- D1 (local + remote) at migration `0004_stripe_billing` — schema in sync with `schema.ts`

## NOT yet verified in test mode (block live)

Ordered by recommended sequence, not priority. Each is "must-do" before live.

### 1. End-of-period invoice behavior via Stripe test clock — **highest leverage**

Why: exercises every other component at the moment money would change
hands. Surfaces problems with card decline, `invoice.payment_failed`
webhook handling, and the gate's reaction to `past_due` (we've only
verified `canceled` so far).

```bash
# Create a test clock, attach a customer to it at signup, advance time
stripe test_helpers test_clocks create --frozen-time $(date +%s)
# Then signup with a special header or modify createCustomerOnSignUp to
# attach the customer to the clock — see Stripe docs
stripe test_helpers test_clocks advance <clock_id> --frozen-time <future>
# Observe invoice.created, invoice.payment_failed, sub status changes
```

Expected outcomes to verify:
- usage ≤ $1, no card → $0 invoice, sub stays `active`
- usage > $1, no card → invoice fails → sub goes `past_due` → gate blocks
- usage > $1, valid card → invoice paid → sub stays `active`
- usage > $1, declining test card (`4000000000000341`) → dunning → eventually `unpaid` → gate blocks

### 2. Realtime client wiring in `apps/rishi-electron` (and `apps/mobile`)

Why: voice chat is the most expensive feature. In production today,
real users using voice cost us money but pay nothing because the
client never calls `POST /api/billing/realtime-usage`. This is a
real revenue leak that goes live the moment we go live.

Touch points (need investigation):
- `packages/shared/src/voice-chat/` — find where realtime sessions
  end and add a POST to `/api/billing/realtime-usage` with token
  counts from `response.done` events
- Mobile equivalent in `apps/mobile/`

### 3. Existing-user backfill

Why: production users without `stripe_customer_id` keep using AI
free forever — silently failing the gate as `null` after deploy.
We block them, OR we backfill, OR we exempt them. Need a decision.

If backfilling: write a one-off script that iterates `user` rows
where `stripe_customer_id IS NULL`, calls `stripe.customers.create
+ applyWelcomeCreditAndSubscription`, persists the customer id.
Test in test mode against test users first.

### 4. `onCustomerCreate` idempotency

Why: if signup races (double-click, retry, webhook replay), user
might get $2 credit or two subscriptions. Test by hitting `/test/sign-in`
with the same email twice in quick succession and verifying only
one customer + one credit + one sub exist.

### 5. Card-on-file flow end-to-end

Why: we mint Customer Portal URLs but haven't verified that a user
can actually go to the URL, add a card, and have the next invoice
charge it correctly. Probably works (it's stock Stripe) but verify
once.

### 6. `invoice.payment_failed` → user notification

Why: when dunning starts in live mode, the user should know.
Currently they hit the gate silently. Add a webhook side effect
that sends an email (Resend is already wired) or surfaces an
in-app banner.

### 7. In-app "Manage billing" button

Why: users need a way to reach the portal. Add a button in
`apps/rishi-electron` settings that calls `POST /api/billing/portal`
and opens the returned URL.

## Local dev setup notes

`.dev.vars` was extended for testing (gitignored). To run E2E
again locally:

```bash
# .dev.vars must contain:
STRIPE_SECRET_KEY=sk_test_...                          # the test-mode key
STRIPE_WEBHOOK_SECRET=whsec_...                        # whatever stripe listen prints
ENABLE_TEST_AUTH=true
TEST_AUTH_SECRET=local-billing-test-2026-06-03

# Two terminals:
stripe listen --forward-to http://localhost:8787/api/auth/stripe/webhook
cd workers/worker && pnpm run dev

# Drive a test signup:
curl -X POST http://localhost:8787/test/sign-in \
  -H "Content-Type: application/json" \
  -H "X-Test-Auth-Secret: local-billing-test-2026-06-03" \
  -d '{"email":"e2e-$(date +%s)@test.fidexa.org","password":"hunter22"}'
```

## Known gotchas

- **drizzle-kit drift.** `drizzle-kit generate` emits any unmigrated
  schema changes, not just yours. If a generated migration includes
  surprise CREATE TABLE / ALTER TABLE statements for tables you
  didn't touch, **stop and investigate** — that's exactly how we
  found commit `9c17bd50`. Use the `gsd-debugger` skill or just
  query `wrangler d1 execute rishi-sync --remote --command "..."`
  to compare schema vs. D1 reality before applying.

- **pnpm + file: deps don't auto-refresh.** After editing
  `packages/shared/package.json` (e.g., adding an export), you need
  to re-run `pnpm install` in any package that depends on
  `@rishi/shared`, otherwise the symlinked copy is stale.

- **`stripe listen` whsec is ephemeral.** Each `stripe listen`
  session prints a new `whsec_...` valid only for that session.
  When the session ends the secret is gone. `.dev.vars` should be
  updated each time you start a new listen session.

- **Test customers accumulate in Stripe test mode.** Each E2E run
  creates a `cus_...` + `sub_...`. Harmless, but `stripe customers
  list` will get noisy. Periodic cleanup: `stripe customers list
  --limit 100 | jq -r '.data[].id' | xargs -n1 stripe customers
  delete -c`.

- **Workers + Stripe SDK.** Worker uses `nodejs_compat`. The Stripe
  client is constructed with `Stripe.createFetchHttpClient()` —
  don't switch to the default Node HTTP client, it doesn't work on
  Workers.

- **Subscription rows can have multiple per user over time.** The
  gate queries the most recent by `periodStart desc`. If we ever
  let users resubscribe after cancellation, double-check this query
  still returns the right row.

## Resume commands

```bash
# Pick up exactly where this handoff left off:
cd /Users/faridmatovu/projects/rishi-monorepo
git log --oneline ac7d0783..HEAD     # see the 8 commits
cat workers/worker/BILLING.md         # the runbook
cat workers/worker/BILLING-HANDOFF.md # this file

# Run all worker billing tests:
cd workers/worker && pnpm test --run src/billing/

# Run all shared billing tests:
cd packages/shared && pnpm test --run src/billing/
```

## Recommended next step

**Stripe test clock for invoice simulation (item 1 above).** It
covers the single biggest unknown (what happens at month-end) and
indirectly validates items 5 and 6 of the gap list. Estimate: one
session of focused work.

If you want a faster win first: **item 2 (realtime client wiring)**
is mechanically simpler and closes the largest revenue leak. But
without item 1 you still don't know what happens at month-end.

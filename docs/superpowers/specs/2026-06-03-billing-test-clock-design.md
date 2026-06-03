# Billing Test Clock Script — Design Spec

Phase 1 of the post-`65090285` billing roadmap. Produces a single
reproducible CLI script that exercises the four end-of-period billing
scenarios listed in `workers/worker/BILLING-HANDOFF.md` and prints
pass/fail. Run before each promotion from Stripe test mode to live
mode.

> **Re-creation note (2026-06-03).** This spec was originally approved
> earlier in the same session, deleted during a brief Polar.sh
> exploration, and re-created verbatim after the user pivoted back to
> Stripe. The only substantive update versus the original is the
> `applyWelcomeCreditAndSubscription` signature — it now takes
> `customerIpAddress` as a third argument (added by commit `f9936fd6`
> for Stripe Tax). The script passes `null` because it bypasses the
> auth path that normally extracts the IP.

## Goal

A developer can run one command — against the local worker, with
`stripe listen` forwarding webhooks — and learn within a few minutes
whether month-end billing behaves correctly across four scenarios:

| Scenario | Usage | Card | Expected D1 status | Expected `/api/embed` |
|---|---|---|---|---|
| A | ~10M embed tokens (~$0.24 customer cost) | none | `active` | 200 |
| B | ~100M embed tokens (~$2.40 customer cost) | none | `past_due` | 402 `BILLING_INACTIVE` |
| C | ~100M embed tokens (~$2.40 customer cost) | `pm_card_visa` attached + default | `active` | 200 |
| D | ~100M embed tokens (~$2.40 customer cost) | `pm_card_chargeCustomerFail` attached + default, advance through full dunning window | `unpaid` | 402 `BILLING_INACTIVE` |

Customer cost = OpenAI cost × `MARKUP_MULTIPLIER` (1.2), enforced by
the Stripe Price's `unit_amount_decimal`. The $1.00 welcome credit is
applied in customer dollars, so scenario A's $0.24 is fully absorbed
and scenario B–D's $2.40 leaves a $1.40 balance that must be charged.

Exit `0` if every scenario passes; `1` otherwise.

## Shape

A one-shot Node CLI script:

- Path: `workers/worker/scripts/billing-e2e-clock.ts`
- Invocation: `pnpm tsx scripts/billing-e2e-clock.ts [--keep]`
- Environment: against the **local** worker (`pnpm run dev` on
  `:8787`), with `stripe listen --forward-to
  localhost:8787/api/auth/stripe/webhook` running in a second
  terminal.
- Not part of the regular test suite. No CI gate. Run manually before
  each live-mode promotion.

Rationale for script-not-vitest: each scenario takes 30+ seconds of
real wall-clock time (Stripe needs time to invoice after a clock
advance); the script generates real Stripe test-mode customers and
subscriptions that would pollute shared CI; this verification runs
roughly once per release cycle, not per commit.

## Lifecycle

```
preflight
  └─ assert env vars, worker reachable, stripe listen forwarding
setup
  └─ create one test clock (reused across all four scenarios)
for each scenario A..D:
  ├─ create clock-attached customer via stripe.customers.create({ test_clock })
  ├─ call applyWelcomeCreditAndSubscription(stripe, customer.id, null) directly
  ├─ persist user + subscription rows into local D1
  ├─ (C, D only) attach payment method + set as default
  ├─ call reportMeterEvent with deterministic embed-token-equivalent micro-dollars
  ├─ advance clock past current_period_end (multi-step for D)
  ├─ poll D1 for expected subscription.status (≤30s per advance)
  ├─ mint session for test user, probe POST /api/embed
  └─ record pass/fail
teardown (unless --keep)
  ├─ delete the test clock (cascades customers + subs)
  ├─ delete D1 user, subscription, session rows
report
  └─ print ASCII table, exit 0 or 1
```

## Mechanism

### Customer attachment

Script imports `applyWelcomeCreditAndSubscription(stripe,
stripeCustomerId, customerIpAddress)` from
`workers/worker/src/billing/stripe.ts` and calls it directly with
`customerIpAddress = null`, after creating the customer with
`stripe.customers.create({ test_clock, metadata: { userId } })`. This
honestly exercises the subscription/credit logic but skips the Better
Auth signup wrapper. Zero production-code changes are required for
customer creation.

Passing `null` for the IP means the in-function `if (customerIpAddress)`
branch is skipped — no `stripe.customers.update({ tax: { ip_address }})`
call is made. The test customers' tax behaviour falls back to Stripe's
defaults. This is acceptable because the test-clock script is verifying
billing flow / status transitions, not Stripe Tax behaviour. Tax
verification is its own follow-up if needed.

`applyWelcomeCreditAndSubscription` and `reportMeterEvent` both accept
the Stripe client as a parameter and have no dependency on
`CloudflareBindings`, so they import cleanly into a Node script. The
script constructs its own Stripe client — either by calling the same
`createStripeClient(secretKey)` (which uses
`Stripe.createFetchHttpClient()`; works in Node 18+ where `fetch` is
global) or by instantiating `new Stripe(secretKey)` directly with the
default Node HTTP client. Either works; the implementation plan picks
one. `meterFromContext` is **not** reusable from Node because it takes
`CloudflareBindings`; the script bypasses it and calls
`reportMeterEvent` directly.

### D1 access

The script runs in Node, not in the worker runtime, so it cannot use
the worker's `env.DB` binding directly. Two viable approaches:

1. Shell out to `wrangler d1 execute rishi-sync --local --command "..."`
   for inserts, polls, and deletes. Simple; no production-code blast
   radius.
2. Call a new test-only worker endpoint that performs the D1 operations.

The implementation plan picks one. The (1) `wrangler` path is the
current lean.

### Session minting for the gate probe

The HTTP gate probe needs a valid Better Auth session for the test
user. Two viable approaches:

1. A small `/test/mint-session` endpoint behind the existing
   `TEST_AUTH_SECRET` that takes a `userId` and returns a fresh
   session token. Adds a small piece of test-only worker code that's
   guarded the same way `/test/sign-in` is.
2. Insert a `session` row directly into local D1 via the same wrangler
   path used elsewhere.

The implementation plan picks one. Both are acceptable; (1) is closer
to the real auth path.

### Usage simulation

Script imports `reportMeterEvent` from
`workers/worker/src/billing/meter.ts` and calls it directly with
deterministic micro-dollar amounts. This exercises our exact metering
code without paying for real OpenAI calls and without the worker
serving any AI requests during the run.

Two amounts are needed: `LOW_USAGE_MICRODOLLARS` (well below $1
welcome credit when multiplied by the 1.2× markup at the price layer)
and `HIGH_USAGE_MICRODOLLARS` (well above so an invoice can fail).
The values are derived at script load time from `DEFAULT_RATES` and a
chosen embed-token count, so the math stays correct if the rate card
changes:

- LOW: tokens = 10_000_000; OpenAI cost = `tokens * 0.02 / 1_000_000`
  = $0.20; micro-dollars = 200_000. Stripe Price marks up to $0.24
  customer cost, fully absorbed by $1.00 welcome credit.
- HIGH: tokens = 100_000_000; OpenAI cost = $2.00; micro-dollars =
  2_000_000. Stripe Price marks up to $2.40 customer cost; leaves
  $1.40 to invoice after the welcome credit.

### Clock advancement

For scenarios A, B, C: a single `advance` past `current_period_end` is
enough to trigger invoicing.

For scenario D (declining card → dunning): Stripe's default smart-retry
schedule plays out over ~3 weeks of subscription time. The script
advances in steps (e.g. `+1d`, `+3d`, `+7d`, `+14d`, `+21d`), polling
D1 between each step, and only asserts `unpaid` after the final
advance. If `unpaid` is reached earlier, the script accepts the
earlier success.

### Webhook delivery

`stripe listen` forwards with sub-second latency in practice. The
delay between `advance` and the relevant webhook firing is dominated
by Stripe's invoice generation, typically 10–30 seconds. The script's
30-second D1 poll per advance covers this range. If the poll times
out, the failure message includes both the most recent observed D1
status and Stripe's current subscription status, so the operator can
distinguish webhook-delivery problems from genuine logic failures.

### Preflight checks

Script aborts with a clear message if any of these fail:

- `STRIPE_SECRET_KEY` is unset or doesn't start with `sk_test_` (live
  keys are a hard error).
- `TEST_AUTH_SECRET` is unset.
- Worker not reachable at `http://localhost:8787`.
- `stripe listen` not forwarding to the worker (probe by triggering
  `stripe trigger ping` and watching the worker log for a 200 within
  3 seconds — or by checking `stripe events list` for a recent ping).

## Output

After every run:

```
Scenario                    Expected           Got                Result
A: low usage, no card       active/200         active/200         PASS
B: high usage, no card      past_due/402       past_due/402       PASS
C: high usage, valid card   active/200         active/200         PASS
D: high usage, decline      unpaid/402         past_due/402       FAIL (after 30s on final advance)
                                                                  ───────
                                                                  3/4 PASS
```

`--keep` preserves the clock, customers, and D1 rows, and prints their
ids so the operator can inspect Stripe Dashboard and run `wrangler d1
execute` queries against the lingering state.

## Testing the script itself

The script does not have unit tests. Its correctness is verified by:

1. The four scenarios it runs (each is its own assertion).
2. A dry-run option (`--dry-run`) that walks the lifecycle without
   touching Stripe or D1, used to catch import / type / argument-shape
   regressions in CI alongside the rest of the worker test suite.

## Out of scope

This phase covers only the test clock script and any minimal
test-only worker endpoint needed for session minting. It does **not**
cover:

- Webhook handlers for `invoice.payment_failed` notifications (Phase 6
  of `BILLING-HANDOFF.md`).
- Realtime usage client wiring in apps (Phase 2).
- Existing-user backfill (Phase 3).
- `onCustomerCreate` idempotency hardening (Phase 4); the script will
  surface duplication if it occurs but won't fix it.
- Stripe Tax line-item verification on the resulting invoices.

## Acceptance criteria

1. `pnpm tsx workers/worker/scripts/billing-e2e-clock.ts` runs
   end-to-end against a local worker + `stripe listen` and exits `0`
   with all four scenarios `PASS` on a green build of `main`.
2. Re-running the script back-to-back produces the same result and
   leaves no Stripe or D1 state behind (verified by `stripe customers
   list` and a D1 row count before/after).
3. `--keep` preserves all artifacts with their ids printed.
4. `--dry-run` exits `0` without touching Stripe or D1.
5. Preflight failures (missing env var, no `stripe listen`, live key)
   produce clear messages and exit `1` before any Stripe call.
6. Failure modes (D1 status mismatch, gate HTTP mismatch, webhook
   timeout) produce diagnostic output including both observed and
   expected state.

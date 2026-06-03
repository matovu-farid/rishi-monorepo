#!/usr/bin/env tsx
/**
 * billing-e2e-clock.ts — Phase 1 of workers/worker/BILLING-HANDOFF.md.
 *
 * Drives four end-of-period Stripe billing scenarios against the local
 * worker (must be running on :8787 with `stripe listen` forwarding
 * webhooks to /api/auth/stripe/webhook). Prints pass/fail and exits
 * 0/1. See docs/superpowers/specs/2026-06-03-billing-test-clock-design.md
 * for design rationale.
 */

import { spawnSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

interface Flags {
  keep: boolean;
  dryRun: boolean;
  help: boolean;
}

function parseFlags(argv: string[]): Flags {
  const flags: Flags = { keep: false, dryRun: false, help: false };
  for (const a of argv) {
    if (a === "--keep") flags.keep = true;
    else if (a === "--dry-run") flags.dryRun = true;
    else if (a === "--help" || a === "-h") flags.help = true;
    else {
      console.error(`Unknown flag: ${a}`);
      console.error("Run with --help for usage.");
      process.exit(1);
    }
  }
  return flags;
}

function printHelp(): void {
  console.log(`
Usage: pnpm tsx scripts/billing-e2e-clock.ts [--keep] [--dry-run]

Runs four end-of-period Stripe billing scenarios against the local
worker. Requires:
  - workers/worker running on :8787 (pnpm run dev)
  - stripe listen --forward-to localhost:8787/api/auth/stripe/webhook
  - .dev.vars: STRIPE_SECRET_KEY (sk_test_...), TEST_AUTH_SECRET

Flags:
  --keep      Preserve test clock, customers, D1 rows after run
              (default: delete everything on exit)
  --dry-run   Walk the lifecycle without touching Stripe or D1
              (for catching regressions in CI)
  --help      Show this message

Exit codes:
  0  All scenarios passed
  1  At least one scenario failed (or preflight aborted)
`);
}

const __dirname = dirname(fileURLToPath(import.meta.url));
const WORKER_DIR = resolve(__dirname, "..");
const DEV_VARS = resolve(WORKER_DIR, ".dev.vars");
const WORKER_URL = "http://localhost:8787";

interface Env {
  STRIPE_SECRET_KEY: string;
  TEST_AUTH_SECRET: string;
}

/**
 * Read .dev.vars (or process.env as fallback) and return the secrets
 * the script needs. Throws if anything required is missing or
 * STRIPE_SECRET_KEY is a live key (sk_live_...).
 */
function loadEnv(): Env {
  const env: Record<string, string> = {};
  if (existsSync(DEV_VARS)) {
    for (const line of readFileSync(DEV_VARS, "utf8").split("\n")) {
      const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
      if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
    }
  }
  // process.env overrides .dev.vars so CI / one-off shells can swap values.
  for (const k of ["STRIPE_SECRET_KEY", "TEST_AUTH_SECRET"]) {
    if (process.env[k]) env[k] = process.env[k]!;
  }
  const STRIPE_SECRET_KEY = env.STRIPE_SECRET_KEY;
  const TEST_AUTH_SECRET = env.TEST_AUTH_SECRET;
  if (!STRIPE_SECRET_KEY) throw new Error("STRIPE_SECRET_KEY is not set (check .dev.vars).");
  if (STRIPE_SECRET_KEY.startsWith("sk_live_")) {
    throw new Error("Refusing to run against a live Stripe key. Use sk_test_... only.");
  }
  if (!STRIPE_SECRET_KEY.startsWith("sk_test_")) {
    throw new Error(`STRIPE_SECRET_KEY does not look like a test key: ${STRIPE_SECRET_KEY.slice(0, 8)}...`);
  }
  if (!TEST_AUTH_SECRET) throw new Error("TEST_AUTH_SECRET is not set (check .dev.vars).");
  return { STRIPE_SECRET_KEY, TEST_AUTH_SECRET };
}

/**
 * Confirms the worker is reachable. Hits /health which always exists.
 */
async function probeWorker(): Promise<void> {
  let res: Response;
  try {
    res = await fetch(`${WORKER_URL}/health`);
  } catch (err) {
    throw new Error(`Worker not reachable at ${WORKER_URL}. Is \`pnpm run dev\` running?`);
  }
  if (!res.ok) {
    throw new Error(`Worker /health returned ${res.status}; expected 200.`);
  }
}

async function preflight(_env: Env): Promise<void> {
  console.log("→ Preflight…");
  console.log(`  ✓ STRIPE_SECRET_KEY is a test key`);
  console.log(`  ✓ TEST_AUTH_SECRET present`);
  await probeWorker();
  console.log(`  ✓ Worker reachable at ${WORKER_URL}`);
  // We deliberately do NOT probe `stripe listen` here: the CLI has no
  // cheap no-op event to trigger (every `stripe trigger <event>`
  // creates real Stripe objects). If the operator forgot to start
  // `stripe listen`, scenarios B/C/D will surface it within 30s as
  // `waitForSubStatus` returns the seeded "active" instead of the
  // expected post-invoice status.
}

import Stripe from "stripe";
import { MICRO_DOLLARS_PER_USD } from "@rishi/shared/billing/stripe-config";
import { DEFAULT_RATES } from "@rishi/shared/billing/default-rates";
import { applyWelcomeCreditAndSubscription } from "../src/billing/stripe";
import { reportMeterEvent } from "../src/billing/meter";

/**
 * Construct a Stripe client suitable for Node. The worker's own
 * createStripeClient uses Stripe.createFetchHttpClient() which works
 * on Node 18+ because fetch is global there. We pass the test-mode
 * secret key.
 */
function makeStripe(env: Env): Stripe {
  return new Stripe(env.STRIPE_SECRET_KEY, {
    httpClient: Stripe.createFetchHttpClient(),
  });
}

/**
 * Create a test clock frozen at "now". Reused across all four
 * scenarios.
 */
async function createTestClock(stripe: Stripe): Promise<string> {
  const clock = await stripe.testHelpers.testClocks.create({
    frozen_time: Math.floor(Date.now() / 1000),
    name: `billing-e2e-clock-${Date.now()}`,
  });
  return clock.id;
}

/**
 * Create a Stripe customer attached to a test clock, with userId
 * stored in metadata. The customer is "the" user from the script's
 * point of view.
 */
async function createClockedCustomer(
  stripe: Stripe,
  clockId: string,
  userId: string,
  email: string,
): Promise<string> {
  const cust = await stripe.customers.create({
    email,
    test_clock: clockId,
    metadata: { userId },
  });
  return cust.id;
}

/**
 * Attach a payment method (a Stripe test card) to a customer and set
 * as the invoice default. Used for scenarios C (valid card) and D
 * (declining card).
 *
 * Stripe test payment-method tokens:
 *   pm_card_visa                — always succeeds
 *   pm_card_chargeCustomerFail  — declines on charge
 */
async function attachCardAndSetDefault(
  stripe: Stripe,
  customerId: string,
  pmId: string,
): Promise<void> {
  await stripe.paymentMethods.attach(pmId, { customer: customerId });
  await stripe.customers.update(customerId, {
    invoice_settings: { default_payment_method: pmId },
  });
}

/**
 * Advance the clock to a future timestamp. Stripe processes the
 * advance synchronously but invoice generation + webhook delivery
 * happen async. The advance call returns when Stripe has accepted the
 * jump; the downstream effects manifest within ~10–30s.
 */
async function advanceClockTo(
  stripe: Stripe,
  clockId: string,
  unixSeconds: number,
): Promise<void> {
  await stripe.testHelpers.testClocks.advance(clockId, { frozen_time: unixSeconds });
}

/**
 * Convert a USD amount to micro-dollars (the units Stripe meter
 * events expect, per stripe-config.ts).
 */
function usdToMicros(usd: number): number {
  return Math.round(usd * MICRO_DOLLARS_PER_USD);
}

/**
 * Embed-token cost in USD, using the rate card. Decoupled from the
 * markup (which is applied in Stripe's Price unit_amount_decimal, not
 * here).
 */
function embedTokensToUsd(tokens: number): number {
  return (tokens * DEFAULT_RATES.embedding["text-embedding-3-small"].per1MTokens) / 1_000_000;
}

// Deterministic test amounts derived from the rate card at load time.
// Low: $0.20 OpenAI cost = $0.24 customer cost (under $1 welcome credit).
// High: $2.00 OpenAI cost = $2.40 customer cost (over the credit).
const LOW_USAGE_TOKENS = 10_000_000;
const HIGH_USAGE_TOKENS = 100_000_000;
const LOW_USAGE_MICROS = usdToMicros(embedTokensToUsd(LOW_USAGE_TOKENS));
const HIGH_USAGE_MICROS = usdToMicros(embedTokensToUsd(HIGH_USAGE_TOKENS));

/**
 * Run a SQL command against local D1 via wrangler. Returns stdout as
 * a string. Throws on non-zero exit.
 *
 * We shell out (not import Drizzle) because the script runs in Node
 * and doesn't have the Workers DB binding. wrangler's --local mode
 * uses the same SQLite file the dev server uses, so changes are
 * immediately visible to the worker.
 */
function d1Exec(sqlCmd: string): string {
  const res = spawnSync(
    "pnpm",
    ["wrangler", "d1", "execute", "rishi-sync", "--local", "--command", sqlCmd, "--json"],
    { cwd: WORKER_DIR, encoding: "utf8" },
  );
  if (res.status !== 0) {
    throw new Error(`wrangler d1 execute failed:\n${res.stderr}\n${res.stdout}`);
  }
  return res.stdout;
}

/**
 * SELECT one row's first column, or null if no rows. wrangler --json
 * output is a JSON array of { results: [...] } per command run.
 */
function d1Scalar(sqlCmd: string): string | number | null {
  const out = d1Exec(sqlCmd);
  const parsed = JSON.parse(out);
  const results = Array.isArray(parsed) ? parsed[0]?.results : parsed.results;
  const row = results?.[0];
  if (!row) return null;
  const firstCol = Object.values(row)[0];
  return (firstCol as string | number | null) ?? null;
}

/**
 * Escape a single value for inline SQL. We only handle strings,
 * numbers, and null — that's all the script uses. NEVER pass
 * untrusted input here; this is fine for the test script's controlled
 * values but not for general use.
 */
function sql(value: string | number | null): string {
  if (value === null) return "NULL";
  if (typeof value === "number") return String(value);
  return `'${value.replace(/'/g, "''")}'`;
}

/**
 * Insert a Better Auth user row with a known userId. The script
 * controls every field; no signup flow is exercised.
 */
function insertUser(userId: string, email: string, stripeCustomerId: string): void {
  const now = Math.floor(Date.now() / 1000);
  d1Exec(
    `INSERT INTO user (id, name, email, email_verified, image, created_at, updated_at, stripe_customer_id) VALUES (${sql(userId)}, ${sql("test-" + userId)}, ${sql(email)}, 1, NULL, ${now}, ${now}, ${sql(stripeCustomerId)});`,
  );
}

/**
 * Mint a Better Auth session by inserting a row with a random token.
 * The bearer() plugin (auth.ts:50) authenticates `Authorization: Bearer ${token}`
 * by looking up the token in this table — no further mechanism
 * needed.
 */
function insertSession(userId: string): { sessionId: string; token: string } {
  const sessionId = `sess_e2e_${cryptoRandomHex(12)}`;
  const token = `tok_e2e_${cryptoRandomHex(32)}`;
  const now = Math.floor(Date.now() / 1000);
  const expires = now + 3600;
  d1Exec(
    `INSERT INTO session (id, expires_at, token, created_at, updated_at, ip_address, user_agent, user_id) VALUES (${sql(sessionId)}, ${expires}, ${sql(token)}, ${now}, ${now}, NULL, ${sql("billing-e2e-clock")}, ${sql(userId)});`,
  );
  return { sessionId, token };
}

function cryptoRandomHex(bytes: number): string {
  const buf = new Uint8Array(bytes);
  crypto.getRandomValues(buf);
  return Array.from(buf, (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Insert a subscription row (cache layer — webhooks normally
 * populate this, but for scenarios where we're driving Stripe
 * directly we seed the row at "active" and let webhook updates flip
 * the status as the clock advances).
 */
function insertSubscription(
  subscriptionId: string,
  userId: string,
  stripeCustomerId: string,
): void {
  const now = Math.floor(Date.now() / 1000);
  d1Exec(
    `INSERT INTO subscription (id, plan, reference_id, stripe_customer_id, stripe_subscription_id, status, period_start, period_end) VALUES (${sql(subscriptionId)}, 'usage', ${sql(userId)}, ${sql(stripeCustomerId)}, ${sql(subscriptionId)}, 'active', ${now}, ${now + 30 * 24 * 3600});`,
  );
}

/**
 * Poll the subscription row's status until it matches `expected`, or
 * until `timeoutMs` elapses. Returns the final observed status.
 */
async function waitForSubStatus(
  subscriptionId: string,
  expected: string,
  timeoutMs: number,
): Promise<string | null> {
  const start = Date.now();
  let last: string | null = null;
  while (Date.now() - start < timeoutMs) {
    const v = d1Scalar(
      `SELECT status FROM subscription WHERE stripe_subscription_id = ${sql(subscriptionId)};`,
    );
    last = typeof v === "string" ? v : null;
    if (last === expected) return last;
    await new Promise((r) => setTimeout(r, 1500));
  }
  return last;
}

/**
 * Delete D1 rows for a single test user/customer/subscription. Idempotent.
 */
function deleteUserCascade(userId: string, subscriptionId: string): void {
  d1Exec(`DELETE FROM subscription WHERE stripe_subscription_id = ${sql(subscriptionId)};`);
  d1Exec(`DELETE FROM session WHERE user_id = ${sql(userId)};`);
  d1Exec(`DELETE FROM user WHERE id = ${sql(userId)};`);
}

interface ScenarioInput {
  label: string;                            // e.g. "A: low usage, no card"
  stripe: Stripe;
  env: Env;
  clockId: string;
  usageMicros: number;                      // LOW_USAGE_MICROS or HIGH_USAGE_MICROS
  attachCardKind?: "valid" | "decline";     // C: valid; D: decline; undefined: A/B
  advanceSchedule: number[];                // seconds to add per step (e.g. [31*24*3600] for one period; [1d, 3d, ...] for dunning)
  expectedStatus: string;                   // "active" | "past_due" | "unpaid" | ...
  expectedHttp: 200 | 402;
}

interface ScenarioResult {
  label: string;
  expected: string;                         // "active/200"
  got: string;                              // "active/200"
  pass: boolean;
  diagnostic?: string;                      // failure detail
  // Created artifacts for cleanup:
  userId: string;
  customerId: string;
  subscriptionId: string;
}

async function runScenario(input: ScenarioInput): Promise<ScenarioResult> {
  console.log(`\n→ ${input.label}`);
  const userId = `user_e2e_${cryptoRandomHex(8)}`;
  const email = `${userId}@e2e.fidexa.org`;

  // 1. Create Stripe customer attached to the clock.
  const customerId = await createClockedCustomer(input.stripe, input.clockId, userId, email);
  console.log(`  • customer ${customerId}`);

  // 2. Apply welcome credit + start subscription via worker's own helper.
  //    Pass null for IP — script bypasses the signup path where IP is captured.
  const { subscriptionId } = await applyWelcomeCreditAndSubscription(
    input.stripe,
    customerId,
    null,
  );
  console.log(`  • subscription ${subscriptionId}`);

  // 3. Seed D1 (user, session, subscription).
  insertUser(userId, email, customerId);
  const { token } = insertSession(userId);
  insertSubscription(subscriptionId, userId, customerId);

  // 4. Card attach (scenarios C, D).
  if (input.attachCardKind === "valid") {
    await attachCardAndSetDefault(input.stripe, customerId, "pm_card_visa");
    console.log(`  • attached pm_card_visa`);
  } else if (input.attachCardKind === "decline") {
    await attachCardAndSetDefault(input.stripe, customerId, "pm_card_chargeCustomerFail");
    console.log(`  • attached pm_card_chargeCustomerFail`);
  }

  // 5. Ingest meter usage via the worker's own reportMeterEvent.
  await reportMeterEvent(input.stripe, customerId, input.usageMicros);
  console.log(`  • metered ${input.usageMicros} micro-dollars`);

  // 6. Advance the clock in steps. Poll D1 between each step. The
  //    final observed status is what we assert.
  const baseTime = Math.floor(Date.now() / 1000);
  let accumulated = 0;
  let observedStatus: string | null = "active";
  for (const stepSeconds of input.advanceSchedule) {
    accumulated += stepSeconds;
    const target = baseTime + accumulated;
    console.log(`  • advancing clock +${stepSeconds}s`);
    await advanceClockTo(input.stripe, input.clockId, target);
    observedStatus = await waitForSubStatus(subscriptionId, input.expectedStatus, 30_000);
    if (observedStatus === input.expectedStatus) break;
  }

  // 7. Probe the gate.
  const httpRes = await fetch(`${WORKER_URL}/api/embed`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({ input: "test clock probe" }),
  });
  const observedHttp = httpRes.status;
  console.log(`  • /api/embed → ${observedHttp}`);

  const expected = `${input.expectedStatus}/${input.expectedHttp}`;
  const got = `${observedStatus ?? "null"}/${observedHttp}`;
  const pass = observedStatus === input.expectedStatus && observedHttp === input.expectedHttp;
  const diagnostic = pass
    ? undefined
    : `expected ${expected}, got ${got}` +
      (observedHttp !== input.expectedHttp
        ? ` (response body: ${(await httpRes.text()).slice(0, 200)})`
        : "");

  return {
    label: input.label,
    expected,
    got,
    pass,
    diagnostic,
    userId,
    customerId,
    subscriptionId,
  };
}

const ONE_DAY = 24 * 3600;
const ONE_MONTH = 31 * ONE_DAY;

function scenarioInputs(stripe: Stripe, env: Env, clockId: string): ScenarioInput[] {
  return [
    {
      label: "A: low usage, no card",
      stripe,
      env,
      clockId,
      usageMicros: LOW_USAGE_MICROS,
      advanceSchedule: [ONE_MONTH + ONE_DAY],
      expectedStatus: "active",
      expectedHttp: 200,
    },
    {
      label: "B: high usage, no card",
      stripe,
      env,
      clockId,
      usageMicros: HIGH_USAGE_MICROS,
      advanceSchedule: [ONE_MONTH + ONE_DAY],
      expectedStatus: "past_due",
      expectedHttp: 402,
    },
    {
      label: "C: high usage, valid card",
      stripe,
      env,
      clockId,
      usageMicros: HIGH_USAGE_MICROS,
      attachCardKind: "valid",
      advanceSchedule: [ONE_MONTH + ONE_DAY],
      expectedStatus: "active",
      expectedHttp: 200,
    },
    {
      label: "D: high usage, declining card (dunning)",
      stripe,
      env,
      clockId,
      usageMicros: HIGH_USAGE_MICROS,
      attachCardKind: "decline",
      // Stripe smart-retry schedule plays out over ~3 weeks.
      // After invoice generation + first failed charge, retries at
      // ~1d, ~3d, ~7d, ~14d. We advance past each.
      advanceSchedule: [
        ONE_MONTH + ONE_DAY,
        ONE_DAY,
        3 * ONE_DAY,
        7 * ONE_DAY,
        14 * ONE_DAY,
      ],
      expectedStatus: "unpaid",
      expectedHttp: 402,
    },
  ];
}

async function realRun(flags: Flags): Promise<void> {
  const env = loadEnv();
  await preflight(env);

  const stripe = makeStripe(env);
  const clockId = await createTestClock(stripe);
  console.log(`✓ Created test clock ${clockId}`);

  const results: ScenarioResult[] = [];
  try {
    for (const input of scenarioInputs(stripe, env, clockId)) {
      results.push(await runScenario(input));
    }
  } catch (err) {
    console.error("FATAL during scenario run:", err);
    // Still attempt cleanup unless --keep.
  }

  // Output table.
  console.log("\n" + "─".repeat(72));
  const headerLabel = "Scenario".padEnd(40);
  const headerExpected = "Expected".padEnd(15);
  const headerGot = "Got".padEnd(15);
  console.log(`${headerLabel}${headerExpected}${headerGot}Result`);
  console.log("─".repeat(72));
  for (const r of results) {
    const label = r.label.padEnd(40).slice(0, 40);
    const exp = r.expected.padEnd(15);
    const got = r.got.padEnd(15);
    const result = r.pass ? "PASS" : "FAIL";
    console.log(`${label}${exp}${got}${result}`);
    if (r.diagnostic) console.log(`  ↳ ${r.diagnostic}`);
  }
  const passed = results.filter((r) => r.pass).length;
  console.log("─".repeat(72));
  console.log(`${passed}/${results.length} PASS`);

  // Cleanup.
  if (flags.keep) {
    console.log("\n--keep: artifacts preserved");
    console.log(`  Test clock:    ${clockId}`);
    for (const r of results) {
      console.log(`  ${r.label}`);
      console.log(`    user:         ${r.userId}`);
      console.log(`    customer:     ${r.customerId}`);
      console.log(`    subscription: ${r.subscriptionId}`);
    }
  } else {
    console.log("\nCleanup…");
    try {
      // Deleting the test clock cascades all attached customers + subs.
      await stripe.testHelpers.testClocks.del(clockId);
      console.log(`  ✓ deleted clock ${clockId} (Stripe artifacts cascaded)`);
    } catch (err) {
      console.error(`  ✗ failed to delete clock ${clockId}:`, err);
    }
    for (const r of results) {
      try {
        deleteUserCascade(r.userId, r.subscriptionId);
      } catch (err) {
        console.error(`  ✗ D1 cleanup failed for ${r.userId}:`, err);
      }
    }
    console.log(`  ✓ D1 rows removed`);
  }

  process.exit(passed === results.length && results.length > 0 ? 0 : 1);
}

async function main(): Promise<void> {
  const flags = parseFlags(process.argv.slice(2));
  if (flags.help) {
    printHelp();
    process.exit(0);
  }
  if (flags.dryRun) {
    console.log("[dry-run] Would run scenarios A, B, C, D");
    console.log("[dry-run] Would preflight: STRIPE_SECRET_KEY, TEST_AUTH_SECRET, worker, stripe listen");
    console.log("[dry-run] No Stripe or D1 calls made.");
    process.exit(0);
  }
  await realRun(flags);
}

main().catch((err) => {
  console.error("FATAL:", err);
  process.exit(1);
});

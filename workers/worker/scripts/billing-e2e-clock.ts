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

/**
 * Confirms stripe listen is forwarding to the worker by triggering a
 * ping event. We don't actually verify the worker received it (would
 * require scraping wrangler stdout); the trigger succeeding plus the
 * stripe CLI being authed is a strong-enough signal. Downstream
 * webhook polling failures will surface a true forwarding gap within
 * 30s if stripe listen is not running.
 */
function probeStripeListen(env: Env): void {
  const trig = spawnSync("stripe", ["trigger", "ping"], {
    encoding: "utf8",
    env: { ...process.env, STRIPE_API_KEY: env.STRIPE_SECRET_KEY },
  });
  if (trig.status !== 0) {
    throw new Error(
      `\`stripe trigger ping\` failed (exit ${trig.status}). Is the stripe CLI installed and authed?\n${trig.stderr}`,
    );
  }
  // Give the webhook ~3 seconds to land.
  const start = Date.now();
  while (Date.now() - start < 3000) {
    // no-op
  }
  console.log("✓ stripe trigger ping accepted (stripe listen path assumed working)");
}

async function preflight(env: Env): Promise<void> {
  console.log("→ Preflight…");
  console.log(`  ✓ STRIPE_SECRET_KEY is a test key`);
  console.log(`  ✓ TEST_AUTH_SECRET present`);
  await probeWorker();
  console.log(`  ✓ Worker reachable at ${WORKER_URL}`);
  probeStripeListen(env);
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
  const env = loadEnv();
  await preflight(env);
  // Scenario runs wired in Task 6.
  console.error("Scenarios not yet implemented — preflight succeeded.");
  process.exit(1);
}

main().catch((err) => {
  console.error("FATAL:", err);
  process.exit(1);
});

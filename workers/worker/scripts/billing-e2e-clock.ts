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

async function main(): Promise<void> {
  const flags = parseFlags(process.argv.slice(2));
  if (flags.help) {
    printHelp();
    process.exit(0);
  }
  if (flags.dryRun) {
    console.log("[dry-run] Would run scenarios A, B, C, D");
    console.log("[dry-run] No Stripe or D1 calls made.");
    process.exit(0);
  }
  // Real run wired in Task 4.
  console.error("Real run not yet implemented — use --dry-run for now.");
  process.exit(1);
}

main().catch((err) => {
  console.error("FATAL:", err);
  process.exit(1);
});

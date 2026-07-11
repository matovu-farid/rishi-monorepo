#!/usr/bin/env tsx
/**
 * billing-backfill.ts — Closes BILLING-HANDOFF.md gap #3.
 *
 * Walks `user` rows in D1 where `stripe_customer_id IS NULL`, ensures
 * each has a Stripe customer + welcome credit + active subscription on
 * the configured price, and patches the D1 row so the Better-Auth
 * Stripe plugin's webhook can populate the `subscription` table on
 * `customer.subscription.created`. Idempotent: safe to re-run.
 */
import { spawnSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import Stripe from "stripe";
import { getStripeIdsForKey } from "@rishi/shared/billing/stripe-config";
import { backfillOneUser } from "../src/billing/backfill";
const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 10_000;
function parseFlags(argv) {
    const flags = {
        dryRun: false,
        limit: DEFAULT_LIMIT,
        filter: null,
        remote: false,
        help: false,
    };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === "--dry-run")
            flags.dryRun = true;
        else if (a === "--remote")
            flags.remote = true;
        else if (a === "--help" || a === "-h")
            flags.help = true;
        else if (a === "--limit") {
            const v = argv[++i];
            const n = Number(v);
            if (!Number.isFinite(n) || n <= 0) {
                console.error(`--limit requires a positive integer (got ${v}).`);
                process.exit(1);
            }
            flags.limit = Math.min(Math.floor(n), MAX_LIMIT);
        }
        else if (a.startsWith("--limit=")) {
            const n = Number(a.slice("--limit=".length));
            if (!Number.isFinite(n) || n <= 0) {
                console.error(`--limit requires a positive integer.`);
                process.exit(1);
            }
            flags.limit = Math.min(Math.floor(n), MAX_LIMIT);
        }
        else if (a === "--filter") {
            flags.filter = argv[++i] ?? null;
            if (!flags.filter) {
                console.error("--filter requires a SQL fragment.");
                process.exit(1);
            }
        }
        else if (a.startsWith("--filter=")) {
            flags.filter = a.slice("--filter=".length);
        }
        else {
            console.error(`Unknown flag: ${a}`);
            console.error("Run with --help for usage.");
            process.exit(1);
        }
    }
    return flags;
}
function printHelp() {
    console.log(`
Usage: pnpm tsx scripts/billing-backfill.ts [flags]

Backfills Stripe customer + welcome credit + metered subscription for
every D1 \`user\` row where \`stripe_customer_id IS NULL\`. Idempotent:
safe to re-run. The Better-Auth Stripe plugin's webhook is trusted to
populate the \`subscription\` table on customer.subscription.created.

Flags:
  --dry-run            Print intended actions, no Stripe or D1 writes.
  --limit N            Process at most N users (default ${DEFAULT_LIMIT}, cap ${MAX_LIMIT}).
  --filter "<sql>"     Extra WHERE clause AND'd onto the user query
                       (operator-only, NEVER pass untrusted input).
  --remote             Use \`wrangler d1 execute --remote\` instead of
                       --local. Required for production runs. Allows
                       STRIPE_SECRET_KEY=sk_live_… (with a warning).
  --help / -h          Show this message.

Exit codes:
  0  All users succeeded (or dry-run completed).
  1  One or more users failed, or preflight aborted.
`);
}
const __dirname = dirname(fileURLToPath(import.meta.url));
const WORKER_DIR = resolve(__dirname, "..");
const DEV_VARS = resolve(WORKER_DIR, ".dev.vars");
function loadEnv(remote) {
    const env = {};
    if (existsSync(DEV_VARS)) {
        for (const line of readFileSync(DEV_VARS, "utf8").split("\n")) {
            const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
            if (m)
                env[m[1]] = m[2].replace(/^["']|["']$/g, "");
        }
    }
    if (process.env.STRIPE_SECRET_KEY) {
        env.STRIPE_SECRET_KEY = process.env.STRIPE_SECRET_KEY;
    }
    const STRIPE_SECRET_KEY = env.STRIPE_SECRET_KEY;
    if (!STRIPE_SECRET_KEY) {
        throw new Error("STRIPE_SECRET_KEY is not set (check .dev.vars).");
    }
    if (STRIPE_SECRET_KEY.startsWith("sk_live_") && !remote) {
        throw new Error("Refusing to use a live Stripe key without --remote. Pass --remote to run against production.");
    }
    if (!STRIPE_SECRET_KEY.startsWith("sk_test_") &&
        !STRIPE_SECRET_KEY.startsWith("sk_live_")) {
        throw new Error(`STRIPE_SECRET_KEY does not look like a Stripe key: ${STRIPE_SECRET_KEY.slice(0, 8)}…`);
    }
    return { STRIPE_SECRET_KEY };
}
function d1Exec(sqlCmd, remote) {
    const args = [
        "wrangler",
        "d1",
        "execute",
        "rishi-sync",
        remote ? "--remote" : "--local",
        "--command",
        sqlCmd,
        "--json",
    ];
    const res = spawnSync("pnpm", args, {
        cwd: WORKER_DIR,
        encoding: "utf8",
    });
    if (res.status !== 0) {
        throw new Error(`wrangler d1 execute failed:\n${res.stderr}\n${res.stdout}`);
    }
    return res.stdout;
}
function d1Query(sqlCmd, remote) {
    const out = d1Exec(sqlCmd, remote);
    const parsed = JSON.parse(out);
    const results = Array.isArray(parsed) ? parsed[0]?.results : parsed.results;
    return results ?? [];
}
function sql(value) {
    if (value === null)
        return "NULL";
    if (typeof value === "number")
        return String(value);
    return `'${value.replace(/'/g, "''")}'`;
}
async function sleep(ms) {
    await new Promise((r) => setTimeout(r, ms));
}
function makeStripe(env) {
    return new Stripe(env.STRIPE_SECRET_KEY, {
        httpClient: Stripe.createFetchHttpClient(),
    });
}
async function realRun(flags) {
    const env = loadEnv(flags.remote);
    const isLive = env.STRIPE_SECRET_KEY.startsWith("sk_live_");
    if (flags.remote) {
        console.log("\n" + "!".repeat(72));
        console.log(`! REMOTE MODE: writing to production D1${isLive ? " + LIVE Stripe" : ""}.`);
        console.log("! Press Ctrl-C within 5 seconds to abort.");
        console.log("!".repeat(72) + "\n");
        await sleep(5000);
    }
    const whereParts = ["stripe_customer_id IS NULL"];
    if (flags.filter)
        whereParts.push(`(${flags.filter})`);
    const where = whereParts.join(" AND ");
    const query = `SELECT id, email FROM user WHERE ${where} LIMIT ${flags.limit};`;
    console.log(`→ ${query}`);
    const users = d1Query(query, flags.remote);
    console.log(`  found ${users.length} user(s) to backfill\n`);
    if (users.length === 0) {
        console.log("Nothing to do.");
        process.exit(0);
    }
    const stripe = makeStripe(env);
    const priceId = getStripeIdsForKey(env.STRIPE_SECRET_KEY).priceId;
    const outcomes = [];
    for (const u of users) {
        if (flags.dryRun) {
            console.log(`  [dry-run] would backfill ${u.id} <${u.email}>`);
            outcomes.push({
                userId: u.id,
                email: u.email,
                stripeCustomerId: "-",
                steps: "-",
                status: "dry-run",
            });
            continue;
        }
        try {
            const result = await backfillOneUser(stripe, u.id, u.email, priceId, {
                onCustomerEnsured: async (stripeCustomerId) => {
                    d1Exec(`UPDATE user SET stripe_customer_id = ${sql(stripeCustomerId)} WHERE id = ${sql(u.id)};`, flags.remote);
                },
            });
            console.log(`  ✓ ${u.id} → ${result.stripeCustomerId} [${result.steps.join(", ")}]`);
            outcomes.push({
                userId: u.id,
                email: u.email,
                stripeCustomerId: result.stripeCustomerId,
                steps: result.steps.join(","),
                status: "ok",
            });
        }
        catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            console.error(`  ✗ ${u.id}: ${msg}`);
            outcomes.push({
                userId: u.id,
                email: u.email,
                stripeCustomerId: "-",
                steps: "-",
                status: "fail",
                error: msg,
            });
        }
    }
    console.log("\n" + "─".repeat(110));
    const head = `${"userId".padEnd(28)}${"email".padEnd(32)}${"stripe_customer_id".padEnd(28)}${"steps".padEnd(14)}status`;
    console.log(head);
    console.log("─".repeat(110));
    for (const o of outcomes) {
        console.log(`${o.userId.padEnd(28).slice(0, 28)}${o.email.padEnd(32).slice(0, 32)}${o.stripeCustomerId.padEnd(28).slice(0, 28)}${o.steps.padEnd(14).slice(0, 14)}${o.status}`);
        if (o.error)
            console.log(`  ↳ ${o.error}`);
    }
    const failed = outcomes.filter((o) => o.status === "fail").length;
    const ok = outcomes.filter((o) => o.status === "ok").length;
    const dry = outcomes.filter((o) => o.status === "dry-run").length;
    console.log("─".repeat(110));
    console.log(`${ok} ok | ${dry} dry-run | ${failed} fail`);
    process.exit(failed === 0 ? 0 : 1);
}
async function main() {
    const flags = parseFlags(process.argv.slice(2));
    if (flags.help) {
        printHelp();
        process.exit(0);
    }
    await realRun(flags);
}
main().catch((err) => {
    console.error("FATAL:", err);
    process.exit(1);
});

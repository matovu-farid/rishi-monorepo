#!/usr/bin/env tsx
/**
 * billing-portal-check.ts — Closes BILLING-HANDOFF.md gap #5.
 *
 * Verifies that POST /api/billing/portal mints a real Stripe-hosted
 * Customer Portal URL for a freshly created test user. Scenario C of
 * billing-e2e-clock already proves the card-attach → invoice-paid
 * mechanism; this script proves the URL the worker mints actually
 * points at a live Stripe page tied to the right customer.
 *
 * Requires:
 *   - workers/worker running on :8787 (pnpm run dev)
 *   - .dev.vars: STRIPE_SECRET_KEY (sk_test_...), TEST_AUTH_SECRET,
 *     ENABLE_TEST_AUTH=true
 *
 * Exit codes:
 *   0  Portal URL minted and reachable
 *   1  Any check failed (or preflight aborted)
 */
import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
function parseFlags(argv) {
    const flags = { keep: false, dryRun: false, help: false };
    for (const a of argv) {
        if (a === "--keep")
            flags.keep = true;
        else if (a === "--dry-run")
            flags.dryRun = true;
        else if (a === "--help" || a === "-h")
            flags.help = true;
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
Usage: pnpm tsx scripts/billing-portal-check.ts [--keep] [--dry-run]

Verifies POST /api/billing/portal mints a real Stripe-hosted Customer
Portal URL for a freshly minted test user.

Flags:
  --keep      Leave the test user behind on success (default: delete).
  --dry-run   Print intended steps without hitting Stripe or the worker.
  --help      Show this message.

Exit codes:
  0  All checks passed
  1  A check failed (or preflight aborted)
`);
}
const __dirname = dirname(fileURLToPath(import.meta.url));
const WORKER_DIR = resolve(__dirname, "..");
const DEV_VARS = resolve(WORKER_DIR, ".dev.vars");
const WORKER_URL = "http://localhost:8787";
function loadEnv() {
    const env = {};
    if (existsSync(DEV_VARS)) {
        for (const line of readFileSync(DEV_VARS, "utf8").split("\n")) {
            const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
            if (m)
                env[m[1]] = m[2].replace(/^["']|["']$/g, "");
        }
    }
    for (const k of ["STRIPE_SECRET_KEY", "TEST_AUTH_SECRET"]) {
        if (process.env[k])
            env[k] = process.env[k];
    }
    const STRIPE_SECRET_KEY = env.STRIPE_SECRET_KEY;
    const TEST_AUTH_SECRET = env.TEST_AUTH_SECRET;
    if (!STRIPE_SECRET_KEY)
        throw new Error("STRIPE_SECRET_KEY is not set (check .dev.vars).");
    if (STRIPE_SECRET_KEY.startsWith("sk_live_")) {
        throw new Error("Refusing to run against a live Stripe key. Use sk_test_... only.");
    }
    if (!STRIPE_SECRET_KEY.startsWith("sk_test_")) {
        throw new Error(`STRIPE_SECRET_KEY does not look like a test key: ${STRIPE_SECRET_KEY.slice(0, 8)}...`);
    }
    if (!TEST_AUTH_SECRET)
        throw new Error("TEST_AUTH_SECRET is not set (check .dev.vars).");
    return { STRIPE_SECRET_KEY, TEST_AUTH_SECRET };
}
async function probeWorker() {
    let res;
    try {
        res = await fetch(`${WORKER_URL}/health`);
    }
    catch {
        throw new Error(`Worker not reachable at ${WORKER_URL}. Is \`pnpm run dev\` running?`);
    }
    if (!res.ok) {
        throw new Error(`Worker /health returned ${res.status}; expected 200.`);
    }
}
function cryptoRandomHex(bytes) {
    const buf = new Uint8Array(bytes);
    crypto.getRandomValues(buf);
    return Array.from(buf, (b) => b.toString(16).padStart(2, "0")).join("");
}
async function signInFreshUser(env) {
    const email = `portal-check-${cryptoRandomHex(8)}@e2e.fidexa.org`;
    const res = await fetch(`${WORKER_URL}/test/sign-in`, {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            "X-Test-Auth-Secret": env.TEST_AUTH_SECRET,
        },
        body: JSON.stringify({ email, password: "hunter22" }),
    });
    if (!res.ok) {
        const body = await res.text();
        throw new Error(`/test/sign-in failed: ${res.status} ${body.slice(0, 200)}`);
    }
    const data = (await res.json());
    return data;
}
async function deleteUser(env, email) {
    await fetch(`${WORKER_URL}/test/users/${encodeURIComponent(email)}`, {
        method: "DELETE",
        headers: { "X-Test-Auth-Secret": env.TEST_AUTH_SECRET },
    }).catch((err) => {
        console.error(`  ! cleanup DELETE failed for ${email}:`, err);
    });
}
/**
 * Hit the worker's portal endpoint and assert we get back a real
 * Stripe-hosted URL. Stripe test-mode portal sessions live under
 * https://billing.stripe.com/p/session/... — the same pattern used
 * by production (test/live differ only in the session token).
 */
async function mintPortalUrl(token) {
    const res = await fetch(`${WORKER_URL}/api/billing/portal`, {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({}),
    });
    if (res.status !== 200) {
        const body = await res.text();
        throw new Error(`/api/billing/portal returned ${res.status}: ${body.slice(0, 200)}`);
    }
    const data = (await res.json());
    if (!data.url) {
        throw new Error(`/api/billing/portal returned no url field: ${JSON.stringify(data)}`);
    }
    return data.url;
}
const PORTAL_URL_PATTERN = /^https:\/\/billing\.stripe\.com\/p\/session\/[A-Za-z0-9_]+/;
/**
 * Probe the minted URL to confirm Stripe actually serves it. We use
 * redirect: 'manual' because the portal page may 30x to a localized
 * subdomain — we accept 200/30x as proof the session exists. A 404
 * (session not found) or 410 (expired) would be the failure mode.
 */
async function probePortalUrl(url) {
    const res = await fetch(url, { redirect: "manual" });
    const host = res.headers.get("location")
        ? new URL(res.headers.get("location"), url).host
        : new URL(url).host;
    return { status: res.status, host };
}
async function realRun(flags) {
    const env = loadEnv();
    console.log("→ Preflight…");
    console.log("  ✓ STRIPE_SECRET_KEY is a test key");
    console.log("  ✓ TEST_AUTH_SECRET present");
    await probeWorker();
    console.log(`  ✓ Worker reachable at ${WORKER_URL}`);
    console.log("\n→ Sign in fresh user via /test/sign-in");
    const session = await signInFreshUser(env);
    console.log(`  • userId  ${session.userId}`);
    console.log(`  • email   ${session.email}`);
    let portalUrl;
    let urlMatches = false;
    let probeStatus = null;
    let probeHost = null;
    let failure = null;
    try {
        console.log("\n→ POST /api/billing/portal");
        portalUrl = await mintPortalUrl(session.token);
        console.log(`  • url ${portalUrl}`);
        urlMatches = PORTAL_URL_PATTERN.test(portalUrl);
        if (!urlMatches) {
            failure = `Portal URL did not match expected pattern ${PORTAL_URL_PATTERN}`;
        }
        console.log("\n→ Probe portal URL (HEAD-equivalent with redirect: manual)");
        try {
            const probe = await probePortalUrl(portalUrl);
            probeStatus = probe.status;
            probeHost = probe.host;
            console.log(`  • status ${probe.status}  host ${probe.host}`);
            const reachable = probe.status >= 200 && probe.status < 400;
            const onStripe = probe.host?.endsWith("stripe.com") ?? false;
            if (!reachable || !onStripe) {
                failure ??= `Portal URL probe returned status=${probe.status} host=${probe.host}`;
            }
        }
        catch (err) {
            failure ??= `Portal URL probe threw: ${err instanceof Error ? err.message : String(err)}`;
        }
    }
    catch (err) {
        failure = err instanceof Error ? err.message : String(err);
    }
    if (!flags.keep) {
        console.log("\n→ Cleanup");
        await deleteUser(env, session.email);
        console.log("  ✓ test user deleted");
    }
    else {
        console.log(`\n--keep: user ${session.email} preserved`);
    }
    console.log("\n" + "─".repeat(72));
    const checks = [
        { name: "portal endpoint returned 200 + url", pass: failure === null || urlMatches, detail: failure ?? "OK" },
        { name: "url matches Stripe billing pattern", pass: urlMatches, detail: urlMatches ? "OK" : `no match for ${PORTAL_URL_PATTERN}` },
        {
            name: "URL is reachable on billing.stripe.com",
            pass: probeStatus !== null && probeStatus >= 200 && probeStatus < 400 && (probeHost?.endsWith("stripe.com") ?? false),
            detail: probeStatus === null ? "not probed" : `status=${probeStatus} host=${probeHost}`,
        },
    ];
    for (const c of checks) {
        console.log(`  ${c.pass ? "✓" : "✗"} ${c.name}  (${c.detail})`);
    }
    console.log("─".repeat(72));
    const allPass = checks.every((c) => c.pass);
    console.log(allPass ? "PASS" : "FAIL");
    process.exit(allPass ? 0 : 1);
}
async function main() {
    const flags = parseFlags(process.argv.slice(2));
    if (flags.help) {
        printHelp();
        process.exit(0);
    }
    if (flags.dryRun) {
        console.log("[dry-run] Would preflight env + worker");
        console.log("[dry-run] Would POST /test/sign-in with a fresh email");
        console.log("[dry-run] Would POST /api/billing/portal with bearer token");
        console.log("[dry-run] Would probe returned URL with redirect: 'manual'");
        console.log("[dry-run] Would DELETE the test user unless --keep");
        process.exit(0);
    }
    await realRun(flags);
}
main().catch((err) => {
    console.error("FATAL:", err);
    process.exit(1);
});

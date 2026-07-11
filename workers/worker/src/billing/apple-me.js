import { and, desc, eq, inArray } from "drizzle-orm";
import { appleSubscriptions, subscription } from "@rishi/shared/schema";
import { createDb } from "../db/drizzle";
// ─── Pure handler ──────────────────────────────────────────────────────────
/**
 * Resolve a user's premium entitlement.
 *
 * Precedence: Apple row wins if present; otherwise fall back to the existing
 * Stripe `subscription` table. Without the Stripe fallback, users who paid via
 * Stripe pre-IAP would regress to "free" until they re-purchase through
 * StoreKit (RESEARCH §6).
 *
 * Returns `{premium:false, premiumUntil:null}` when neither side has an
 * active row.
 */
export async function handleBillingMe(input) {
    const apple = await input.deps.db.findAppleActive(input.userId);
    if (apple) {
        return {
            premium: true,
            premiumUntil: apple.currentPeriodEnd.toISOString(),
        };
    }
    const stripe = await input.deps.db.findStripeActive(input.userId);
    if (stripe) {
        return {
            premium: true,
            premiumUntil: new Date(stripe.periodEnd * 1000).toISOString(),
        };
    }
    return { premium: false, premiumUntil: null };
}
// ─── Hono route mount (production wiring) ─────────────────────────────────
/**
 * Register `GET /api/billing/me` on the worker app behind `requireAuth`.
 * Called once at startup from `src/index.ts`.
 *
 * Caches for 30s as `private` — iOS reconciler hits this on launch, on
 * foreground, and after each `Transaction.updates` event, so even a short
 * cache window dampens the hot path. `must-revalidate` forces a refresh
 * after expiry rather than serving stale.
 */
export function registerBillingMeRoute(app, requireAuth) {
    app.get("/api/billing/me", requireAuth, async (c) => {
        const db = createDb(c.env.DB);
        const userId = c.get("userId");
        const deps = {
            db: {
                findAppleActive: async (uid) => {
                    const row = await db
                        .select({
                        currentPeriodEnd: appleSubscriptions.currentPeriodEnd,
                        status: appleSubscriptions.status,
                    })
                        .from(appleSubscriptions)
                        .where(and(eq(appleSubscriptions.userId, uid), inArray(appleSubscriptions.status, ["active", "in_grace"])))
                        .orderBy(desc(appleSubscriptions.currentPeriodEnd))
                        .get();
                    return row ?? null;
                },
                findStripeActive: async (uid) => {
                    const row = await db
                        .select({
                        periodEnd: subscription.periodEnd,
                        status: subscription.status,
                    })
                        .from(subscription)
                        .where(and(eq(subscription.referenceId, uid), inArray(subscription.status, ["active", "trialing"])))
                        .orderBy(desc(subscription.periodEnd))
                        .get();
                    if (!row || row.periodEnd == null)
                        return null;
                    // subscription.periodEnd is `timestamp` mode (seconds-precision
                    // stored, Date returned). Convert to seconds-since-1970 for the
                    // DI contract so the handler is testable without a Date import.
                    return {
                        periodEnd: Math.floor(row.periodEnd.getTime() / 1000),
                        status: row.status ?? "active",
                    };
                },
            },
        };
        const result = await handleBillingMe({ deps, userId });
        c.header("Cache-Control", "private, max-age=30, must-revalidate");
        return c.json(result, 200);
    });
}

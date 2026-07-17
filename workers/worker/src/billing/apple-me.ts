import { and, desc, eq, inArray } from "drizzle-orm";
import type { Hono, MiddlewareHandler } from "hono";
import { appleSubscriptions, subscription } from "@rishi/shared/schema";
import { createDb } from "../db/drizzle";
import type { EntitlementSnapshot } from "../durable-objects/user-usage-ledger/types";
// Type-only import to avoid a runtime ESM cycle with ../index — same shape as
// the 14-04 verify-receipt and 14-05 webhook factories. `requireAuth` is
// passed in by the caller (src/index.ts) rather than imported here.


// ─── Wire types ────────────────────────────────────────────────────────────

/**
 * Entitlement read model shared with iOS `EntitlementReconciler`.
 *
 * `premiumUntil` is an ISO8601 UTC string (Z-suffixed) — DIFFERENT from
 * `/verify-receipt`'s response, which uses seconds-since-1970 as a JSON number.
 * Both shapes are intentional and locked:
 *
 * - `/verify-receipt` pairs with iOS `JSONDecoder().dateDecodingStrategy =
 *   .secondsSince1970` (the `VerifyReceiptAPI.swift` decoder), so a number
 *   is the natural shape.
 * - `/me` is documented as an ISO string in `WORKER-CONTRACT-IAP.md` and the
 *   iOS-side `EntitlementReconciler` parses ISO strings on this path.
 *
 * 14-08 will confirm the iOS decoder matches; this file ships the contract.
 */
/**
 * Superset response: the original binary `premium`/`premiumUntil` fields
 * are kept, DEPRECATED-BUT-PRESENT, alongside the full `EntitlementSnapshot`
 * spread flat into the same object (`{ ...snapshot, premium, premiumUntil }`,
 * see the plan's "Design decisions" #6). `premium`/`premiumUntil` are kept
 * because the current iOS app's `EntitlementReconciler` still parses this
 * exact shape; remove them in a later cleanup pass once the iOS
 * entitlement-client plan (a separate plan in this series) ships and no
 * production client depends on the old shape anymore.
 */
export type BillingMeResponse = {
  premium: boolean;
  premiumUntil: string | null;
} & EntitlementSnapshot;

// ─── DI surface ────────────────────────────────────────────────────────────

export interface BillingMeDeps {
  db: {
    /**
     * Return the active (or in-grace) Apple subscription row for `userId`, or
     * `null` if none exists. The production resolver filters
     * `status IN ('active','in_grace')` and orders by `currentPeriodEnd DESC`
     * so the row with the latest expiry wins.
     */
    findAppleActive(userId: string): Promise<{
      currentPeriodEnd: Date;
      status: string;
    } | null>;
    /**
     * Return the active (or trialing) Stripe subscription row for `userId`,
     * or `null`. `periodEnd` is seconds-since-1970 (Stripe's native unit; the
     * production resolver converts the Drizzle `timestamp`-mode Date to
     * seconds before passing it through this DI port).
     */
    findStripeActive(userId: string): Promise<{
      periodEnd: number;
      status: string;
    } | null>;
  };
  /** Wraps `env.USER_USAGE_LEDGER.getByName(userId).getEntitlementSnapshot()`. */
  ledger: {
    getEntitlementSnapshot(userId: string): Promise<EntitlementSnapshot>;
  };
}

export interface BillingMeInput {
  deps: BillingMeDeps;
  userId: string;
}

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
export async function handleBillingMe(
  input: BillingMeInput,
): Promise<BillingMeResponse> {
  const apple = await input.deps.db.findAppleActive(input.userId);
  let premium = false;
  let premiumUntil: string | null = null;

  if (apple) {
    premium = true;
    premiumUntil = apple.currentPeriodEnd.toISOString();
  } else {
    const stripe = await input.deps.db.findStripeActive(input.userId);
    if (stripe) {
      premium = true;
      premiumUntil = new Date(stripe.periodEnd * 1000).toISOString();
    }
  }

  const snapshot = await input.deps.ledger.getEntitlementSnapshot(input.userId);

  return { premium, premiumUntil, ...snapshot };
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
export function registerBillingMeRoute(
  app: Hono<{
    Bindings: Env;
    Variables: { userId: string };
  }>,
  requireAuth: MiddlewareHandler,
): void {
  app.get("/api/billing/me", requireAuth, async (c) => {
    const db = createDb(c.env.DB);
    const userId = c.get("userId");

    const deps: BillingMeDeps = {
      db: {
        findAppleActive: async (uid) => {
          const row = await db
            .select({
              currentPeriodEnd: appleSubscriptions.currentPeriodEnd,
              status: appleSubscriptions.status,
            })
            .from(appleSubscriptions)
            .where(
              and(
                eq(appleSubscriptions.userId, uid),
                inArray(appleSubscriptions.status, ["active", "in_grace"]),
              ),
            )
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
            .where(
              and(
                eq(subscription.referenceId, uid),
                inArray(subscription.status, ["active", "trialing"]),
              ),
            )
            .orderBy(desc(subscription.periodEnd))
            .get();
          if (!row || row.periodEnd == null) return null;
          // subscription.periodEnd is `timestamp` mode (seconds-precision
          // stored, Date returned). Convert to seconds-since-1970 for the
          // DI contract so the handler is testable without a Date import.
          return {
            periodEnd: Math.floor(row.periodEnd.getTime() / 1000),
            status: row.status ?? "active",
          };
        },
      },
      ledger: {
        getEntitlementSnapshot: async (uid) => {
          const stub = c.env.USER_USAGE_LEDGER.getByName(uid);
          return stub.getEntitlementSnapshot();
        },
      },
    };

    const result = await handleBillingMe({ deps, userId });
    c.header("Cache-Control", "private, max-age=30, must-revalidate");
    return c.json(result, 200);
  });
}

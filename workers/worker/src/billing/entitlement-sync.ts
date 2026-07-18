import { z } from "zod";
import { and, desc, eq, ne } from "drizzle-orm";
import type { Hono, MiddlewareHandler } from "hono";
import { verifyAppleJWS, JWSInvalid } from "./jws-verify";
import { allowancePeriod, appleSubscriptions, usageAuditLog } from "../db/schema";
import { createDb } from "../db/drizzle";
import {
  APPLE_BUNDLE_ID,
  APPLE_PRODUCT_PLAN_MAP,
  PLAN_ALLOWANCES,
  type ApplePlan,
} from "./apple-product-plans";
import type { EntitlementSnapshot } from "../durable-objects/user-usage-ledger/types";
import {
  classifyTransition,
  type CurrentPeriodInfo,
} from "./subscription-transitions";
import { addOneCalendarMonth, rollAllowancePeriodsForward } from "./allowance-period-rollover";
// NOTE: no runtime import of `../index` here -- same ESM-cycle constraint
// as apple-verify-receipt.ts / apple-webhook.ts / apple-me.ts. `requireAuth`
// is passed in by the route factory below.
//
// NOTE: no local `EntitlementSnapshot` reader is defined in this file --
// plan 5 (billing-me-entitlement-snapshot) is the sole, authoritative
// implementation (see "Context" item 5 above). This file only imports the
// *type* and calls the real Durable Object method for its final response.

// ─── appAccountToken derivation ────────────────────────────────────────────

/**
 * Fixed RFC 4122 v5 namespace for deriving a Rishi user's `appAccountToken`.
 * Generated once (2026-07-17); MUST NEVER change once any purchase relies
 * on it -- changing it silently breaks the app_account_token match for
 * every previously-derived token.
 */
const APP_ACCOUNT_TOKEN_NAMESPACE = "fbf6524d-646b-4317-b479-476821e250f6";

function uuidStringToBytes(uuid: string): Uint8Array {
  const hex = uuid.replace(/-/g, "");
  const bytes = new Uint8Array(16);
  for (let i = 0; i < 16; i++) {
    bytes[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

function bytesToUuidString(bytes: Uint8Array): string {
  const hex = Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}

/**
 * Derive a deterministic UUID v5 from the Rishi user id, for use as
 * StoreKit's `Purchase.Options.appAccountToken(_:)` (a Foundation `UUID`).
 *
 * Better Auth's `user.id` is NOT a UUID -- confirmed by reading
 * `@better-auth/core/src/utils/id.ts`: the default `generateId()` is
 * `createRandomStringGenerator("a-z","A-Z","0-9")(32)`, a 32-char
 * alphanumeric string with no hyphens and letters outside [0-9a-f]. Passing
 * it directly to Swift's `UUID(uuidString:)` fails to parse for most ids.
 * Deriving a UUID v5 (namespace + name = userId) needs no new column and no
 * round trip: the Worker and the iOS "storekit-products" plan each compute
 * it independently and always get the same value for the same
 * authenticated user.
 *
 * iOS MUST implement the byte-identical algorithm (UUID v5, SHA-1, this
 * exact namespace constant, name = the user's Rishi id string) -- see
 * "Exports for downstream plans" at the bottom of the plan doc that added
 * this function.
 */
export async function deriveAppAccountToken(userId: string): Promise<string> {
  const namespaceBytes = uuidStringToBytes(APP_ACCOUNT_TOKEN_NAMESPACE);
  const nameBytes = new TextEncoder().encode(userId);
  const data = new Uint8Array(namespaceBytes.length + nameBytes.length);
  data.set(namespaceBytes, 0);
  data.set(nameBytes, namespaceBytes.length);

  const hashBuffer = await crypto.subtle.digest("SHA-1", data);
  const hash = new Uint8Array(hashBuffer).slice(0, 16);
  hash[6] = (hash[6] & 0x0f) | 0x50; // version 5
  hash[8] = (hash[8] & 0x3f) | 0x80; // RFC 4122 variant

  return bytesToUuidString(hash);
}

// ─── Wire types ────────────────────────────────────────────────────────────

/**
 * Decoded Apple JWS transaction payload -- subset entitlement-sync cares
 * about. Same UInt64-precision / ms-epoch pitfalls as
 * `apple-verify-receipt.ts` / `apple-webhook.ts` (transactionId /
 * originalTransactionId stringified; expiresDate / purchaseDate ms-epoch).
 */
export interface DecodedAppleTransaction {
  bundleId: string;
  productId: string;
  transactionId: string;
  originalTransactionId: string;
  appAccountToken?: string;
  purchaseDate: number;
  expiresDate: number;
  environment: "Sandbox" | "Production";
}

/** A `DecodedAppleTransaction` that has passed every entitlement-sync guard. */
export interface VerifiedAppleTransaction {
  transactionId: string;
  originalTransactionId: string;
  productId: string;
  plan: ApplePlan;
  purchaseDate: number;
  expiresDate: number;
  environment: "Sandbox" | "Production";
  appAccountToken: string;
}

export type EntitlementSyncReason =
  | "jws_signature_invalid"
  | "bundle_id_mismatch"
  | "invalid_environment"
  | "unknown_product_id"
  | "app_account_token_mismatch"
  | "transaction_owned_by_different_user";

export interface EntitlementSyncResponse {
  verified: boolean;
  reason: EntitlementSyncReason | null;
  snapshot: EntitlementSnapshot | null;
}

const RequestSchema = z.object({
  transactionJWS: z.string().min(10),
});

// ─── applyAppleTransaction ─────────────────────────────────────────────────

/**
 * Idempotently persist a verified Apple transaction and apply the full
 * upgrade/downgrade/renewal/crossgrade transition matrix (2026-07-17
 * pricing/trial-launch design doc, "Subscription transitions") against the
 * user's most recent allowance-period D1 row. Supersedes the
 * `storekit-entitlement-sync` plan's "first-ever-period-only"
 * implementation -- see that plan's "Exports for downstream plans" >
 * "applyAppleTransaction" for the exact behavior this replaces.
 *
 * Classification is delegated to `classifyTransition` (./subscription-
 * transitions.ts) so the tier/product comparison is a pure, dependency-free
 * decision table kept out of this already-large function -- see this
 * plan's "Design decisions" #1.
 *
 * D1-PERSISTENCE FIX (this plan's "Design decisions" intro, and #7): the
 * prior version of this function never inserted into `allowancePeriod`
 * itself, under an assumption (flagged explicitly in that plan) that
 * `UserUsageLedger.syncAllowancePeriod()` would persist the D1 row. Plan 5
 * (`billing-me-entitlement-snapshot`) has since landed and its own docs
 * confirm the opposite: `syncAllowancePeriod()` ONLY maintains the Durable
 * Object's local mirror and never writes to D1. This rewrite closes that
 * gap for every branch, including the first-ever-period case -- every
 * period this function creates is now backed by a real `allowancePeriod`
 * D1 row, which this function's own FUTURE calls depend on to read
 * `currentPeriod` correctly.
 *
 * PRODUCTION GOTCHA (unchanged from the prior version): the D1 read of the
 * user's most recent period and the subsequent D1 write / DO sync below are
 * still not one transaction -- two concurrent entitlement-sync calls for
 * the same brand-new event (e.g. a launch call racing a StoreKit
 * transaction-update call) could both observe the same `currentPeriod` and
 * both attempt to open a new one. As before, the Durable Object's
 * single-request-at-a-time execution model is the real backstop; this D1
 * read is a cheap first-pass optimization, not the sole correctness
 * mechanism.
 *
 * IDEMPOTENCY FIX (entitlement-sync-idempotency plan): the client resends
 * the same still-valid transaction JWS on every foreground, restore, and
 * launch -- NOT only when Apple actually issues a new transaction. Before
 * this fix, every one of those repeats re-ran the classification/period-
 * opening logic below and, for an annual product, misclassified itself as
 * "renewed" every time (`expiresDate` is ~1 year out; the 1-month period
 * it opened kept expiring against it), granting a fresh full allowance on
 * every single foreground. This function now checks whether an
 * `allowancePeriod` row already carries this exact `tx.transactionId` as
 * its `sourceTransactionId` and, if so, skips every allowance-period side
 * effect below entirely -- the `apple_subscriptions` status upsert above
 * still runs unconditionally, since re-confirming "still active" is cheap
 * and correct to repeat.
 *
 * ANNUAL-PRODUCT FIX (same plan): opening a period no longer relies on a
 * fresh Apple transaction to advance month-to-month. `rollAllowancePeriodsForward`
 * (./allowance-period-rollover.ts) runs at the end of this function on
 * every call, independent of whether THIS call's transaction was new, and
 * opens the next monthly period purely on wall-clock time whenever the
 * current one has lapsed but the subscription's own paid term (Apple's
 * `expiresDate`, stored on `apple_subscriptions.currentPeriodEnd`) has
 * not. That is what lets an annual subscriber keep getting monthly
 * allowance through months 2-12 without a new Apple transaction ever
 * arriving.
 */
export async function applyAppleTransaction(
  env: Env,
  userId: string,
  tx: VerifiedAppleTransaction,
): Promise<void> {
  const db = createDb(env.DB);
  const now = new Date();
  const nowMs = now.getTime();
  const isActive = tx.expiresDate > nowMs;

  // 1. Idempotent upsert into apple_subscriptions -- UNCHANGED from plan 6.
  await db
    .insert(appleSubscriptions)
    .values({
      appleTransactionId: tx.transactionId,
      appleOriginalTransactionId: tx.originalTransactionId,
      userId,
      productId: tx.productId,
      status: isActive ? "active" : "expired",
      currentPeriodEnd: new Date(tx.expiresDate),
      environment: tx.environment,
      appAccountToken: tx.appAccountToken,
    })
    .onConflictDoUpdate({
      target: appleSubscriptions.appleTransactionId,
      set: {
        status: isActive ? "active" : "expired",
        currentPeriodEnd: new Date(tx.expiresDate),
        appAccountToken: tx.appAccountToken,
        updatedAt: now,
      },
    })
    .run();

  // 2. Full upgrade/downgrade/renewal/crossgrade transition matrix (design
  // doc's "Subscription transitions" table) -- but ONLY for a transaction
  // whose allowance-period side effects haven't already been applied. A
  // period already exists with this exact `tx.transactionId` as its
  // `sourceTransactionId` iff some earlier call already ran this branch
  // for it (directly, or via a rollover chain that copied the id
  // forward -- see "IDEMPOTENCY FIX" above and `allowance-period-
  // rollover.ts`'s doc comment). Skipping the open/close/audit work below
  // is what makes a repeated foreground sync of the same still-valid JWS
  // a no-op for period creation. DO rehydration still happens: step 2b
  // (`rollAllowancePeriodsForward`) always syncs the current D1 period to
  // the ledger mirror, which heals a failed first-sync after D1 insert
  // without resetting usage (same-id path in `syncAllowancePeriod`).
  if (isActive) {
    const alreadyProcessed = await db
      .select({ id: allowancePeriod.id })
      .from(allowancePeriod)
      .where(
        and(
          eq(allowancePeriod.userId, userId),
          eq(allowancePeriod.sourceTransactionId, tx.transactionId),
        ),
      )
      .get();

    if (!alreadyProcessed) {
      // Read the user's single most recent allowance-period D1 row,
      // regardless of whether it is still active -- see "Design decisions"
      // #2. Ordering by createdAt (not periodEnd) always finds the period
      // most recently opened, which is the correct "current" one even after
      // an early truncation below can move an older row's periodEnd earlier
      // than it originally was -- see "Design decisions" #6.
      const mostRecentPeriod = await db
        .select()
        .from(allowancePeriod)
        .where(eq(allowancePeriod.userId, userId))
        .orderBy(desc(allowancePeriod.createdAt))
        .get();

      let currentPeriod: CurrentPeriodInfo | null = null;
      if (mostRecentPeriod) {
        let productId: string | null = null;
        if (mostRecentPeriod.sourceTransactionId) {
          const sourceSub = await db
            .select({ productId: appleSubscriptions.productId })
            .from(appleSubscriptions)
            .where(
              eq(appleSubscriptions.appleTransactionId, mostRecentPeriod.sourceTransactionId),
            )
            .get();
          productId = sourceSub?.productId ?? null;
        }
        currentPeriod = {
          id: mostRecentPeriod.id,
          plan: mostRecentPeriod.plan,
          productId,
          periodEnd: mostRecentPeriod.periodEnd.getTime(),
        };
      }

      const classification = classifyTransition({
        currentPeriod,
        newPlan: tx.plan,
        newProductId: tx.productId,
        now: nowMs,
      });

      const allowances = PLAN_ALLOWANCES[tx.plan];

      const openFreshPeriod = async (
        transitionReason: "initial" | "renewed" | "upgraded" | "downgraded" | "crossgrade",
        priorPeriodId: string | null,
      ): Promise<string> => {
        const periodId = crypto.randomUUID();
        const periodStart = new Date(tx.purchaseDate);
        const periodEnd = addOneCalendarMonth(periodStart);

        // Unique on (userId, periodStart): concurrent first-applies lose
        // the insert and adopt the winner's row (same pattern as rollover).
        const insertResult = await db
          .insert(allowancePeriod)
          .values({
            id: periodId,
            userId,
            plan: tx.plan,
            periodStart,
            periodEnd,
            narrationSecondsTotal: allowances.narrationSecondsTotal,
            narrationSecondsUsed: 0,
            voiceChatSecondsTotal: allowances.voiceChatSecondsTotal,
            voiceChatSecondsUsed: 0,
            transitionReason,
            priorPeriodId,
            sourceTransactionId: tx.transactionId,
            createdAt: now,
          })
          .onConflictDoNothing({
            target: [allowancePeriod.userId, allowancePeriod.periodStart],
          })
          .run();

        const inserted =
          ((insertResult as { meta?: { changes?: number } })?.meta?.changes ?? 0) > 0;

        let resolvedId: string = periodId;
        let resolvedPlan: ApplePlan = tx.plan;
        let resolvedStart = periodStart;
        let resolvedEnd = periodEnd;
        let resolvedNarrationTotal = allowances.narrationSecondsTotal;
        let resolvedVoiceTotal = allowances.voiceChatSecondsTotal;

        if (!inserted) {
          const winner = await db
            .select()
            .from(allowancePeriod)
            .where(
              and(
                eq(allowancePeriod.userId, userId),
                eq(allowancePeriod.periodStart, periodStart),
              ),
            )
            .get();
          if (!winner) {
            throw new Error(
              `openFreshPeriod conflict but no winner for userId=${userId} periodStart=${periodStart.toISOString()}`,
            );
          }
          resolvedId = winner.id;
          resolvedPlan = winner.plan;
          resolvedStart = winner.periodStart;
          resolvedEnd = winner.periodEnd;
          resolvedNarrationTotal = winner.narrationSecondsTotal;
          resolvedVoiceTotal = winner.voiceChatSecondsTotal;
        }

        // Plan 5's DO mirror holds exactly one "current" row -- syncing here
        // always REPLACES whatever period it previously mirrored, so no
        // separate "close" call is needed on the DO side (see "Design
        // decisions" #7). Same-id resync (winner already mirrored) preserves
        // usage counters.
        await env.USER_USAGE_LEDGER.getByName(userId).syncAllowancePeriod({
          id: resolvedId,
          plan: resolvedPlan,
          periodStart: resolvedStart.getTime(),
          periodEnd: resolvedEnd.getTime(),
          narrationSecondsTotal: resolvedNarrationTotal,
          voiceChatSecondsTotal: resolvedVoiceTotal,
        });

        return resolvedId;
      };

      // Truncates a still-active period's periodEnd to "now" for an
      // IMMEDIATE transition (upgrade, or a same-product renewal signaled
      // while the old period hadn't reached its boundary yet). Never call
      // this for a period that has already lapsed naturally -- see "Design
      // decisions" #4 -- that would incorrectly push its periodEnd LATER.
      const closePeriodNow = async (periodId: string): Promise<void> => {
        await db
          .update(allowancePeriod)
          .set({ periodEnd: now })
          .where(eq(allowancePeriod.id, periodId))
          .run();
      };

      let newPeriodId: string | null = null;
      let priorPeriodIdForAudit: string | null = null;

      switch (classification.kind) {
        case "first_period":
          newPeriodId = await openFreshPeriod("initial", null);
          break;

        case "renewed":
          priorPeriodIdForAudit = classification.priorPeriodId;
          if (currentPeriod && currentPeriod.periodEnd > nowMs) {
            await closePeriodNow(classification.priorPeriodId);
          }
          newPeriodId = await openFreshPeriod("renewed", classification.priorPeriodId);
          break;

        case "upgraded":
          priorPeriodIdForAudit = classification.priorPeriodId;
          if (currentPeriod && currentPeriod.periodEnd > nowMs) {
            await closePeriodNow(classification.priorPeriodId);
          }
          newPeriodId = await openFreshPeriod("upgraded", classification.priorPeriodId);
          break;

        case "downgraded_applied":
          priorPeriodIdForAudit = classification.priorPeriodId;
          newPeriodId = await openFreshPeriod("downgraded", classification.priorPeriodId);
          break;

        case "crossgrade_applied":
          priorPeriodIdForAudit = classification.priorPeriodId;
          newPeriodId = await openFreshPeriod("crossgrade", classification.priorPeriodId);
          break;

        case "downgraded_deferred":
        case "crossgrade_deferred":
          // Design doc's "Subscription transitions" table: keep serving the
          // current (higher-tier, or different-duration) period untouched
          // until a later sync reports the new product as active. No D1
          // write, no syncAllowancePeriod call.
          priorPeriodIdForAudit = classification.priorPeriodId;
          break;
      }

      await db
        .insert(usageAuditLog)
        .values({
          id: crypto.randomUUID(),
          userId,
          eventType: "allowance_period.transition",
          details: JSON.stringify({
            classification: classification.kind,
            priorPeriodId: priorPeriodIdForAudit,
            newPeriodId,
            transactionId: tx.transactionId,
            productId: tx.productId,
            plan: tx.plan,
          }),
          createdAt: now,
        })
        .run();
    }
  }

  // 2b. Roll the current allowance period forward on wall-clock time if it
  // has lapsed but the anchoring Apple transaction's paid term has not --
  // see "ANNUAL-PRODUCT FIX" above. Runs unconditionally (not gated on
  // `isActive`/`alreadyProcessed` for THIS transaction): the period that
  // needs rolling forward may belong to a different, still-valid
  // subscription than the one `tx` describes, and a repeat sync of an
  // already-processed transaction must still advance a lapsed period.
  await rollAllowancePeriodsForward(env, userId, now);

  // 3. Append-only per-transaction audit row -- UNCHANGED from plan 6.
  // Written for every applied transaction (active or expired), independent
  // of the transition-specific row above (which only fires when isActive).
  await db
    .insert(usageAuditLog)
    .values({
      id: crypto.randomUUID(),
      userId,
      eventType: "apple_transaction_applied",
      details: JSON.stringify({
        transactionId: tx.transactionId,
        originalTransactionId: tx.originalTransactionId,
        productId: tx.productId,
        plan: tx.plan,
        isActive,
      }),
      createdAt: now,
    })
    .run();
}

// ─── DI surface ────────────────────────────────────────────────────────────

export interface EntitlementSyncDeps {
  verifyJws: (jws: string) => Promise<DecodedAppleTransaction>;
  findOwnerByOriginalTransactionId: (
    originalTransactionId: string,
  ) => Promise<string | null>;
  applyAppleTransaction: (userId: string, tx: VerifiedAppleTransaction) => Promise<void>;
  getSnapshot: (userId: string) => Promise<EntitlementSnapshot>;
}

export interface EntitlementSyncInput {
  deps: EntitlementSyncDeps;
  userId: string;
  body: { transactionJWS: string };
}

// ─── Pure handler ──────────────────────────────────────────────────────────

/**
 * Verify + apply an Apple-signed transaction JWS and return the resulting
 * entitlement snapshot. Pure function over `EntitlementSyncDeps` for
 * testability (per the design doc's Deferred Scope: "keep components small
 * and interfaces explicit so they are testable later" -- no tests are
 * written by this plan, but the seam is here for the later test pass).
 *
 * Guard order (design doc "Authoritative entitlement model"): JWS signature
 * -> bundle id -> environment shape -> known product id -> appAccountToken
 * match -> anti-account-sharing (different-user) check. Any failure
 * short-circuits with `verified: false` and a tagged `reason`; the
 * transaction is never partially applied. Matches the existing
 * `/api/billing/verify-receipt` convention of returning HTTP 200 for a
 * business-logic rejection (only a malformed request body is a 4xx) -- see
 * `registerEntitlementSyncRoute` below.
 */
export async function handleEntitlementSync(
  input: EntitlementSyncInput,
): Promise<EntitlementSyncResponse> {
  let decoded: DecodedAppleTransaction;
  try {
    decoded = await input.deps.verifyJws(input.body.transactionJWS);
  } catch (e) {
    if (e instanceof JWSInvalid) {
      return { verified: false, reason: "jws_signature_invalid", snapshot: null };
    }
    throw e;
  }

  if (decoded.bundleId !== APPLE_BUNDLE_ID) {
    return { verified: false, reason: "bundle_id_mismatch", snapshot: null };
  }

  if (decoded.environment !== "Sandbox" && decoded.environment !== "Production") {
    return { verified: false, reason: "invalid_environment", snapshot: null };
  }

  const mapping = APPLE_PRODUCT_PLAN_MAP[decoded.productId];
  if (!mapping) {
    return { verified: false, reason: "unknown_product_id", snapshot: null };
  }

  const expectedToken = await deriveAppAccountToken(input.userId);
  if (!decoded.appAccountToken || decoded.appAccountToken !== expectedToken) {
    return { verified: false, reason: "app_account_token_mismatch", snapshot: null };
  }

  const owner = await input.deps.findOwnerByOriginalTransactionId(
    decoded.originalTransactionId,
  );
  if (owner && owner !== input.userId) {
    return {
      verified: false,
      reason: "transaction_owned_by_different_user",
      snapshot: null,
    };
  }

  const verifiedTx: VerifiedAppleTransaction = {
    transactionId: decoded.transactionId,
    originalTransactionId: decoded.originalTransactionId,
    productId: decoded.productId,
    plan: mapping.plan,
    purchaseDate: decoded.purchaseDate,
    expiresDate: decoded.expiresDate,
    environment: decoded.environment,
    appAccountToken: decoded.appAccountToken,
  };

  await input.deps.applyAppleTransaction(input.userId, verifiedTx);
  const snapshot = await input.deps.getSnapshot(input.userId);

  return { verified: true, reason: null, snapshot };
}

// ─── Hono route mount (production wiring) ─────────────────────────────────

/**
 * Register `POST /api/billing/entitlement-sync` behind `requireAuth`.
 * Called once at startup from `src/index.ts`. `requireAuth` is passed in to
 * avoid a circular import (same constraint as the other IAP route
 * factories -- see their header comments).
 */
export function registerEntitlementSyncRoute(
  app: Hono<{
    Bindings: Env;
    Variables: { userId: string };
  }>,
  requireAuth: MiddlewareHandler,
): void {
  app.post("/api/billing/entitlement-sync", requireAuth, async (c) => {
    const raw = await c.req.json().catch(() => null);
    const parsed = RequestSchema.safeParse(raw);
    if (!parsed.success) {
      return c.json({ error: "bad_request" }, 400);
    }

    const env = c.env;
    const db = createDb(env.DB);

    const deps: EntitlementSyncDeps = {
      verifyJws: async (jws) => {
        const payload = await verifyAppleJWS<{
          bundleId: string;
          productId: string;
          transactionId: number | string;
          originalTransactionId: number | string;
          appAccountToken?: string;
          purchaseDate: number;
          expiresDate: number;
          environment: "Sandbox" | "Production";
        }>(jws);
        return {
          bundleId: payload.bundleId,
          productId: payload.productId,
          transactionId: String(payload.transactionId),
          originalTransactionId: String(payload.originalTransactionId),
          appAccountToken: payload.appAccountToken,
          purchaseDate: payload.purchaseDate,
          expiresDate: payload.expiresDate,
          environment: payload.environment,
        };
      },
      findOwnerByOriginalTransactionId: async (originalTransactionId) => {
        const row = await db
          .select({ userId: appleSubscriptions.userId })
          .from(appleSubscriptions)
          .where(
            and(
              eq(appleSubscriptions.appleOriginalTransactionId, originalTransactionId),
              ne(appleSubscriptions.userId, ""),
            ),
          )
          .orderBy(desc(appleSubscriptions.updatedAt))
          .get();
        return row?.userId ?? null;
      },
      applyAppleTransaction: (userId, tx) => applyAppleTransaction(env, userId, tx),
      getSnapshot: (userId) => env.USER_USAGE_LEDGER.getByName(userId).getEntitlementSnapshot(),
    };

    const result = await handleEntitlementSync({
      deps,
      userId: c.get("userId"),
      body: parsed.data,
    });
    return c.json(result, 200);
  });
}

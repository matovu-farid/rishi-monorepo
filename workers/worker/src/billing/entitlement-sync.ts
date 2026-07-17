import { z } from "zod";
import { and, desc, eq, gt, ne } from "drizzle-orm";
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

function addOneCalendarMonth(date: Date): Date {
  const result = new Date(date.getTime());
  result.setUTCMonth(result.getUTCMonth() + 1);
  return result;
}

// ─── applyAppleTransaction ─────────────────────────────────────────────────

/**
 * Idempotently persist a verified Apple transaction and, for a user's
 * FIRST-EVER active subscription only, start their initial allowance
 * period.
 *
 * SCOPE NOTE for the "subscription-transitions" follow-up plan: this
 * function currently only handles the case where NO active allowance
 * period exists yet for the user -- it starts one and stops.
 * Upgrade/downgrade/renewal/crossgrade transitions across MULTIPLE
 * allowance periods (design doc's "Subscription transitions" table) are
 * explicitly out of scope here. The follow-up plan should MODIFY THIS
 * FUNCTION IN PLACE -- replace the single `if (!existingActivePeriod)`
 * branch below with the full transition matrix -- rather than adding a
 * second code path elsewhere. That plan will also need to EXTEND the
 * `syncAllowancePeriod` call's argument shape: the assumed signature this
 * plan uses has no `transitionReason` / `priorPeriodId` /
 * `sourceTransactionId` fields, even though `allowancePeriod` (the schema
 * table) has all three -- those only matter once transitions exist.
 *
 * ASSUMPTION (reconcile when the UserUsageLedger Durable Object plan
 * lands): `env.USER_USAGE_LEDGER.getByName(userId).syncAllowancePeriod(...)`
 * is responsible for PERSISTING the `allowance_period` row to D1 itself --
 * the design doc describes the DO as the sole coordinator that writes
 * through Drizzle. This function does NOT insert into `allowancePeriod`
 * directly; it only SELECTs from it (read-only) to decide whether an
 * active period already exists, then hands the computed period shape to
 * the Durable Object. If that assumption is wrong, add one
 * `db.insert(allowancePeriod)...` call where the comment below marks it.
 *
 * PRODUCTION GOTCHA: the "does an active period already exist" read and
 * the `syncAllowancePeriod` call below are two separate steps, not one
 * transaction -- two concurrent entitlement-sync requests for the same
 * brand-new subscriber (e.g. a launch call racing a StoreKit
 * transaction-update call) could both see "no active period" and both
 * call `syncAllowancePeriod` with a different candidate period id. Durable
 * Objects execute one request at a time per instance, so the DO's own
 * `syncAllowancePeriod` implementation is the right place to make this
 * fully race-safe (e.g. by treating a second call within the same
 * timeframe as a no-op) -- this plan's D1 read is a cheap first-pass
 * optimization, not the sole correctness mechanism.
 */
export async function applyAppleTransaction(
  env: Env,
  userId: string,
  tx: VerifiedAppleTransaction,
): Promise<void> {
  const db = createDb(env.DB);
  const now = new Date();
  const isActive = tx.expiresDate > now.getTime();

  // 1. Idempotent upsert into apple_subscriptions, keyed by the PK
  // apple_transaction_id -- safe to call on every entitlement-sync (launch,
  // foreground, purchase, restore, transaction-updates) with the same
  // transaction.
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

  // 2. First-ever-active-subscription allowance period (see scope note
  // above). Guarding on "no active period exists" makes this safe to call
  // on every sync -- an already-active period is left untouched.
  if (isActive) {
    const existingActivePeriod = await db
      .select({ id: allowancePeriod.id })
      .from(allowancePeriod)
      .where(and(eq(allowancePeriod.userId, userId), gt(allowancePeriod.periodEnd, now)))
      .orderBy(desc(allowancePeriod.periodEnd))
      .get();

    if (!existingActivePeriod) {
      const periodId = crypto.randomUUID();
      const periodStart = new Date(tx.purchaseDate);
      const periodEnd = addOneCalendarMonth(periodStart);
      const allowances = PLAN_ALLOWANCES[tx.plan];

      // NOT inserted into `allowancePeriod` here -- see the ASSUMPTION note
      // above the function.
      await env.USER_USAGE_LEDGER.getByName(userId).syncAllowancePeriod({
        id: periodId,
        plan: tx.plan,
        periodStart: periodStart.getTime(),
        periodEnd: periodEnd.getTime(),
        narrationSecondsTotal: allowances.narrationSecondsTotal,
        voiceChatSecondsTotal: allowances.voiceChatSecondsTotal,
      });
    }
  }

  // 3. Append-only audit row for every applied transaction (not just the
  // first) -- matches usageAuditLog's "audit trail for entitlement/usage
  // decisions" purpose (workers/worker/src/db/schema.ts).
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

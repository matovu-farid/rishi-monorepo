import { z } from "zod";
import { eq } from "drizzle-orm";
import type { Hono, MiddlewareHandler } from "hono";
import { verifyAppleJWS, JWSInvalid } from "./jws-verify";
import { appleSubscriptions } from "@rishi/shared/schema";
import { createDb } from "../db/drizzle";
// NOTE: `CloudflareBindings` and `requireAuth` live in `../index.ts`. We
// CANNOT `import { requireAuth } from "../index"` here — index.ts imports
// `registerVerifyReceiptRoute` from this file, and a runtime cycle breaks
// Vitest's ESM loader (`Cannot access '__vite_ssr_import_*__' before
// initialization`). Caller passes `requireAuth` in via the route factory.
import type { Env } from "../index";

// ─── Wire types ────────────────────────────────────────────────────────────

/**
 * Decoded Apple JWS transaction payload — subset that Phase 14 cares about.
 * `expiresDate` is ms-since-1970 (Apple's native unit; see RESEARCH Pitfall 5).
 * `transactionId` is stringified UInt64 (RESEARCH Pitfall 2 — Apple's value
 * overflows JS Number.MAX_SAFE_INTEGER).
 */
export interface AppleTransactionPayload {
  productId: string;
  transactionId: string;
  originalTransactionId: string;
  expiresDate: number;
  environment: "Sandbox" | "Production";
}

const RequestSchema = z.object({
  jws: z.string().min(10),
  productId: z.string().min(1),
  // iOS sends transactionId as a JSON number (UInt64 -> Number). We accept
  // strings too for clients that already pre-stringify (defensive).
  transactionId: z.union([z.number(), z.string()]),
});

/**
 * Canonical reason strings shared with iOS WorkerReceiptVerifier
 * (apps/apple — WORKER-CONTRACT-IAP.md §1.5).
 */
export type ReceiptReason =
  | "jws_signature_invalid"
  | "product_id_mismatch"
  | "transaction_id_mismatch"
  | "user_not_found"
  | "replay_detected"
  | "apple_unreachable";

export interface VerifyReceiptResponse {
  verified: boolean;
  /**
   * Seconds since 1970-01-01T00:00:00Z (NOT ms, NOT ISO string).
   *
   * iOS-side `WorkerClient` decodes responses with a default `JSONDecoder()`,
   * whose default `dateDecodingStrategy` is `.deferredToDate` (NOT
   * `.secondsSince1970`). HOWEVER the contract on `VerifyReceiptAPI.swift`
   * keys this field as `Date?` and the iOS DEBUG stub returns a real Date —
   * decoding a JSON number as a Date requires `.secondsSince1970`.
   *
   * Phase 13 / Phase 14 contract resolves this by emitting a JSON number in
   * seconds and pairing it with the `JSONDecoder().dateDecodingStrategy =
   * .secondsSince1970` setting on the iOS WorkerClient (locked in 14-04
   * plan frontmatter must_haves).
   */
  premiumUntil: number | null;
  reason: ReceiptReason | null;
}

// ─── DI surface ────────────────────────────────────────────────────────────

export interface VerifyReceiptDeps {
  verifyJws: (jws: string) => Promise<AppleTransactionPayload>;
  db: {
    findByTransactionId(transactionId: string): Promise<{
      appleTransactionId: string;
      userId: string;
      currentPeriodEnd: number; // ms-epoch as stored in D1 (timestamp_ms mode)
    } | null>;
    upsertSubscription(row: {
      appleTransactionId: string;
      appleOriginalTransactionId: string;
      userId: string;
      productId: string;
      status: "active";
      currentPeriodEnd: Date;
      environment: "Sandbox" | "Production";
    }): Promise<void>;
  };
}

export interface VerifyReceiptInput {
  deps: VerifyReceiptDeps;
  userId: string;
  body: { jws: string; productId: string; transactionId: number | string };
}

// ─── Pure handler ──────────────────────────────────────────────────────────

/**
 * Verify an iOS-supplied StoreKit 2 JWS receipt and upsert the subscription
 * row. Pure function over `VerifyReceiptDeps` — Vitest substitutes stubs;
 * production wiring is in `registerVerifyReceiptRoute` below.
 *
 * Flow (RESEARCH §4.1):
 *   1. Verify JWS signature (`deps.verifyJws`).
 *   2. Cross-check `productId` against the decoded payload.
 *   3. Cross-check `transactionId` against the decoded payload (string compare
 *      to keep UInt64 precision — Pitfall 2).
 *   4. Look up an existing row by `transactionId`:
 *      - Different user => `replay_detected`, no DB write.
 *      - Same user      => short-circuit: return persisted `currentPeriodEnd`
 *                          without re-upserting (RESEARCH §4.4 idempotency).
 *   5. No row yet      => upsert and return seconds-since-1970 from the
 *      decoded `expiresDate` (ms / 1000, floored).
 *
 * Apple S2S `GetTransactionInfo` defense-in-depth (RESEARCH §4.1 step 7) is
 * INTENTIONALLY out of scope for this plan — daily reconciliation cron (filed
 * as a §7.4 follow-up) covers the catch-up gap until that lands.
 */
export async function handleVerifyReceipt(
  input: VerifyReceiptInput,
): Promise<VerifyReceiptResponse> {
  const txIdStr = String(input.body.transactionId);

  // 1. Verify JWS signature.
  let decoded: AppleTransactionPayload;
  try {
    decoded = await input.deps.verifyJws(input.body.jws);
  } catch (e) {
    if (e instanceof JWSInvalid) {
      return {
        verified: false,
        premiumUntil: null,
        reason: "jws_signature_invalid",
      };
    }
    throw e;
  }

  // 2. Cross-check productId.
  if (decoded.productId !== input.body.productId) {
    return {
      verified: false,
      premiumUntil: null,
      reason: "product_id_mismatch",
    };
  }

  // 3. Cross-check transactionId (string compare preserves UInt64 precision).
  if (String(decoded.transactionId) !== txIdStr) {
    return {
      verified: false,
      premiumUntil: null,
      reason: "transaction_id_mismatch",
    };
  }

  // 4. Replay defence + idempotent short-circuit.
  const existing = await input.deps.db.findByTransactionId(txIdStr);
  if (existing) {
    if (existing.userId !== input.userId) {
      return {
        verified: false,
        premiumUntil: null,
        reason: "replay_detected",
      };
    }
    // Idempotent same-user replay: return persisted state without re-upsert.
    return {
      verified: true,
      premiumUntil: Math.floor(existing.currentPeriodEnd / 1000),
      reason: null,
    };
  }

  // 5. Upsert + return decoded expiry as seconds-since-1970.
  // TODO §7.4: defense-in-depth Apple S2S GetTransactionInfo call here.
  // Daily reconciliation cron covers the catch-up gap until that lands.
  await input.deps.db.upsertSubscription({
    appleTransactionId: txIdStr,
    appleOriginalTransactionId: String(decoded.originalTransactionId),
    userId: input.userId,
    productId: decoded.productId,
    status: "active",
    currentPeriodEnd: new Date(decoded.expiresDate),
    environment: decoded.environment,
  });

  return {
    verified: true,
    premiumUntil: Math.floor(decoded.expiresDate / 1000),
    reason: null,
  };
}

// ─── Hono route mount (production wiring) ─────────────────────────────────

/**
 * Register `POST /api/billing/verify-receipt` on the worker app behind
 * `requireAuth`. Called once at startup from `src/index.ts`.
 *
 * The handler wires real `verifyAppleJWS` + a Drizzle-backed `db` adapter,
 * then delegates to the pure `handleVerifyReceipt` above.
 */
export function registerVerifyReceiptRoute(
  app: Hono<{
    Bindings: Env;
    Variables: { userId: string };
  }>,
  requireAuth: MiddlewareHandler,
): void {
  app.post("/api/billing/verify-receipt", requireAuth, async (c) => {
    const raw = await c.req.json().catch(() => null);
    const parsed = RequestSchema.safeParse(raw);
    if (!parsed.success) {
      return c.json({ error: "bad_request" }, 400);
    }

    const db = createDb(c.env.DB);
    const deps: VerifyReceiptDeps = {
      verifyJws: async (jws) => {
        const payload = await verifyAppleJWS<{
          productId: string;
          transactionId: number | string;
          originalTransactionId: number | string;
          expiresDate: number;
          environment: "Sandbox" | "Production";
        }>(jws);
        return {
          productId: payload.productId,
          transactionId: String(payload.transactionId),
          originalTransactionId: String(payload.originalTransactionId),
          expiresDate: payload.expiresDate,
          environment: payload.environment,
        };
      },
      db: {
        findByTransactionId: async (txId) => {
          const row = await db
            .select()
            .from(appleSubscriptions)
            .where(eq(appleSubscriptions.appleTransactionId, txId))
            .get();
          if (!row) return null;
          return {
            appleTransactionId: row.appleTransactionId,
            userId: row.userId,
            // currentPeriodEnd is a Date (timestamp_ms mode) — convert to
            // ms-epoch for the DI contract.
            currentPeriodEnd: row.currentPeriodEnd.getTime(),
          };
        },
        upsertSubscription: async (row) => {
          // D1/SQLite ON CONFLICT DO UPDATE keyed on apple_transaction_id PK.
          await db
            .insert(appleSubscriptions)
            .values({
              appleTransactionId: row.appleTransactionId,
              appleOriginalTransactionId: row.appleOriginalTransactionId,
              userId: row.userId,
              productId: row.productId,
              status: row.status,
              currentPeriodEnd: row.currentPeriodEnd,
              environment: row.environment,
            })
            .onConflictDoUpdate({
              target: appleSubscriptions.appleTransactionId,
              set: {
                currentPeriodEnd: row.currentPeriodEnd,
                status: row.status,
                updatedAt: new Date(),
              },
            })
            .run();
        },
      },
    };

    const result = await handleVerifyReceipt({
      deps,
      userId: c.get("userId"),
      body: parsed.data,
    });
    return c.json(result, 200);
  });
}

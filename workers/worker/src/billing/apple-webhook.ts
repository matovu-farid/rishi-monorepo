import { z } from "zod";
import { and, desc, eq, lt, ne, sql } from "drizzle-orm";
import type { Hono } from "hono";
import { verifyAppleJWS, JWSInvalid } from "./jws-verify";
import { createApnsSender, type ApnsSender } from "./apns";
import {
  appleSubscriptions,
  appleNotificationsLog,
  devices as devicesTable,
  retainedAppleTransaction,
  retainedAppleEntitlement,
  restoredAppleEntitlement,
  deletionState,
} from "../db/schema";
import { createDb } from "../db/drizzle";
import {
  hashAppleOriginalTransactionCandidates,
  hashAppleOriginalTransaction,
  type AppleTransactionHashSecrets,
  type HashedAppleTransaction,
} from "../entitlement-retention";
// NOTE: type-only import — runtime import would form an ESM cycle with
// src/index.ts via the route mount (same constraint as 14-04). The webhook
// has NO requireAuth — Apple posts unauthenticated; trust is the JWS chain.


// ─── Wire types ────────────────────────────────────────────────────────────

/**
 * Outer envelope decoded from the ASSN V2 `signedPayload` JWS.
 * Subset of Apple's `responseBodyV2DecodedPayload` — only the fields the
 * dispatcher consumes. `version` MUST equal "2.0" (RESEARCH Pitfall 14:
 * Apple has historically shipped breaking-change major versions; reject
 * anything else so a silent migration doesn't corrupt state).
 */
export interface AppleNotificationEnvelope {
  notificationType: string;
  subtype?: string;
  notificationUUID: string;
  version: string;
  signedDate?: number;
  data: {
    bundleId: string;
    environment: "Sandbox" | "Production";
    // Optional: Apple's `TEST` notification (and any future non-
    // transactional notification type) does NOT include an inner
    // transaction JWS. Handler must skip the inner verify + dispatch
    // when this field is absent — see step 3 below.
    signedTransactionInfo?: string;
    signedRenewalInfo?: string;
  };
}

/**
 * Inner JWS payload decoded from `data.signedTransactionInfo`.
 * `transactionId` / `originalTransactionId` are stringified UInt64
 * (Pitfall 2 — Apple values overflow JS Number.MAX_SAFE_INTEGER).
 * `expiresDate` is ms-since-1970 (Pitfall 5 — Apple's native unit).
 */
export interface AppleTransactionPayload {
  productId: string;
  transactionId: string;
  originalTransactionId: string;
  expiresDate: number;
  environment: "Sandbox" | "Production";
}

// ─── DI surface ────────────────────────────────────────────────────────────

export interface AppleWebhookDeps {
  verifyJws: (jws: string) => Promise<any>;
  transactionHashSecrets?: AppleTransactionHashSecrets;
  db: {
    /**
     * Insert a notification log row keyed on `notificationUuid` PK.
     * D1 INSERT ... ON CONFLICT DO NOTHING returns 0 changes when a row
     * with the same PK already exists (RESEARCH Pitfall 3 — insert-and-
     * catch is atomic; SELECT-then-INSERT has a race window).
     */
    insertLog(row: {
      notificationUuid: string;
      notificationType: string;
      subtype: string | null;
      userId: string | null;
      appleTransactionId: string | null;
      rawPayload: string;
    }): Promise<{ inserted: boolean; existingProcessingError?: string | null }>;
    markLogProcessed(
      notificationUuid: string,
      err: string | null,
    ): Promise<void>;
    upsertSub(row: {
      appleTransactionId: string;
      appleOriginalTransactionId: string;
      userId: string;
      productId: string;
      status: "active" | "in_grace" | "expired" | "refunded";
      currentPeriodEnd: Date;
      environment: "Sandbox" | "Production";
      eventAt?: number;
    }): Promise<{ updated: boolean } | void>;
    updateSubStatus(
      appleTransactionId: string,
      patch: {
        status: "active" | "in_grace" | "expired" | "refunded";
        currentPeriodEnd: Date;
        eventAt?: number;
      },
    ): Promise<{ updated: boolean } | void>;
    /**
     * Resolve the owning userId for a subscription from a prior row keyed on
     * `appleOriginalTransactionId` (populated by /verify-receipt with the
     * real userId). Returns null when no non-empty-userId row exists yet —
     * e.g. a brand-new purchase whose verify-receipt call hasn't landed.
     */
    findUserIdByOriginalTransactionId(
      originalTransactionId: string,
    ): Promise<string | null>;
    /**
     * All devices registered for a user, for silent-push fan-out. Returns
     * the minimal shape APNs needs (token + topic + env). Empty when the
     * user has no registered devices.
     */
    findDevicesByUserId(
      userId: string,
    ): Promise<Array<{ deviceToken: string; topic: string; env: string }>>;
    isStaleEvent?(input: {
      transactionId: string;
      originalTransactionId: string;
      environment: "Sandbox" | "Production";
      eventAt: number;
    }): Promise<boolean>;
    resolveAppleTransaction?(originalTransactionId: string, environment: "Sandbox" | "Production"): Promise<{
      transactionHashVersion: number;
      originalTransactionHash: string;
      identityHashVersion: number;
      identityHash: string;
      retentionExpiresAt: Date;
    } | null>;
    reconcileRetainedTransaction?(row: {
      identityHashVersion: number;
      identityHash: string;
      transactionHashVersion: number;
      originalTransactionHash: string;
      feature: "reader" | "voice";
      environment: "Sandbox" | "Production";
      lastEventAt: number;
      status: "active" | "in_grace" | "expired" | "refunded";
      periodEnd: Date | null;
      retentionExpiresAt: Date;
      updatedAt: Date;
      eventAt: number;
      monotonic: true;
    }): Promise<{ updated: boolean } | void>;
    upsertRestoredEntitlement?(row: {
      userId: string;
      identityHashVersion: number;
      identityHash: string;
      transactionHashVersion: number;
      environment: "Sandbox" | "Production";
      originalTransactionHash: string;
      feature: "reader" | "voice";
      status: "active" | "in_grace" | "expired" | "refunded";
      periodEnd: Date | null;
      updatedAt: Date;
    }): Promise<{ updated: boolean } | void>;
    updateLiveLedger?(input: {
      userId: string;
      feature: "reader" | "voice";
      status: "active" | "in_grace" | "expired" | "refunded";
      periodEnd: Date | null;
      eventAt: number;
    }): Promise<void>;
  };
  /**
   * APNs silent-push sender, or null when APNs credentials
   * (APPLE_APNS_KEY_P8 / APPLE_APNS_KEY_ID / APPLE_TEAM_ID) are not
   * provisioned. When null the REFUND/REVOKE path skips the push and logs a
   * warning — entitlement still flips on the device's next foreground pull.
   */
  apns: ApnsSender | null;
}

const BodySchema = z.object({ signedPayload: z.string().min(10) });

export interface WebhookInput {
  deps: AppleWebhookDeps;
  signedPayload: string;
}

export interface WebhookResult {
  status: 200 | 400 | 500;
  body: { ok: true } | { error: string };
}

// ─── Pure handler ──────────────────────────────────────────────────────────

/**
 * Verify an Apple ASSN V2 webhook, log idempotently, and dispatch by
 * `notificationType`. Pure function over `AppleWebhookDeps` — Vitest
 * substitutes stubs; production wiring is in `registerAppleWebhookRoute`.
 *
 * Algorithm (RESEARCH §5):
 *   1. Verify outer JWS signature (rejects bad chain / forged leaf).
 *   2. Guard `version === "2.0"` and `bundleId === "org.fidexa.rishi"`.
 *   3. If `data.signedTransactionInfo` is present, verify it as an inner
 *      JWS. Apple's `TEST` notification (sent by
 *      `POST /inApps/v1/notifications/test`) omits this field — and any
 *      future non-transactional type may too. Without an inner JWS we
 *      skip dispatch entirely and fall through to log-only handling.
 *   4. Atomic INSERT ... ON CONFLICT DO NOTHING on the log row keyed by
 *      notificationUUID. If duplicate, ACK 200 immediately — Apple is
 *      retrying a notification we've already processed. When there is no
 *      inner transaction, `appleTransactionId` is logged as null so the
 *      row still exists for verification / audit queries.
 *   5. Dispatch by notificationType per RESEARCH §5.3 table — only when
 *      a verified transaction payload is available. TEST and any other
 *      transaction-less type take the dispatcher's unknown / log-only
 *      branch (no Apple redelivery on 200).
 *   6. Mark the log row processed (or record the error and still ACK 200
 *      so Apple stops retrying; reconciliation cron catches the catch-up).
 *
 * Webhook has NO Better Auth gate — Apple does not authenticate; trust
 * derives from the verified JWS chain.
 */
export async function handleAppleWebhook(
  input: WebhookInput,
): Promise<WebhookResult> {
  // 1. Verify outer envelope JWS.
  let envelope: AppleNotificationEnvelope;
  try {
    envelope = await input.deps.verifyJws(input.signedPayload);
  } catch (e) {
    if (e instanceof JWSInvalid) {
      return { status: 400, body: { error: "invalid signature" } };
    }
    throw e;
  }

  // 2. Envelope guards (Pitfall 14).
  if (envelope.version !== "2.0") {
    return { status: 400, body: { error: "unsupported version" } };
  }
  if (envelope.data?.bundleId !== "org.fidexa.rishi") {
    return { status: 400, body: { error: "wrong bundleId" } };
  }

  // 3. Verify inner transaction JWS — but only when one is present.
  // Apple's TEST notification (delivered by
  // `POST /inApps/v1/notifications/test`) carries NO signedTransactionInfo
  // and NO signedRenewalInfo. Treating its absence as an error would
  // return non-2xx and trip `UNSUCCESSFUL_HTTP_RESPONSE_CODE` in Apple's
  // diagnostics UI — exactly the bug this fix lands. The same fall-
  // through covers any future non-transactional notificationType.
  let tx: AppleTransactionPayload | null = null;
  if (envelope.data.signedTransactionInfo) {
    try {
      tx = await input.deps.verifyJws(envelope.data.signedTransactionInfo);
    } catch (e) {
      if (e instanceof JWSInvalid) {
        return { status: 400, body: { error: "invalid signature" } };
      }
      throw e;
    }
  }

  // signedRenewalInfo is decoded by the dispatch table on demand — only
  // DID_CHANGE_RENEWAL_STATUS reads it today. Skipped in the hot path so
  // an absent renewal info doesn't fault non-renewal notification types.

  const txIdStr = tx ? String(tx.transactionId) : null;
  const loggedTransactionId = tx && input.deps.transactionHashSecrets
    ? (await hashAppleOriginalTransaction(String(tx.originalTransactionId), input.deps.transactionHashSecrets.current)).originalTransactionHash
    : null;
  const eventAt = Number(envelope.signedDate ?? Date.now());

  // 4. Idempotent log insert (Pitfall 3 — atomic insert-and-catch).
  // For TEST / transaction-less notifications, appleTransactionId is null
  // but the row still lands so verification queries can confirm receipt.
  const insertResult = await input.deps.db.insertLog({
    notificationUuid: envelope.notificationUUID,
    notificationType: envelope.notificationType,
    subtype: envelope.subtype ?? null,
    userId: null,
    // This log is inserted before the owner can be resolved. Never persist a
    // raw Apple identifier or signed payload in the ownerless path; retained
    // entitlement history uses versioned HMACs instead.
    // This legacy column carries a versioned HMAC when a transaction exists;
    // it is never populated with Apple's raw identifier. That gives the
    // bounded replay/redaction job a stable lookup key without retaining PII.
    appleTransactionId: loggedTransactionId,
    rawPayload: JSON.stringify({
      notificationUUID: envelope.notificationUUID,
      notificationType: envelope.notificationType,
      subtype: envelope.subtype ?? null,
      environment: envelope.data.environment,
      signedDate: eventAt,
      hasTransaction: Boolean(txIdStr),
    }),
  });
  if (!insertResult.inserted && !insertResult.existingProcessingError) {
    // Duplicate UUID — Apple retry. Already processed; ACK 200 with no
    // further side effects.
    return { status: 200, body: { ok: true } };
  }

  // 5. Dispatch by notificationType (RESEARCH §5.3 table). Only when a
  // verified transaction payload is available — TEST and any other
  // transaction-less type take the dispatcher's log-only / unknown
  // branch (already logged above; ACK 200 means Apple will not redeliver).
  if (tx) {
    try {
      if (await input.deps.db.isStaleEvent?.({
        transactionId: txIdStr!,
        originalTransactionId: String(tx.originalTransactionId),
        environment: tx.environment,
        eventAt,
      })) {
        await input.deps.db.markLogProcessed(envelope.notificationUUID, null);
        return { status: 200, body: { ok: true } };
      }
      await dispatch(envelope, tx, input.deps, eventAt);
      await input.deps.db.markLogProcessed(envelope.notificationUUID, null);
    } catch (e) {
      await input.deps.db.markLogProcessed(
        envelope.notificationUUID,
        String(e),
      );
      // Return a non-2xx response so Apple retries. A duplicate notification
      // with an existing processing error is allowed back through above.
      return { status: 500, body: { error: "temporary dispatch failure" } };
    }
  } else {
    await input.deps.db.markLogProcessed(envelope.notificationUUID, null);
  }
  return { status: 200, body: { ok: true } };
}

/**
 * Notification → subscription side-effect dispatcher.
 * Table (RESEARCH §5.3 + WORKER-CONTRACT-IAP.md §2.3):
 *
 *   SUBSCRIBED                          -> upsert active row
 *   DID_RENEW                           -> upsert active row w/ new expiry
 *   DID_FAIL_TO_RENEW (GRACE_PERIOD)    -> status=in_grace
 *   DID_FAIL_TO_RENEW (other subtypes)  -> status=expired
 *   GRACE_PERIOD_EXPIRED / EXPIRED      -> status=expired
 *   REFUND / REVOKE                     -> status=refunded, currentPeriodEnd=now
 *   DID_CHANGE_RENEWAL_STATUS           -> log only; entitlement unchanged
 *   <unknown>                           -> log only; no-op (no Apple redelivery on 200)
 */
async function dispatch(
  envelope: AppleNotificationEnvelope,
  tx: AppleTransactionPayload,
  deps: AppleWebhookDeps,
  eventAt: number,
): Promise<void> {
  const txIdStr = String(tx.transactionId);
  const origIdStr = String(tx.originalTransactionId);
  const expires = new Date(tx.expiresDate);
  const feature: "reader" | "voice" = tx.productId.toLowerCase().includes("voice") ? "voice" : "reader";
  const resolvedUserId = await deps.db.findUserIdByOriginalTransactionId(origIdStr);
  const liveUserId = resolvedUserId;
  const retentionEnabled = Boolean(deps.transactionHashSecrets && deps.db.resolveAppleTransaction);

  const reconcile = async (status: "active" | "in_grace" | "expired" | "refunded", periodEnd: Date | null) => {
    const retained = await deps.db.resolveAppleTransaction?.(origIdStr, tx.environment);
    if (!retained || !deps.transactionHashSecrets) return;
    const row = {
      ...retained,
      feature,
      environment: tx.environment,
      lastEventAt: eventAt,
      status,
      periodEnd,
      updatedAt: new Date(eventAt),
      eventAt,
      monotonic: true as const,
    };
    if (!resolvedUserId) {
      await deps.db.reconcileRetainedTransaction?.(row);
      return;
    }
    await deps.db.upsertRestoredEntitlement?.({ userId: resolvedUserId, ...row });
    await deps.db.updateLiveLedger?.({ userId: resolvedUserId, feature, status, periodEnd, eventAt });
  };

  if (!resolvedUserId && retentionEnabled) {
    switch (envelope.notificationType) {
      case "SUBSCRIBED":
      case "DID_RENEW":
        await reconcile("active", expires);
        return;
      case "DID_FAIL_TO_RENEW":
        await reconcile(
          envelope.subtype === "GRACE_PERIOD" ? "in_grace" : "expired",
          expires,
        );
        return;
      case "GRACE_PERIOD_EXPIRED":
      case "EXPIRED":
        await reconcile("expired", expires);
        return;
      case "REFUND":
      case "REVOKE":
        await reconcile("refunded", null);
        return;
      default:
        return;
    }
  }

  switch (envelope.notificationType) {
    case "SUBSCRIBED":
    case "DID_RENEW": {
      // Recover the owning user from a prior /verify-receipt row keyed on the
      // ORIGINAL transaction id (renewals share it). When found, the
      // notification-written row attaches to the real user instead of an
      // ownerless placeholder.
      // When null (brand-new purchase whose verify-receipt hasn't arrived
      // yet), keep the verified notification log only. A subscription row
      // without an owner is invalid because userId is the entitlement owner
      // and a later notification can reconcile after ownership is known.
      const resolvedUserId =
        await deps.db.findUserIdByOriginalTransactionId(origIdStr);
      if (!resolvedUserId) {
        console.log(`[apple-webhook] ${envelope.notificationType}: verified notification logged without resolved owner`);
        return;
      }
      await deps.db.upsertSub({
        appleTransactionId: txIdStr,
        appleOriginalTransactionId: origIdStr,
        userId: resolvedUserId,
        productId: tx.productId,
        status: "active",
        currentPeriodEnd: expires,
        environment: tx.environment,
        eventAt,
      });
      await reconcile("active", expires);
      break;
    }
    case "DID_FAIL_TO_RENEW":
      if (envelope.subtype === "GRACE_PERIOD") {
        if (liveUserId || !retentionEnabled) await deps.db.updateSubStatus(txIdStr, { status: "in_grace", currentPeriodEnd: expires, eventAt });
        await reconcile("in_grace", expires);
      } else {
        if (liveUserId || !retentionEnabled) await deps.db.updateSubStatus(txIdStr, { status: "expired", currentPeriodEnd: expires, eventAt });
        await reconcile("expired", expires);
      }
      break;
    case "GRACE_PERIOD_EXPIRED":
    case "EXPIRED":
      if (liveUserId || !retentionEnabled) await deps.db.updateSubStatus(txIdStr, { status: "expired", currentPeriodEnd: expires, eventAt });
      await reconcile("expired", expires);
      break;
    case "REFUND":
    case "REVOKE": {
      if (liveUserId || !retentionEnabled) await deps.db.updateSubStatus(txIdStr, { status: "refunded", currentPeriodEnd: new Date(), eventAt });
      await reconcile("refunded", null);
      // Emit a silent push to every registered device so the app's
      // EntitlementReconciler invalidates immediately rather than waiting
      // for the next launch/foreground pull. Best-effort: a push failure
      // must NEVER change the webhook response — Apple still gets HTTP 200.
      await emitEntitlementChangedPush(origIdStr, deps);
      break;
    }
    case "DID_CHANGE_RENEWAL_STATUS":
      // autoRenew flag flip only — does NOT change entitlement state.
      // Already logged by the insertLog call above; nothing else.
      break;
    default:
      // Unknown notificationType — log only (already logged above).
      // ACK 200 means Apple will NOT redeliver; that's the intended
      // contract for forward-compat with new notification types.
      break;
  }
}

/**
 * Resolve the owning user from the original transaction id and fan out a
 * `entitlement.changed` silent push to all of their devices.
 *
 * Strictly best-effort:
 *   - No resolvable userId  -> log + return (no device lookup, no send).
 *   - apns not configured    -> log a warn + return (push skipped).
 *   - Per-device send fails  -> log + continue to the next device.
 * The caller's webhook response is unaffected; Apple always gets HTTP 200.
 */
async function emitEntitlementChangedPush(
  originalTransactionId: string,
  deps: AppleWebhookDeps,
): Promise<void> {
  const userId =
    (await deps.db.findUserIdByOriginalTransactionId(originalTransactionId)) ??
    "";
  if (!userId) {
    console.log(
      "[apple-webhook] REFUND/REVOKE: no resolvable userId; skipping push",
    );
    return;
  }
  if (!deps.apns) {
    console.warn(
      "[apple-webhook] REFUND/REVOKE: APNs not configured; skipping silent push",
    );
    return;
  }
  const apns = deps.apns;
  const userDevices = await deps.db.findDevicesByUserId(userId);
  if (userDevices.length === 0) {
    console.log(
      `[apple-webhook] REFUND/REVOKE: user ${userId} has no devices; skipping push`,
    );
    return;
  }
  const payload = { rishi: { kind: "entitlement.changed" } };
  for (const d of userDevices) {
    try {
      await apns.sendSilentPush({
        deviceToken: d.deviceToken,
        topic: d.topic,
        env: d.env,
        payload,
      });
    } catch (e) {
      // Best-effort: log and keep going. Failures do not affect the ACK.
      console.error(
        `[apple-webhook] silent push failed for device ${d.deviceToken}: ${String(e)}`,
      );
    }
  }
}

// ─── Hono route mount (production wiring) ─────────────────────────────────

/**
 * Register `POST /api/billing/apple-webhook` on the worker app. Called
 * once at startup from `src/index.ts`. NO requireAuth middleware — Apple
 * posts unauthenticated; the JWS chain is the trust path.
 */
export function registerAppleWebhookRoute(
  app: Hono<{
    Bindings: Env;
    Variables: { userId: string };
  }>,
): void {
  app.post("/api/billing/apple-webhook", async (c) => {
    const raw = await c.req.json().catch(() => null);
    const parsed = BodySchema.safeParse(raw);
    if (!parsed.success) {
      return c.json({ error: "bad_request" }, 400);
    }

    const db = createDb(c.env.DB);

    // Build the real APNs sender only when all three credentials are
    // provisioned. When any is missing, pass null and the REFUND/REVOKE
    // path logs a warning and skips the silent push (entitlement still
    // reconciles on the device's next foreground pull).
    const envWithRetention = c.env as Env & {
      APPLE_APNS_KEY_P8?: string;
      APPLE_APNS_KEY_ID?: string;
      APPLE_TRANSACTION_HASH_SECRET?: string;
      APPLE_TRANSACTION_HASH_SECRET_PREVIOUS?: string;
    };
    const apnsKeyP8 = envWithRetention.APPLE_APNS_KEY_P8;
    const apnsKeyId = envWithRetention.APPLE_APNS_KEY_ID;
    const apnsTeamId = c.env.APPLE_TEAM_ID;
    const apns: ApnsSender | null =
      apnsKeyP8 && apnsKeyId && apnsTeamId
        ? createApnsSender({
            keyP8: apnsKeyP8,
            keyId: apnsKeyId,
            teamId: apnsTeamId,
          })
        : null;

    const retentionSecrets = envWithRetention.APPLE_TRANSACTION_HASH_SECRET
      ? { current: envWithRetention.APPLE_TRANSACTION_HASH_SECRET, previous: envWithRetention.APPLE_TRANSACTION_HASH_SECRET_PREVIOUS }
      : undefined;
    const deps: AppleWebhookDeps = {
      verifyJws: (jws) => verifyAppleJWS<any>(jws),
      apns,
      transactionHashSecrets: retentionSecrets,
      db: {
        insertLog: async (row) => {
          // D1 ON CONFLICT DO NOTHING — atomic dedupe on notificationUuid PK.
          const result = await db
            .insert(appleNotificationsLog)
            .values({
              notificationUuid: row.notificationUuid,
              notificationType: row.notificationType,
              subtype: row.subtype,
              userId: row.userId,
              appleTransactionId: row.appleTransactionId,
              rawPayload: row.rawPayload,
            })
            .onConflictDoNothing({
              target: appleNotificationsLog.notificationUuid,
            })
            .run();
          // D1's `meta.changes` is the canonical "row inserted?" signal.
          // Drizzle d1 wraps this on the result object.
          const changes = (result as any)?.meta?.changes ?? 0;
          if (changes > 0) return { inserted: true };
          const existing = await db.select({ processingError: appleNotificationsLog.processingError })
            .from(appleNotificationsLog)
            .where(eq(appleNotificationsLog.notificationUuid, row.notificationUuid)).get();
          return { inserted: false, existingProcessingError: existing?.processingError ?? null };
        },
        markLogProcessed: async (uuid, err) => {
          await db
            .update(appleNotificationsLog)
            .set({ processedAt: new Date(), processingError: err })
            .where(eq(appleNotificationsLog.notificationUuid, uuid))
            .run();
        },
        upsertSub: async (row) => {
          const deleting = await db.select({ userId: deletionState.userId }).from(deletionState).where(eq(deletionState.userId, row.userId)).get();
          if (deleting) throw new Error("account deletion pending");
          const eventDate = new Date(row.eventAt ?? Date.now());
          const current = await db.select({ updatedAt: appleSubscriptions.updatedAt }).from(appleSubscriptions).where(eq(appleSubscriptions.appleTransactionId, row.appleTransactionId)).get();
          if (current && current.updatedAt.getTime() >= eventDate.getTime()) return { updated: false };
          await db
            .insert(appleSubscriptions)
            .values(row)
            .onConflictDoUpdate({
              target: appleSubscriptions.appleTransactionId,
              set: {
                status: row.status,
                currentPeriodEnd: row.currentPeriodEnd,
                updatedAt: eventDate,
              },
            })
            .run();
        },
        updateSubStatus: async (txId, patch) => {
          const owner = await db.select({ userId: appleSubscriptions.userId }).from(appleSubscriptions).where(eq(appleSubscriptions.appleTransactionId, txId)).get();
          if (owner && await db.select({ userId: deletionState.userId }).from(deletionState).where(eq(deletionState.userId, owner.userId)).get()) throw new Error("account deletion pending");
          const eventDate = new Date(patch.eventAt ?? Date.now());
          const current = await db.select({ updatedAt: appleSubscriptions.updatedAt }).from(appleSubscriptions).where(eq(appleSubscriptions.appleTransactionId, txId)).get();
          if (current && current.updatedAt.getTime() >= eventDate.getTime()) return { updated: false };
          await db
            .update(appleSubscriptions)
            .set({
              status: patch.status,
              currentPeriodEnd: patch.currentPeriodEnd,
              updatedAt: eventDate,
            })
            .where(eq(appleSubscriptions.appleTransactionId, txId))
            .run();
        },
        findUserIdByOriginalTransactionId: async (originalTransactionId) => {
          // Resolve via the apple_subscriptions_original_txn index. Filter
          // out empty userIds so we never "resolve" to another placeholder
          // row; newest wins.
          const row = await db
            .select({ userId: appleSubscriptions.userId })
            .from(appleSubscriptions)
            .where(
              and(
                eq(
                  appleSubscriptions.appleOriginalTransactionId,
                  originalTransactionId,
                ),
                ne(appleSubscriptions.userId, ""),
              ),
            )
            .orderBy(desc(appleSubscriptions.updatedAt))
            .get();
          return row?.userId ?? null;
        },
        findDevicesByUserId: async (userId) => {
          const rows = await db
            .select({
              deviceToken: devicesTable.deviceToken,
              topic: devicesTable.topic,
              env: devicesTable.env,
            })
            .from(devicesTable)
            .where(eq(devicesTable.userId, userId))
            .all();
          return rows;
        },
        isStaleEvent: async ({ originalTransactionId, environment, eventAt }) => {
          if (!retentionSecrets) return false;
          const candidates = await hashAppleOriginalTransactionCandidates(originalTransactionId, retentionSecrets);
          for (const candidate of candidates) {
            const row = await db.select({ lastEventAt: retainedAppleTransaction.lastEventAt })
              .from(retainedAppleTransaction)
              .where(and(
                eq(retainedAppleTransaction.transactionHashVersion, candidate.transactionHashVersion),
                eq(retainedAppleTransaction.originalTransactionHash, candidate.originalTransactionHash),
                eq(retainedAppleTransaction.environment, environment),
              )).get();
            if (row && row.lastEventAt.getTime() >= eventAt) return true;
          }
          return false;
        },
        resolveAppleTransaction: async (originalTransactionId, environment) => {
          if (!retentionSecrets) return null;
          const candidates = await hashAppleOriginalTransactionCandidates(originalTransactionId, retentionSecrets);
          for (const candidate of candidates) {
            const row = await db.select({
              transactionHashVersion: retainedAppleTransaction.transactionHashVersion,
              originalTransactionHash: retainedAppleTransaction.originalTransactionHash,
              identityHashVersion: retainedAppleTransaction.identityHashVersion,
              identityHash: retainedAppleTransaction.identityHash,
              retentionExpiresAt: retainedAppleTransaction.retentionExpiresAt,
            }).from(retainedAppleTransaction).where(and(
              eq(retainedAppleTransaction.transactionHashVersion, candidate.transactionHashVersion),
              eq(retainedAppleTransaction.originalTransactionHash, candidate.originalTransactionHash),
              eq(retainedAppleTransaction.environment, environment),
            )).get();
            if (row) return row;
          }
          return null;
        },
        reconcileRetainedTransaction: async (row) => {
          const eventDate = new Date(row.eventAt);
          const changed = await db.update(retainedAppleTransaction).set({
            identityHashVersion: row.identityHashVersion,
            identityHash: row.identityHash,
            feature: row.feature,
            status: row.status,
            periodEnd: row.periodEnd,
            lastEventAt: eventDate,
            updatedAt: row.updatedAt,
          }).where(and(
            eq(retainedAppleTransaction.transactionHashVersion, row.transactionHashVersion),
            eq(retainedAppleTransaction.originalTransactionHash, row.originalTransactionHash),
            eq(retainedAppleTransaction.environment, row.environment),
            lt(retainedAppleTransaction.lastEventAt, eventDate),
          )).run();
          const transactions = await db.select().from(retainedAppleTransaction).where(and(
            eq(retainedAppleTransaction.identityHashVersion, row.identityHashVersion),
            eq(retainedAppleTransaction.identityHash, row.identityHash),
          )).all();
          const summarize = (feature: "reader" | "voice") => {
            const rows = transactions.filter((transaction) => transaction.feature === feature);
            const active = rows.filter((transaction) => (transaction.status === "active" || transaction.status === "in_grace") && transaction.periodEnd && transaction.periodEnd.getTime() > Date.now());
            const latest = [...rows].sort((a, b) => b.lastEventAt.getTime() - a.lastEventAt.getTime())[0];
            return {
              activeUntil: active.reduce<Date | null>((max, transaction) => !max || !transaction.periodEnd || transaction.periodEnd > max ? transaction.periodEnd : max, null),
              status: active[0]?.status ?? latest?.status ?? null,
            };
          };
          const reader = summarize("reader");
          const voice = summarize("voice");
          await db.update(retainedAppleEntitlement).set({
            readerActiveUntil: reader.activeUntil,
            readerStatus: reader.status,
            voiceActiveUntil: voice.activeUntil,
            voiceStatus: voice.status,
            updatedAt: eventDate,
          }).where(and(
            eq(retainedAppleEntitlement.identityHashVersion, row.identityHashVersion),
            eq(retainedAppleEntitlement.identityHash, row.identityHash),
          )).run();
          return { updated: ((changed as any)?.meta?.changes ?? 0) > 0 };
        },
        upsertRestoredEntitlement: async (row) => {
          if (await db.select({ userId: deletionState.userId }).from(deletionState).where(eq(deletionState.userId, row.userId)).get()) throw new Error("account deletion pending");
          await db.insert(restoredAppleEntitlement).values(row).onConflictDoUpdate({
            target: [restoredAppleEntitlement.userId, restoredAppleEntitlement.transactionHashVersion, restoredAppleEntitlement.environment, restoredAppleEntitlement.originalTransactionHash],
            set: { status: row.status, periodEnd: row.periodEnd, feature: row.feature, updatedAt: row.updatedAt },
          }).run();
        },
        updateLiveLedger: async ({ userId, feature, status, periodEnd }) => {
          if (await db.select({ userId: deletionState.userId }).from(deletionState).where(eq(deletionState.userId, userId)).get()) throw new Error("account deletion pending");
          const ledgerEnv = c.env as Env & { USER_USAGE_LEDGER: { getByName(name: string): { reconcileFeatureEntitlement(input: { feature: "reader" | "voice"; status: "active" | "in_grace" | "expired" | "refunded"; periodEnd: number | null }): Promise<void> } } };
          await ledgerEnv.USER_USAGE_LEDGER.getByName(userId).reconcileFeatureEntitlement({ feature, status, periodEnd: periodEnd?.getTime() ?? null });
        },
      },
    };

    const { status, body } = await handleAppleWebhook({
      deps,
      signedPayload: parsed.data.signedPayload,
    });
    return c.json(body, status);
  });
}

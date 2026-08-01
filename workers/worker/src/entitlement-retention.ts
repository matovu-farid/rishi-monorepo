import type {
  NewRetainedAppleEntitlement,
  NewRetainedAppleTransaction,
  RetainedAppleEntitlement,
  RetainedAppleTransaction,
} from "./db/schema";
import { appleNotificationsLog, retainedAppleEntitlement, retainedAppleTransaction } from "./db/schema";
import { and, eq, isNull, lt } from "drizzle-orm";
import type { WorkerDb } from "./db/drizzle";

export const IDENTITY_HASH_VERSION = 1;
export const TRANSACTION_HASH_VERSION = 1;
export const TRANSACTION_HASH_VERSION_PREVIOUS = 0;

export type RetainedTrialState = "never_granted" | "active" | "exhausted";
export type AppleFeature = "reader" | "voice";
export type AppleStatus = "active" | "in_grace" | "expired" | "refunded";

export interface EntitlementRetentionSnapshot {
  trialState: RetainedTrialState;
  trialInitialCredits: number;
  trialUsedCredits: number;
  reader: { total: number; used: number; activeUntil: number | null; status: AppleStatus | null };
  voice: { total: number; used: number; activeUntil: number | null; status: AppleStatus | null };
  transactions: Array<{
    originalTransactionId: string;
    feature: AppleFeature;
    environment: "Sandbox" | "Production";
    lastEventAt: number;
    status: AppleStatus;
    periodEnd: number | null;
  }>;
  deletedAt: number;
}

export interface HashedEntitlementIdentity {
  identityHashVersion: number;
  identityHash: string;
}

export interface HashedAppleTransaction {
  transactionHashVersion: number;
  originalTransactionHash: string;
}

export interface AppleTransactionHashSecrets {
  current: string;
  previous?: string;
}

function toBase64Url(bytes: ArrayBuffer): string {
  let binary = "";
  for (const byte of new Uint8Array(bytes)) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function hmac(secret: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return toBase64Url(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value)));
}

export async function hashAppleIdentity(subject: string, secret: string): Promise<HashedEntitlementIdentity> {
  if (!subject || !secret) throw new Error("Apple identity retention hashing requires subject and secret");
  return { identityHashVersion: IDENTITY_HASH_VERSION, identityHash: await hmac(secret, subject) };
}

export async function hashAppleOriginalTransaction(
  originalTransactionId: string,
  secret: string,
): Promise<HashedAppleTransaction> {
  if (!originalTransactionId || !secret) throw new Error("Apple transaction retention hashing requires identifier and secret");
  return {
    transactionHashVersion: TRANSACTION_HASH_VERSION,
    originalTransactionHash: await hmac(secret, originalTransactionId),
  };
}

/**
 * Return current-first HMAC candidates so a rotated secret can continue to
 * address retained rows created before rotation. New rows always use the
 * first candidate; callers may select the previous candidate when it already
 * owns the retained binding.
 */
export async function hashAppleOriginalTransactionCandidates(
  originalTransactionId: string,
  secrets: AppleTransactionHashSecrets,
): Promise<HashedAppleTransaction[]> {
  const current = await hashAppleOriginalTransaction(originalTransactionId, secrets.current);
  if (!secrets.previous) return [current];
  return [
    current,
    {
      transactionHashVersion: TRANSACTION_HASH_VERSION_PREVIOUS,
      originalTransactionHash: await hmac(secrets.previous, originalTransactionId),
    },
  ];
}

export function retentionExpiresAt(deletedAt: number, latestPaidPeriodEnd: number | null): number {
  const boundary = new Date(Math.max(deletedAt, latestPaidPeriodEnd ?? deletedAt));
  boundary.setUTCMonth(boundary.getUTCMonth() + 24);
  return boundary.getTime();
}

export function mergeRetentionSnapshot(
  existing: RetainedAppleEntitlement | null,
  incoming: NewRetainedAppleEntitlement,
): NewRetainedAppleEntitlement {
  if (!existing) return { ...incoming };
  const dateMs = (value: Date | number | null | undefined): number =>
    value instanceof Date ? value.getTime() : value ?? 0;
  const maxReaderEnd = Math.max(dateMs(existing.readerActiveUntil), dateMs(incoming.readerActiveUntil));
  const maxVoiceEnd = Math.max(dateMs(existing.voiceActiveUntil), dateMs(incoming.voiceActiveUntil));
  return {
    ...incoming,
    trialState: existing.trialState === "exhausted" || incoming.trialState === "exhausted"
      ? "exhausted"
      : existing.trialState === "active" || incoming.trialState === "active" ? "active" : "never_granted",
    trialInitialCredits: Math.max(existing.trialInitialCredits, incoming.trialInitialCredits),
    trialUsedCredits: Math.max(existing.trialUsedCredits, incoming.trialUsedCredits),
    readerCreditsTotal: Math.max(existing.readerCreditsTotal, incoming.readerCreditsTotal),
    readerCreditsUsed: Math.max(existing.readerCreditsUsed, incoming.readerCreditsUsed),
    voiceCreditsTotal: Math.max(existing.voiceCreditsTotal, incoming.voiceCreditsTotal),
    voiceCreditsUsed: Math.max(existing.voiceCreditsUsed, incoming.voiceCreditsUsed),
    readerActiveUntil: maxReaderEnd ? new Date(maxReaderEnd) : null,
    voiceActiveUntil: maxVoiceEnd ? new Date(maxVoiceEnd) : null,
    deletedAt: new Date(Math.min(existing.deletedAt.getTime(), incoming.deletedAt instanceof Date ? incoming.deletedAt.getTime() : incoming.deletedAt)),
    retentionExpiresAt: new Date(Math.max(existing.retentionExpiresAt.getTime(), incoming.retentionExpiresAt instanceof Date ? incoming.retentionExpiresAt.getTime() : incoming.retentionExpiresAt)),
    updatedAt: new Date(Math.max(existing.updatedAt.getTime(), incoming.updatedAt instanceof Date ? incoming.updatedAt.getTime() : incoming.updatedAt)),
  };
}

export function isRestorableTransaction(row: Pick<RetainedAppleTransaction, "status" | "periodEnd">, now = Date.now()): boolean {
  return (row.status === "active" || row.status === "in_grace") && !!row.periodEnd && row.periodEnd.getTime() > now;
}

export function isExpiredRetention(row: Pick<RetainedAppleEntitlement, "retentionExpiresAt">, now = Date.now()): boolean {
  return row.retentionExpiresAt.getTime() <= now;
}

export function activeTransactionCount(rows: Array<Pick<RetainedAppleTransaction, "status" | "periodEnd">>, now = Date.now()): number {
  return rows.filter((row) => isRestorableTransaction(row, now)).length;
}

/** Delete at most `limit` expired retention rows per invocation. */
export async function purgeExpiredRetention(db: WorkerDb, now = new Date(), limit = 500): Promise<number> {
  const entitlements = await db.select({ identityHashVersion: retainedAppleEntitlement.identityHashVersion, identityHash: retainedAppleEntitlement.identityHash })
    .from(retainedAppleEntitlement)
    .where(lt(retainedAppleEntitlement.retentionExpiresAt, now))
    .limit(limit)
    .all();
  for (const row of entitlements) {
    await db.delete(retainedAppleTransaction).where(
      and(
        eq(retainedAppleTransaction.identityHashVersion, row.identityHashVersion),
        eq(retainedAppleTransaction.identityHash, row.identityHash),
      ),
    );
    await db.delete(retainedAppleEntitlement).where(
      and(
        eq(retainedAppleEntitlement.identityHashVersion, row.identityHashVersion),
        eq(retainedAppleEntitlement.identityHash, row.identityHash),
      ),
    );
  }
  return entitlements.length;
}

/** Remove raw identifiers from legacy ownerless webhook log rows. */
export async function redactOwnerlessAppleNotificationLogs(db: WorkerDb): Promise<void> {
  const rows = await db.select({ id: appleNotificationsLog.notificationUuid })
    .from(appleNotificationsLog)
    .where(isNull(appleNotificationsLog.userId))
    .limit(500)
    .all();
  for (const row of rows) {
    await db.update(appleNotificationsLog).set({
      appleTransactionId: null,
      rawPayload: JSON.stringify({ redacted: true, notificationUuid: row.id }),
    }).where(eq(appleNotificationsLog.notificationUuid, row.id));
  }
}

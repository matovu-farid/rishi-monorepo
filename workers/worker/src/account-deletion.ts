import { createHash, randomUUID } from "node:crypto";
import { and, asc, eq, exists, gt, inArray, lte, ne, notInArray, or } from "drizzle-orm";
import type { WorkerDb } from "./db/drizzle";
import {
  appleNotificationsLog,
  appleSubscriptions,
  appleUsers,
  books,
  deletionState,
  retainedAppleEntitlement,
  retainedAppleTransaction,
  sharePackages,
  sharePackageItems,
  sessionInviteRedemptions,
  sessionInvites,
  subscription,
  user,
  verification,
} from "./db/schema";
import { decryptSiwaRefreshToken } from "./siwa-token-crypto";
import { mintAppleClientSecret } from "./auth-apple-secret";
import { createStripeClient } from "./billing/stripe";
import { hashAppleIdentity, hashAppleOriginalTransaction, mergeRetentionSnapshot, retentionExpiresAt } from "./entitlement-retention";
import type { AccountEntitlementSnapshot } from "./durable-objects/user-usage-ledger/types";
import { deleteUnreferencedR2Objects, referencedR2Keys } from "./shares/shareReferences";
import { isSessionSharingServiceError, SessionSharingService } from "./session-sharing-service";

type DeletionStatus = "revoked" | "legacy_no_token" | "revocation_unavailable";

export interface AccountDeletionEnvironment {
  DB: D1Database;
  BOOK_STORAGE: R2Bucket;
  SHARING_WORKER?: { fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> };
  SHARING_INTERNAL_SECRET?: string;
  SIWA_TOKEN_ENCRYPTION_SECRET?: string;
  APPLE_SIWA_PRIVATE_KEY?: string;
  APPLE_SIWA_KEY_ID?: string;
  APPLE_TEAM_ID?: string;
  APPLE_SIWA_CLIENT_ID?: string;
  STRIPE_SECRET_KEY?: string;
  APPLE_IDENTITY_RETENTION_SECRET_CURRENT?: string;
  APPLE_TRANSACTION_HASH_SECRET?: string;
  USER_USAGE_LEDGER?: {
    getByName(name: string): {
      snapshotAccountEntitlements(): Promise<AccountEntitlementSnapshot>;
      purgeAccountData(): Promise<{ purged: true }>;
    };
  };
}

type DeletionMarker = typeof deletionState.$inferSelect;
const ROOM_SCAN_LIMIT = 25;
const RETRY_DELAY_MS = 60_000;
// Keep the deletion fence open for the 300-second PUT URLs issued by
// routes/upload.ts, plus a small propagation/drain margin at the boundary.
const PRE_MARKER_UPLOAD_DRAIN_MS = 300_000 + 1_000;

export type AccountDeletionErrorBody =
  | { code: "ACCOUNT_DELETION_PENDING"; status: 503; retryable: true; retryAt: number }
  | { code: "ACCOUNT_DELETION_CONFLICT"; status: 409; retryable: true };

export function accountDeletionErrorBody(error: unknown): AccountDeletionErrorBody | undefined {
  if (!error || typeof error !== "object") return;
  const value = error as Partial<AccountDeletionErrorBody> & { retryAt?: number };
  if (value.retryable !== true) return;
  if (value.code === "ACCOUNT_DELETION_PENDING" && value.status === 503 && typeof value.retryAt === "number") {
    return { code: value.code, status: 503, retryable: true, retryAt: value.retryAt };
  }
  if (value.code === "ACCOUNT_DELETION_CONFLICT" && value.status === 409) {
    return { code: value.code, status: 409, retryable: true };
  }
}

export function accountDeletionErrorEnvelope(error: unknown, correlationId: string) {
  const known = accountDeletionErrorBody(error);
  if (known) {
    return {
      code: known.code,
      error: "Account deletion is still being completed. Try again shortly.",
      retryable: true,
      action: "retry",
      correlationId,
      ...(known.code === "ACCOUNT_DELETION_PENDING" ? { retryAt: known.retryAt } : {}),
    };
  }
  return {
    code: "ACCOUNT_DELETION_UNAVAILABLE",
    error: "Rishi could not complete account deletion. Try again shortly.",
    retryable: true,
    action: "retry",
    correlationId,
  };
}

function pendingError(retryAt: Date = new Date(Date.now() + RETRY_DELAY_MS)) {
  return Object.assign(new Error("Account deletion is pending"), {
    code: "ACCOUNT_DELETION_PENDING" as const, status: 503 as const, retryable: true as const, retryAt: retryAt.getTime(),
  });
}

// Internal-only marker: the upload drain has already been durably scheduled.
// The public response remains 503 until deletion actually finishes.
const uploadDrainScheduled = Symbol("uploadDrainScheduled");

function uploadDrainScheduledError(deadline: Date) {
  return Object.assign(pendingError(deadline), { [uploadDrainScheduled]: true as const });
}

function isUploadDrainScheduled(error: unknown): boolean {
  return Boolean(error && typeof error === "object" && uploadDrainScheduled in error);
}

function markerCondition(marker: DeletionMarker) {
  return and(
    eq(deletionState.userId, marker.userId),
    eq(deletionState.deletionId, marker.deletionId),
    eq(deletionState.status, marker.status),
    eq(deletionState.retryAt, marker.retryAt),
  );
}

function leaseGuard(db: WorkerDb, marker: DeletionMarker) {
  return exists(db.select({ userId: deletionState.userId }).from(deletionState)
    .where(and(markerCondition(marker), gt(deletionState.retryAt, new Date()))));
}

async function reloadPending(db: WorkerDb, userId: string): Promise<never> {
  const current = await db.select().from(deletionState).where(eq(deletionState.userId, userId)).get();
  throw pendingError(current?.retryAt);
}

async function waitForPreMarkerUploads(
  db: WorkerDb,
  marker: DeletionMarker,
): Promise<void> {
  const deadline = new Date(marker.createdAt.getTime() + PRE_MARKER_UPLOAD_DRAIN_MS);
  if (Date.now() >= deadline.getTime()) return;
  const scheduled = await db.update(deletionState).set({
    status: "purging",
    retryAt: deadline,
    updatedAt: new Date(),
  }).where(markerCondition(marker));
  if (scheduled.meta.changes === 0) return reloadPending(db, marker.userId);
  throw uploadDrainScheduledError(deadline);
}

function unresolvedRooms(db: WorkerDb, userId: string) {
  return db.selectDistinct({ sessionId: sessionInvites.sessionId })
    .from(sessionInvites)
    .leftJoin(sessionInviteRedemptions, eq(sessionInviteRedemptions.inviteId, sessionInvites.id))
    .where(or(
      and(eq(sessionInvites.ownerUserId, userId), inArray(sessionInvites.status, ["open", "ended"])),
      and(eq(sessionInviteRedemptions.userId, userId), inArray(sessionInviteRedemptions.membershipStatus, ["pending", "admitted", "left"])),
    ))
    .orderBy(asc(sessionInvites.sessionId))
    .limit(ROOM_SCAN_LIMIT);
}

/**
 * Remove account references from the versioned Apple sharing transport before
 * deleting the D1 rows that identify those rooms. The room state lives in a
 * separate Durable Object, so deleting only session_invites would otherwise
 * leave an ended or active room containing the account id and book context.
 */
async function purgeAccountReadingRooms(
  db: WorkerDb,
  env: AccountDeletionEnvironment,
  marker: DeletionMarker,
  correlationId: string,
): Promise<void> {
  const { userId, deletionId } = marker;
  const rooms = await unresolvedRooms(db, userId).all();
  if (rooms.length === 0) return;
  if (!env.SHARING_WORKER || !env.SHARING_INTERNAL_SECRET) {
    throw new Error("sharing Worker binding is required to delete account reading rooms");
  }

  const service = new SessionSharingService(env.SHARING_WORKER, {
    internalTokenSecret: env.SHARING_INTERNAL_SECRET,
    internalPathPrefix: "/v2/internal",
    correlationId,
  });

  for (const room of rooms) {
    const invite = await db.select().from(sessionInvites).where(eq(sessionInvites.sessionId, room.sessionId)).get();
    if (!invite) continue;
    try {
      await service.revokeAccountReferences({
        sessionId: room.sessionId,
        accountUserId: userId,
        deletionOperationId: createHash("sha256").update(JSON.stringify([deletionId, room.sessionId])).digest("hex"),
      });
    } catch (error) {
      if (!isSessionSharingServiceError(error) || error.code !== "SESSION_NOT_FOUND") throw error;
    }
    if (invite.ownerUserId === userId) {
      try {
        await service.purgeAppleRoom({ sessionId: room.sessionId });
      } catch (error) {
        if (!isSessionSharingServiceError(error) || error.code !== "SESSION_NOT_FOUND") throw error;
      }
      const deleted = await db.delete(sessionInvites).where(and(
        eq(sessionInvites.id, invite.id), eq(sessionInvites.ownerUserId, userId),
        inArray(sessionInvites.status, ["open", "ended"]), leaseGuard(db, marker),
      ));
      if (deleted.meta.changes === 0 && await db.select().from(sessionInvites).where(eq(sessionInvites.id, invite.id)).get()) {
        await reloadPending(db, userId);
      }
    } else {
      const removed = await db.update(sessionInviteRedemptions).set({ membershipStatus: "removed", updatedAt: new Date() }).where(and(
        eq(sessionInviteRedemptions.inviteId, invite.id), eq(sessionInviteRedemptions.userId, userId),
        inArray(sessionInviteRedemptions.membershipStatus, ["pending", "admitted", "left"]), leaseGuard(db, marker),
      ));
      if (removed.meta.changes === 0 && await db.select().from(sessionInviteRedemptions).where(and(
        eq(sessionInviteRedemptions.inviteId, invite.id), eq(sessionInviteRedemptions.userId, userId),
        inArray(sessionInviteRedemptions.membershipStatus, ["pending", "admitted", "left"]),
      )).get()) await reloadPending(db, userId);
    }
  }
}

function userLogId(userId: string): string {
  return createHash("sha256").update(userId).digest("hex").slice(0, 16);
}

function logDeletionStage(
  stage: "revoke" | "stripe" | "r2" | "d1" | "verify",
  userId: string,
  deletionId: string,
  correlationId: string,
  details: Record<string, unknown> = {},
): void {
  console.info("account_deletion", {
    stage,
    deletionId,
    correlationId,
    userHash: userLogId(userId),
    ...details,
  });
}

async function anonymizeStripeCustomer(
  env: AccountDeletionEnvironment,
  stripeCustomerId: string | null,
): Promise<void> {
  if (!stripeCustomerId) return;
  if (!env.STRIPE_SECRET_KEY) {
    throw new Error("Stripe customer exists but STRIPE_SECRET_KEY is not configured");
  }
  await createStripeClient(env.STRIPE_SECRET_KEY).customers.update(stripeCustomerId, {
    name: "Deleted Rishi account",
    email: null as unknown as string,
    description: "Deleted Rishi account",
    metadata: {},
  });
}

export interface AccountDeletionResult {
  deletionId: string;
  alreadyDeleted: boolean;
  revocationStatus: DeletionStatus;
  r2ObjectsRemoved: number;
}

function hasAppleConfiguration(env: AccountDeletionEnvironment): env is AccountDeletionEnvironment & {
  APPLE_SIWA_PRIVATE_KEY: string;
  APPLE_SIWA_KEY_ID: string;
  APPLE_TEAM_ID: string;
  APPLE_SIWA_CLIENT_ID: string;
} {
  return Boolean(
    env.APPLE_SIWA_PRIVATE_KEY &&
      env.APPLE_SIWA_KEY_ID &&
      env.APPLE_TEAM_ID &&
      env.APPLE_SIWA_CLIENT_ID,
  );
}

async function revokeAppleAuthorization(
  env: AccountDeletionEnvironment,
  ciphertext: string | null,
  nonce: string | null,
): Promise<DeletionStatus> {
  if (!ciphertext || !nonce) return "legacy_no_token";
  if (!env.SIWA_TOKEN_ENCRYPTION_SECRET || !hasAppleConfiguration(env)) {
    return "revocation_unavailable";
  }

  const refreshToken = await decryptSiwaRefreshToken(
    { ciphertext, nonce },
    env.SIWA_TOKEN_ENCRYPTION_SECRET,
  );
  const clientSecret = await mintAppleClientSecret(env);
  const response = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: env.APPLE_SIWA_CLIENT_ID,
      client_secret: clientSecret,
      token: refreshToken,
      token_type_hint: "refresh_token",
    }),
  });

  if (response.ok) return "revoked";
  if (response.status === 400) {
    const body = await response.json().catch(() => null) as { error?: unknown } | null;
    // Apple documents invalid_grant for an already-invalid/expired token. It
    // is safe to treat that state as already revoked; invalid_client and
    // invalid_request indicate a configuration/request problem instead.
    if (body?.error === "invalid_grant") return "revoked";
  }
  return "revocation_unavailable";
}

type AccountR2Scope = { userId: string; packageIds: string[] };

/** Release only this account's references while retaining D1 rows until the
 * guarded batch. A failed R2 delete leaves the package IDs available on retry. */
async function deleteAccountR2Objects(
  db: WorkerDb,
  bucket: R2Bucket,
  candidates: Array<string | null>,
  scope: AccountR2Scope,
): Promise<number> {
  const keys = [...new Set(candidates.filter((key): key is string => Boolean(key)))];
  if (keys.length === 0) return 0;
  const [libraryRows, shareRows] = await Promise.all([
    db.select({ fileR2Key: books.fileR2Key, coverR2Key: books.coverR2Key }).from(books).where(and(
      ne(books.userId, scope.userId), eq(books.isDeleted, false),
      or(inArray(books.fileR2Key, keys), inArray(books.coverR2Key, keys)),
    )).all(),
    db.select({ fileR2Key: sharePackageItems.fileR2Key, coverR2Key: sharePackageItems.coverR2Key }).from(sharePackageItems).where(and(
      scope.packageIds.length ? notInArray(sharePackageItems.packageId, scope.packageIds) : undefined,
      or(inArray(sharePackageItems.fileR2Key, keys), inArray(sharePackageItems.coverR2Key, keys)),
    )).all(),
  ]);
  const referenced = new Set([...libraryRows, ...shareRows].flatMap((row) => [row.fileR2Key, row.coverR2Key]));
  const removable = keys.filter((key) => !referenced.has(key));
  await Promise.all(removable.map((key) => bucket.delete(key)));
  return removable.length;
}

async function deleteR2PrefixObjects(
  db: WorkerDb,
  bucket: R2Bucket,
  prefixes: string[],
  scope?: AccountR2Scope,
): Promise<number> {
  const candidates: string[] = [];
  let removed = 0;
  for (const prefix of prefixes) {
    let cursor: string | undefined;
    while (true) {
      const page = await bucket.list({ prefix, limit: 1000, ...(cursor ? { cursor } : {}) });
      candidates.push(...page.objects.map((object) => object.key));
      if (!page.truncated || !page.cursor) break;
      cursor = page.cursor;
    }
  }
  removed += scope
    ? await deleteAccountR2Objects(db, bucket, candidates, scope)
    : (await deleteUnreferencedR2Objects(db, bucket, candidates)).length;
  return removed;
}

async function verifyPreDeleteCleanup(
  db: WorkerDb,
  bucket: R2Bucket,
  marker: DeletionMarker,
  r2Keys: string[],
  packageIds: string[],
): Promise<void> {
  if (!await db.select({ id: user.id }).from(user).where(eq(user.id, marker.userId)).get()) {
    throw new Error("account deletion verification lost the user row");
  }
  if (!await db.select({ deletionId: deletionState.deletionId }).from(deletionState)
    .where(markerCondition(marker)).get()) {
    throw new Error("account deletion verification lost the deletion marker");
  }

  const [referencedByLibrary, survivingShareRows] = await Promise.all([
    referencedR2Keys(db, r2Keys, { ignoreBookUserId: marker.userId }),
    db.select({ fileR2Key: sharePackageItems.fileR2Key, coverR2Key: sharePackageItems.coverR2Key })
      .from(sharePackageItems)
      .where(and(
        packageIds.length ? notInArray(sharePackageItems.packageId, packageIds) : undefined,
        or(inArray(sharePackageItems.fileR2Key, r2Keys), inArray(sharePackageItems.coverR2Key, r2Keys)),
      ))
      .all(),
  ]);
  const referenced = new Set([
    ...referencedByLibrary,
    ...survivingShareRows.flatMap((row) => [row.fileR2Key, row.coverR2Key]),
  ]);
  for (const key of r2Keys) {
    if (await bucket.head(key) && !referenced.has(key)) {
      throw new Error("account deletion verification found an R2 object");
    }
  }
}

async function deleteRows(
  db: WorkerDb,
  marker: DeletionMarker,
  transactionIds: string[],
  verificationIdentifiers: string[],
): Promise<boolean> {
  const userId = marker.userId;
  const guard = leaseGuard(db, marker);
  // These rows are not fully owned by a user FK. Notification records can
  // arrive before a user is resolved, verification tokens use a polymorphic
  // identifier, and Better Auth's Stripe table stores a referenceId rather
  // than a foreign key. Everything else is removed by the user-row cascades.
  const results = await db.batch([
    db.delete(appleNotificationsLog).where(and(guard,
    transactionIds.length > 0
      ? or(
          eq(appleNotificationsLog.userId, userId),
          inArray(appleNotificationsLog.appleTransactionId, transactionIds),
        )
      : eq(appleNotificationsLog.userId, userId),
    )),
    db.delete(verification).where(and(guard, inArray(verification.identifier, verificationIdentifiers))),
    db.delete(subscription).where(and(guard, eq(subscription.referenceId, userId))),
    db.delete(sharePackages).where(and(guard, or(
      eq(sharePackages.senderUserId, userId), eq(sharePackages.recipientUserId, userId), eq(sharePackages.claimedBy, userId),
    ))),
    db.delete(user).where(and(guard, eq(user.id, userId))),
  ]);
  return results[results.length - 1]!.meta.changes > 0;
}

async function retainAppleEntitlements(
  db: WorkerDb,
  env: AccountDeletionEnvironment,
  appleRow: typeof appleUsers.$inferSelect | undefined,
  subscriptions: Array<typeof appleSubscriptions.$inferSelect>,
  snapshot: AccountEntitlementSnapshot,
  deletedAt: number,
): Promise<void> {
  if (!appleRow) return;
  if (!env.APPLE_IDENTITY_RETENTION_SECRET_CURRENT || !env.APPLE_TRANSACTION_HASH_SECRET) {
    throw new Error("Apple entitlement retention secrets are not configured");
  }
  const identity = await hashAppleIdentity(appleRow.appleUserId, env.APPLE_IDENTITY_RETENTION_SECRET_CURRENT);
  const latestPaid = subscriptions.reduce((latest, row) => Math.max(latest, row.currentPeriodEnd.getTime()), deletedAt);
  const expiry = retentionExpiresAt(deletedAt, latestPaid);
  const retainedValues: typeof retainedAppleEntitlement.$inferInsert = {
    ...identity,
    trialState: snapshot.trialState,
    trialInitialCredits: snapshot.trialInitialCredits,
    trialUsedCredits: snapshot.trialUsedCredits,
    readerActiveUntil: snapshot.reader.activeUntil ? new Date(snapshot.reader.activeUntil) : null,
    voiceActiveUntil: snapshot.voice.activeUntil ? new Date(snapshot.voice.activeUntil) : null,
    readerCreditsTotal: snapshot.reader.total,
    readerCreditsUsed: snapshot.reader.used,
    voiceCreditsTotal: snapshot.voice.total,
    voiceCreditsUsed: snapshot.voice.used,
    readerStatus: snapshot.reader.status,
    voiceStatus: snapshot.voice.status,
    deletedAt: new Date(deletedAt),
    retentionExpiresAt: new Date(expiry),
    updatedAt: new Date(deletedAt),
  };
  const existing = (await db.select().from(retainedAppleEntitlement).where(and(
    eq(retainedAppleEntitlement.identityHashVersion, identity.identityHashVersion),
    eq(retainedAppleEntitlement.identityHash, identity.identityHash),
  )).get()) ?? null;
  const merged = mergeRetentionSnapshot(existing, retainedValues);
  await db.insert(retainedAppleEntitlement).values(merged).onConflictDoUpdate({
    target: [retainedAppleEntitlement.identityHashVersion, retainedAppleEntitlement.identityHash],
    set: merged,
  });
  for (const row of subscriptions) {
    const transaction = await hashAppleOriginalTransaction(row.appleOriginalTransactionId, env.APPLE_TRANSACTION_HASH_SECRET);
    const feature = row.productId.toLowerCase().includes("voice") ? "voice" : "reader";
    await db.insert(retainedAppleTransaction).values({
      ...identity,
      ...transaction,
      feature,
      environment: row.environment,
      lastEventAt: row.updatedAt,
      status: row.status,
      periodEnd: row.currentPeriodEnd,
      retentionExpiresAt: new Date(expiry),
      updatedAt: new Date(deletedAt),
    }).onConflictDoUpdate({
      target: [retainedAppleTransaction.transactionHashVersion, retainedAppleTransaction.environment, retainedAppleTransaction.originalTransactionHash],
      set: {
        identityHashVersion: identity.identityHashVersion,
        identityHash: identity.identityHash,
        feature,
        lastEventAt: row.updatedAt,
        status: row.status,
        periodEnd: row.currentPeriodEnd,
        retentionExpiresAt: new Date(expiry),
        updatedAt: new Date(deletedAt),
      },
    });
  }
}

export async function deleteAccount(
  db: WorkerDb,
  env: AccountDeletionEnvironment,
  userId: string,
  correlationId = `delete_${crypto.randomUUID().replaceAll("-", "")}`,
): Promise<AccountDeletionResult> {
  try {
    return await executeDeletion(db, env, userId, undefined, correlationId);
  } catch (error) {
    if (accountDeletionErrorBody(error)) throw error;
    // Setup failures and already-deleted cleanup failures use the same public
    // retry contract as a failure after acquiring the durable lease.
    throw pendingError();
  }
}

async function executeDeletion(
  db: WorkerDb,
  env: AccountDeletionEnvironment,
  userId: string,
  scheduledMarker?: DeletionMarker,
  correlationId = `delete_${createHash("sha256").update(userId).digest("hex").slice(0, 32)}`,
): Promise<AccountDeletionResult> {
  const ledger = env.USER_USAGE_LEDGER?.getByName(userId);
  if (!ledger) throw pendingError();
  const userRow = await db.select().from(user).where(eq(user.id, userId)).get();

  // Hard deletion is intentionally idempotent. Once the parent row is gone,
  // the database has already removed all FK-backed account data, so a repeat
  // request is a successful no-op rather than a reason to retain a tombstone.
  if (!userRow) {
    if (scheduledMarker) return reloadPending(db, userId);
    await ledger.purgeAccountData();
    const r2ObjectsRemoved = await deleteR2PrefixObjects(db, env.BOOK_STORAGE, [
      `books/${userId}/`,
      `covers/${userId}/`,
    ]);
    return {
      deletionId: randomUUID(),
      alreadyDeleted: true,
      revocationStatus: "legacy_no_token",
      r2ObjectsRemoved,
    };
  }

  const markerNow = new Date();
  // Fence new share creation before taking the ownership snapshot. Share
  // creation checks this durable marker before copying any R2 objects.
  if (!scheduledMarker) await db.insert(deletionState).values({
    userId,
    deletionId: randomUUID(),
    ledgerName: userId,
    status: "pending",
    retryAt: markerNow,
    createdAt: markerNow,
    updatedAt: markerNow,
  }).onConflictDoNothing();

  const stored = scheduledMarker ?? await db.select().from(deletionState).where(eq(deletionState.userId, userId)).get();
  if (!stored || !["pending", "purging"].includes(stored.status)) return reloadPending(db, userId);
  // Successful claims are strictly newer than the prior lease. The exact old
  // timestamp participates in the CAS, so simultaneous claimants cannot win.
  const retryAt = new Date(Math.max(Date.now() + RETRY_DELAY_MS, stored.retryAt.getTime() + 1));
  const claimed = await db.update(deletionState).set({ retryAt, updatedAt: new Date() }).where(and(
    markerCondition(stored), lte(deletionState.retryAt, new Date()),
  ));
  if (claimed.meta.changes === 0) return reloadPending(db, userId);
  const marker = { ...stored, retryAt };

  try {
    if (marker.status === "pending") {
      await purgeAccountReadingRooms(db, env, marker, correlationId);
      if ((await unresolvedRooms(db, userId).all()).length > 0) throw pendingError(marker.retryAt);
      const transitioned = await db.update(deletionState).set({ status: "purging", updatedAt: new Date() })
        .where(and(markerCondition(marker), gt(deletionState.retryAt, new Date())));
      if (transitioned.meta.changes === 0) return await reloadPending(db, userId);
      marker.status = "purging";
    }
    return await finalizeAccountDeletion(db, env, userRow, marker, correlationId);
  } catch (error) {
    // The drain deadline was committed by waitForPreMarkerUploads; a second
    // CAS against the old lease would turn this into a false retry failure.
    if (isUploadDrainScheduled(error)) throw error;
    const pending = accountDeletionErrorBody(error);
    const retryAt = pending?.code === "ACCOUNT_DELETION_PENDING"
      ? new Date(pending.retryAt)
      : new Date(Date.now() + RETRY_DELAY_MS);
    const scheduled = await db.update(deletionState).set({ retryAt, updatedAt: new Date() })
      .where(markerCondition(marker));
    if (scheduled.meta.changes === 0) return reloadPending(db, userId);
    if (isSessionSharingServiceError(error) && (error.code === "CONFLICT" || error.status === 409)) {
      throw Object.assign(new Error("Account deletion conflicts with room state"), {
        code: "ACCOUNT_DELETION_CONFLICT", status: 409, retryable: true,
      });
    }
    throw pendingError(retryAt);
  }
}

async function finalizeAccountDeletion(
  db: WorkerDb,
  env: AccountDeletionEnvironment,
  userRow: typeof user.$inferSelect,
  marker: DeletionMarker,
  correlationId: string,
): Promise<AccountDeletionResult> {
  const { userId, deletionId } = marker;
  const ledger = env.USER_USAGE_LEDGER!.getByName(marker.ledgerName);

  const [appleRow, userBooks, userAppleSubscriptions] = await Promise.all([
    db.select().from(appleUsers).where(eq(appleUsers.userId, userId)).get(),
    db.select({ id: books.id, fileR2Key: books.fileR2Key, coverR2Key: books.coverR2Key })
      .from(books).where(eq(books.userId, userId)).all(),
    db.select().from(appleSubscriptions).where(eq(appleSubscriptions.userId, userId)).all(),
  ]);
  const entitlementSnapshot = await ledger.snapshotAccountEntitlements();
  await retainAppleEntitlements(db, env, appleRow, userAppleSubscriptions, entitlementSnapshot, marker.createdAt.getTime());
  await ledger.purgeAccountData();
  // Snapshot package IDs only after external ledger work so requests that
  // crossed the deletion fence before it was written are included as well.
  const userSharePackages = await db.select({ id: sharePackages.id })
      .from(sharePackages)
      .where(or(
        eq(sharePackages.senderUserId, userId),
        eq(sharePackages.recipientUserId, userId),
        eq(sharePackages.claimedBy, userId),
      ))
      .all();
  const userSharePackageIDs = userSharePackages.map(({ id }) => id);
  const userShareItems = userSharePackageIDs.length > 0
    ? await db.select({ fileR2Key: sharePackageItems.fileR2Key, coverR2Key: sharePackageItems.coverR2Key })
      .from(sharePackageItems)
      .where(inArray(sharePackageItems.packageId, userSharePackageIDs))
      .all()
    : [];
  const userShareItemR2Keys = userShareItems.flatMap((item) => [item.fileR2Key, item.coverR2Key]);
  const userSharePackagePrefixes = userSharePackageIDs.map((id) => `shares/${id}/`);
  const verificationEmail = userRow?.email ?? appleRow?.email;
  const verificationIdentifiers = [userId, ...(verificationEmail ? [verificationEmail] : [])];

  logDeletionStage("revoke", userId, deletionId, correlationId, { tokenPresent: Boolean(appleRow?.siwaRefreshTokenCiphertext) });

  let revocationStatus: DeletionStatus = "legacy_no_token";
  try {
    revocationStatus = await revokeAppleAuthorization(
      env,
      appleRow?.siwaRefreshTokenCiphertext ?? null,
      appleRow?.siwaRefreshTokenNonce ?? null,
    );
  } catch (error) {
    console.error("account deletion Apple revocation unavailable", {
      event: "account_deletion.apple_revocation_failed",
      deletionId,
      correlationId,
      userHash: userLogId(userId),
      category: error instanceof Error ? error.name : "unknown",
    });
    revocationStatus = "revocation_unavailable";
  }

  logDeletionStage("stripe", userId, deletionId, correlationId, { customerPresent: Boolean(userRow?.stripeCustomerId) });
  await anonymizeStripeCustomer(env, userRow?.stripeCustomerId ?? null);

  logDeletionStage("r2", userId, deletionId, correlationId, {
    objectCount: userBooks.length * 2,
    sharePackageCount: userSharePackages.length,
  });
  const candidateR2Keys = userBooks.flatMap((book) => [book.fileR2Key, book.coverR2Key])
    .filter((key): key is string => Boolean(key));
  const r2Keys = candidateR2Keys;
  const userR2Prefixes = [`books/${userId}/`, `covers/${userId}/`];
  const sweptBeforeDelete = await deleteR2PrefixObjects(
    db,
    env.BOOK_STORAGE,
    userR2Prefixes,
  );

  logDeletionStage("d1", userId, deletionId, correlationId);
  // The book rows may have pointed at objects that are not discoverable by a
  // prefix listing in a mocked or eventually-consistent bucket. Release the
  // owner's references explicitly before deleting the rows. If R2 fails, the
  // user row and deletion marker remain so the operation can be retried.
  const snapshottedObjectsRemoved = await deleteAccountR2Objects(
    db,
    env.BOOK_STORAGE,
    [...r2Keys, ...userShareItemR2Keys],
    { userId, packageIds: userSharePackageIDs },
  );
  // Remove legacy materialized package copies while the package IDs are still
  // available. If the Worker crashes after the D1 rows cascade, a retry cannot
  // reconstruct those IDs from the deleted account, so the final sweep below
  // is intentionally a second pass for late-arriving objects.
  const sharePackageObjectsRemovedBeforeDelete = await deleteR2PrefixObjects(
    db,
    env.BOOK_STORAGE,
    userSharePackagePrefixes,
    { userId, packageIds: userSharePackageIDs },
  );

  await waitForPreMarkerUploads(db, marker);

  // Legacy share implementations may have materialized package copies under
  // a package-specific prefix. Sweep only prefixes captured from this account;
  // a global `shares/` sweep could delete another user's package. Keep this
  // second pass before the final D1 batch so a failure can still reschedule
  // the marker with its package IDs available.
  const sharePackageObjectsRemovedFinal = await deleteR2PrefixObjects(
    db,
    env.BOOK_STORAGE,
    userSharePackagePrefixes,
    { userId, packageIds: userSharePackageIDs },
  );
  // A presigned upload issued before deletion can still arrive after the
  // initial key snapshot. This final user-scoped sweep runs while the user and
  // marker still exist, so a failure remains retryable.
  const sweptFinal = await deleteR2PrefixObjects(
    db,
    env.BOOK_STORAGE,
    userR2Prefixes,
  );

  logDeletionStage("verify", userId, deletionId, correlationId);
  await verifyPreDeleteCleanup(
    db,
    env.BOOK_STORAGE,
    marker,
    r2Keys,
    userSharePackageIDs,
  );

  // This guarded batch is the final irreversible operation. No fallible
  // external cleanup or verification may run after the user cascade.
  if (!await deleteRows(db, marker, userAppleSubscriptions.map((row) => row.appleTransactionId), verificationIdentifiers)) {
    return reloadPending(db, userId);
  }
  return {
    deletionId,
    alreadyDeleted: false,
    revocationStatus,
    r2ObjectsRemoved: snapshottedObjectsRemoved + sweptBeforeDelete + sweptFinal + sharePackageObjectsRemovedBeforeDelete + sharePackageObjectsRemovedFinal,
  };
}

/** Retry fenced deletions after a Worker crash, bounded for scheduled runs. */
export async function retryPendingDeletions(
  db: WorkerDb,
  env: AccountDeletionEnvironment,
  limit = 25,
): Promise<number> {
  const pending = await db.select()
    .from(deletionState)
    .where(and(
      inArray(deletionState.status, ["pending", "purging"]),
      // Do not hot-loop a failed deletion on every scheduled invocation.
      // The marker remains in place and middleware continues to fence access.
      lte(deletionState.retryAt, new Date()),
    ))
    .limit(limit)
    .all();
  let completed = 0;
  let firstFailure: { deletionId: string; correlationId: string } | undefined;
  for (const row of pending) {
    const correlationId = `retry_${row.deletionId}`;
    try {
      await executeDeletion(db, env, row.userId, row, correlationId);
      completed += 1;
    } catch (error) {
      if (isUploadDrainScheduled(error)) continue;
      firstFailure ??= { deletionId: row.deletionId, correlationId };
      console.error("account deletion retry failed", {
        event: "account_deletion.retry_failed",
        deletionId: row.deletionId,
        correlationId,
        category: error instanceof Error ? error.name : "unknown",
      });
    }
  }
  if (firstFailure) {
    throw new Error(`Account deletion retry failed: deletionId=${firstFailure.deletionId} correlationId=${firstFailure.correlationId}`);
  }
  return completed;
}

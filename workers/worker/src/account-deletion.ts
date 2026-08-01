import { createHash, randomUUID } from "node:crypto";
import { and, eq, gt, inArray, lte, ne, or } from "drizzle-orm";
import type { WorkerDb } from "./db/drizzle";
import {
  appleNotificationsLog,
  appleSubscriptions,
  appleUsers,
  books,
  deletionState,
  retainedAppleEntitlement,
  retainedAppleTransaction,
  subscription,
  user,
  verification,
} from "./db/schema";
import { decryptSiwaRefreshToken } from "./siwa-token-crypto";
import { mintAppleClientSecret } from "./auth-apple-secret";
import { createStripeClient } from "./billing/stripe";
import { hashAppleIdentity, hashAppleOriginalTransaction, mergeRetentionSnapshot, retentionExpiresAt } from "./entitlement-retention";
import type { AccountEntitlementSnapshot } from "./durable-objects/user-usage-ledger/types";

type DeletionStatus = "revoked" | "legacy_no_token" | "revocation_unavailable";

export interface AccountDeletionEnvironment {
  DB: D1Database;
  BOOK_STORAGE: R2Bucket;
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

function userLogId(userId: string): string {
  return createHash("sha256").update(userId).digest("hex").slice(0, 16);
}

function logDeletionStage(
  stage: "revoke" | "stripe" | "r2" | "d1" | "verify",
  userId: string,
  deletionId: string,
  details: Record<string, unknown> = {},
): void {
  console.info("account_deletion", {
    stage,
    deletionId,
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

async function deleteR2Objects(
  bucket: R2Bucket,
  keys: Array<string | null>,
): Promise<number> {
  const uniqueKeys = [...new Set(keys.filter((key): key is string => Boolean(key)))];
  await Promise.all(uniqueKeys.map((key) => bucket.delete(key)));
  return uniqueKeys.length;
}

async function deleteR2PrefixObjects(
  bucket: R2Bucket,
  prefixes: string[],
): Promise<number> {
  let removed = 0;
  for (const prefix of prefixes) {
    // Always restart from the first page after deleting. Advancing a cursor
    // while mutating the listing can skip keys when objects disappear between
    // pages; repeating until empty is both bounded by the number of objects
    // and safe for late-arriving uploads.
    while (true) {
      const page = await bucket.list({ prefix, limit: 1000 });
      const keys = page.objects.map((object) => object.key);
      if (keys.length === 0) break;
      removed += await deleteR2Objects(bucket, keys);
    }
  }
  return removed;
}

async function verifyR2PrefixesEmpty(
  bucket: R2Bucket,
  prefixes: string[],
): Promise<void> {
  for (const prefix of prefixes) {
    const page = await bucket.list({ prefix, limit: 1 });
    if (page.objects.length > 0) {
      throw new Error("account deletion verification found a user-scoped R2 object");
    }
  }
}

async function verifyDeletion(
  db: WorkerDb,
  bucket: R2Bucket,
  userId: string,
  r2Keys: string[],
): Promise<void> {
  if (await db.select({ id: user.id }).from(user).where(eq(user.id, userId)).get()) {
    throw new Error("account deletion verification found the user row");
  }

  for (const key of r2Keys) {
    if (await bucket.head(key)) {
      throw new Error("account deletion verification found an R2 object");
    }
  }
}

async function deleteRows(
  db: WorkerDb,
  userId: string,
  transactionIds: string[],
  verificationIdentifiers: string[],
): Promise<void> {
  // These rows are not fully owned by a user FK. Notification records can
  // arrive before a user is resolved, verification tokens use a polymorphic
  // identifier, and Better Auth's Stripe table stores a referenceId rather
  // than a foreign key. Everything else is removed by the user-row cascades.
  await db.delete(appleNotificationsLog).where(
    transactionIds.length > 0
      ? or(
          eq(appleNotificationsLog.userId, userId),
          inArray(appleNotificationsLog.appleTransactionId, transactionIds),
        )
      : eq(appleNotificationsLog.userId, userId),
  );
  if (verificationIdentifiers.length > 0) {
    await db.delete(verification).where(inArray(verification.identifier, verificationIdentifiers));
  }
  await db.delete(subscription).where(eq(subscription.referenceId, userId));
  await db.delete(user).where(eq(user.id, userId));
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
): Promise<AccountDeletionResult> {
  const ledger = env.USER_USAGE_LEDGER?.getByName(userId);
  if (!ledger) throw new Error("USER_USAGE_LEDGER binding is required for account deletion");
  const userRow = await db.select().from(user).where(eq(user.id, userId)).get();

  // Hard deletion is intentionally idempotent. Once the parent row is gone,
  // the database has already removed all FK-backed account data, so a repeat
  // request is a successful no-op rather than a reason to retain a tombstone.
  if (!userRow) {
    await ledger.purgeAccountData();
    const r2ObjectsRemoved = await deleteR2PrefixObjects(env.BOOK_STORAGE, [
      `books/${userId}/`,
      `covers/${userId}/`,
    ]);
    await verifyR2PrefixesEmpty(env.BOOK_STORAGE, [
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

  const deletionId = randomUUID();

  const [appleRow, userBooks, userAppleSubscriptions] = await Promise.all([
    db.select().from(appleUsers).where(eq(appleUsers.userId, userId)).get(),
    db.select({ id: books.id, fileR2Key: books.fileR2Key, coverR2Key: books.coverR2Key })
      .from(books).where(eq(books.userId, userId)).all(),
    db.select().from(appleSubscriptions).where(eq(appleSubscriptions.userId, userId)).all(),
  ]);
  const verificationEmail = userRow?.email ?? appleRow?.email;
  const verificationIdentifiers = [userId, ...(verificationEmail ? [verificationEmail] : [])];
  const markerNow = new Date();
  await db.insert(deletionState).values({
    userId,
    deletionId,
    ledgerName: userId,
    status: "pending",
    retryAt: new Date(markerNow.getTime() + 60_000),
    createdAt: markerNow,
    updatedAt: markerNow,
  }).onConflictDoUpdate({
    target: deletionState.userId,
    set: { deletionId, ledgerName: userId, status: "pending", retryAt: new Date(markerNow.getTime() + 60_000), updatedAt: markerNow },
  });
  const entitlementSnapshot = await ledger.snapshotAccountEntitlements();
  await retainAppleEntitlements(db, env, appleRow, userAppleSubscriptions, entitlementSnapshot, markerNow.getTime());

  logDeletionStage("revoke", userId, deletionId, { tokenPresent: Boolean(appleRow?.siwaRefreshTokenCiphertext) });

  let revocationStatus: DeletionStatus = "legacy_no_token";
  try {
    revocationStatus = await revokeAppleAuthorization(
      env,
      appleRow?.siwaRefreshTokenCiphertext ?? null,
      appleRow?.siwaRefreshTokenNonce ?? null,
    );
  } catch (error) {
    console.error("account deletion Apple revocation unavailable", {
      deletionId,
      userHash: userLogId(userId),
      error: error instanceof Error ? error.message : "unknown",
    });
    revocationStatus = "revocation_unavailable";
  }

  logDeletionStage("stripe", userId, deletionId, { customerPresent: Boolean(userRow?.stripeCustomerId) });
  await anonymizeStripeCustomer(env, userRow?.stripeCustomerId ?? null);

  logDeletionStage("r2", userId, deletionId, { objectCount: userBooks.length * 2 });
  const candidateR2Keys = userBooks.flatMap((book) => [book.fileR2Key, book.coverR2Key])
    .filter((key): key is string => Boolean(key));
  const sharedR2References = candidateR2Keys.length > 0
    ? await db.select({ fileR2Key: books.fileR2Key, coverR2Key: books.coverR2Key })
      .from(books)
      .where(and(
        ne(books.userId, userId),
        or(
          inArray(books.fileR2Key, candidateR2Keys),
          inArray(books.coverR2Key, candidateR2Keys),
        ),
      )).all()
    : [];
  const protectedR2Keys = new Set(sharedR2References.flatMap((book) => [book.fileR2Key, book.coverR2Key])
    .filter((key): key is string => Boolean(key)));
  const r2Keys = candidateR2Keys.filter((key) => !protectedR2Keys.has(key));
  const r2ObjectsRemoved = await deleteR2Objects(
    env.BOOK_STORAGE,
    r2Keys,
  );
  const userR2Prefixes = [`books/${userId}/`, `covers/${userId}/`];
  const sweptBeforeDelete = await deleteR2PrefixObjects(env.BOOK_STORAGE, userR2Prefixes);

  logDeletionStage("d1", userId, deletionId);
  await db.update(deletionState)
    .set({ status: "purging", retryAt: new Date(Date.now() + 60_000), updatedAt: new Date() })
    .where(eq(deletionState.userId, userId));
  await ledger.purgeAccountData();
  await deleteRows(db, userId, userAppleSubscriptions.map((row) => row.appleTransactionId), verificationIdentifiers);

  // A presigned upload issued before deletion can still arrive after the
  // initial key snapshot. Sweep again after the parent row is gone; retries
  // of an already-deleted account repeat this safe user-scoped sweep.
  const sweptAfterDelete = await deleteR2PrefixObjects(env.BOOK_STORAGE, userR2Prefixes);

  logDeletionStage("verify", userId, deletionId);
  await verifyDeletion(
    db,
    env.BOOK_STORAGE,
    userId,
    r2Keys,
  );
  await verifyR2PrefixesEmpty(env.BOOK_STORAGE, userR2Prefixes);

  return {
    deletionId,
    alreadyDeleted: false,
    revocationStatus,
    r2ObjectsRemoved: r2ObjectsRemoved + sweptBeforeDelete + sweptAfterDelete,
  };
}

/** Retry fenced deletions after a Worker crash, bounded for scheduled runs. */
export async function retryPendingDeletions(
  db: WorkerDb,
  env: AccountDeletionEnvironment,
  limit = 25,
): Promise<number> {
  const pending = await db.select({ userId: deletionState.userId })
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
  for (const row of pending) {
    try {
      await deleteAccount(db, env, row.userId);
      completed += 1;
    } catch (error) {
      console.error("account deletion retry failed", { userHash: userLogId(row.userId), error });
    }
  }
  return completed;
}

import { createHash, randomUUID } from "node:crypto";
import { and, eq, inArray, ne, or } from "drizzle-orm";
import type { WorkerDb } from "./db/drizzle";
import {
  appleNotificationsLog,
  appleSubscriptions,
  appleUsers,
  books,
  subscription,
  user,
  verification,
} from "./db/schema";
import { decryptSiwaRefreshToken } from "./siwa-token-crypto";
import { mintAppleClientSecret } from "./auth-apple-secret";
import { createStripeClient } from "./billing/stripe";

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

export async function deleteAccount(
  db: WorkerDb,
  env: AccountDeletionEnvironment,
  userId: string,
): Promise<AccountDeletionResult> {
  const userRow = await db.select().from(user).where(eq(user.id, userId)).get();

  // Hard deletion is intentionally idempotent. Once the parent row is gone,
  // the database has already removed all FK-backed account data, so a repeat
  // request is a successful no-op rather than a reason to retain a tombstone.
  if (!userRow) {
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
    db.select({ appleTransactionId: appleSubscriptions.appleTransactionId })
      .from(appleSubscriptions).where(eq(appleSubscriptions.userId, userId)).all(),
  ]);
  const verificationEmail = userRow?.email ?? appleRow?.email;
  const verificationIdentifiers = [userId, ...(verificationEmail ? [verificationEmail] : [])];

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

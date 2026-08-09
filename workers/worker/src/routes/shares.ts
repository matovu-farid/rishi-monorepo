import { Hono } from "hono";
import type { Context } from "hono";
import { and, eq, gt, inArray, lt } from "drizzle-orm";

import { createDb } from "../db/drizzle";
import {
  books,
  deletionState,
  sharePackageItems,
  sharePackages,
  user,
  usernames,
} from "../db/schema";
import { requireAuth } from "../middleware";
import { requireAiDataConsent } from "../middleware/ai-data-consent";
import { signR2Url } from "../r2-presign";
import type { R2SigningEnv } from "../r2-presign";
import { normalizeUsername, validateUsername } from "../usernames";
import {
  createShareTokenFromSecret,
  hashShareToken,
  isShareExpired,
  shareExpiry,
} from "../shares/shareTokens";
import { deleteUnreferencedR2Objects } from "../shares/shareReferences";
import { devices } from "../db/schema";
import { createApnsSenderFromEnv, type ApnsCredentialsEnv } from "../billing/apns";
import { emitShareCreatedPush } from "../shares/shareNotifications";

const REFERENCE_DATE_OFFSET_MS = 978_307_200_000;
const DOWNLOAD_URL_EXPIRES_SEC = 600;
const MAX_SHARE_ITEMS = 500;
const SUPPORTED_FORMATS = new Set(["epub", "pdf", "mobi", "azw3"]);

type ShareKind = "single" | "selection" | "library";
type Delivery = "link" | "username";
type ShareContext = Context<{ Bindings: Env; Variables: { userId: string } }>;

function signingEnv(c: ShareContext): R2SigningEnv {
  return c.env as unknown as R2SigningEnv;
}

type SharePreviewItem = {
  id: string;
  title: string;
  author: string | null;
  format: string;
  cover_url?: string;
};

type ShareDownloadItem = SharePreviewItem & {
  file_size: number;
  file_url: string;
};

function referenceSeconds(date: Date): number {
  return (date.getTime() - REFERENCE_DATE_OFFSET_MS) / 1000;
}

function errorResponse(c: ShareContext, code: string, status: 400 | 403 | 404 | 409 | 410 | 422 | 423 | 500) {
  return c.json({ error: code, code }, status);
}

function packageLink(token: string): string {
  return `https://rishi.fidexa.org/sharing/join?token=${encodeURIComponent(token)}`;
}

async function signedItem(
  c: ShareContext,
  item: typeof sharePackageItems.$inferSelect,
): Promise<ShareDownloadItem> {
  const fileUrl = await signR2Url(signingEnv(c), {
    key: item.fileR2Key,
    method: "GET",
    expiresSec: DOWNLOAD_URL_EXPIRES_SEC,
  });
  const coverUrl = item.coverR2Key
    ? await signR2Url(signingEnv(c), {
        key: item.coverR2Key,
        method: "GET",
        expiresSec: DOWNLOAD_URL_EXPIRES_SEC,
      })
    : undefined;
  return {
    id: item.id,
    title: item.title,
    author: item.author,
    format: item.format,
    file_size: item.fileSize,
    file_url: fileUrl,
    ...(coverUrl ? { cover_url: coverUrl } : {}),
  };
}

async function previewItem(
  c: ShareContext,
  item: typeof sharePackageItems.$inferSelect,
): Promise<SharePreviewItem> {
  const coverUrl = item.coverR2Key
    ? await signR2Url(signingEnv(c), {
        key: item.coverR2Key,
        method: "GET",
        expiresSec: DOWNLOAD_URL_EXPIRES_SEC,
      })
    : undefined;
  return {
    id: item.id,
    title: item.title,
    author: item.author,
    format: item.format,
    ...(coverUrl ? { cover_url: coverUrl } : {}),
  };
}

async function itemsFor(db: ReturnType<typeof createDb>, packageId: string) {
  return db
    .select()
    .from(sharePackageItems)
    .where(eq(sharePackageItems.packageId, packageId))
    .all();
}

async function previewFor(
  c: ShareContext,
  db: ReturnType<typeof createDb>,
  pkg: typeof sharePackages.$inferSelect,
  senderName: string,
  senderUsername: string | null,
) {
  const items = await itemsFor(db, pkg.id);
  return {
    id: pkg.id,
    sender_name: senderName,
    sender_username: senderUsername,
    count: items.length,
    items: await Promise.all(items.map((item) => previewItem(c, item))),
    expires_at: referenceSeconds(pkg.expiresAt),
  };
}

async function downloadResponse(
  c: Parameters<typeof requireAuth>[0],
  db: ReturnType<typeof createDb>,
  packageId: string,
) {
  const items = await itemsFor(db, packageId);
  return {
    id: packageId,
    items: await Promise.all(items.map((item) => signedItem(c, item))),
  };
}

export const sharesRoutes = new Hono<{
  Bindings: Env;
  Variables: { userId: string };
}>();

/** Remove expired packages and release their references to the original R2
 * objects. The object is deleted only when no active book or other share item
 * still references it. */
export async function purgeExpiredShares(
  db: ReturnType<typeof createDb>,
  bucket: R2Bucket,
  limit = 100,
): Promise<number> {
  const expired = await db
    .select({ id: sharePackages.id })
    .from(sharePackages)
    .where(and(
      lt(sharePackages.expiresAt, new Date()),
      inArray(sharePackages.status, ["building", "pending", "expired"]),
    ))
    .limit(limit)
    .all();
  let removed = 0;
  for (const pkg of expired) {
    const fenced = await db.update(sharePackages)
      .set({ status: "expired" })
      .where(and(
        eq(sharePackages.id, pkg.id),
        lt(sharePackages.expiresAt, new Date()),
        inArray(sharePackages.status, ["building", "pending", "expired"]),
      ))
      .run();
    if (fenced.meta?.changes !== 1) continue;
    const items = await db
      .select({ fileR2Key: sharePackageItems.fileR2Key, coverR2Key: sharePackageItems.coverR2Key })
      .from(sharePackageItems)
      .where(eq(sharePackageItems.packageId, pkg.id))
      .all();
    try {
      await db.delete(sharePackages).where(and(eq(sharePackages.id, pkg.id), eq(sharePackages.status, "expired"))).run();
      await deleteUnreferencedR2Objects(
        db,
        bucket,
        items.flatMap((item) => [item.fileR2Key, item.coverR2Key]),
      );
      removed += 1;
    } catch (error) {
      console.error("expired share cleanup failed", { packageId: pkg.id, error });
    }
  }
  return removed;
}

sharesRoutes.get("/preview", async (c) => {
  const token = c.req.query("token")?.trim();
  if (!token) return errorResponse(c, "SHARE_INVALID_REQUEST", 400);

  const db = createDb(c.env.DB);
  const tokenHash = await hashShareToken(token);
  const row = await db
    .select({
      pkg: sharePackages,
      senderName: user.name,
      senderUsername: usernames.username,
    })
    .from(sharePackages)
    .innerJoin(user, eq(user.id, sharePackages.senderUserId))
    .leftJoin(usernames, eq(usernames.userId, sharePackages.senderUserId))
    .where(eq(sharePackages.tokenHash, tokenHash))
    .get();

  if (!row) return errorResponse(c, "SHARE_NOT_FOUND", 404);
  if (isShareExpired(row.pkg.expiresAt)) {
    await db.update(sharePackages).set({ status: "expired" }).where(eq(sharePackages.id, row.pkg.id)).run();
    return errorResponse(c, "SHARE_EXPIRED", 410);
  }
  return c.json(await previewFor(c, db, row.pkg, row.senderName, row.senderUsername));
});

sharesRoutes.post("/", requireAuth, requireAiDataConsent, async (c) => {
  const body = await c.req.json().catch(() => null) as {
    idempotency_key?: unknown;
    kind?: unknown;
    book_ids?: unknown;
    delivery?: unknown;
    recipient_username?: unknown;
  } | null;
  if (
    !body || typeof body.idempotency_key !== "string" ||
    !["single", "selection", "library"].includes(String(body.kind)) ||
    !Array.isArray(body.book_ids) || body.book_ids.length < 1 || body.book_ids.length > MAX_SHARE_ITEMS ||
    !["link", "username"].includes(String(body.delivery))
  ) return errorResponse(c, "SHARE_INVALID_REQUEST", 400);

  const userId = c.get("userId");
  const kind = body.kind as ShareKind;
  const delivery = body.delivery as Delivery;
  const ids = [...new Set(body.book_ids.filter((id): id is string => typeof id === "string"))];
  if (ids.length !== body.book_ids.length) return errorResponse(c, "SHARE_INVALID_REQUEST", 400);
  if (kind === "single" && ids.length !== 1) return errorResponse(c, "SHARE_INVALID_REQUEST", 400);
  if (delivery === "username" && typeof body.recipient_username !== "string") {
    return errorResponse(c, "SHARE_INVALID_REQUEST", 400);
  }

  const db = createDb(c.env.DB);
  const deletionFence = await db
    .select({ status: deletionState.status })
    .from(deletionState)
    .where(eq(deletionState.userId, userId))
    .get();
  if (deletionFence) return errorResponse(c, "ACCOUNT_DELETION_IN_PROGRESS", 423);
  const existing = await db
    .select({ pkg: sharePackages })
    .from(sharePackages)
    .where(and(eq(sharePackages.senderUserId, userId), eq(sharePackages.idempotencyKey, body.idempotency_key)))
    .get();
  if (existing) {
    if (isShareExpired(existing.pkg.expiresAt)) return errorResponse(c, "SHARE_EXPIRED", 410);
    if (existing.pkg.status === "building") return errorResponse(c, "SHARE_IN_PROGRESS", 409);
    const existingDelivery: Delivery = existing.pkg.recipientUserId ? "username" : "link";
    if (delivery !== existingDelivery) {
      return errorResponse(c, "SHARE_IDEMPOTENCY_CONFLICT", 409);
    }
    const sender = await db
      .select({ name: user.name, username: usernames.username })
      .from(user)
      .leftJoin(usernames, eq(usernames.userId, user.id))
      .where(eq(user.id, userId))
      .get();
    if (!sender) return errorResponse(c, "SHARE_NOT_FOUND", 404);
    const preview = await previewFor(c, db, existing.pkg, sender.name, sender.username);
    const linkToken = existingDelivery === "link"
      ? await createShareTokenFromSecret(c.env.BETTER_AUTH_SECRET, userId, body.idempotency_key)
      : undefined;
    return c.json({
      id: preview.id,
      expires_at: preview.expires_at,
      link: linkToken ? packageLink(linkToken) : undefined,
      preview,
    });
  }

  let recipientUsername: string | null = null;
  if (delivery === "username") {
    const validation = validateUsername(String(body.recipient_username));
    if (!validation.ok) return errorResponse(c, "SHARE_INVALID_REQUEST", 400);
    recipientUsername = validation.value;
  }
  const recipient = recipientUsername
    ? await db
        .select({ id: user.id })
        .from(usernames)
        .innerJoin(user, eq(user.id, usernames.userId))
        .where(eq(usernames.username, normalizeUsername(recipientUsername)))
        .get()
    : null;
  if (delivery === "username" && !recipient) return errorResponse(c, "SHARE_RECIPIENT_NOT_FOUND", 404);
  if (recipient?.id === userId) return errorResponse(c, "SHARE_INVALID_REQUEST", 400);

  const sourceBooks = await db
    .select()
    .from(books)
    .where(and(eq(books.userId, userId), inArray(books.id, ids), eq(books.isDeleted, false)))
    .all();
  if (sourceBooks.length !== ids.length || sourceBooks.some((book) => !book.fileR2Key || !SUPPORTED_FORMATS.has(book.format))) {
    return errorResponse(c, "SHARE_BOOK_NOT_READY", 422);
  }

  const packageId = crypto.randomUUID();
  const token = delivery === "link"
    ? await createShareTokenFromSecret(c.env.BETTER_AUTH_SECRET, userId, body.idempotency_key)
    : null;
  const packageItems = sourceBooks.map((book) => {
    const itemId = crypto.randomUUID();
    const extension = book.format.toLowerCase();
    return {
      item: {
        id: itemId,
        packageId,
        title: book.title,
        author: book.author,
        format: extension,
        // These are references, not package-owned copies. Keeping the source
        // keys means every recipient reads the same immutable book object.
        fileR2Key: book.fileR2Key!,
        coverR2Key: book.coverR2Key ?? null,
        fileHash: book.fileHash,
        fileSize: Number(book.fileSize ?? 0),
        createdAt: new Date(),
      },
    };
  });
  let packageReserved = false;
  try {
    await db.insert(sharePackages).values({
      id: packageId,
      senderUserId: userId,
      recipientUserId: recipient?.id ?? null,
      tokenHash: token ? await hashShareToken(token) : null,
      kind,
      status: "building",
      idempotencyKey: body.idempotency_key,
      expiresAt: shareExpiry(),
      createdAt: new Date(),
    }).run();
    packageReserved = true;
    for (const { item } of packageItems) await db.insert(sharePackageItems).values(item).run();
    await db.update(sharePackages).set({ status: "pending" }).where(eq(sharePackages.id, packageId)).run();
  } catch (error) {
    // A concurrent request may have reserved the idempotency key first. The
    // reservation is created before the item references, so this loser can
    // safely ask the caller to retry while the winner completes its package.
    const winner = await db.select().from(sharePackages)
      .where(and(eq(sharePackages.senderUserId, userId), eq(sharePackages.idempotencyKey, body.idempotency_key)))
      .get();
    if (winner && winner.id !== packageId) {
      return errorResponse(c, "SHARE_IN_PROGRESS", 409);
    }
    if (!packageReserved) throw error;
    // The item rows are references only, so deleting the package releases
    // them without touching the source objects.
    await db.delete(sharePackages).where(eq(sharePackages.id, packageId)).run().catch(() => undefined);
    throw error;
  }

  const sender = await db
    .select({ name: user.name, username: usernames.username })
    .from(user)
    .leftJoin(usernames, eq(usernames.userId, user.id))
    .where(eq(user.id, userId))
    .get();
  const pkg = await db.select().from(sharePackages).where(eq(sharePackages.id, packageId)).get();
  if (!sender || !pkg) return errorResponse(c, "SHARE_NOT_FOUND", 500);

  if (delivery === "username" && recipient?.id) {
    const apns = createApnsSenderFromEnv(c.env as unknown as ApnsCredentialsEnv);
    const notificationPromise = emitShareCreatedPush(
      {
        apns,
        findDevicesByUserId: async (recipientUserId) => db
          .select({
            deviceToken: devices.deviceToken,
            topic: devices.topic,
            env: devices.env,
          })
          .from(devices)
          .where(eq(devices.userId, recipientUserId))
          .all(),
      },
      {
        recipientUserId: recipient.id,
        packageId,
        bookCount: packageItems.length,
      },
    );
    try {
      c.executionCtx.waitUntil(notificationPromise);
    } catch {
      // Hono's bare Request test context has no ExecutionContext. Awaiting
      // here keeps that context deterministic; Workers use waitUntil above.
      await notificationPromise;
    }
  }
  const preview = await previewFor(c, db, pkg, sender.name, sender.username);
  return c.json({
    id: preview.id,
    expires_at: preview.expires_at,
    link: token ? packageLink(token) : undefined,
    preview,
  }, 201);
});

async function claimPackage(
  c: ShareContext,
  packageId: string,
  tokenHash?: string,
) {
  const db = createDb(c.env.DB);
  const userId = c.get("userId");
  const pkg = await db.select().from(sharePackages).where(eq(sharePackages.id, packageId)).get();
  if (!pkg) return errorResponse(c, "SHARE_NOT_FOUND", 404);
  if (tokenHash && pkg.tokenHash !== tokenHash) return errorResponse(c, "SHARE_NOT_FOUND", 404);
  if (!tokenHash && !pkg.recipientUserId) {
    return errorResponse(c, "SHARE_TOKEN_REQUIRED", 403);
  }
  if (pkg.recipientUserId && pkg.recipientUserId !== userId) return errorResponse(c, "SHARE_ALREADY_CLAIMED", 409);
  if (isShareExpired(pkg.expiresAt) && pkg.status !== "claimed") {
    await db.update(sharePackages).set({ status: "expired" }).where(eq(sharePackages.id, pkg.id)).run();
    return errorResponse(c, "SHARE_EXPIRED", 410);
  }
  if (pkg.status === "claimed") {
    if (pkg.claimedBy !== userId) return errorResponse(c, "SHARE_ALREADY_CLAIMED", 409);
    return c.json(await downloadResponse(c, db, pkg.id));
  }
  const result = await db.update(sharePackages)
    .set({ status: "claimed", claimedAt: new Date(), claimedBy: userId })
    .where(and(eq(sharePackages.id, pkg.id), eq(sharePackages.status, "pending"), gt(sharePackages.expiresAt, new Date())))
    .run();
  if (result.meta?.changes !== 1) {
    const current = await db.select().from(sharePackages).where(eq(sharePackages.id, pkg.id)).get();
    if (current?.status === "claimed" && current.claimedBy === userId) return c.json(await downloadResponse(c, db, pkg.id));
    return errorResponse(c, current?.status === "expired" ? "SHARE_EXPIRED" : "SHARE_ALREADY_CLAIMED", current?.status === "expired" ? 410 : 409);
  }
  return c.json(await downloadResponse(c, db, pkg.id));
}

sharesRoutes.post("/redeem", requireAuth, requireAiDataConsent, async (c) => {
  const body = await c.req.json().catch(() => null) as { token?: unknown } | null;
  if (!body || typeof body.token !== "string" || body.token.length < 20) return errorResponse(c, "SHARE_INVALID_REQUEST", 400);
  const db = createDb(c.env.DB);
  const tokenHash = await hashShareToken(body.token);
  const pkg = await db.select({ id: sharePackages.id }).from(sharePackages).where(eq(sharePackages.tokenHash, tokenHash)).get();
  if (!pkg) return errorResponse(c, "SHARE_NOT_FOUND", 404);
  return claimPackage(c, pkg.id, tokenHash);
});

sharesRoutes.get("/inbox", requireAuth, requireAiDataConsent, async (c) => {
  const db = createDb(c.env.DB);
  const rows = await db
    .select({ pkg: sharePackages, senderName: user.name, senderUsername: usernames.username })
    .from(sharePackages)
    .innerJoin(user, eq(user.id, sharePackages.senderUserId))
    .leftJoin(usernames, eq(usernames.userId, sharePackages.senderUserId))
    .where(and(eq(sharePackages.recipientUserId, c.get("userId")), eq(sharePackages.status, "pending")))
    .all();
  const shares = [];
  for (const row of rows) {
    if (isShareExpired(row.pkg.expiresAt)) {
      await db.update(sharePackages).set({ status: "expired" }).where(eq(sharePackages.id, row.pkg.id)).run();
      continue;
    }
    shares.push(await previewFor(c, db, row.pkg, row.senderName, row.senderUsername));
  }
  return c.json({ shares });
});

sharesRoutes.post("/:id/accept", requireAuth, requireAiDataConsent, async (c) => {
  return claimPackage(c, c.req.param("id"));
});

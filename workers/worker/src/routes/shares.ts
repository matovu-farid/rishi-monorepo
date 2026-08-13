import { Hono } from "hono";
import type { Context } from "hono";
import { and, eq, gt, inArray, isNull, lt } from "drizzle-orm";

import { createDb } from "../db/drizzle";
import {
  books,
  deletionState,
  sharePackageItems,
  sharePackageRedemptions,
  shareLinkSlots,
  sharePackages,
  user,
} from "../db/schema";
import { requireAuth } from "../middleware";
import { requireAiDataConsent } from "../middleware/ai-data-consent";
import { signR2Url } from "../r2-presign";
import type { R2SigningEnv } from "../r2-presign";
import {
  createShareTokenFromSecret,
  hashShareToken,
  isShareExpired,
  shareExpiry,
} from "../shares/shareTokens";
import { deleteUnreferencedR2Objects } from "../shares/shareReferences";

const REFERENCE_DATE_OFFSET_MS = 978_307_200_000;
const DOWNLOAD_URL_EXPIRES_SEC = 600;
const MAX_SHARE_ITEMS = 500;
const SUPPORTED_FORMATS = new Set(["epub", "pdf", "mobi", "azw3"]);
const PREPARED_BUILD_LEASE_MS = 5 * 60 * 1000;
const MAX_PREPARE_BOOKS = 50;

type ShareKind = "single" | "selection" | "library";
type ShareAccess = "one_time" | "public";
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
  file_hash?: string | null;
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

function shareTokenSecrets(c: ShareContext): string[] {
  const env = c.env as unknown as {
    SHARE_TOKEN_SECRET?: string;
    SHARE_TOKEN_SECRET_PREVIOUS?: string;
    BETTER_AUTH_SECRET_PREVIOUS?: string;
  };
  return [...new Set([
    env.SHARE_TOKEN_SECRET,
    c.env.BETTER_AUTH_SECRET,
    env.SHARE_TOKEN_SECRET_PREVIOUS,
    env.BETTER_AUTH_SECRET_PREVIOUS,
  ].filter((secret): secret is string => Boolean(secret)))];
}

async function packageToken(
  c: ShareContext,
  pkg: typeof sharePackages.$inferSelect,
  senderUserId: string,
): Promise<string> {
  const secrets = shareTokenSecrets(c);
  for (const secret of secrets) {
    const token = await createShareTokenFromSecret(secret, senderUserId, pkg.idempotencyKey);
    if (!pkg.tokenHash || await hashShareToken(token) === pkg.tokenHash) return token;
  }
  return createShareTokenFromSecret(secrets[0] ?? c.env.BETTER_AUTH_SECRET, senderUserId, pkg.idempotencyKey);
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
    ...(item.fileHash ? { file_hash: item.fileHash } : {}),
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

function shareIdentity(title: string, author: string | null, format: string): string {
  return [title, author ?? "", format]
    .map((value) => value.toLowerCase().split(/\s+/).filter(Boolean).join(" "))
    .join("\u001f");
}

async function ownedItemIDs(
  db: ReturnType<typeof createDb>,
  packageId: string,
  userId: string,
): Promise<Set<string>> {
  const [packageItems, ownedBooks] = await Promise.all([
    itemsFor(db, packageId),
    db.select({
      title: books.title,
      author: books.author,
      format: books.format,
      fileHash: books.fileHash,
    }).from(books).where(and(eq(books.userId, userId), eq(books.isDeleted, false))).all(),
  ]);
  const owned = new Set<string>();
  for (const item of packageItems) {
    if (ownedBooks.some((book) => {
      if (item.fileHash && book.fileHash) return item.fileHash === book.fileHash;
      return shareIdentity(item.title, item.author, item.format)
        === shareIdentity(book.title, book.author, book.format);
    })) {
      owned.add(item.id);
    }
  }
  return owned;
}

async function previewFor(
  c: ShareContext,
  db: ReturnType<typeof createDb>,
  pkg: typeof sharePackages.$inferSelect,
  senderName: string,
) {
  const items = await itemsFor(db, pkg.id);
  return {
    id: pkg.id,
    sender_name: senderName,
    count: items.length,
    items: await Promise.all(items.map((item) => previewItem(c, item))),
    expires_at: referenceSeconds(pkg.expiresAt),
  };
}

async function downloadResponse(
  c: Parameters<typeof requireAuth>[0],
  db: ReturnType<typeof createDb>,
  packageId: string,
  excludedItemIDs: Set<string> = new Set(),
) {
  const items = (await itemsFor(db, packageId)).filter((item) => !excludedItemIDs.has(item.id));
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
      inArray(sharePackages.status, ["building", "pending", "claimed", "expired"]),
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
        inArray(sharePackages.status, ["building", "pending", "claimed", "expired"]),
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
    })
    .from(sharePackages)
    .innerJoin(user, eq(user.id, sharePackages.senderUserId))
    .where(eq(sharePackages.tokenHash, tokenHash))
    .get();

  if (!row) return errorResponse(c, "SHARE_NOT_FOUND", 404);
  if (isShareExpired(row.pkg.expiresAt)) {
    await db.update(sharePackages).set({ status: "expired" }).where(eq(sharePackages.id, row.pkg.id)).run();
    return errorResponse(c, "SHARE_EXPIRED", 410);
  }
  return c.json(await previewFor(c, db, row.pkg, row.senderName));
});

sharesRoutes.post("/", requireAuth, requireAiDataConsent, async (c) => {
  const body = await c.req.json().catch(() => null) as {
    idempotency_key?: unknown;
    kind?: unknown;
    book_ids?: unknown;
    delivery?: unknown;
    access?: unknown;
  } | null;
  if (
    !body || typeof body.idempotency_key !== "string" ||
    !["single", "selection", "library"].includes(String(body.kind)) ||
    !Array.isArray(body.book_ids) || body.book_ids.length < 1 || body.book_ids.length > MAX_SHARE_ITEMS ||
    body.delivery !== "link" ||
    !["one_time", "public"].includes(String(body.access))
  ) return errorResponse(c, "SHARE_INVALID_REQUEST", 400);

  const userId = c.get("userId");
  const kind = body.kind as ShareKind;
  const access = body.access as ShareAccess;
  const ids = [...new Set(body.book_ids.filter((id): id is string => typeof id === "string"))];
  if (ids.length !== body.book_ids.length) return errorResponse(c, "SHARE_INVALID_REQUEST", 400);
  if (kind === "single" && ids.length !== 1) return errorResponse(c, "SHARE_INVALID_REQUEST", 400);

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
    if (existing.pkg.recipientUserId || existing.pkg.access !== access) {
      return errorResponse(c, "SHARE_IDEMPOTENCY_CONFLICT", 409);
    }
    const sender = await db
      .select({ name: user.name })
      .from(user)
      .where(eq(user.id, userId))
      .get();
    if (!sender) return errorResponse(c, "SHARE_NOT_FOUND", 404);
    const preview = await previewFor(c, db, existing.pkg, sender.name);
    const linkToken = await packageToken(c, existing.pkg, userId);
    return c.json({
      id: preview.id,
      expires_at: preview.expires_at,
      link: linkToken ? packageLink(linkToken) : undefined,
      preview,
    });
  }

  const sourceBooks = await db
    .select()
    .from(books)
    .where(and(eq(books.userId, userId), inArray(books.id, ids), eq(books.isDeleted, false)))
    .all();
  if (sourceBooks.length !== ids.length || sourceBooks.some((book) => !book.fileR2Key || !SUPPORTED_FORMATS.has(book.format))) {
    return errorResponse(c, "SHARE_BOOK_NOT_READY", 422);
  }

  const packageId = crypto.randomUUID();
  const tokenSecret = shareTokenSecrets(c)[0] ?? c.env.BETTER_AUTH_SECRET;
  const token = await createShareTokenFromSecret(tokenSecret, userId, body.idempotency_key);
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
      recipientUserId: null,
      tokenHash: token ? await hashShareToken(token) : null,
      kind,
      access,
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
    .select({ name: user.name })
    .from(user)
    .where(eq(user.id, userId))
    .get();
  const pkg = await db.select().from(sharePackages).where(eq(sharePackages.id, packageId)).get();
  if (!sender || !pkg) return errorResponse(c, "SHARE_NOT_FOUND", 500);

  const preview = await previewFor(c, db, pkg, sender.name);
  return c.json({
    id: preview.id,
    expires_at: preview.expires_at,
    link: token ? packageLink(token) : undefined,
    preview,
  }, 201);
});

async function preparedLinkFor(
  c: ShareContext,
  db: ReturnType<typeof createDb>,
  userId: string,
  book: typeof books.$inferSelect,
  access: ShareAccess,
) {
  const now = new Date();
  let slot = await db.select().from(shareLinkSlots).where(and(
    eq(shareLinkSlots.ownerUserId, userId),
    eq(shareLinkSlots.bookId, book.id),
    eq(shareLinkSlots.access, access),
  )).get();

  if (!slot) {
    const slotID = crypto.randomUUID();
    await db.insert(shareLinkSlots).values({
      id: slotID,
      ownerUserId: userId,
      bookId: book.id,
      access,
      generation: 0,
      activePackageId: null,
      createdAt: now,
      updatedAt: now,
    }).onConflictDoNothing().run();
    slot = await db.select().from(shareLinkSlots).where(and(
      eq(shareLinkSlots.ownerUserId, userId),
      eq(shareLinkSlots.bookId, book.id),
      eq(shareLinkSlots.access, access),
    )).get();
  }
  if (!slot) throw new Error("prepared share slot unavailable");

  if (slot.activePackageId) {
    const active = await db.select().from(sharePackages).where(eq(sharePackages.id, slot.activePackageId)).get();
    if (active && !isShareExpired(active.expiresAt) && active.status === "pending") {
      const token = await packageToken(c, active, userId);
      return { bookID: book.id, access, packageID: active.id, generation: slot.generation, expiresAt: active.expiresAt, link: packageLink(token) };
    }
    if (active?.status === "building" && now.getTime() - active.createdAt.getTime() < PREPARED_BUILD_LEASE_MS) {
      throw new Error("prepared share is still building");
    }
    if (active?.status === "building") {
      await db.update(sharePackages).set({ status: "expired" }).where(and(
        eq(sharePackages.id, active.id),
        eq(sharePackages.status, "building"),
        lt(sharePackages.createdAt, new Date(now.getTime() - PREPARED_BUILD_LEASE_MS)),
      )).run();
    }
  }

  let nextGeneration = slot.activePackageId ? slot.generation + 1 : slot.generation;
  let idempotencyKey = `prepared:${slot.id}:${nextGeneration}`;
  let pkg = await db.select().from(sharePackages).where(and(
    eq(sharePackages.senderUserId, userId),
    eq(sharePackages.idempotencyKey, idempotencyKey),
  )).get();
  let createdPackage = false;
  if (pkg && (pkg.status === "expired" || (pkg.status === "building" && now.getTime() - pkg.createdAt.getTime() >= PREPARED_BUILD_LEASE_MS))) {
    await db.update(sharePackages).set({ status: "expired" }).where(and(eq(sharePackages.id, pkg.id), inArray(sharePackages.status, ["building", "expired"]))).run();
    nextGeneration += 1;
    idempotencyKey = `prepared:${slot.id}:${nextGeneration}`;
    pkg = undefined;
  }
  if (!pkg) {
    const packageID = crypto.randomUUID();
    const tokenSecret = shareTokenSecrets(c)[0] ?? c.env.BETTER_AUTH_SECRET;
    const token = await createShareTokenFromSecret(tokenSecret, userId, idempotencyKey);
    try {
      await db.insert(sharePackages).values({
        id: packageID,
        senderUserId: userId,
        recipientUserId: null,
        tokenHash: await hashShareToken(token),
        kind: "single",
        access,
        status: "building",
        idempotencyKey,
        expiresAt: shareExpiry(),
        createdAt: now,
      }).run();
      createdPackage = true;
      await db.insert(sharePackageItems).values({
        id: crypto.randomUUID(),
        packageId: packageID,
        title: book.title,
        author: book.author,
        format: book.format.toLowerCase(),
        fileR2Key: book.fileR2Key!,
        coverR2Key: book.coverR2Key ?? null,
        fileHash: book.fileHash,
        fileSize: Number(book.fileSize ?? 0),
        createdAt: now,
      }).run();
      await db.update(sharePackages).set({ status: "pending" }).where(and(
        eq(sharePackages.id, packageID),
        eq(sharePackages.status, "building"),
        eq(sharePackages.createdAt, now),
      )).run();
    } catch (error) {
      pkg = await db.select().from(sharePackages).where(and(
        eq(sharePackages.senderUserId, userId),
        eq(sharePackages.idempotencyKey, idempotencyKey),
      )).get();
      if (!pkg) throw error;
    }
    pkg ??= await db.select().from(sharePackages).where(eq(sharePackages.id, packageID)).get();
  }
  if (!pkg || pkg.status !== "pending") {
    if (createdPackage && pkg?.status === "building") {
      await db.update(sharePackages).set({ status: "expired" }).where(and(eq(sharePackages.id, pkg.id), eq(sharePackages.status, "building"))).run();
    }
    throw new Error("prepared share incomplete");
  }

  const pointer = await db.update(shareLinkSlots).set({
    activePackageId: pkg.id,
    generation: nextGeneration,
    updatedAt: new Date(),
  }).where(and(
    eq(shareLinkSlots.id, slot.id),
    eq(shareLinkSlots.generation, slot.generation),
    slot.activePackageId
      ? eq(shareLinkSlots.activePackageId, slot.activePackageId)
      : isNull(shareLinkSlots.activePackageId),
  )).run();
  if (pointer.meta?.changes !== 1) {
    const winner = await db.select({ slot: shareLinkSlots, pkg: sharePackages })
      .from(shareLinkSlots)
      .innerJoin(sharePackages, eq(sharePackages.id, shareLinkSlots.activePackageId))
      .where(eq(shareLinkSlots.id, slot.id)).get();
    if (!winner || winner.pkg.status !== "pending") throw new Error("prepared share race lost");
    if (winner.pkg.id !== pkg.id) {
      const referenced = await db.select({ id: shareLinkSlots.id })
        .from(shareLinkSlots)
        .where(eq(shareLinkSlots.activePackageId, pkg.id))
        .get();
      if (!referenced) {
        await db.update(sharePackages).set({ status: "expired" }).where(and(
          eq(sharePackages.id, pkg.id),
          eq(sharePackages.status, "pending"),
        )).run();
      }
    }
    const winnerToken = await packageToken(c, winner.pkg, userId);
    return { bookID: book.id, access, packageID: winner.pkg.id, generation: winner.slot.generation, expiresAt: winner.pkg.expiresAt, link: packageLink(winnerToken) };
  }
  const token = await packageToken(c, pkg, userId);
  return { bookID: book.id, access, packageID: pkg.id, generation: nextGeneration, expiresAt: pkg.expiresAt, link: packageLink(token) };
}

sharesRoutes.post("/prepare", requireAuth, requireAiDataConsent, async (c) => {
  const body = await c.req.json().catch(() => null) as { book_ids?: unknown } | null;
  if (!body || !Array.isArray(body.book_ids) || body.book_ids.length < 1 || body.book_ids.length > MAX_PREPARE_BOOKS) {
    return errorResponse(c, "SHARE_INVALID_REQUEST", 400);
  }
  const ids = [...new Set(body.book_ids)];
  if (ids.some((id) => typeof id !== "string") || ids.length !== body.book_ids.length) {
    return errorResponse(c, "SHARE_INVALID_REQUEST", 400);
  }
  const userId = c.get("userId");
  const db = createDb(c.env.DB);
  const sourceBooks = await db.select().from(books).where(and(
    eq(books.userId, userId),
    inArray(books.id, ids as string[]),
    eq(books.isDeleted, false),
  )).all();
  const byID = new Map(sourceBooks.map((book) => [book.id, book]));
  const links: Array<Record<string, unknown>> = [];
  const skipped: Array<{ book_id: string; code: string }> = [];
  for (const id of ids as string[]) {
    const book = byID.get(id);
    if (!book || !book.fileR2Key || !SUPPORTED_FORMATS.has(book.format)) {
      skipped.push({ book_id: id, code: "SHARE_BOOK_NOT_READY" });
      continue;
    }
    try {
      const preparedForBook = await Promise.all([
        preparedLinkFor(c, db, userId, book, "public"),
        preparedLinkFor(c, db, userId, book, "one_time"),
      ]);
      const [publicLink, oneTimeLink] = preparedForBook;
      const packagePayload = (link: typeof publicLink) => ({
        id: link.packageID,
        generation: link.generation,
        expires_at: referenceSeconds(link.expiresAt),
        link: link.link,
      });
      links.push({ book_id: book.id, public: packagePayload(publicLink), one_time: packagePayload(oneTimeLink) });
    } catch (error) {
      console.error("prepared share failed", { userId, bookId: id, error });
      const message = error instanceof Error ? error.message : "";
      if (["prepared share is still building", "prepared share incomplete", "prepared share race lost"].includes(message)) {
        skipped.push({ book_id: id, code: "SHARE_IN_PROGRESS" });
        continue;
      }
      throw error;
    }
  }
  return c.json({ links, skipped });
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
  if (isShareExpired(pkg.expiresAt)) {
    await db.update(sharePackages).set({ status: "expired" }).where(eq(sharePackages.id, pkg.id)).run();
    return errorResponse(c, "SHARE_EXPIRED", 410);
  }
  if (pkg.status === "building") return errorResponse(c, "SHARE_IN_PROGRESS", 409);

  // The sender already has the source books. Opening their own pending link
  // is a successful no-op and must not consume a one-time link intended for
  // somebody else.
  if (pkg.senderUserId === userId) {
    return c.json({ id: pkg.id, items: [] });
  }

  const packageItems = await itemsFor(db, pkg.id);
  const owned = await ownedItemIDs(db, pkg.id, userId);
  if (owned.size === packageItems.length) {
    return c.json({ id: pkg.id, items: [] });
  }

  if (pkg.access === "public") {
    if (pkg.status !== "pending") return errorResponse(c, "SHARE_EXPIRED", 410);
    await db.insert(sharePackageRedemptions).values({
      id: crypto.randomUUID(),
      packageId: pkg.id,
      userId,
      createdAt: new Date(),
    }).onConflictDoNothing({
      target: [sharePackageRedemptions.packageId, sharePackageRedemptions.userId],
    }).run();
    return c.json(await downloadResponse(c, db, pkg.id, owned));
  }

  if (pkg.status === "claimed") {
    if (pkg.claimedBy !== userId) return errorResponse(c, "SHARE_ALREADY_CLAIMED", 409);
    return c.json(await downloadResponse(c, db, pkg.id, owned));
  }
  const result = await db.update(sharePackages)
    .set({ status: "claimed", claimedAt: new Date(), claimedBy: userId })
    .where(and(
      eq(sharePackages.id, pkg.id),
      eq(sharePackages.status, "pending"),
      eq(sharePackages.access, "one_time"),
      gt(sharePackages.expiresAt, new Date()),
    ))
    .run();
  if (result.meta?.changes !== 1) {
    const current = await db.select().from(sharePackages).where(eq(sharePackages.id, pkg.id)).get();
    if (current?.status === "claimed" && current.claimedBy === userId) return c.json(await downloadResponse(c, db, pkg.id));
    return errorResponse(c, current?.status === "expired" ? "SHARE_EXPIRED" : "SHARE_ALREADY_CLAIMED", current?.status === "expired" ? 410 : 409);
  }
  return c.json(await downloadResponse(c, db, pkg.id, owned));
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

import { Hono } from "hono";
import { eq, gt, sql, and, max } from "drizzle-orm";
import type { CloudflareBindings } from "../index";
import { requireWorkerAuth } from "../index";
import { createDb } from "../db/drizzle";
import { books, highlights } from "@rishi/shared/schema";
import type { PushRequest, PushResponse, PullResponse } from "@rishi/shared/sync-types";

export const syncRoutes = new Hono<{
  Bindings: CloudflareBindings;
  Variables: { userId: string };
}>();

// ─── POST /push ────────────────────────────────────────────────────────────────
// Accepts dirty book and highlight records from client, upserts into D1 with LWW resolution.
// filePath and coverPath are stripped before writing -- they are local-only paths.
syncRoutes.post("/push", requireWorkerAuth, async (c) => {
  const body = await c.req.json<PushRequest>();
  const userId = c.get("userId");
  const db = createDb(c.env.DB);

  const conflicts: Array<Record<string, unknown>> = [];
  const upsertedBookIds: string[] = [];
  const upsertedHighlightIds: string[] = [];

  // ── Books upsert loop ──────────────────────────────────────────────────────
  for (const book of body.changes.books) {
    // Strip local-only fields -- these MUST NOT be written to D1
    const {
      filePath,
      coverPath,
      isDirty,
      ...serverFields
    } = book as Record<string, unknown>;

    const bookId = serverFields.id as string;
    if (!bookId) continue;

    // Look up existing record scoped to this user
    const existing = await db
      .select()
      .from(books)
      .where(and(eq(books.id, bookId), eq(books.userId, userId)))
      .get();

    const pushedUpdatedAt = (serverFields.updatedAt as number) ?? 0;

    if (!existing) {
      // INSERT new record
      await db.insert(books).values({
        ...serverFields,
        id: bookId,
        userId,
        // Ensure filePath has a default for the NOT NULL constraint in schema
        filePath: "",
        updatedAt: pushedUpdatedAt || Date.now(),
        createdAt: (serverFields.createdAt as number) || Date.now(),
      } as typeof books.$inferInsert);
      upsertedBookIds.push(bookId);
    } else if (pushedUpdatedAt > (existing.updatedAt ?? 0)) {
      // Client is newer -- UPDATE (excluding filePath/coverPath)
      const { id, createdAt, ...updateFields } = serverFields;
      await db
        .update(books)
        .set({
          ...updateFields,
          filePath: existing.filePath, // Preserve server's existing value
          coverPath: existing.coverPath, // Preserve server's existing value
          updatedAt: pushedUpdatedAt,
        } as Partial<typeof books.$inferInsert>)
        .where(and(eq(books.id, bookId), eq(books.userId, userId)));
      upsertedBookIds.push(bookId);
    } else {
      // Server is newer -- conflict
      conflicts.push(existing as unknown as Record<string, unknown>);
    }
  }

  // ── Highlights upsert loop ─────────────────────────────────────────────────
  for (const highlight of body.changes.highlights ?? []) {
    const { isDirty, ...serverFields } = highlight as Record<string, unknown>;
    const highlightId = serverFields.id as string;
    if (!highlightId) continue;

    const existing = await db
      .select()
      .from(highlights)
      .where(and(eq(highlights.id, highlightId), eq(highlights.userId, userId)))
      .get();

    const pushedUpdatedAt = (serverFields.updatedAt as number) ?? 0;

    if (!existing) {
      // INSERT new highlight (union merge: always accept new highlights)
      await db.insert(highlights).values({
        ...serverFields,
        id: highlightId,
        userId,
        updatedAt: pushedUpdatedAt || Date.now(),
        createdAt: (serverFields.createdAt as number) || Date.now(),
      } as typeof highlights.$inferInsert);
      upsertedHighlightIds.push(highlightId);
    } else if (pushedUpdatedAt > (existing.updatedAt ?? 0)) {
      // Client is newer -- UPDATE (LWW by updatedAt)
      const { id, createdAt, ...updateFields } = serverFields;
      await db
        .update(highlights)
        .set({
          ...updateFields,
          updatedAt: pushedUpdatedAt,
        } as Partial<typeof highlights.$inferInsert>)
        .where(and(eq(highlights.id, highlightId), eq(highlights.userId, userId)));
      upsertedHighlightIds.push(highlightId);
    } else {
      // Server is newer -- return server version as conflict (union merge: never delete)
      conflicts.push(existing as unknown as Record<string, unknown>);
    }
  }

  // ── Assign syncVersion to all upserted records ────────────────────────────
  const totalUpserted = upsertedBookIds.length + upsertedHighlightIds.length;
  let newSyncVersion = 0;

  if (totalUpserted > 0) {
    // Get current max syncVersion across both tables
    const maxBookVersion = (await db.select({ v: max(books.syncVersion) }).from(books).get())?.v ?? 0;
    const maxHighlightVersion = (await db.select({ v: max(highlights.syncVersion) }).from(highlights).get())?.v ?? 0;
    newSyncVersion = Math.max(maxBookVersion, maxHighlightVersion) + 1;

    // Update all upserted books with the new syncVersion
    for (const id of upsertedBookIds) {
      await db
        .update(books)
        .set({ syncVersion: newSyncVersion, isDirty: false })
        .where(eq(books.id, id));
    }

    // Update all upserted highlights with the new syncVersion
    for (const id of upsertedHighlightIds) {
      await db
        .update(highlights)
        .set({ syncVersion: newSyncVersion, isDirty: false })
        .where(eq(highlights.id, id));
    }
  } else {
    // No upserts -- return current max version across both tables
    const maxBookVersion = (await db.select({ v: max(books.syncVersion) }).from(books).get())?.v ?? 0;
    const maxHighlightVersion = (await db.select({ v: max(highlights.syncVersion) }).from(highlights).get())?.v ?? 0;
    newSyncVersion = Math.max(maxBookVersion, maxHighlightVersion);
  }

  const response: PushResponse = {
    conflicts,
    syncVersion: newSyncVersion,
  };

  return c.json(response);
});

// ─── GET /pull ─────────────────────────────────────────────────────────────────
// Returns books and highlights changed since the given syncVersion for the authenticated user.
// filePath is set to '' and coverPath to null to prevent path contamination.
syncRoutes.get("/pull", requireWorkerAuth, async (c) => {
  const sinceVersion = Number(c.req.query("since_version") ?? "0");
  const userId = c.get("userId");
  const db = createDb(c.env.DB);

  const changedBooks = await db
    .select()
    .from(books)
    .where(
      and(
        eq(books.userId, userId),
        gt(books.syncVersion, sinceVersion)
      )
    )
    .all();

  // Strip local-only paths from response -- client must never overwrite its local paths
  const sanitizedBooks = changedBooks.map((book) => ({
    ...book,
    filePath: "",
    coverPath: null,
  }));

  const changedHighlights = await db
    .select()
    .from(highlights)
    .where(
      and(
        eq(highlights.userId, userId),
        gt(highlights.syncVersion, sinceVersion)
      )
    )
    .all();

  // Get current max syncVersion across both tables for this user
  const maxBookVer = (await db.select({ v: max(books.syncVersion) }).from(books).where(eq(books.userId, userId)).get())?.v ?? 0;
  const maxHighVer = (await db.select({ v: max(highlights.syncVersion) }).from(highlights).where(eq(highlights.userId, userId)).get())?.v ?? 0;
  const currentSyncVersion = Math.max(maxBookVer, maxHighVer);

  const response: PullResponse = {
    changes: {
      books: sanitizedBooks as unknown as Array<Record<string, unknown>>,
      highlights: changedHighlights as unknown as Array<Record<string, unknown>>,
    },
    syncVersion: currentSyncVersion,
  };

  return c.json(response);
});

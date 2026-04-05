import { Hono } from "hono";
import { eq, gt, sql, and, max } from "drizzle-orm";
import type { CloudflareBindings } from "../index";
import { requireWorkerAuth } from "../index";
import { createDb } from "../db/drizzle";
import { books } from "@rishi/shared/schema";
import type { PushRequest, PushResponse, PullResponse } from "@rishi/shared/sync-types";

export const syncRoutes = new Hono<{
  Bindings: CloudflareBindings;
  Variables: { userId: string };
}>();

// ─── POST /push ────────────────────────────────────────────────────────────────
// Accepts dirty book records from client, upserts into D1 with LWW resolution.
// filePath and coverPath are stripped before writing -- they are local-only paths.
syncRoutes.post("/push", requireWorkerAuth, async (c) => {
  const body = await c.req.json<PushRequest>();
  const userId = c.get("userId");
  const db = createDb(c.env.DB);

  const conflicts: Array<Record<string, unknown>> = [];
  const upsertedIds: string[] = [];

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
      upsertedIds.push(bookId);
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
      upsertedIds.push(bookId);
    } else {
      // Server is newer -- conflict
      conflicts.push(existing as unknown as Record<string, unknown>);
    }
  }

  // Assign new syncVersion to all upserted records
  let newSyncVersion = 0;
  if (upsertedIds.length > 0) {
    // Get current max syncVersion
    const maxResult = await db
      .select({ maxVersion: max(books.syncVersion) })
      .from(books)
      .get();
    newSyncVersion = (maxResult?.maxVersion ?? 0) + 1;

    // Update all upserted records with the new syncVersion
    for (const id of upsertedIds) {
      await db
        .update(books)
        .set({ syncVersion: newSyncVersion, isDirty: false })
        .where(eq(books.id, id));
    }
  } else {
    // No upserts -- return current max version
    const maxResult = await db
      .select({ maxVersion: max(books.syncVersion) })
      .from(books)
      .get();
    newSyncVersion = maxResult?.maxVersion ?? 0;
  }

  const response: PushResponse = {
    conflicts,
    syncVersion: newSyncVersion,
  };

  return c.json(response);
});

// ─── GET /pull ─────────────────────────────────────────────────────────────────
// Returns books changed since the given syncVersion for the authenticated user.
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

  // Get current max syncVersion
  const maxResult = await db
    .select({ maxVersion: max(books.syncVersion) })
    .from(books)
    .where(eq(books.userId, userId))
    .get();
  const currentSyncVersion = maxResult?.maxVersion ?? 0;

  const response: PullResponse = {
    changes: {
      books: sanitizedBooks as unknown as Array<Record<string, unknown>>,
    },
    syncVersion: currentSyncVersion,
  };

  return c.json(response);
});

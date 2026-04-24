import { Hono } from "hono";
import { eq, gt, and, max, asc, inArray, sql } from "drizzle-orm";
import { z } from "zod";
import type { CloudflareBindings } from "../index";
import { requireWorkerAuth } from "../index";
import { createDb } from "../db/drizzle";
import { books, highlights, conversations, messages } from "@rishi/shared/schema";
import type { PushResponse, PullResponse } from "@rishi/shared/sync-types";

const pushRequestSchema = z.object({
  changes: z.object({
    books: z.array(z.record(z.string(), z.unknown())).max(500).default([]),
    highlights: z.array(z.record(z.string(), z.unknown())).max(5000).default([]),
    conversations: z.array(z.record(z.string(), z.unknown())).max(500).default([]),
    messages: z.array(z.record(z.string(), z.unknown())).max(5000).default([]),
  }),
});

export const syncRoutes = new Hono<{
  Bindings: CloudflareBindings;
  Variables: { userId: string };
}>();

// ─── POST /push ────────────────────────────────────────────────────────────────
// Accepts dirty book and highlight records from client, upserts into D1 with LWW resolution.
// filePath and coverPath are stripped before writing -- they are local-only paths.
syncRoutes.post("/push", requireWorkerAuth, async (c) => {
  const body = pushRequestSchema.parse(await c.req.json());
  const userId = c.get("userId");
  const db = createDb(c.env.DB);

  const result = await db.transaction(async (tx) => {
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
      const existing = await tx
        .select()
        .from(books)
        .where(and(eq(books.id, bookId), eq(books.userId, userId)))
        .get();

      const pushedUpdatedAt = (serverFields.updatedAt as number) ?? 0;

      if (!existing) {
        // INSERT new record
        await tx.insert(books).values({
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
        await tx
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

      const existing = await tx
        .select()
        .from(highlights)
        .where(and(eq(highlights.id, highlightId), eq(highlights.userId, userId)))
        .get();

      const pushedUpdatedAt = (serverFields.updatedAt as number) ?? 0;

      if (!existing) {
        // INSERT new highlight (union merge: always accept new highlights)
        await tx.insert(highlights).values({
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
        await tx
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

    // ── Conversations upsert loop (LWW) ──────────────────────────────────────
    const upsertedConversationIds: string[] = [];

    for (const conv of body.changes.conversations ?? []) {
      const { isDirty, ...serverFields } = conv as Record<string, unknown>;
      const convId = serverFields.id as string;
      if (!convId) continue;

      const existing = await tx
        .select()
        .from(conversations)
        .where(and(eq(conversations.id, convId), eq(conversations.userId, userId)))
        .get();

      const pushedUpdatedAt = (serverFields.updatedAt as number) ?? 0;

      if (!existing) {
        await tx.insert(conversations).values({
          ...serverFields,
          id: convId,
          userId,
          updatedAt: pushedUpdatedAt || Date.now(),
          createdAt: (serverFields.createdAt as number) || Date.now(),
        } as typeof conversations.$inferInsert);
        upsertedConversationIds.push(convId);
      } else if (pushedUpdatedAt > (existing.updatedAt ?? 0)) {
        const { id, createdAt, ...updateFields } = serverFields;
        await tx
          .update(conversations)
          .set({
            ...updateFields,
            updatedAt: pushedUpdatedAt,
          } as Partial<typeof conversations.$inferInsert>)
          .where(and(eq(conversations.id, convId), eq(conversations.userId, userId)));
        upsertedConversationIds.push(convId);
      } else {
        conflicts.push(existing as unknown as Record<string, unknown>);
      }
    }

    // ── Messages upsert loop (append-only) ─────────────────────────────────
    const upsertedMessageIds: string[] = [];

    for (const msg of body.changes.messages ?? []) {
      const { isDirty, ...serverFields } = msg as Record<string, unknown>;
      const msgId = serverFields.id as string;
      if (!msgId) continue;

      const existing = await tx
        .select()
        .from(messages)
        .where(eq(messages.id, msgId))
        .get();

      if (existing) {
        // Append-only: never update existing messages, skip entirely
        continue;
      }

      // Verify the parent conversation belongs to this user before inserting
      const convId = serverFields.conversationId as string;
      if (!convId) continue;

      const parentConv = await tx
        .select({ userId: conversations.userId })
        .from(conversations)
        .where(and(eq(conversations.id, convId), eq(conversations.userId, userId)))
        .get();

      if (!parentConv) {
        // Conversation doesn't exist or doesn't belong to this user -- skip
        continue;
      }

      // New message -- insert (userId verified via conversation ownership)
      await tx.insert(messages).values({
        ...serverFields,
        id: msgId,
        updatedAt: (serverFields.updatedAt as number) || Date.now(),
        createdAt: (serverFields.createdAt as number) || Date.now(),
      } as typeof messages.$inferInsert);
      upsertedMessageIds.push(msgId);
    }

    // ── Assign syncVersion to all upserted records (inside transaction) ────
    const totalUpserted = upsertedBookIds.length + upsertedHighlightIds.length + upsertedConversationIds.length + upsertedMessageIds.length;
    let newSyncVersion = 0;

    if (totalUpserted > 0) {
      // Compute the next version ONCE inside the transaction to guarantee all
      // records in this push get the same monotonically increasing version
      // number. The transaction isolation prevents concurrent pushes from
      // reading the same MAX and assigning duplicate versions.
      const nextVersionResult = await tx.get<{ next_version: number }>(
        sql`SELECT COALESCE(MAX(v), 0) + 1 AS next_version FROM (
          SELECT MAX(sync_version) AS v FROM books
          UNION ALL SELECT MAX(sync_version) AS v FROM highlights
          UNION ALL SELECT MAX(sync_version) AS v FROM conversations
          UNION ALL SELECT MAX(sync_version) AS v FROM messages
        )`
      );
      const nextVersion = nextVersionResult?.next_version ?? 1;

      // Update all upserted books
      for (const id of upsertedBookIds) {
        await tx.run(sql`UPDATE books SET sync_version = ${nextVersion}, is_dirty = 0 WHERE id = ${id}`);
      }

      // Update all upserted highlights
      for (const id of upsertedHighlightIds) {
        await tx.run(sql`UPDATE highlights SET sync_version = ${nextVersion}, is_dirty = 0 WHERE id = ${id}`);
      }

      // Update all upserted conversations
      for (const id of upsertedConversationIds) {
        await tx.run(sql`UPDATE conversations SET sync_version = ${nextVersion}, is_dirty = 0 WHERE id = ${id}`);
      }

      // Update all upserted messages
      for (const id of upsertedMessageIds) {
        await tx.run(sql`UPDATE messages SET sync_version = ${nextVersion}, is_dirty = 0 WHERE id = ${id}`);
      }

      newSyncVersion = nextVersion;
    } else {
      // No upserts -- return current max version across all tables
      const versionResult = await tx.get<{ v: number }>(
        sql`SELECT COALESCE(MAX(v), 0) AS v FROM (
          SELECT MAX(sync_version) AS v FROM books
          UNION ALL SELECT MAX(sync_version) AS v FROM highlights
          UNION ALL SELECT MAX(sync_version) AS v FROM conversations
          UNION ALL SELECT MAX(sync_version) AS v FROM messages
        )`
      );
      newSyncVersion = versionResult?.v ?? 0;
    }

    return { conflicts, syncVersion: newSyncVersion };
  });

  const response: PushResponse = {
    conflicts: result.conflicts,
    syncVersion: result.syncVersion,
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

  // NOTE: Deleted records (isDeleted = true) are intentionally NOT filtered out.
  // They must be included in pull results so other devices learn about deletions
  // and can apply the soft-delete locally.
  const PULL_LIMIT = 5000;

  const changedBooks = await db
    .select()
    .from(books)
    .where(
      and(
        eq(books.userId, userId),
        gt(books.syncVersion, sinceVersion)
      )
    )
    .limit(PULL_LIMIT)
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
    .limit(PULL_LIMIT)
    .all();

  // ── Pull conversations ─────���───────────────────────────���──────────────────
  const changedConversations = await db
    .select()
    .from(conversations)
    .where(
      and(
        eq(conversations.userId, userId),
        gt(conversations.syncVersion, sinceVersion)
      )
    )
    .limit(PULL_LIMIT)
    .all();

  // ── Pull messages (via user's conversations) ─────────────────────────────
  // Get all conversation IDs belonging to this user
  const userConvIds = (
    await db
      .select({ id: conversations.id })
      .from(conversations)
      .where(eq(conversations.userId, userId))
      .all()
  ).map((c) => c.id);

  let changedMessages: Array<typeof messages.$inferSelect> = [];
  if (userConvIds.length > 0) {
    // Fetch messages for user's conversations that changed since sinceVersion
    changedMessages = await db
      .select()
      .from(messages)
      .where(
        and(
          gt(messages.syncVersion, sinceVersion),
          inArray(messages.conversationId, userConvIds)
        )
      )
      .orderBy(asc(messages.createdAt))
      .limit(PULL_LIMIT)
      .all();
  }

  // Get current max syncVersion across all tables for this user
  const maxBookVer = (await db.select({ v: max(books.syncVersion) }).from(books).where(eq(books.userId, userId)).get())?.v ?? 0;
  const maxHighVer = (await db.select({ v: max(highlights.syncVersion) }).from(highlights).where(eq(highlights.userId, userId)).get())?.v ?? 0;
  const maxConvVer = (await db.select({ v: max(conversations.syncVersion) }).from(conversations).where(eq(conversations.userId, userId)).get())?.v ?? 0;
  // Messages don't have userId directly, but we already filtered above
  const maxMsgVer = changedMessages.length > 0
    ? Math.max(...changedMessages.map((m) => m.syncVersion ?? 0))
    : 0;
  const currentSyncVersion = Math.max(maxBookVer, maxHighVer, maxConvVer, maxMsgVer);

  const hasMore =
    changedBooks.length >= PULL_LIMIT ||
    changedHighlights.length >= PULL_LIMIT ||
    changedConversations.length >= PULL_LIMIT ||
    changedMessages.length >= PULL_LIMIT;

  const response: PullResponse = {
    changes: {
      books: sanitizedBooks as unknown as Array<Record<string, unknown>>,
      highlights: changedHighlights as unknown as Array<Record<string, unknown>>,
      conversations: changedConversations as unknown as Array<Record<string, unknown>>,
      messages: changedMessages as unknown as Array<Record<string, unknown>>,
    },
    syncVersion: currentSyncVersion,
    hasMore,
  };

  return c.json(response);
});

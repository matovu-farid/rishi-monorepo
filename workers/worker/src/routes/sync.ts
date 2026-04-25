import { Hono } from "hono";
import { eq, gt, and, max, asc, sql, getTableColumns } from "drizzle-orm";
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

      // Whitelist of allowed book fields (excludes id, userId, filePath, coverPath, isDirty, syncVersion)
      const allowedBookKeys = ['title', 'author', 'format', 'fileHash', 'fileR2Key', 'coverR2Key', 'currentCfi', 'currentPage', 'isDeleted'] as const;
      const safeBookFields: Record<string, unknown> = {};
      for (const key of allowedBookKeys) {
        if (key in serverFields) safeBookFields[key] = serverFields[key];
      }

      if (!existing) {
        // INSERT new record
        await tx.insert(books).values({
          ...safeBookFields,
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
        await tx
          .update(books)
          .set({
            ...safeBookFields,
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

      // Whitelist of allowed highlight fields
      const allowedHighlightKeys = ['bookId', 'cfiRange', 'text', 'color', 'note', 'chapter', 'isDeleted'] as const;
      const safeHighlightFields: Record<string, unknown> = {};
      for (const key of allowedHighlightKeys) {
        if (key in serverFields) safeHighlightFields[key] = serverFields[key];
      }

      if (!existing) {
        // INSERT new highlight (union merge: always accept new highlights)
        await tx.insert(highlights).values({
          ...safeHighlightFields,
          id: highlightId,
          userId,
          updatedAt: pushedUpdatedAt || Date.now(),
          createdAt: (serverFields.createdAt as number) || Date.now(),
        } as typeof highlights.$inferInsert);
        upsertedHighlightIds.push(highlightId);
      } else if (pushedUpdatedAt > (existing.updatedAt ?? 0)) {
        // Client is newer -- UPDATE (LWW by updatedAt)
        await tx
          .update(highlights)
          .set({
            ...safeHighlightFields,
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

      // Whitelist of allowed conversation fields
      const allowedConvKeys = ['bookId', 'title', 'isDeleted'] as const;
      const safeConvFields: Record<string, unknown> = {};
      for (const key of allowedConvKeys) {
        if (key in serverFields) safeConvFields[key] = serverFields[key];
      }

      if (!existing) {
        await tx.insert(conversations).values({
          ...safeConvFields,
          id: convId,
          userId,
          updatedAt: pushedUpdatedAt || Date.now(),
          createdAt: (serverFields.createdAt as number) || Date.now(),
        } as typeof conversations.$inferInsert);
        upsertedConversationIds.push(convId);
      } else if (pushedUpdatedAt > (existing.updatedAt ?? 0)) {
        await tx
          .update(conversations)
          .set({
            ...safeConvFields,
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

      // Whitelist of allowed message fields
      const allowedMsgKeys = ['conversationId', 'role', 'content', 'sourceChunks', 'isDeleted'] as const;
      const safeMsgFields: Record<string, unknown> = {};
      for (const key of allowedMsgKeys) {
        if (key in serverFields) safeMsgFields[key] = serverFields[key];
      }

      // New message -- insert (userId verified via conversation ownership)
      await tx.insert(messages).values({
        ...safeMsgFields,
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
  if (!Number.isFinite(sinceVersion) || sinceVersion < 0) {
    return c.json({ error: "since_version must be a non-negative number" }, 400);
  }
  const userId = c.get("userId");
  const db = createDb(c.env.DB);

  // NOTE: Deleted records (isDeleted = true) are intentionally NOT filtered out.
  // They must be included in pull results so other devices learn about deletions
  // and can apply the soft-delete locally.
  const PULL_LIMIT = 5000;

  // Wrap all pull queries in a transaction to prevent phantom reads from
  // concurrent pushes interleaving between individual queries.
  const result = await db.transaction(async (tx) => {
    const changedBooks = await tx
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

    const changedHighlights = await tx
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

    // ── Pull conversations ─────────────────────────────────────────────────
    const changedConversations = await tx
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

    // ── Pull messages (via JOIN to avoid unbounded IN list) ─────────────────
    // Uses an inner join on conversations instead of fetching all conversation
    // IDs first, which would crash SQLite with >999 params in the IN clause.
    const changedMessages = await tx
      .select({ ...getTableColumns(messages) })
      .from(messages)
      .innerJoin(conversations, eq(messages.conversationId, conversations.id))
      .where(
        and(
          gt(messages.syncVersion, sinceVersion),
          eq(conversations.userId, userId)
        )
      )
      .orderBy(asc(messages.createdAt))
      .limit(PULL_LIMIT)
      .all();

    // Get current max syncVersion across all tables for this user
    const maxBookVer = (await tx.select({ v: max(books.syncVersion) }).from(books).where(eq(books.userId, userId)).get())?.v ?? 0;
    const maxHighVer = (await tx.select({ v: max(highlights.syncVersion) }).from(highlights).where(eq(highlights.userId, userId)).get())?.v ?? 0;
    const maxConvVer = (await tx.select({ v: max(conversations.syncVersion) }).from(conversations).where(eq(conversations.userId, userId)).get())?.v ?? 0;
    // Query max message syncVersion from DB via JOIN (not from truncated result set)
    const maxMsgVerResult = await tx
      .select({ v: max(messages.syncVersion) })
      .from(messages)
      .innerJoin(conversations, eq(messages.conversationId, conversations.id))
      .where(eq(conversations.userId, userId))
      .get();
    const maxMsgVer = maxMsgVerResult?.v ?? 0;

    const currentSyncVersion = Math.max(maxBookVer, maxHighVer, maxConvVer, maxMsgVer);

    return { changedBooks, changedHighlights, changedConversations, changedMessages, currentSyncVersion };
  });

  // Strip local-only paths from response -- client must never overwrite its local paths
  const sanitizedBooks = result.changedBooks.map((book) => ({
    ...book,
    filePath: "",
    coverPath: null,
  }));

  const hasMore =
    result.changedBooks.length >= PULL_LIMIT ||
    result.changedHighlights.length >= PULL_LIMIT ||
    result.changedConversations.length >= PULL_LIMIT ||
    result.changedMessages.length >= PULL_LIMIT;

  const response: PullResponse = {
    changes: {
      books: sanitizedBooks as unknown as Array<Record<string, unknown>>,
      highlights: result.changedHighlights as unknown as Array<Record<string, unknown>>,
      conversations: result.changedConversations as unknown as Array<Record<string, unknown>>,
      messages: result.changedMessages as unknown as Array<Record<string, unknown>>,
    },
    syncVersion: result.currentSyncVersion,
    hasMore,
  };

  return c.json(response);
});

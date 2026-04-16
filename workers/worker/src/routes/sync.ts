import { Hono } from "hono";
import { eq, gt, and, max } from "drizzle-orm";
import type { CloudflareBindings } from "../index";
import { requireWorkerAuth } from "../index";
import { createDb } from "../db/drizzle";
import { books, highlights, conversations, messages } from "@rishi/shared/schema";
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

  // ── Conversations upsert loop (LWW) ──────────────────────────────────────
  const upsertedConversationIds: string[] = [];

  for (const conv of body.changes.conversations ?? []) {
    const { isDirty, ...serverFields } = conv as Record<string, unknown>;
    const convId = serverFields.id as string;
    if (!convId) continue;

    const existing = await db
      .select()
      .from(conversations)
      .where(and(eq(conversations.id, convId), eq(conversations.userId, userId)))
      .get();

    const pushedUpdatedAt = (serverFields.updatedAt as number) ?? 0;

    if (!existing) {
      await db.insert(conversations).values({
        ...serverFields,
        id: convId,
        userId,
        updatedAt: pushedUpdatedAt || Date.now(),
        createdAt: (serverFields.createdAt as number) || Date.now(),
      } as typeof conversations.$inferInsert);
      upsertedConversationIds.push(convId);
    } else if (pushedUpdatedAt > (existing.updatedAt ?? 0)) {
      const { id, createdAt, ...updateFields } = serverFields;
      await db
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

    const existing = await db
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

    const parentConv = await db
      .select({ userId: conversations.userId })
      .from(conversations)
      .where(and(eq(conversations.id, convId), eq(conversations.userId, userId)))
      .get();

    if (!parentConv) {
      // Conversation doesn't exist or doesn't belong to this user -- skip
      continue;
    }

    // New message -- insert (userId verified via conversation ownership)
    await db.insert(messages).values({
      ...serverFields,
      id: msgId,
      updatedAt: (serverFields.updatedAt as number) || Date.now(),
      createdAt: (serverFields.createdAt as number) || Date.now(),
    } as typeof messages.$inferInsert);
    upsertedMessageIds.push(msgId);
  }

  // ── Assign syncVersion to all upserted records (atomic via D1 batch) ────
  const totalUpserted = upsertedBookIds.length + upsertedHighlightIds.length + upsertedConversationIds.length + upsertedMessageIds.length;
  let newSyncVersion = 0;

  if (totalUpserted > 0) {
    // Use D1 batch to atomically compute MAX+1 and update all records.
    // D1 batch executes all statements in a single transaction, preventing
    // concurrent pushes from reading the same max version.
    const d1 = c.env.DB;

    // Build a subquery that computes MAX(sync_version)+1 across all tables
    const maxVersionSubquery = `(SELECT COALESCE(MAX(v), 0) + 1 FROM (
      SELECT MAX(sync_version) AS v FROM books
      UNION ALL SELECT MAX(sync_version) AS v FROM highlights
      UNION ALL SELECT MAX(sync_version) AS v FROM conversations
      UNION ALL SELECT MAX(sync_version) AS v FROM messages
    ))`;

    const batchStatements: D1PreparedStatement[] = [];

    // Update all upserted books
    for (const id of upsertedBookIds) {
      batchStatements.push(
        d1.prepare(`UPDATE books SET sync_version = ${maxVersionSubquery}, is_dirty = 0 WHERE id = ?`).bind(id)
      );
    }

    // Update all upserted highlights
    for (const id of upsertedHighlightIds) {
      batchStatements.push(
        d1.prepare(`UPDATE highlights SET sync_version = ${maxVersionSubquery}, is_dirty = 0 WHERE id = ?`).bind(id)
      );
    }

    // Update all upserted conversations
    for (const id of upsertedConversationIds) {
      batchStatements.push(
        d1.prepare(`UPDATE conversations SET sync_version = ${maxVersionSubquery}, is_dirty = 0 WHERE id = ?`).bind(id)
      );
    }

    // Update all upserted messages
    for (const id of upsertedMessageIds) {
      batchStatements.push(
        d1.prepare(`UPDATE messages SET sync_version = ${maxVersionSubquery}, is_dirty = 0 WHERE id = ?`).bind(id)
      );
    }

    if (batchStatements.length > 0) {
      await d1.batch(batchStatements);
    }

    // Read back the assigned syncVersion (all records got the same value)
    const result = await d1.prepare(
      `SELECT COALESCE(MAX(v), 0) AS v FROM (
        SELECT MAX(sync_version) AS v FROM books
        UNION ALL SELECT MAX(sync_version) AS v FROM highlights
        UNION ALL SELECT MAX(sync_version) AS v FROM conversations
        UNION ALL SELECT MAX(sync_version) AS v FROM messages
      )`
    ).first<{ v: number }>();
    newSyncVersion = result?.v ?? 0;
  } else {
    // No upserts -- return current max version across all tables
    const result = await c.env.DB.prepare(
      `SELECT COALESCE(MAX(v), 0) AS v FROM (
        SELECT MAX(sync_version) AS v FROM books
        UNION ALL SELECT MAX(sync_version) AS v FROM highlights
        UNION ALL SELECT MAX(sync_version) AS v FROM conversations
        UNION ALL SELECT MAX(sync_version) AS v FROM messages
      )`
    ).first<{ v: number }>();
    newSyncVersion = result?.v ?? 0;
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
    const allMessages = await db
      .select()
      .from(messages)
      .where(gt(messages.syncVersion, sinceVersion))
      .all();
    changedMessages = allMessages.filter((m) => userConvIds.includes(m.conversationId));
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

  const response: PullResponse = {
    changes: {
      books: sanitizedBooks as unknown as Array<Record<string, unknown>>,
      highlights: changedHighlights as unknown as Array<Record<string, unknown>>,
      conversations: changedConversations as unknown as Array<Record<string, unknown>>,
      messages: changedMessages as unknown as Array<Record<string, unknown>>,
    },
    syncVersion: currentSyncVersion,
  };

  return c.json(response);
});

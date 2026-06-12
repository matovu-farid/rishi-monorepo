import { Hono } from "hono";
import { eq, gt, and, max, asc, sql, getTableColumns } from "drizzle-orm";
import { z } from "zod";
import type { CloudflareBindings } from "../index";
import { requireAuth } from "../index";
import { createDb } from "../db/drizzle";
import { books, highlights, conversations, messages } from "@rishi/shared/schema";
import type { PullResponse } from "@rishi/shared/sync-types";

// ─── Date wire convention ──────────────────────────────────────────────────────
// iOS WorkerClient.swift:96 uses a bare JSONDecoder() with the default
// .deferredToDate strategy, which reads JSON numbers via
// Date(timeIntervalSinceReferenceDate:). Apple's reference date is
// 2001-01-01T00:00:00Z, i.e. 978_307_200_000 ms after the unix epoch. Every
// Date that crosses this wire MUST therefore round-trip through these helpers.
// See workers/worker/src/routes/changes.ts for the canonical conversion.
const REFERENCE_DATE_OFFSET_MS = 978_307_200_000;
const fromSecondsSinceRef = (s: number) => s * 1000 + REFERENCE_DATE_OFFSET_MS;

// ─── iOS SyncChange envelope schema ───────────────────────────────────────────
// Matches apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/SyncAPI.swift
// SyncChange + SyncPushEndpoint.Body verbatim. The flat array shape replaces
// the legacy grouped-object body {changes: {books, highlights, ...}} that the
// /pull handler still echoes — those two contracts diverged after Phase 7.
const SyncChangeSchema = z.object({
  kind: z.enum(["book", "position", "highlight", "conversation", "message"]),
  id: z.string(),
  payload: z.record(z.string(), z.unknown()),
  updated_at: z.number(),
  deleted: z.boolean(),
});

const PushBodySchema = z.object({
  changes: z.array(SyncChangeSchema).max(5000),
});

export const syncRoutes = new Hono<{
  Bindings: CloudflareBindings;
  Variables: { userId: string };
}>();

// ─── POST /push ────────────────────────────────────────────────────────────────
// Accepts the iOS flat SyncChange envelope and dispatches per `kind` to the
// matching D1 table. Returns {accepted_at: <seconds-since-2001>} as the
// high-water-mark cursor iOS persists into sync_metadata.last_synced_at.
//
// Per-kind dispatch (snake_case WirePayloads from SyncPayloadCodec.swift):
//   - book         -> books table (LWW by updated_at, scoped to userId).
//                     file_url + cover_path are STRIPPED — local-only paths
//                     that must never round-trip through D1.
//   - position     -> UPDATE existing books row WHERE id == payload.book_id
//                     setting currentCfi = payload.locator and
//                     lastProgressPercent = payload.percent_complete. There
//                     is no separate position table on the worker (per
//                     17-CONTEXT.md: position rides in the book row).
//   - highlight    -> highlights table (LWW). deleted=true flips isDeleted
//                     on the matching row when one exists.
//   - conversation -> conversations table (LWW).
//   - message      -> messages table (append-only — existing rows are never
//                     overwritten; userId is enforced via parent conversation).
syncRoutes.post("/push", requireAuth, async (c) => {
  const rawBody = await c.req.json().catch(() => null);
  const parsed = PushBodySchema.safeParse(rawBody);
  if (!parsed.success) {
    return c.json(
      { error: "bad_request", detail: parsed.error.message },
      400,
    );
  }
  const body = parsed.data;
  const userId = c.get("userId");
  const db = createDb(c.env.DB);

  await db.transaction(async (tx) => {
    for (const change of body.changes) {
      // ── book ─────────────────────────────────────────────────────────────
      if (change.kind === "book") {
        const p = change.payload as Record<string, unknown>;
        const bookId = (p.id as string) ?? change.id;
        if (!bookId) continue;

        const pushedUpdatedAtMs = fromSecondsSinceRef(change.updated_at);

        // Whitelist allowed columns from the snake_case wire payload.
        // STRIP file_url + cover_path (local-only, see changes.ts:108-111).
        const fields: Record<string, unknown> = {};
        if (typeof p.title === "string") fields.title = p.title;
        if (typeof p.author === "string") fields.author = p.author;
        if (typeof p.format_type === "string") fields.format = p.format_type;
        if (typeof p.current_cfi === "string") fields.currentCfi = p.current_cfi;
        if (typeof p.current_page === "number") fields.currentPage = p.current_page;
        if (typeof p.last_progress_percent === "number")
          fields.lastProgressPercent = p.last_progress_percent;

        const existing = await tx
          .select()
          .from(books)
          .where(and(eq(books.id, bookId), eq(books.userId, userId)))
          .get();

        if (!existing) {
          await tx.insert(books).values({
            ...fields,
            id: bookId,
            userId,
            title: (fields.title as string) ?? "Untitled",
            author: (fields.author as string) ?? "Unknown",
            format: (fields.format as string) ?? "epub",
            // Local-only path: ALWAYS empty server-side. The mobile client
            // re-derives the on-device path from the R2 key on pull.
            filePath: "",
            coverPath: null,
            isDeleted: change.deleted,
            updatedAt: pushedUpdatedAtMs,
            createdAt: pushedUpdatedAtMs,
          } as typeof books.$inferInsert);
        } else if (pushedUpdatedAtMs > (existing.updatedAt ?? 0)) {
          await tx
            .update(books)
            .set({
              ...fields,
              isDeleted: change.deleted,
              updatedAt: pushedUpdatedAtMs,
            } as Partial<typeof books.$inferInsert>)
            .where(and(eq(books.id, bookId), eq(books.userId, userId)));
        }
        continue;
      }

      // ── position (no separate table — folds into books row) ──────────────
      if (change.kind === "position") {
        const p = change.payload as Record<string, unknown>;
        const bookId = p.book_id as string | undefined;
        if (!bookId) continue;
        const pushedUpdatedAtMs = fromSecondsSinceRef(change.updated_at);

        const patch: Record<string, unknown> = { updatedAt: pushedUpdatedAtMs };
        if (typeof p.locator === "string") patch.currentCfi = p.locator;
        if (typeof p.percent_complete === "number")
          patch.lastProgressPercent = p.percent_complete;

        await tx
          .update(books)
          .set(patch as Partial<typeof books.$inferInsert>)
          .where(and(eq(books.id, bookId), eq(books.userId, userId)));
        continue;
      }

      // ── highlight ────────────────────────────────────────────────────────
      if (change.kind === "highlight") {
        const p = change.payload as Record<string, unknown>;
        const highlightId = (p.id as string) ?? change.id;
        if (!highlightId) continue;
        const pushedUpdatedAtMs = fromSecondsSinceRef(change.updated_at);

        const existing = await tx
          .select()
          .from(highlights)
          .where(
            and(eq(highlights.id, highlightId), eq(highlights.userId, userId)),
          )
          .get();

        if (change.deleted) {
          // Tombstone: flip isDeleted on the matching row if it exists.
          // No-op for unknown ids (the row may live on another device).
          if (existing) {
            await tx
              .update(highlights)
              .set({
                isDeleted: true,
                updatedAt: pushedUpdatedAtMs,
              } as Partial<typeof highlights.$inferInsert>)
              .where(
                and(
                  eq(highlights.id, highlightId),
                  eq(highlights.userId, userId),
                ),
              );
          }
          continue;
        }

        const bookId = p.book_id as string | undefined;
        // cfiRange is the canonical column — accept both locator_start (the
        // iOS wire DTO field) and an explicit cfi_range/cfiRange.
        const cfiRange =
          (p.cfi_range as string | undefined) ??
          (p.cfiRange as string | undefined) ??
          (p.locator_start as string | undefined) ??
          "";
        const text = (p.text as string) ?? "";
        const color = (p.color as string) ?? "yellow";
        const note = (p.note as string | undefined) ?? null;

        if (!existing) {
          await tx.insert(highlights).values({
            id: highlightId,
            bookId: bookId ?? "",
            userId,
            cfiRange,
            text,
            color,
            note,
            isDeleted: false,
            updatedAt: pushedUpdatedAtMs,
            createdAt: pushedUpdatedAtMs,
          } as typeof highlights.$inferInsert);
        } else if (pushedUpdatedAtMs > (existing.updatedAt ?? 0)) {
          const patch: Record<string, unknown> = {
            text,
            color,
            note,
            updatedAt: pushedUpdatedAtMs,
          };
          if (bookId) patch.bookId = bookId;
          if (cfiRange) patch.cfiRange = cfiRange;
          await tx
            .update(highlights)
            .set(patch as Partial<typeof highlights.$inferInsert>)
            .where(
              and(
                eq(highlights.id, highlightId),
                eq(highlights.userId, userId),
              ),
            );
        }
        continue;
      }

      // ── conversation ─────────────────────────────────────────────────────
      if (change.kind === "conversation") {
        const p = change.payload as Record<string, unknown>;
        const convId = (p.id as string) ?? change.id;
        if (!convId) continue;
        const pushedUpdatedAtMs = fromSecondsSinceRef(change.updated_at);

        const existing = await tx
          .select()
          .from(conversations)
          .where(
            and(
              eq(conversations.id, convId),
              eq(conversations.userId, userId),
            ),
          )
          .get();

        const title = (p.title as string) ?? "New conversation";
        const bookId = (p.book_id as string) ?? "";

        if (!existing) {
          await tx.insert(conversations).values({
            id: convId,
            userId,
            bookId,
            title,
            isDeleted: change.deleted,
            updatedAt: pushedUpdatedAtMs,
            createdAt: pushedUpdatedAtMs,
          } as typeof conversations.$inferInsert);
        } else if (pushedUpdatedAtMs > (existing.updatedAt ?? 0)) {
          const patch: Record<string, unknown> = {
            title,
            isDeleted: change.deleted,
            updatedAt: pushedUpdatedAtMs,
          };
          if (bookId) patch.bookId = bookId;
          await tx
            .update(conversations)
            .set(patch as Partial<typeof conversations.$inferInsert>)
            .where(
              and(
                eq(conversations.id, convId),
                eq(conversations.userId, userId),
              ),
            );
        }
        continue;
      }

      // ── message (append-only) ────────────────────────────────────────────
      if (change.kind === "message") {
        const p = change.payload as Record<string, unknown>;
        const msgId = (p.id as string) ?? change.id;
        if (!msgId) continue;
        const pushedUpdatedAtMs = fromSecondsSinceRef(change.updated_at);

        const existing = await tx
          .select()
          .from(messages)
          .where(eq(messages.id, msgId))
          .get();
        if (existing) continue; // append-only

        const convId = p.conversation_id as string | undefined;
        if (!convId) continue;

        // Enforce per-user scoping via parent conversation ownership.
        const parentConv = await tx
          .select()
          .from(conversations)
          .where(
            and(
              eq(conversations.id, convId),
              eq(conversations.userId, userId),
            ),
          )
          .get();
        if (!parentConv) continue;

        await tx.insert(messages).values({
          id: msgId,
          conversationId: convId,
          role: (p.role as string) ?? "user",
          content: (p.content as string) ?? "",
          isDeleted: change.deleted,
          updatedAt: pushedUpdatedAtMs,
          createdAt: pushedUpdatedAtMs,
        } as typeof messages.$inferInsert);
        continue;
      }
    }
  });

  // High-water-mark cursor: the max wire updated_at across all accepted
  // changes. Already in seconds-since-2001 — pass through unmodified so iOS
  // round-trips it via .deferredToDate without any conversion drift.
  let acceptedAt = 0;
  for (const change of body.changes) {
    if (change.updated_at > acceptedAt) acceptedAt = change.updated_at;
  }

  return c.json({ accepted_at: acceptedAt });
});

// ─── GET /pull ─────────────────────────────────────────────────────────────────
// Returns books and highlights changed since the given syncVersion for the authenticated user.
// filePath is set to '' and coverPath to null to prevent path contamination.
syncRoutes.get("/pull", requireAuth, async (c) => {
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

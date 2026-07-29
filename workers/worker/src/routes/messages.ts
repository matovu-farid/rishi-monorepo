import { Hono } from "hono";
import { z } from "zod";
import { conversations, messages } from "../db/schema";
import { createDb } from "../db/drizzle";
import { requireAuth } from "../index";
import { requireAiDataConsent } from "../middleware/ai-data-consent";
import { and, desc, eq, gt, inArray } from "drizzle-orm";

/**
 * Chat sync — Phase 16-03 Task 2.
 *
 * Mounted at /api/sync/messages behind Better Auth's `requireAuth`.
 *
 * Security posture:
 *  - Per-message rows have no direct user FK (the schema scopes ownership
 *    through the parent conversation's userId). The POST handler therefore
 *    must look up each message's parent conversation and silently drop
 *    rows whose parent is owned by a different user.
 *  - SILENT DROP (not 403): a 403 would leak the existence of someone
 *    else's conversation id. We return 200 with the truthful applied_count
 *    of caller-owned rows that landed.
 *  - GET path is a two-step: fetch the caller's conversation ids, then
 *    inArray(messages.conversationId, ids) — Drizzle's native join is
 *    avoided so the in-memory test mock stays trivial.
 *
 * Conflict resolution: Last-Writer-Wins on (id, updated_at). On conflict
 * we overwrite content + updated_at; conversationId stays immutable in v1.
 */

const RowSchema = z.object({
  id: z.string().uuid(),
  conversation_id: z.string().min(1),
  role: z.enum(["user", "assistant", "system"]),
  content: z.string().min(1).max(50_000),
  created_at: z.number().int().nonnegative(),
  updated_at: z.number().int().nonnegative(),
});

const PostBody = z.object({
  messages: z.array(RowSchema).min(1).max(500),
});

export const messagesRoutes = new Hono<{
  Bindings: Env;
  Variables: { userId: string };
}>();

messagesRoutes.post("/", requireAuth, requireAiDataConsent, async (c) => {
  const raw = await c.req.json().catch(() => null);
  const parsed = PostBody.safeParse(raw);
  if (!parsed.success) {
    return c.json({ error: "bad_request", detail: parsed.error.message }, 400);
  }

  const userId = c.get("userId");
  const db = createDb(c.env.DB);
  let applied = 0;
  for (const row of parsed.data.messages) {
    // Parent-ownership pre-check: SILENTLY drop if the parent
    // conversation belongs to a different user. No 403 to avoid
    // leaking conversation-existence info to other users.
    const parent = await db
      .select({ userId: conversations.userId })
      .from(conversations)
      .where(eq(conversations.id, row.conversation_id))
      .get();
    if (!parent || parent.userId !== userId) continue;

    await db
      .insert(messages)
      .values({
        id: row.id,
        conversationId: row.conversation_id,
        role: row.role,
        content: row.content,
        createdAt: row.created_at,
        updatedAt: row.updated_at,
        syncVersion: 0,
        isDirty: false,
        isDeleted: false,
      })
      .onConflictDoUpdate({
        target: messages.id,
        set: {
          content: row.content,
          updatedAt: row.updated_at,
        },
      });
    applied += 1;
  }

  return c.json({ applied_count: applied });
});

messagesRoutes.get("/", requireAuth, requireAiDataConsent, async (c) => {
  const userId = c.get("userId");
  const sinceRaw = c.req.query("since");
  const since = sinceRaw ? Number(sinceRaw) : null;
  const db = createDb(c.env.DB);

  // Two-step: get caller's conversation ids, then scoped message fetch.
  // Avoids Drizzle's join surface so the test in-memory mock stays simple.
  const convs = await db
    .select({ id: conversations.id })
    .from(conversations)
    .where(eq(conversations.userId, userId))
    .all();
  const convIds = convs.map((row: { id: string }) => row.id);
  if (convIds.length === 0) return c.json({ rows: [] });

  const where =
    since !== null && Number.isFinite(since)
      ? and(
          inArray(messages.conversationId, convIds),
          gt(messages.updatedAt, since),
        )
      : inArray(messages.conversationId, convIds);
  const rows = await db
    .select()
    .from(messages)
    .where(where)
    .orderBy(desc(messages.updatedAt))
    .all();

  return c.json({
    rows: rows.map((r: (typeof rows)[number]) => ({
      id: r.id,
      conversation_id: r.conversationId,
      role: r.role,
      content: r.content,
      created_at: r.createdAt,
      updated_at: r.updatedAt,
    })),
  });
});

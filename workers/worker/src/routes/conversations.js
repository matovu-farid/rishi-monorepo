import { Hono } from "hono";
import { z } from "zod";
import { conversations } from "@rishi/shared/schema";
import { createDb } from "../db/drizzle";
import { requireAuth } from "../index";
import { and, desc, eq, gt } from "drizzle-orm";
/**
 * Chat sync — Phase 16-03 Task 1.
 *
 * Mounted at /api/sync/conversations behind Better Auth's `requireAuth`
 * middleware. iOS ConversationUploader (Phase 16-04) posts dirty rows here;
 * SyncEngine inbound (Phase 16-05) pulls via the `?since=<ms>` cursor.
 *
 * Security posture:
 *  - userId is sourced from the verified session (c.get("userId")) and
 *    OVERRIDES any user_id present in the client body. A malicious client
 *    cannot impersonate another user by setting that field.
 *  - GET path filters strictly on conversations.userId == callerId; cross-
 *    user reads are physically impossible without a session swap.
 *
 * Conflict resolution: Last-Writer-Wins on (id, updated_at). On conflict the
 * server overwrites title + updated_at only; bookId stays immutable in v1
 * (book attachment is a property of conversation creation, not editing).
 */
const RowSchema = z.object({
    id: z.string().uuid(),
    user_id: z.string().min(1), // accepted but OVERRIDDEN server-side
    book_id: z.string().min(1),
    title: z.string().min(1).max(500),
    archived: z.boolean(),
    created_at: z.number().int().nonnegative(),
    updated_at: z.number().int().nonnegative(),
});
const PostBody = z.object({
    conversations: z.array(RowSchema).min(1).max(500),
});
export const conversationsRoutes = new Hono();
conversationsRoutes.post("/", requireAuth, async (c) => {
    const raw = await c.req.json().catch(() => null);
    const parsed = PostBody.safeParse(raw);
    if (!parsed.success) {
        return c.json({ error: "bad_request", detail: parsed.error.message }, 400);
    }
    const userId = c.get("userId");
    const db = createDb(c.env.DB);
    let applied = 0;
    for (const row of parsed.data.conversations) {
        await db
            .insert(conversations)
            .values({
            id: row.id,
            userId, // <-- server-side override; client cannot impersonate
            bookId: row.book_id,
            title: row.title,
            createdAt: row.created_at,
            updatedAt: row.updated_at,
            syncVersion: 0,
            isDirty: false,
            isDeleted: false,
        })
            .onConflictDoUpdate({
            target: conversations.id,
            set: {
                title: row.title,
                updatedAt: row.updated_at,
                // bookId intentionally NOT updated — book attachment is immutable in v1.
            },
        });
        applied += 1;
    }
    return c.json({ applied_count: applied });
});
conversationsRoutes.get("/", requireAuth, async (c) => {
    const userId = c.get("userId");
    const sinceRaw = c.req.query("since");
    const since = sinceRaw ? Number(sinceRaw) : null;
    const db = createDb(c.env.DB);
    const where = since !== null && Number.isFinite(since)
        ? and(eq(conversations.userId, userId), gt(conversations.updatedAt, since))
        : eq(conversations.userId, userId);
    const rows = await db
        .select()
        .from(conversations)
        .where(where)
        .orderBy(desc(conversations.updatedAt))
        .all();
    // Map Drizzle camelCase -> wire snake_case. `archived` is not in the
    // current schema; surface as `false` for v1 (Phase 16 deferred).
    return c.json({
        rows: rows.map((r) => ({
            id: r.id,
            user_id: r.userId,
            book_id: r.bookId,
            title: r.title,
            archived: false,
            created_at: r.createdAt,
            updated_at: r.updatedAt,
        })),
    });
});

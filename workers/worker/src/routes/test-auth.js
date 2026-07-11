import { Hono } from "hono";
import { eq } from "drizzle-orm";
import { books, highlights, conversations, messages, bookmarks, user, session, account, } from "@rishi/shared/schema";
import { createDb } from "../db/drizzle";
import { createAuth } from "../auth";
/**
 * Test-only auth routes mounted at /test/*.
 *
 * These exist so end-to-end tests (Playwright + Detox in the parity effort)
 * can spin up a fresh user account, exercise sync, and tear it down — without
 * going through the OAuth browser dance. They are HARD GATED by three checks:
 *
 *   a. c.env.ENABLE_TEST_AUTH === 'true'   (wrangler vars are strings)
 *   b. X-Test-Auth-Secret header matches c.env.TEST_AUTH_SECRET (constant-time)
 *   c. c.env.ENABLE_TEST_AUTH must be PRESENT (defense in depth)
 *
 * Any gate failure returns 404 — NOT 401/403 — so probers see "no such
 * endpoint". Production wrangler.jsonc deliberately does NOT define either
 * variable; they must be set explicitly on dev/staging via `wrangler secret put`.
 */
export const testAuthRoutes = new Hono();
/**
 * Constant-time string comparison.
 *
 * We do the XOR-then-OR ourselves instead of using `crypto.subtle.timingSafeEqual`
 * (which exists on the Cloudflare Workers runtime but NOT on Node, breaking
 * vitest). The loop runs to the longer length so an attacker can't time the
 * mismatch by sending a 1-char header.
 */
function timingSafeEqual(a, b) {
    const encoder = new TextEncoder();
    const bufA = encoder.encode(a);
    const bufB = encoder.encode(b);
    let diff = bufA.length ^ bufB.length;
    const len = Math.max(bufA.length, bufB.length);
    for (let i = 0; i < len; i++) {
        diff |= (bufA[i] ?? 0) ^ (bufB[i] ?? 0);
    }
    return diff === 0;
}
/**
 * Verifies all three gates. Returns null on success, or a 404 Response that
 * the caller should return immediately. We use 404 (not 401/403) so an
 * attacker probing production sees the same response as for any other
 * unknown path.
 */
function gateOrNotFound(c) {
    const enabled = c.env.ENABLE_TEST_AUTH;
    if (!enabled || enabled !== "true") {
        return new Response("Not Found", { status: 404 });
    }
    const expected = c.env.TEST_AUTH_SECRET;
    if (!expected) {
        return new Response("Not Found", { status: 404 });
    }
    const provided = c.req.header("X-Test-Auth-Secret");
    if (!provided || !timingSafeEqual(provided, expected)) {
        return new Response("Not Found", { status: 404 });
    }
    return null;
}
// ─── POST /sign-in ────────────────────────────────────────────────────────────
// Either creates a new user (via Better-Auth signUpEmail) and signs them in,
// or — if the user already exists — just signs them in. Returns the bearer
// session token along with userId + email.
testAuthRoutes.post("/sign-in", async (c) => {
    const gate = gateOrNotFound(c);
    if (gate)
        return gate;
    let body;
    try {
        body = await c.req.json();
    }
    catch {
        return c.json({ error: "Invalid JSON" }, 400);
    }
    const { email, password } = (body ?? {});
    if (!email ||
        typeof email !== "string" ||
        !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ||
        !password ||
        typeof password !== "string" ||
        password.length < 1) {
        return c.json({ error: "email and password required" }, 400);
    }
    const auth = await createAuth(c.env);
    const headers = c.req.raw.headers;
    // Try to sign up first. If the user already exists, Better-Auth throws
    // (or returns a recognisable error) — we swallow it and fall through to
    // signInEmail. This matches the brief's "create if missing" semantics.
    try {
        await auth.api.signUpEmail({
            body: {
                email,
                password,
                name: email.split("@")[0] || "Test User",
            },
            headers,
            asResponse: false,
        });
    }
    catch (err) {
        // Likely "user exists" — proceed to sign in. We don't differentiate here
        // because all other errors will surface again in the signInEmail call.
        void err;
    }
    let signed;
    try {
        signed = await auth.api.signInEmail({
            body: { email, password },
            headers,
            asResponse: false,
        });
    }
    catch (err) {
        const message = err instanceof Error ? err.message : "sign-in failed";
        return c.json({ error: message }, 401);
    }
    // Better-Auth's signInEmail returns { user, token } in v1.6+.
    const token = signed?.token;
    const userId = signed?.user?.id;
    if (!token || !userId) {
        return c.json({ error: "sign-in did not return a token" }, 500);
    }
    return c.json({ token, userId, email });
});
// ─── DELETE /users/:email ─────────────────────────────────────────────────────
// Cascades a user's data:
//   1. R2 objects for every book (fileR2Key + coverR2Key)
//   2. D1 rows: books, highlights, conversations, messages (via convs), bookmarks
//   3. Better-Auth rows: session, account, user
// Returns { deleted, userId, booksRemoved, r2ObjectsRemoved }. Returns 404 if
// the user doesn't exist (also returns 404 on gating failures — same code so
// probers can't distinguish).
testAuthRoutes.delete("/users/:email", async (c) => {
    const gate = gateOrNotFound(c);
    if (gate)
        return gate;
    // Better-Auth lowercases emails on storage, so we normalize on lookup
    // — otherwise a mixed-case test email (e.g. nanoid-generated) creates
    // the user as `foo@x` but the delete looks up `FoO@x` and 404s.
    const email = decodeURIComponent(c.req.param("email")).toLowerCase();
    const db = createDb(c.env.DB);
    // Look up the user by email (case-insensitive normalized above).
    const userRow = await db
        .select()
        .from(user)
        .where(eq(user.email, email))
        .get();
    if (!userRow) {
        return c.json({ error: "user not found" }, 404);
    }
    const userId = userRow.id;
    // ── R2 teardown ──────────────────────────────────────────────────────────
    const userBooks = await db
        .select()
        .from(books)
        .where(eq(books.userId, userId))
        .all();
    let r2ObjectsRemoved = 0;
    for (const b of userBooks) {
        for (const key of [b.fileR2Key, b.coverR2Key]) {
            if (!key)
                continue;
            try {
                await c.env.BOOK_STORAGE.delete(key);
                r2ObjectsRemoved++;
            }
            catch (err) {
                // Don't strand teardown on a transient R2 failure — the row will still
                // be removed so a retry can target only the remaining objects.
                console.error("R2 delete failed:", key, err);
            }
        }
    }
    const booksRemoved = userBooks.length;
    // ── Messages: scoped via conversationId since the messages row lacks
    // userId. Collect this user's conversation ids first, then delete by each.
    // Each table-delete is wrapped — `no such table` errors (which surface on
    // a fresh local D1 that's missing a migration) shouldn't strand teardown.
    const safeRun = async (label, fn) => {
        try {
            await fn();
        }
        catch (err) {
            console.error(`teardown ${label} failed:`, err);
        }
    };
    await safeRun("messages-by-conv", async () => {
        const userConvs = await db
            .select()
            .from(conversations)
            .where(eq(conversations.userId, userId))
            .all();
        for (const conv of userConvs) {
            await db
                .delete(messages)
                .where(eq(messages.conversationId, conv.id))
                .run();
        }
    });
    // ── D1 user-scoped tables ────────────────────────────────────────────────
    await safeRun("books", () => db.delete(books).where(eq(books.userId, userId)).run());
    await safeRun("highlights", () => db.delete(highlights).where(eq(highlights.userId, userId)).run());
    await safeRun("conversations", () => db.delete(conversations).where(eq(conversations.userId, userId)).run());
    await safeRun("bookmarks", () => db.delete(bookmarks).where(eq(bookmarks.userId, userId)).run());
    // ── Better-Auth rows (verification + passkey cascade via FK ON DELETE) ──
    await safeRun("session", () => db.delete(session).where(eq(session.userId, userId)).run());
    await safeRun("account", () => db.delete(account).where(eq(account.userId, userId)).run());
    await safeRun("user", () => db.delete(user).where(eq(user.id, userId)).run());
    return c.json({ deleted: true, userId, booksRemoved, r2ObjectsRemoved });
});

import { describe, it, expect, beforeEach, vi } from "vitest";
const { state, COLS, deleteCalls } = vi.hoisted(() => {
    const COLS = {
        id: { __col: "id" },
        email: { __col: "email" },
        userId: { __col: "userId" },
        fileR2Key: { __col: "fileR2Key" },
        coverR2Key: { __col: "coverR2Key" },
        bookId: { __col: "bookId" },
        conversationId: { __col: "conversationId" },
    };
    return {
        state: {
            users: [],
            books: [],
            highlights: [],
            conversations: [],
            messages: [],
            bookmarks: [],
            sessions: [],
            accounts: [],
        },
        COLS,
        deleteCalls: { r2: [] },
    };
});
function resetState() {
    state.users.length = 0;
    state.books.length = 0;
    state.highlights.length = 0;
    state.conversations.length = 0;
    state.messages.length = 0;
    state.bookmarks.length = 0;
    state.sessions.length = 0;
    state.accounts.length = 0;
    deleteCalls.r2.length = 0;
}
// ─── Mock schema ──────────────────────────────────────────────────────────────
vi.mock("@rishi/shared/schema", () => ({
    books: { ...COLS, __table: "books" },
    highlights: { ...COLS, __table: "highlights" },
    conversations: { ...COLS, __table: "conversations" },
    messages: { ...COLS, __table: "messages" },
    bookmarks: { ...COLS, __table: "bookmarks" },
    user: { ...COLS, __table: "user" },
    session: { ...COLS, __table: "session" },
    account: { ...COLS, __table: "account" },
    verification: { ...COLS, __table: "verification" },
    passkey: { ...COLS, __table: "passkey" },
    syncMeta: { ...COLS, __table: "syncMeta" },
}));
vi.mock("drizzle-orm", () => ({
    eq: (col, value) => ({
        kind: "eq",
        col: col.__col,
        value,
    }),
    and: (...preds) => ({ kind: "and", preds }),
    sql: (s) => ({ __sql: s.join("?") }),
    count: () => ({ __agg: "count" }),
    sum: () => ({ __agg: "sum" }),
}));
function tableKey(table) {
    switch (table.__table) {
        case "books":
            return "books";
        case "highlights":
            return "highlights";
        case "conversations":
            return "conversations";
        case "messages":
            return "messages";
        case "bookmarks":
            return "bookmarks";
        case "user":
            return "users";
        case "session":
            return "sessions";
        case "account":
            return "accounts";
        default:
            return null;
    }
}
function evalPred(pred, row) {
    if (pred.kind === "eq") {
        const p = pred;
        return row[p.col] === p.value;
    }
    if (pred.kind === "and") {
        return pred.preds.every((p) => evalPred(p, row));
    }
    return false;
}
vi.mock("../db/drizzle", () => {
    function createDb() {
        return {
            select(_fields) {
                return {
                    from(table) {
                        const key = tableKey(table);
                        const ctx = {};
                        const builder = {
                            where(pred) {
                                ctx.pred = pred;
                                return builder;
                            },
                            get() {
                                if (!key)
                                    return undefined;
                                return state[key].find((r) => ctx.pred
                                    ? evalPred(ctx.pred, r)
                                    : true);
                            },
                            all() {
                                if (!key)
                                    return [];
                                return state[key].filter((r) => ctx.pred
                                    ? evalPred(ctx.pred, r)
                                    : true);
                            },
                        };
                        return builder;
                    },
                };
            },
            delete(table) {
                const key = tableKey(table);
                const ctx = {};
                const builder = {
                    where(pred) {
                        ctx.pred = pred;
                        return builder;
                    },
                    async run() {
                        if (!key)
                            return;
                        const arr = state[key];
                        for (let i = arr.length - 1; i >= 0; i--) {
                            if (ctx.pred &&
                                evalPred(ctx.pred, arr[i])) {
                                arr.splice(i, 1);
                            }
                        }
                    },
                };
                return builder;
            },
        };
    }
    return { createDb };
});
// ─── Mock createAuth (Better-Auth API) ────────────────────────────────────────
const { authBehavior } = vi.hoisted(() => ({
    authBehavior: {
        signUpEmail: vi.fn(),
        signInEmail: vi.fn(),
    },
}));
vi.mock("../auth", () => ({
    createAuth: () => ({
        api: {
            signUpEmail: authBehavior.signUpEmail,
            signInEmail: authBehavior.signInEmail,
        },
    }),
}));
// ─── Now import the route under test ──────────────────────────────────────────
import { testAuthRoutes } from "./test-auth";
// ─── R2 stub ──────────────────────────────────────────────────────────────────
const fakeR2 = {
    delete: vi.fn(async (key) => {
        deleteCalls.r2.push(key);
    }),
};
const baseEnv = {
    BETTER_AUTH_SECRET: "test-secret",
    PUBLIC_API_URL: "https://api.fidexa.org",
    PUBLIC_WEB_URL: "https://rishi.fidexa.org",
    DB: {},
    BOOK_STORAGE: fakeR2,
};
const SECRET = "super-secret-token";
function envWithGate(opts = {}) {
    const env = { ...baseEnv };
    if (opts.enabled !== false) {
        env.ENABLE_TEST_AUTH = opts.enabled === undefined ? "true" : "true";
    }
    if (opts.secret !== null) {
        env.TEST_AUTH_SECRET = opts.secret ?? SECRET;
    }
    return env;
}
async function call(path, init = {}, env = envWithGate()) {
    const url = `http://test.local${path}`;
    return testAuthRoutes.fetch(new Request(url, init), env);
}
beforeEach(() => {
    resetState();
    authBehavior.signUpEmail.mockReset();
    authBehavior.signInEmail.mockReset();
    fakeR2.delete.mockClear();
});
// ─── Gating: POST /test/sign-in ───────────────────────────────────────────────
describe("POST /test/sign-in — gating", () => {
    it("returns 404 when ENABLE_TEST_AUTH is unset", async () => {
        const env = { ...baseEnv, TEST_AUTH_SECRET: SECRET };
        // ENABLE_TEST_AUTH intentionally absent
        const res = await call("/sign-in", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "X-Test-Auth-Secret": SECRET,
            },
            body: JSON.stringify({ email: "a@b.co", password: "p" }),
        }, env);
        expect(res.status).toBe(404);
    });
    it("returns 404 when X-Test-Auth-Secret header is missing", async () => {
        const res = await call("/sign-in", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ email: "a@b.co", password: "p" }),
        });
        expect(res.status).toBe(404);
    });
    it("returns 404 when X-Test-Auth-Secret header is wrong", async () => {
        const res = await call("/sign-in", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "X-Test-Auth-Secret": "nope",
            },
            body: JSON.stringify({ email: "a@b.co", password: "p" }),
        });
        expect(res.status).toBe(404);
    });
    it("returns 404 when ENABLE_TEST_AUTH is 'false' (any non-'true' string)", async () => {
        const env = {
            ...baseEnv,
            ENABLE_TEST_AUTH: "false",
            TEST_AUTH_SECRET: SECRET,
        };
        const res = await call("/sign-in", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "X-Test-Auth-Secret": SECRET,
            },
            body: JSON.stringify({ email: "a@b.co", password: "p" }),
        }, env);
        expect(res.status).toBe(404);
    });
    it("returns 404 when TEST_AUTH_SECRET is unset (header can't match)", async () => {
        const env = {
            ...baseEnv,
            ENABLE_TEST_AUTH: "true",
        };
        const res = await call("/sign-in", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "X-Test-Auth-Secret": SECRET,
            },
            body: JSON.stringify({ email: "a@b.co", password: "p" }),
        }, env);
        expect(res.status).toBe(404);
    });
});
// ─── Happy paths: POST /test/sign-in ──────────────────────────────────────────
describe("POST /test/sign-in — happy paths", () => {
    it("creates a new user when one doesn't exist + returns session token", async () => {
        authBehavior.signUpEmail.mockResolvedValue({
            user: { id: "user_new", email: "new@x.co" },
            token: "tok_new",
        });
        authBehavior.signInEmail.mockResolvedValue({
            user: { id: "user_new", email: "new@x.co" },
            token: "tok_new",
        });
        const res = await call("/sign-in", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "X-Test-Auth-Secret": SECRET,
            },
            body: JSON.stringify({ email: "new@x.co", password: "pw12345678" }),
        });
        expect(res.status).toBe(200);
        const body = (await res.json());
        expect(body.token).toBe("tok_new");
        expect(body.userId).toBe("user_new");
        expect(body.email).toBe("new@x.co");
        expect(authBehavior.signUpEmail).toHaveBeenCalledOnce();
    });
    it("signs in an existing user when signUpEmail rejects with 'user exists'", async () => {
        // signUpEmail throws when user already exists — caller falls through to signInEmail.
        authBehavior.signUpEmail.mockRejectedValue(new Error("user already exists"));
        authBehavior.signInEmail.mockResolvedValue({
            user: { id: "user_existing", email: "old@x.co" },
            token: "tok_existing",
        });
        const res = await call("/sign-in", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "X-Test-Auth-Secret": SECRET,
            },
            body: JSON.stringify({ email: "old@x.co", password: "pw12345678" }),
        });
        expect(res.status).toBe(200);
        const body = (await res.json());
        expect(body.token).toBe("tok_existing");
        expect(body.userId).toBe("user_existing");
        expect(authBehavior.signInEmail).toHaveBeenCalledOnce();
    });
    it("rejects malformed body with 400 (still gated — but past the gate)", async () => {
        const res = await call("/sign-in", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "X-Test-Auth-Secret": SECRET,
            },
            body: JSON.stringify({ email: "not-an-email" }),
        });
        expect(res.status).toBe(400);
    });
});
// ─── Gating: DELETE /test/users/:email ────────────────────────────────────────
describe("DELETE /test/users/:email — gating", () => {
    it("returns 404 with bad gating", async () => {
        state.users.push({ id: "u1", email: "del@x.co" });
        const env = { ...baseEnv, TEST_AUTH_SECRET: SECRET };
        const res = await call("/users/del@x.co", {
            method: "DELETE",
            // No X-Test-Auth-Secret header
        }, env);
        expect(res.status).toBe(404);
    });
    it("returns 404 when X-Test-Auth-Secret header is wrong", async () => {
        state.users.push({ id: "u1", email: "del@x.co" });
        const res = await call("/users/del@x.co", {
            method: "DELETE",
            headers: { "X-Test-Auth-Secret": "nope" },
        });
        expect(res.status).toBe(404);
    });
});
// ─── Happy path: DELETE /test/users/:email ────────────────────────────────────
describe("DELETE /test/users/:email — happy paths", () => {
    it("cascades books + highlights + conversations + messages + bookmarks and R2 objects", async () => {
        // Seed
        state.users.push({ id: "u1", email: "del@x.co" });
        state.users.push({ id: "u2", email: "other@x.co" }); // unrelated — must survive
        state.books.push({
            id: "b1",
            userId: "u1",
            fileR2Key: "books/u1/hashA",
            coverR2Key: "covers/u1/hashA",
        });
        state.books.push({
            id: "b2",
            userId: "u1",
            fileR2Key: "books/u1/hashB",
            coverR2Key: null,
        });
        state.books.push({
            id: "b3",
            userId: "u2",
            fileR2Key: "books/u2/keep",
            coverR2Key: null,
        });
        state.highlights.push({ id: "h1", userId: "u1" });
        state.highlights.push({ id: "h2", userId: "u2" });
        state.conversations.push({ id: "c1", userId: "u1" });
        state.messages.push({ id: "m1", conversationId: "c1" });
        state.bookmarks.push({ id: "bm1", userId: "u1" });
        state.sessions.push({ id: "s1", userId: "u1" });
        state.accounts.push({ id: "a1", userId: "u1" });
        const res = await call("/users/del@x.co", {
            method: "DELETE",
            headers: { "X-Test-Auth-Secret": SECRET },
        });
        expect(res.status).toBe(200);
        const body = (await res.json());
        expect(body.deleted).toBe(true);
        expect(body.userId).toBe("u1");
        expect(body.booksRemoved).toBe(2);
        // 3 R2 keys: 2 fileR2Key (b1, b2) + 1 coverR2Key (b1 only — b2's was null)
        expect(body.r2ObjectsRemoved).toBe(3);
        // u1's data gone
        expect(state.books.find((b) => b.userId === "u1")).toBeUndefined();
        expect(state.highlights.find((h) => h.userId === "u1")).toBeUndefined();
        expect(state.conversations.find((c) => c.userId === "u1")).toBeUndefined();
        expect(state.bookmarks.find((b) => b.userId === "u1")).toBeUndefined();
        expect(state.sessions.find((s) => s.userId === "u1")).toBeUndefined();
        expect(state.accounts.find((a) => a.userId === "u1")).toBeUndefined();
        expect(state.users.find((u) => u.id === "u1")).toBeUndefined();
        // u2 untouched
        expect(state.books.find((b) => b.userId === "u2")).toBeDefined();
        expect(state.highlights.find((h) => h.userId === "u2")).toBeDefined();
        expect(state.users.find((u) => u.id === "u2")).toBeDefined();
        // R2 deletes
        expect(deleteCalls.r2.sort()).toEqual(["books/u1/hashA", "books/u1/hashB", "covers/u1/hashA"].sort());
    });
    it("returns 404 when user doesn't exist", async () => {
        const res = await call("/users/ghost@x.co", {
            method: "DELETE",
            headers: { "X-Test-Auth-Secret": SECRET },
        });
        expect(res.status).toBe(404);
    });
    it("is resilient when R2 delete throws (still reports remaining work)", async () => {
        state.users.push({ id: "u1", email: "del@x.co" });
        state.books.push({
            id: "b1",
            userId: "u1",
            fileR2Key: "books/u1/willFail",
            coverR2Key: null,
        });
        fakeR2.delete.mockImplementationOnce(async () => {
            throw new Error("R2 down");
        });
        const res = await call("/users/del@x.co", {
            method: "DELETE",
            headers: { "X-Test-Auth-Secret": SECRET },
        });
        // We still want a 2xx — partial R2 failures shouldn't strand the test
        // teardown.
        expect(res.status).toBe(200);
        const body = (await res.json());
        expect(body.deleted).toBe(true);
        expect(body.booksRemoved).toBe(1);
    });
});

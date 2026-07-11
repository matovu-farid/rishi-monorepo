import { describe, it, expect, beforeEach, vi } from "vitest";
const { conversationStore, messageStore, CONV_COLS, MSG_COLS } = vi.hoisted(() => {
    const CONV_COLS = {
        id: { __col: "id", __table: "conv" },
        userId: { __col: "userId", __table: "conv" },
    };
    const MSG_COLS = {
        id: { __col: "id", __table: "msg" },
        conversationId: { __col: "conversationId", __table: "msg" },
        role: { __col: "role", __table: "msg" },
        content: { __col: "content", __table: "msg" },
        createdAt: { __col: "createdAt", __table: "msg" },
        updatedAt: { __col: "updatedAt", __table: "msg" },
        syncVersion: { __col: "syncVersion", __table: "msg" },
        isDirty: { __col: "isDirty", __table: "msg" },
        isDeleted: { __col: "isDeleted", __table: "msg" },
    };
    return {
        conversationStore: [],
        messageStore: [],
        CONV_COLS,
        MSG_COLS,
    };
});
function resetStores() {
    conversationStore.length = 0;
    messageStore.length = 0;
}
function seedConversation(row) {
    conversationStore.push({ id: row.id, userId: row.userId });
}
function seedMessage(row) {
    messageStore.push({
        id: row.id,
        conversationId: row.conversationId,
        role: row.role ?? "user",
        content: row.content ?? "seeded",
        createdAt: row.createdAt ?? row.updatedAt,
        updatedAt: row.updatedAt,
        syncVersion: row.syncVersion ?? 0,
        isDirty: row.isDirty ?? false,
        isDeleted: row.isDeleted ?? false,
    });
}
// ─── Mock @rishi/shared/schema so both tables resolve to column ids ──────────
vi.mock("@rishi/shared/schema", () => ({
    conversations: CONV_COLS,
    messages: MSG_COLS,
    devices: {},
    books: {},
    highlights: {},
    bookmarks: {},
    user: {},
    session: {},
    account: {},
    verification: {},
    passkey: {},
    syncMeta: {},
    appleSubscriptions: {},
    appleNotificationsLog: {},
    subscription: {},
}));
vi.mock("drizzle-orm", () => ({
    eq: (col, value) => ({ kind: "eq", col, value }),
    gt: (col, value) => ({ kind: "gt", col, value }),
    inArray: (col, values) => ({
        kind: "inArray",
        col,
        values,
    }),
    and: (...preds) => ({ kind: "and", preds }),
    desc: (col) => ({ col, dir: "desc" }),
}));
function rowMatches(row, p) {
    if (p.kind === "and")
        return p.preds.every((sub) => rowMatches(row, sub));
    if (p.kind === "eq")
        return row[p.col.__col] === p.value;
    if (p.kind === "gt") {
        const v = row[p.col.__col];
        return typeof v === "number" && v > p.value;
    }
    if (p.kind === "inArray")
        return p.values.includes(row[p.col.__col]);
    return false;
}
function tableOf(p) {
    if (p.kind === "and") {
        for (const sub of p.preds) {
            const t = tableOf(sub);
            if (t)
                return t;
        }
        return null;
    }
    return p.col.__table;
}
// ─── Mock createDb ───────────────────────────────────────────────────────────
vi.mock("../db/drizzle", () => {
    function createDb() {
        return {
            insert(table) {
                // Only the messages table is inserted into in the messages route.
                let pendingValues = {};
                let conflictTarget = null;
                let conflictSet = {};
                const builder = {
                    values(v) {
                        pendingValues = v;
                        return builder;
                    },
                    onConflictDoUpdate(opts) {
                        const t = Array.isArray(opts.target) ? opts.target[0] : opts.target;
                        conflictTarget = t.__col;
                        conflictSet = opts.set;
                        return {
                            then(resolve) {
                                // Only handle inserts targeting the messages table.
                                void table;
                                const existing = conflictTarget
                                    ? messageStore.find((r) => r[conflictTarget] ===
                                        pendingValues[conflictTarget])
                                    : undefined;
                                if (existing) {
                                    Object.assign(existing, conflictSet);
                                }
                                else {
                                    messageStore.push(pendingValues);
                                }
                                resolve(undefined);
                            },
                        };
                    },
                };
                return builder;
            },
            select(_proj) {
                return {
                    from(_table) {
                        let predicate = null;
                        let order = null;
                        const chain = {
                            where(p) {
                                predicate = p;
                                return chain;
                            },
                            orderBy(o) {
                                order = o;
                                return chain;
                            },
                            all() {
                                const t = predicate ? tableOf(predicate) : null;
                                let source = [];
                                if (t === "conv") {
                                    source = conversationStore;
                                }
                                else if (t === "msg") {
                                    source = messageStore;
                                }
                                else {
                                    // No predicate at all — shouldn't happen in messages.ts
                                    source = messageStore;
                                }
                                let rows = source.slice();
                                if (predicate)
                                    rows = rows.filter((r) => rowMatches(r, predicate));
                                if (order) {
                                    rows.sort((a, b) => {
                                        const av = a[order.col.__col];
                                        const bv = b[order.col.__col];
                                        return order.dir === "desc" ? bv - av : av - bv;
                                    });
                                }
                                return rows;
                            },
                            get() {
                                const t = predicate ? tableOf(predicate) : null;
                                const source = t === "conv"
                                    ? conversationStore
                                    : messageStore;
                                if (!predicate)
                                    return source[0] ?? null;
                                return source.find((r) => rowMatches(r, predicate)) ?? null;
                            },
                        };
                        return chain;
                    },
                };
            },
        };
    }
    return { createDb };
});
// ─── Auth state + ../auth + ../index mocks ───────────────────────────────────
const { authState } = vi.hoisted(() => ({
    authState: { userId: "user_alice" },
}));
function setUser(id) {
    authState.userId = id;
}
vi.mock("../auth", () => ({
    createAuth: () => ({
        api: {
            getSession: async () => {
                if (!authState.userId)
                    return null;
                return {
                    user: { id: authState.userId },
                    session: { token: "tok_test" },
                };
            },
        },
    }),
}));
vi.mock("../index", async () => {
    return {
        requireAuth: async (c, next) => {
            if (!authState.userId) {
                return c.json({ error: "Unauthorized" }, 401);
            }
            c.set("userId", authState.userId);
            return next();
        },
    };
});
// ─── Now import the route under test ────────────────────────────────────────
import { messagesRoutes } from "./messages";
const env = {
    BETTER_AUTH_SECRET: "test-secret",
    PUBLIC_API_URL: "https://api.fidexa.org",
    PUBLIC_WEB_URL: "https://rishi.fidexa.org",
    DB: {},
};
async function callPost(body) {
    const req = new Request("http://test.local/", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
    });
    return messagesRoutes.fetch(req, env);
}
async function callGet(query = "") {
    const req = new Request(`http://test.local/${query}`, { method: "GET" });
    return messagesRoutes.fetch(req, env);
}
const MSG_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const MSG_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const MSG_C = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
function validRow(overrides = {}) {
    return {
        id: MSG_A,
        conversation_id: "conv-alice",
        role: "user",
        content: "Hello",
        created_at: 1_700_000_000_000,
        updated_at: 1_700_000_500_000,
        ...overrides,
    };
}
beforeEach(() => {
    resetStores();
    setUser("user_alice");
});
// ─── Tests ───────────────────────────────────────────────────────────────────
describe("POST /api/sync/messages", () => {
    it("unauthenticated -> 401 + zero rows written", async () => {
        setUser(null);
        seedConversation({ id: "conv-alice", userId: "user_alice" });
        const res = await callPost({ messages: [validRow()] });
        expect(res.status).toBe(401);
        const body = (await res.json());
        expect(body.error).toBe("Unauthorized");
        expect(messageStore.length).toBe(0);
    });
    it("happy path -> 200 { applied_count: 2 } for caller-owned conversation", async () => {
        seedConversation({ id: "conv-alice", userId: "user_alice" });
        const res = await callPost({
            messages: [
                validRow({ id: MSG_A, content: "first" }),
                validRow({ id: MSG_B, content: "second" }),
            ],
        });
        expect(res.status).toBe(200);
        const body = (await res.json());
        expect(body.applied_count).toBe(2);
        expect(messageStore.length).toBe(2);
    });
    it("idempotent upsert -> same id twice yields exactly 1 row (LWW)", async () => {
        seedConversation({ id: "conv-alice", userId: "user_alice" });
        const first = await callPost({
            messages: [validRow({ id: MSG_A, content: "v1", updated_at: 100 })],
        });
        expect(first.status).toBe(200);
        expect(messageStore.length).toBe(1);
        const second = await callPost({
            messages: [validRow({ id: MSG_A, content: "v2", updated_at: 200 })],
        });
        expect(second.status).toBe(200);
        expect(messageStore.length).toBe(1);
        expect(messageStore[0].content).toBe("v2");
        expect(messageStore[0].updatedAt).toBe(200);
    });
    it("validation: missing `messages` key -> 400 bad_request", async () => {
        const res = await callPost({});
        expect(res.status).toBe(400);
        const body = (await res.json());
        expect(body.error).toBe("bad_request");
    });
    it("parent-ownership: cross-user-targeted rows are SILENTLY dropped", async () => {
        seedConversation({ id: "conv-alice", userId: "user_alice" });
        seedConversation({ id: "conv-bob", userId: "user_bob" });
        const res = await callPost({
            messages: [
                validRow({ id: MSG_A, conversation_id: "conv-alice", content: "ok" }),
                validRow({ id: MSG_B, conversation_id: "conv-bob", content: "forbidden" }),
            ],
        });
        // 200 with applied_count=1 — the bob-targeted row is silently dropped.
        // NO 403 thrown: we do not leak the existence of someone else's conv id.
        expect(res.status).toBe(200);
        const body = (await res.json());
        expect(body.applied_count).toBe(1);
        expect(messageStore.length).toBe(1);
        expect(messageStore[0].conversationId).toBe("conv-alice");
        expect(messageStore.find((m) => m.id === MSG_B)).toBeUndefined();
    });
});
describe("GET /api/sync/messages", () => {
    it("since cursor -> returns only messages newer than since for caller's convs", async () => {
        seedConversation({ id: "conv-alice", userId: "user_alice" });
        seedConversation({ id: "conv-bob", userId: "user_bob" });
        seedMessage({ id: MSG_A, conversationId: "conv-alice", updatedAt: 100 });
        seedMessage({ id: MSG_B, conversationId: "conv-alice", updatedAt: 200 });
        seedMessage({ id: MSG_C, conversationId: "conv-alice", updatedAt: 300 });
        seedMessage({ id: "bob-msg", conversationId: "conv-bob", updatedAt: 250 });
        const res = await callGet("?since=150");
        expect(res.status).toBe(200);
        const body = (await res.json());
        expect(body.rows.length).toBe(2);
        expect(body.rows.every((r) => r.updated_at > 150)).toBe(true);
        expect(body.rows.every((r) => r.conversation_id === "conv-alice")).toBe(true);
    });
    it("cross-user isolation -> alice's GET excludes bob's messages", async () => {
        seedConversation({ id: "conv-alice", userId: "user_alice" });
        seedConversation({ id: "conv-bob", userId: "user_bob" });
        seedMessage({ id: MSG_A, conversationId: "conv-alice", updatedAt: 200 });
        seedMessage({ id: "bob-msg", conversationId: "conv-bob", updatedAt: 200 });
        const res = await callGet("?since=100");
        expect(res.status).toBe(200);
        const body = (await res.json());
        expect(body.rows.length).toBe(1);
        expect(body.rows.every((r) => r.conversation_id === "conv-alice")).toBe(true);
    });
});

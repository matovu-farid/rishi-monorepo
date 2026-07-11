import { describe, it, expect, beforeEach, vi } from "vitest";
const { bookStore, COLS } = vi.hoisted(() => {
    const COLS = {
        fileR2Key: { __col: "fileR2Key" },
        fileHash: { __col: "fileHash" },
        userId: { __col: "userId" },
        isDeleted: { __col: "isDeleted" },
        id: { __col: "id" },
        fileSize: { __col: "fileSize" },
    };
    return { bookStore: [], COLS };
});
function resetStore() {
    bookStore.length = 0;
}
// ─── Mock @rishi/shared/schema so `books` resolves to our column ids ─────────
vi.mock("@rishi/shared/schema", () => ({
    books: COLS,
    // Other tables referenced transitively by sibling imports — empty stubs.
    highlights: {},
    conversations: {},
    messages: {},
    bookmarks: {},
    user: {},
    session: {},
    account: {},
    verification: {},
    passkey: {},
    syncMeta: {},
    devices: {},
    appleSubscriptions: {},
    appleNotificationsLog: {},
    subscription: {},
}));
vi.mock("drizzle-orm", () => ({
    eq: (col, value) => ({
        kind: "eq",
        col: col.__col,
        value,
    }),
    and: (...preds) => ({ kind: "and", preds }),
    sql: (strings, ...values) => ({
        __sql: strings.join("?"),
        values,
    }),
    count: () => ({ __agg: "count" }),
    sum: (col) => ({ __agg: "sum", col: col.__col }),
}));
function evalPred(pred, row) {
    if (pred.kind === "eq") {
        return row[pred.col] === pred.value;
    }
    if (pred.kind === "and") {
        return pred.preds.every((p) => evalPred(p, row));
    }
    return false;
}
// ─── Mock createDb with a tiny select/from/where builder ─────────────────────
vi.mock("../db/drizzle", () => {
    function createDb() {
        return {
            select(fields) {
                const selectFields = fields;
                return {
                    from(_table) {
                        const ctx = {};
                        const builder = {
                            where(pred) {
                                ctx.pred = pred;
                                return builder;
                            },
                            get() {
                                const match = bookStore.find((r) => ctx.pred ? evalPred(ctx.pred, r) : true);
                                if (!selectFields)
                                    return match;
                                const out = {};
                                for (const [key, val] of Object.entries(selectFields)) {
                                    const v = val;
                                    if (v.__agg === "count") {
                                        const all = bookStore.filter((r) => ctx.pred ? evalPred(ctx.pred, r) : true);
                                        out[key] = all.length;
                                    }
                                    else if (v.__agg === "sum") {
                                        const all = bookStore.filter((r) => ctx.pred ? evalPred(ctx.pred, r) : true);
                                        out[key] = all.reduce((acc, r) => {
                                            const colName = v.col;
                                            const value = r[colName];
                                            return acc + (typeof value === "number" ? value : 0);
                                        }, 0);
                                    }
                                    else if (v.__col) {
                                        if (!match)
                                            return undefined;
                                        out[key] = match[v.__col];
                                    }
                                }
                                return out;
                            },
                            all() {
                                return bookStore.filter((r) => ctx.pred ? evalPred(ctx.pred, r) : true);
                            },
                        };
                        return builder;
                    },
                };
            },
        };
    }
    return { createDb };
});
// ─── Mock aws4fetch so we don't sign a real R2 URL ────────────────────────────
// Returns a stub URL containing X-Amz-Signed-Url-Stub so the handler can return
// `signed.url.toString()` as the `url` field.
vi.mock("aws4fetch", () => ({
    AwsClient: class {
        constructor(_cfg) { }
        async sign(req) {
            return {
                url: new URL(req.url +
                    (req.url.includes("?") ? "&" : "?") +
                    "X-Amz-Signed-Url-Stub=1&X-Amz-Expires=300"),
            };
        }
    },
}));
// ─── Mock createAuth so requireAuth sees a session ────────────────────────────
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
// ─── Mock ../index to avoid pulling the real Hono app + every route ──────────
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
// ─── Now import the route under test ─────────────────────────────────────────
import { uploadRoutes } from "./upload";
const baseEnv = {
    BETTER_AUTH_SECRET: "test-secret",
    PUBLIC_API_URL: "https://api.fidexa.org",
    PUBLIC_WEB_URL: "https://rishi.fidexa.org",
    R2_ACCESS_KEY_ID: "test-key",
    R2_SECRET_ACCESS_KEY: "test-secret",
    CLOUDFLARE_ACCOUNT_ID: "test-acct",
    DB: {},
    BOOK_STORAGE: {},
};
async function callUploadUrl(body, envOverrides = {}) {
    const env = { ...baseEnv, ...envOverrides };
    const req = new Request("http://test.local/upload-url", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
    });
    return uploadRoutes.fetch(req, env);
}
function seedBook(partial) {
    const row = {
        id: partial.id ?? crypto.randomUUID(),
        userId: partial.userId ?? "user_alice",
        fileHash: partial.fileHash ?? null,
        fileR2Key: partial.fileR2Key ?? null,
        fileSize: partial.fileSize ?? 0,
        isDeleted: partial.isDeleted ?? false,
    };
    bookStore.push(row);
    return row;
}
const AUTHED_USER = "user_alice";
const BOOK_ID = "11111111-2222-3333-4444-555555555555";
const REFERENCE_DATE_OFFSET_MS = 978_307_200_000;
beforeEach(() => {
    resetStore();
    setUser(AUTHED_USER);
});
// ─── Tests ───────────────────────────────────────────────────────────────────
describe("POST /api/sync/upload-url — iOS contract", () => {
    it("happy path: accepts {key, content_type} and returns {url, expires_at: <seconds-since-2001 number>}", async () => {
        const before = (Date.now() + 300_000 - REFERENCE_DATE_OFFSET_MS) / 1000;
        const res = await callUploadUrl({
            key: `books/${AUTHED_USER}/${BOOK_ID}.epub`,
            content_type: "application/epub+zip",
        });
        expect(res.status).toBe(200);
        const body = (await res.json());
        // Response shape: exactly {url, expires_at} — no legacy keys.
        expect(typeof body.url).toBe("string");
        expect(body.url.length).toBeGreaterThan(0);
        expect(typeof body.expires_at).toBe("number");
        // No legacy keys leaking through.
        expect(body).not.toHaveProperty("uploadUrl");
        expect(body).not.toHaveProperty("r2Key");
        expect(body).not.toHaveProperty("expiresIn");
        expect(body).not.toHaveProperty("exists");
        // expires_at = seconds since 2001-01-01, ~5 minutes (300s) ahead of now.
        const expiresAt = body.expires_at;
        expect(expiresAt).toBeGreaterThan(0);
        expect(Math.abs(expiresAt - before)).toBeLessThan(5);
    });
    it("rejects path traversal in the supplied key with 403", async () => {
        const res = await callUploadUrl({
            key: `books/${AUTHED_USER}/../other.epub`,
            content_type: "application/epub+zip",
        });
        expect(res.status).toBe(403);
    });
    it("rejects keys that target a different user's prefix with 403", async () => {
        const res = await callUploadUrl({
            key: `books/some-other-user/${BOOK_ID}.epub`,
            content_type: "application/epub+zip",
        });
        expect(res.status).toBe(403);
    });
    it("rejects missing content_type with 400 bad_request", async () => {
        const res = await callUploadUrl({
            key: `books/${AUTHED_USER}/${BOOK_ID}.epub`,
        });
        expect(res.status).toBe(400);
        const body = (await res.json());
        expect(body.error).toBe("bad_request");
    });
    it("rejects unauthenticated callers with 401", async () => {
        setUser(null);
        const res = await callUploadUrl({
            key: `books/${AUTHED_USER}/${BOOK_ID}.epub`,
            content_type: "application/epub+zip",
        });
        expect(res.status).toBe(401);
    });
    it("still enforces per-user storage cap → 507 STORAGE_LIMIT_REACHED", async () => {
        // Seed the user at the storage cap.
        seedBook({
            userId: AUTHED_USER,
            fileHash: "existing-hash",
            fileSize: 1000,
            fileR2Key: `books/${AUTHED_USER}/existing.epub`,
        });
        const res = await callUploadUrl({
            key: `books/${AUTHED_USER}/${BOOK_ID}.epub`,
            content_type: "application/epub+zip",
        }, {
            BOOK_MAX_USER_BYTES: "500", // current sum 1000 already exceeds 500
            BOOK_MAX_PER_USER: "100",
            BOOK_MAX_FILE_BYTES: "100000",
        });
        expect(res.status).toBe(507);
        const body = (await res.json());
        expect(body.code).toBe("STORAGE_LIMIT_REACHED");
    });
});

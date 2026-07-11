import { describe, it, expect, beforeEach, vi } from "vitest";
const { booksStore, highlightsStore, bookmarksStore, BOOK_COLS, HIGHLIGHT_COLS, BOOKMARK_COLS } = vi.hoisted(() => {
    const BOOK_COLS = {
        id: { __table: "books", __col: "id" },
        userId: { __table: "books", __col: "userId" },
        updatedAt: { __table: "books", __col: "updatedAt" },
    };
    const HIGHLIGHT_COLS = {
        id: { __table: "highlights", __col: "id" },
        userId: { __table: "highlights", __col: "userId" },
        updatedAt: {
            __table: "highlights",
            __col: "updatedAt",
        },
    };
    const BOOKMARK_COLS = {
        id: { __table: "bookmarks", __col: "id" },
        userId: { __table: "bookmarks", __col: "userId" },
        updatedAt: {
            __table: "bookmarks",
            __col: "updatedAt",
        },
    };
    return {
        booksStore: [],
        highlightsStore: [],
        bookmarksStore: [],
        BOOK_COLS,
        HIGHLIGHT_COLS,
        BOOKMARK_COLS,
    };
});
function resetStores() {
    booksStore.length = 0;
    highlightsStore.length = 0;
    bookmarksStore.length = 0;
}
const UUID_BOOK_A = "11111111-1111-4111-8111-111111111111";
const UUID_BOOK_B = "22222222-2222-4222-8222-222222222222";
const UUID_BOOK_C = "33333333-3333-4333-8333-333333333333";
const UUID_HL_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const UUID_BM_A = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
function seedBook(overrides = {}) {
    const updatedAt = overrides.updatedAt ?? 1_700_000_000_000;
    const full = {
        id: overrides.id ?? UUID_BOOK_A,
        userId: overrides.userId ?? "user_alice",
        title: overrides.title ?? "Seeded Book",
        author: overrides.author ?? "Anon",
        coverPath: overrides.coverPath ?? "/local/cover.jpg",
        filePath: overrides.filePath ?? "/local/book.epub",
        format: overrides.format ?? "epub",
        currentCfi: overrides.currentCfi ?? null,
        currentPage: overrides.currentPage ?? null,
        lastProgressPercent: overrides.lastProgressPercent ?? null,
        fileHash: overrides.fileHash ?? null,
        fileR2Key: overrides.fileR2Key ?? null,
        coverR2Key: overrides.coverR2Key ?? null,
        fileSize: overrides.fileSize ?? 0,
        fileNeedsRedownload: overrides.fileNeedsRedownload ?? false,
        createdAt: overrides.createdAt ?? updatedAt,
        updatedAt,
        syncVersion: overrides.syncVersion ?? 0,
        isDirty: overrides.isDirty ?? false,
        isDeleted: overrides.isDeleted ?? false,
        extractionStatus: overrides.extractionStatus ?? null,
        extractedPages: overrides.extractedPages ?? 0,
        totalPages: overrides.totalPages ?? null,
        extractionError: overrides.extractionError ?? null,
    };
    booksStore.push(full);
    return full;
}
function seedHighlight(overrides = {}) {
    const updatedAt = overrides.updatedAt ?? 1_700_000_100_000;
    const full = {
        id: overrides.id ?? UUID_HL_A,
        bookId: overrides.bookId ?? UUID_BOOK_A,
        userId: overrides.userId ?? "user_alice",
        cfiRange: overrides.cfiRange ?? "cfi:1",
        text: overrides.text ?? "quote",
        color: overrides.color ?? "yellow",
        note: overrides.note ?? null,
        chapter: overrides.chapter ?? null,
        createdAt: overrides.createdAt ?? updatedAt,
        updatedAt,
        syncVersion: overrides.syncVersion ?? 0,
        isDirty: overrides.isDirty ?? false,
        isDeleted: overrides.isDeleted ?? false,
    };
    highlightsStore.push(full);
    return full;
}
function seedBookmark(overrides = {}) {
    const updatedAt = overrides.updatedAt ?? 1_700_000_200_000;
    const full = {
        id: overrides.id ?? UUID_BM_A,
        bookId: overrides.bookId ?? UUID_BOOK_A,
        userId: overrides.userId ?? "user_alice",
        location: overrides.location ?? "epubcfi(/6/4!/4/2)",
        label: overrides.label ?? "My bookmark",
        snippet: overrides.snippet ?? null,
        pageNumber: overrides.pageNumber ?? null,
        createdAt: overrides.createdAt ?? updatedAt,
        updatedAt,
        syncVersion: overrides.syncVersion ?? 0,
        isDirty: overrides.isDirty ?? false,
        isDeleted: overrides.isDeleted ?? false,
    };
    bookmarksStore.push(full);
    return full;
}
// ─── Mock @rishi/shared/schema so `books` + `highlights` + `bookmarks` resolve ───
vi.mock("@rishi/shared/schema", () => ({
    books: BOOK_COLS,
    highlights: HIGHLIGHT_COLS,
    bookmarks: BOOKMARK_COLS,
    // Sibling tables touched by transitive imports — empty stubs.
    conversations: {},
    messages: {},
    devices: {},
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
    eq: (col, value) => ({
        kind: "eq",
        table: col.__table,
        col: col.__col,
        value,
    }),
    gt: (col, value) => ({
        kind: "gt",
        table: col.__table,
        col: col.__col,
        value,
    }),
    and: (...preds) => ({ kind: "and", preds }),
    asc: (col) => ({
        table: col.__table,
        col: col.__col,
        dir: "asc",
    }),
    desc: (col) => ({
        table: col.__table,
        col: col.__col,
        dir: "desc",
    }),
}));
// ─── Mock createDb with a tiny select builder over our two stores ────────────
function matches(row, p) {
    if (p.kind === "and")
        return p.preds.every((sub) => matches(row, sub));
    if (p.kind === "eq")
        return row[p.col] === p.value;
    if (p.kind === "gt") {
        const v = row[p.col];
        return typeof v === "number" && v > p.value;
    }
    return false;
}
vi.mock("../db/drizzle", () => {
    function createDb() {
        return {
            select(_proj) {
                return {
                    from(table) {
                        // Detect which store to read from. Our column-id stubs all
                        // share the same __table tag, but drizzle's table objects
                        // themselves are the column-id map we mocked above. The
                        // handler imports `books` / `highlights` from the schema
                        // mock — those resolve to BOOK_COLS / HIGHLIGHT_COLS which
                        // are objects whose nested cols carry __table. Use the
                        // first column's __table to identify.
                        const tableTag = (() => {
                            const t = table;
                            for (const k of Object.keys(t)) {
                                const ref = t[k];
                                if (ref && typeof ref === "object" && "__table" in ref) {
                                    return ref.__table;
                                }
                            }
                            return null;
                        })();
                        let predicate = null;
                        let order = null;
                        let limit = null;
                        const chain = {
                            where(p) {
                                predicate = p;
                                return chain;
                            },
                            orderBy(o) {
                                order = o;
                                return chain;
                            },
                            limit(n) {
                                limit = n;
                                return chain;
                            },
                            all() {
                                const src = tableTag === "books"
                                    ? booksStore
                                    : tableTag === "highlights"
                                        ? highlightsStore
                                        : tableTag === "bookmarks"
                                            ? bookmarksStore
                                            : [];
                                let rows = src.slice();
                                if (predicate)
                                    rows = rows.filter((r) => matches(r, predicate));
                                if (order) {
                                    rows.sort((a, b) => {
                                        const av = a[order.col];
                                        const bv = b[order.col];
                                        return order.dir === "desc" ? bv - av : av - bv;
                                    });
                                }
                                if (limit !== null)
                                    rows = rows.slice(0, limit);
                                return rows;
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
// ─── Now import the route under test — this is the RED on first run ─────────
import { changesRoutes } from "./changes";
const env = {
    BETTER_AUTH_SECRET: "test-secret",
    PUBLIC_API_URL: "https://api.fidexa.org",
    PUBLIC_WEB_URL: "https://rishi.fidexa.org",
    DB: {},
};
async function callChanges(query = "") {
    const url = query ? `http://test.local/${query}` : "http://test.local/";
    const req = new Request(url, { method: "GET" });
    return changesRoutes.fetch(req, env);
}
async function parseEnvelope(res) {
    return (await res.json());
}
beforeEach(() => {
    resetStores();
    setUser("user_alice");
});
// ─── Tests ───────────────────────────────────────────────────────────────────
describe("GET /api/sync/changes", () => {
    it("unauthenticated -> 401, no DB read", async () => {
        setUser(null);
        seedBook();
        const res = await callChanges();
        expect(res.status).toBe(401);
        const body = (await res.json());
        expect(body.error).toBe("Unauthorized");
    });
    it("no since cursor -> 200 + {changes} containing seeded book + highlight", async () => {
        seedBook({ id: UUID_BOOK_A, updatedAt: 1_700_000_000_000 });
        seedHighlight({ id: UUID_HL_A, updatedAt: 1_700_000_100_000 });
        const res = await callChanges();
        expect(res.status).toBe(200);
        const env = await parseEnvelope(res);
        expect(env.changes.length).toBe(2);
        for (const c of env.changes) {
            // Envelope keys MUST match iOS SyncChange CodingKeys exactly.
            expect(new Set(Object.keys(c).sort())).toEqual(new Set(["kind", "id", "payload", "updated_at", "deleted"].sort()));
            expect(["book", "highlight"]).toContain(c.kind);
            expect(typeof c.id).toBe("string");
            expect(typeof c.payload).toBe("object");
            expect(typeof c.updated_at).toBe("number");
            expect(typeof c.deleted).toBe("boolean");
        }
    });
    it("since = old ISO8601 -> 200 + includes both pre-existing rows", async () => {
        const now = Date.now();
        seedBook({ id: UUID_BOOK_A, updatedAt: now });
        seedHighlight({ id: UUID_HL_A, updatedAt: now });
        const res = await callChanges("?since=2020-01-01T00:00:00Z");
        expect(res.status).toBe(200);
        const env = await parseEnvelope(res);
        expect(env.changes.length).toBe(2);
        const kinds = env.changes.map((c) => c.kind).sort();
        expect(kinds).toEqual(["book", "highlight"]);
    });
    it("since = future ISO8601 -> 200 + {changes: []}", async () => {
        seedBook({ id: UUID_BOOK_A, updatedAt: 1_700_000_000_000 });
        seedHighlight({ id: UUID_HL_A, updatedAt: 1_700_000_100_000 });
        const res = await callChanges("?since=2099-01-01T00:00:00Z");
        expect(res.status).toBe(200);
        const env = await parseEnvelope(res);
        expect(env.changes.length).toBe(0);
    });
    it("since = garbage -> 400 with explicit error message", async () => {
        const res = await callChanges("?since=not-a-real-timestamp");
        expect(res.status).toBe(400);
        const body = (await res.json());
        expect(body.error).toBe("since must be a valid ISO8601 timestamp");
    });
    it("cross-user isolation: user A sees only user A's rows", async () => {
        seedBook({
            id: UUID_BOOK_A,
            userId: "user_alice",
            updatedAt: 1_700_000_000_000,
        });
        seedBook({
            id: UUID_BOOK_B,
            userId: "user_bob",
            updatedAt: 1_700_000_000_000,
        });
        seedHighlight({
            id: UUID_HL_A,
            userId: "user_bob",
            updatedAt: 1_700_000_100_000,
        });
        setUser("user_alice");
        const res = await callChanges();
        expect(res.status).toBe(200);
        const env = await parseEnvelope(res);
        expect(env.changes.length).toBe(1);
        expect(env.changes[0].kind).toBe("book");
        expect(env.changes[0].id).toBe(UUID_BOOK_A);
    });
    it("soft-deleted rows are included with deleted: true", async () => {
        seedBook({
            id: UUID_BOOK_A,
            updatedAt: 1_700_000_000_000,
            isDeleted: true,
        });
        const res = await callChanges();
        expect(res.status).toBe(200);
        const env = await parseEnvelope(res);
        expect(env.changes.length).toBe(1);
        expect(env.changes[0].kind).toBe("book");
        expect(env.changes[0].id).toBe(UUID_BOOK_A);
        expect(env.changes[0].deleted).toBe(true);
    });
    it("book payload omits file_path + cover_path; highlight payload includes all cols", async () => {
        seedBook({
            id: UUID_BOOK_A,
            title: "X",
            filePath: "/local/path",
            coverPath: "/local/cover",
            updatedAt: 1_700_000_000_000,
        });
        seedHighlight({
            id: UUID_HL_A,
            cfiRange: "cfi:1",
            text: "quote",
            color: "yellow",
            updatedAt: 1_700_000_100_000,
        });
        const res = await callChanges();
        expect(res.status).toBe(200);
        const env = await parseEnvelope(res);
        const bookChange = env.changes.find((c) => c.kind === "book");
        expect(bookChange).toBeDefined();
        // Camel + snake — neither shape may appear in the payload.
        expect(bookChange.payload.file_path).toBeUndefined();
        expect(bookChange.payload.filePath).toBeUndefined();
        expect(bookChange.payload.cover_path).toBeUndefined();
        expect(bookChange.payload.coverPath).toBeUndefined();
        // Other fields survive (in either casing — handler may pass through
        // schema camelCase).
        const titleField = bookChange.payload.title ??
            bookChange.payload.Title;
        expect(titleField).toBe("X");
        const hlChange = env.changes.find((c) => c.kind === "highlight");
        expect(hlChange).toBeDefined();
        // Highlights include EVERY column — sanity check the three the seed
        // set explicitly.
        const hlPayload = hlChange.payload;
        const cfiField = hlPayload.cfi_range ?? hlPayload.cfiRange;
        const textField = hlPayload.text;
        const colorField = hlPayload.color;
        expect(cfiField).toBe("cfi:1");
        expect(textField).toBe("quote");
        expect(colorField).toBe("yellow");
    });
    it("rows ordered by updatedAt ASC", async () => {
        seedBook({ id: UUID_BOOK_A, updatedAt: 3000 });
        seedBook({ id: UUID_BOOK_B, updatedAt: 1000 });
        seedBook({ id: UUID_BOOK_C, updatedAt: 2000 });
        const res = await callChanges();
        expect(res.status).toBe(200);
        const env = await parseEnvelope(res);
        expect(env.changes.length).toBe(3);
        const updatedAts = env.changes.map((c) => c.updated_at);
        // Strictly ascending.
        for (let i = 1; i < updatedAts.length; i += 1) {
            expect(updatedAts[i]).toBeGreaterThan(updatedAts[i - 1]);
        }
    });
    it("updated_at encoded as seconds-since-reference-date (2001-01-01)", async () => {
        // Reference-date offset: 978_307_200_000 ms = 2001-01-01T00:00:00Z.
        // Seed 1 second AFTER the reference date — expected wire = 1.
        //
        // Anti-cases the test must reject:
        //   - ms-epoch:                  978_307_201_000 (off by ~31y * ms factor)
        //   - seconds-since-1970:        978_307_201    (off by 31 years)
        //   - ISO string (typeof===str): would fail typeof === "number"
        const REFERENCE_DATE_OFFSET_MS = 978_307_200_000;
        seedBook({
            id: UUID_BOOK_A,
            updatedAt: REFERENCE_DATE_OFFSET_MS + 1000,
        });
        const res = await callChanges();
        expect(res.status).toBe(200);
        const env = await parseEnvelope(res);
        expect(env.changes.length).toBe(1);
        expect(typeof env.changes[0].updated_at).toBe("number");
        expect(env.changes[0].updated_at).toBe(1);
    });
    it("emits a seeded bookmark as kind 'bookmark' with location->locator mapping", async () => {
        const REFERENCE_DATE_OFFSET_MS = 978_307_200_000;
        seedBookmark({
            id: UUID_BM_A,
            bookId: UUID_BOOK_A,
            location: "epubcfi(/6/4!/4/8)",
            label: "Ch 1",
            snippet: "a saved excerpt",
            createdAt: REFERENCE_DATE_OFFSET_MS + 5000, // 2001-01-01 + 5s
            updatedAt: REFERENCE_DATE_OFFSET_MS + 2000, // wire = 2
            isDeleted: false,
        });
        const res = await callChanges();
        expect(res.status).toBe(200);
        const env = await parseEnvelope(res);
        expect(env.changes.length).toBe(1);
        const bm = env.changes[0];
        expect(bm.kind).toBe("bookmark");
        expect(bm.id).toBe(UUID_BM_A);
        // NAME MISMATCH lock: row.location -> payload.locator.
        expect(bm.payload.locator).toBe("epubcfi(/6/4!/4/8)");
        expect(bm.payload.book_id).toBe(UUID_BOOK_A);
        expect(bm.payload.label).toBe("Ch 1");
        expect(bm.payload.snippet).toBe("a saved excerpt");
        // payload.created_at is an ISO8601 STRING (SyncPayloadCodec .iso8601).
        expect(typeof bm.payload.created_at).toBe("string");
        expect(bm.payload.created_at).toBe(new Date(REFERENCE_DATE_OFFSET_MS + 5000).toISOString());
        // Envelope updated_at = seconds-since-2001 = 2.
        expect(typeof bm.updated_at).toBe("number");
        expect(bm.updated_at).toBe(2);
        expect(bm.deleted).toBe(false);
        // Envelope keys MUST match the SyncChange CodingKeys exactly.
        expect(new Set(Object.keys(bm).sort())).toEqual(new Set(["kind", "id", "payload", "updated_at", "deleted"].sort()));
    });
    it("bookmark soft-delete is emitted with deleted: true", async () => {
        seedBookmark({ id: UUID_BM_A, isDeleted: true });
        const res = await callChanges();
        expect(res.status).toBe(200);
        const env = await parseEnvelope(res);
        const bm = env.changes.find((c) => c.kind === "bookmark");
        expect(bm).toBeDefined();
        expect(bm.deleted).toBe(true);
    });
    it("cross-user isolation: user B's /changes excludes user A's bookmark", async () => {
        seedBookmark({ id: UUID_BM_A, userId: "user_alice" });
        setUser("user_bob");
        const res = await callChanges();
        expect(res.status).toBe(200);
        const env = await parseEnvelope(res);
        expect(env.changes.find((c) => c.kind === "bookmark")).toBeUndefined();
    });
    it("since-cursor: bookmark <= since excluded; > since included", async () => {
        // since = 2020-01-01; seed one before and one after.
        const sinceMs = Date.parse("2020-01-01T00:00:00Z");
        seedBookmark({ id: UUID_BM_A, updatedAt: sinceMs - 1000 }); // excluded
        const res = await callChanges("?since=2020-01-01T00:00:00Z");
        expect(res.status).toBe(200);
        const env = await parseEnvelope(res);
        expect(env.changes.find((c) => c.kind === "bookmark")).toBeUndefined();
        resetStores();
        setUser("user_alice");
        seedBookmark({ id: UUID_BM_A, updatedAt: sinceMs + 1000 }); // included
        const res2 = await callChanges("?since=2020-01-01T00:00:00Z");
        const env2 = await parseEnvelope(res2);
        expect(env2.changes.find((c) => c.kind === "bookmark")?.id).toBe(UUID_BM_A);
    });
});

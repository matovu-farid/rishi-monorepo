import { describe, it, expect, beforeEach, vi } from "vitest"

vi.mock("cloudflare:workers", () => ({ DurableObject: class {} }));
(vi as any).hoisted ??= <T>(factory: () => T) => factory()

/**
 * Tests for GET /api/sync/changes — Quick-G89 inbound book + highlight bridge.
 *
 * The iOS RemoteChangeFetcher
 * (apps/apple/Packages/RishiSync/Sources/RishiSync/Inbound/RemoteChangeFetcher.swift)
 * calls this route on every sync tick to pull the caller's books + highlights
 * back from the worker. Before this quick-task the worker had ZERO handler at
 * /api/sync/changes — live curl returned 404. This suite locks the v1
 * contract the iOS WorkerClient already ships:
 *
 *   { changes: [
 *       { kind: "book"|"highlight", id: <uuid>, payload: {...},
 *         updated_at: <number>, deleted: <bool> }, ...
 *   ] }
 *
 * The MOST load-bearing assertion is case 10 (updated_at encoded as
 * seconds-since-reference-date 2001-01-01). The iOS WorkerClient at
 * apps/apple/Packages/RishiAPI/Sources/RishiAPI/WorkerClient.swift:96 uses a
 * bare `JSONDecoder()` with NO custom `dateDecodingStrategy`, so the default
 * `.deferredToDate` strategy reads the JSON value as a Double and feeds it to
 * `Date(timeIntervalSinceReferenceDate:)` — Apple's reference date is
 * 2001-01-01T00:00:00Z, i.e. 978_307_200 seconds after the unix epoch.
 * Emitting ms-epoch or ISO8601 would mis-decode by 31 years (or throw).
 *
 * Mocking strategy mirrors src/routes/conversations.test.ts: column-id stubs
 * for `books` + `highlights`, a tiny predicate parser for eq/and/gt, two
 * in-memory stores, and `requireAuth` faked via the same `authState.userId`
 * boolean gate.
 */

// ─── In-memory book + highlight stores ────────────────────────────────────────
interface FakeBookRow {
  id: string
  userId: string
  title: string
  author: string
  coverPath: string | null
  filePath: string
  format: string
  currentCfi: string | null
  currentPage: number | null
  lastProgressPercent: number | null
  fileHash: string | null
  fileR2Key: string | null
  coverR2Key: string | null
  fileSize: number
  fileNeedsRedownload: boolean
  createdAt: number
  updatedAt: number
  syncVersion: number
  isDirty: boolean
  isDeleted: boolean
  extractionStatus: string | null
  extractedPages: number
  totalPages: number | null
  extractionError: string | null
}

interface FakeHighlightRow {
  id: string
  bookId: string
  userId: string
  cfiRange: string
  text: string
  color: string
  note: string | null
  chapter: string | null
  createdAt: number
  updatedAt: number
  syncVersion: number
  isDirty: boolean
  isDeleted: boolean
}

interface FakeBookmarkRow {
  id: string
  bookId: string
  userId: string
  location: string
  label: string
  snippet: string | null
  pageNumber: number | null
  createdAt: number
  updatedAt: number
  syncVersion: number
  isDirty: boolean
  isDeleted: boolean
}

interface FakeChapterIndexRow {
  id: string; userId: string; bookId: string; contentVersion: string; status: string
  modelIdentifier: string; modelVersion: string; completedCount: number; totalCount: number
  errorMessage: string | null; createdAt: number; updatedAt: number
}

interface FakeChapterSummaryRow {
  id: string; userId: string; bookId: string; contentVersion: string; chapterId: string
  sourcePosition: number; name: string; summary: string; createdAt: number; updatedAt: number
}

const { booksStore, highlightsStore, bookmarksStore, chapterIndexesStore, chapterSummariesStore, BOOK_COLS, HIGHLIGHT_COLS, BOOKMARK_COLS, CHAPTER_INDEX_COLS, CHAPTER_SUMMARY_COLS } =
  vi.hoisted(() => {
    const BOOK_COLS = {
      id: { __table: "books" as const, __col: "id" } as const,
      userId: { __table: "books" as const, __col: "userId" } as const,
      updatedAt: { __table: "books" as const, __col: "updatedAt" } as const,
    }
    const HIGHLIGHT_COLS = {
      id: { __table: "highlights" as const, __col: "id" } as const,
      userId: { __table: "highlights" as const, __col: "userId" } as const,
      updatedAt: {
        __table: "highlights" as const,
        __col: "updatedAt",
      } as const,
    }
    const BOOKMARK_COLS = {
      id: { __table: "bookmarks" as const, __col: "id" } as const,
      userId: { __table: "bookmarks" as const, __col: "userId" } as const,
      updatedAt: {
        __table: "bookmarks" as const,
        __col: "updatedAt",
      } as const,
    }
    return {
      booksStore: [] as FakeBookRow[],
      highlightsStore: [] as FakeHighlightRow[],
      bookmarksStore: [] as FakeBookmarkRow[],
      chapterIndexesStore: [] as FakeChapterIndexRow[],
      chapterSummariesStore: [] as FakeChapterSummaryRow[],
      BOOK_COLS,
      HIGHLIGHT_COLS,
      BOOKMARK_COLS,
      CHAPTER_INDEX_COLS: {
        id: { __table: "chapter_indexes" as const, __col: "id" },
        userId: { __table: "chapter_indexes" as const, __col: "userId" },
        updatedAt: { __table: "chapter_indexes" as const, __col: "updatedAt" },
      },
      CHAPTER_SUMMARY_COLS: {
        id: { __table: "chapter_index_chapters" as const, __col: "id" },
        userId: { __table: "chapter_index_chapters" as const, __col: "userId" },
        bookId: { __table: "chapter_index_chapters" as const, __col: "bookId" },
        contentVersion: { __table: "chapter_index_chapters" as const, __col: "contentVersion" },
        sourcePosition: { __table: "chapter_index_chapters" as const, __col: "sourcePosition" },
      },
    }
  })

function resetStores() {
  booksStore.length = 0
  highlightsStore.length = 0
  bookmarksStore.length = 0
  chapterIndexesStore.length = 0
  chapterSummariesStore.length = 0
}

const UUID_BOOK_A = "11111111-1111-4111-8111-111111111111"
const UUID_BOOK_B = "22222222-2222-4222-8222-222222222222"
const UUID_BOOK_C = "33333333-3333-4333-8333-333333333333"
const UUID_HL_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
const UUID_BM_A = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
const UUID_INDEX_A = "99999999-9999-4999-8999-999999999999"

function seedBook(overrides: Partial<FakeBookRow> = {}): FakeBookRow {
  const updatedAt = overrides.updatedAt ?? 1_700_000_000_000
  const full: FakeBookRow = {
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
  }
  booksStore.push(full)
  return full
}

function seedHighlight(
  overrides: Partial<FakeHighlightRow> = {},
): FakeHighlightRow {
  const updatedAt = overrides.updatedAt ?? 1_700_000_100_000
  const full: FakeHighlightRow = {
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
  }
  highlightsStore.push(full)
  return full
}

function seedBookmark(
  overrides: Partial<FakeBookmarkRow> = {},
): FakeBookmarkRow {
  const updatedAt = overrides.updatedAt ?? 1_700_000_200_000
  const full: FakeBookmarkRow = {
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
  }
  bookmarksStore.push(full)
  return full
}

function seedChapterIndex(overrides: Partial<FakeChapterIndexRow> = {}) {
  const updatedAt = overrides.updatedAt ?? 1_700_000_300_000
  const row: FakeChapterIndexRow = {
    id: overrides.id ?? UUID_INDEX_A,
    userId: overrides.userId ?? "user_alice",
    bookId: overrides.bookId ?? UUID_BOOK_A,
    contentVersion: overrides.contentVersion ?? "content-v1",
    status: overrides.status ?? "ready",
    modelIdentifier: overrides.modelIdentifier ?? "model",
    modelVersion: overrides.modelVersion ?? "1",
    completedCount: overrides.completedCount ?? 2,
    totalCount: overrides.totalCount ?? 2,
    errorMessage: overrides.errorMessage ?? null,
    createdAt: overrides.createdAt ?? updatedAt,
    updatedAt,
  }
  chapterIndexesStore.push(row)
  chapterSummariesStore.push(
    { id: "summary-2", userId: row.userId, bookId: row.bookId, contentVersion: row.contentVersion, chapterId: "chapter-2", sourcePosition: 1, name: "Two", summary: "Second", createdAt: row.createdAt, updatedAt },
    { id: "summary-1", userId: row.userId, bookId: row.bookId, contentVersion: row.contentVersion, chapterId: "chapter-1", sourcePosition: 0, name: "One", summary: "First", createdAt: row.createdAt, updatedAt },
  )
}

// ─── Mock @rishi/shared/schema so `books` + `highlights` + `bookmarks` resolve ───
vi.mock("@rishi/shared/schema", () => ({
  books: BOOK_COLS,
  highlights: HIGHLIGHT_COLS,
  bookmarks: BOOKMARK_COLS,
  chapterIndexes: CHAPTER_INDEX_COLS,
  chapterIndexChapters: CHAPTER_SUMMARY_COLS,
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
}))

vi.mock("../db/schema", () => ({
  books: BOOK_COLS,
  highlights: HIGHLIGHT_COLS,
  bookmarks: BOOKMARK_COLS,
  chapterIndexes: CHAPTER_INDEX_COLS,
  chapterIndexChapters: CHAPTER_SUMMARY_COLS,
}))

// ─── Mock drizzle-orm helpers as predicate descriptors ────────────────────────
type ColRef = { __table: "books" | "highlights" | "bookmarks" | "chapter_indexes" | "chapter_index_chapters"; __col: string }
type Pred =
  | { kind: "eq"; table: ColRef["__table"]; col: string; value: unknown }
  | { kind: "gt"; table: ColRef["__table"]; col: string; value: number }
  | { kind: "in"; table: ColRef["__table"]; col: string; value: unknown[] }
  | { kind: "and"; preds: Pred[] }

type OrderBy = { table: ColRef["__table"]; col: string; dir: "asc" | "desc" }

vi.mock("drizzle-orm", () => ({
  eq: (col: ColRef, value: unknown): Pred => ({
    kind: "eq",
    table: col.__table,
    col: col.__col,
    value,
  }),
  gt: (col: ColRef, value: number): Pred => ({
    kind: "gt",
    table: col.__table,
    col: col.__col,
    value,
  }),
  inArray: (col: ColRef, value: unknown[]): Pred => ({ kind: "in", table: col.__table, col: col.__col, value }),
  and: (...preds: Pred[]): Pred => ({ kind: "and", preds }),
  asc: (col: ColRef): OrderBy => ({
    table: col.__table,
    col: col.__col,
    dir: "asc",
  }),
  desc: (col: ColRef): OrderBy => ({
    table: col.__table,
    col: col.__col,
    dir: "desc",
  }),
}))

// ─── Mock createDb with a tiny select builder over our two stores ────────────
function matches(row: Record<string, unknown>, p: Pred): boolean {
  if (p.kind === "and") return p.preds.every((sub) => matches(row, sub))
  if (p.kind === "eq") return row[p.col] === p.value
  if (p.kind === "gt") {
    const v = row[p.col]
    return typeof v === "number" && v > (p.value as number)
  }
  if (p.kind === "in") return p.value.includes(row[p.col])
  return false
}

vi.mock("../db/drizzle", () => {
  function createDb() {
    return {
      select(_proj?: unknown) {
        return {
          from(table: { __table?: "books" | "highlights" | "bookmarks" } | unknown) {
            // Detect which store to read from. Our column-id stubs all
            // share the same __table tag, but drizzle's table objects
            // themselves are the column-id map we mocked above. The
            // handler imports `books` / `highlights` from the schema
            // mock — those resolve to BOOK_COLS / HIGHLIGHT_COLS which
            // are objects whose nested cols carry __table. Use the
            // first column's __table to identify.
            const tableTag = (() => {
              const t = table as Record<string, ColRef>
              for (const k of Object.keys(t)) {
                const ref = t[k]
                if (ref && typeof ref === "object" && "__table" in ref) {
                  return ref.__table
                }
              }
              return null
            })()

            let predicate: Pred | null = null
            let order: OrderBy | null = null
            let limit: number | null = null
            const chain = {
              where(p: Pred) {
                predicate = p
                return chain
              },
              orderBy(o: OrderBy) {
                order = o
                return chain
              },
              limit(n: number) {
                limit = n
                return chain
              },
              all() {
                const src =
                  tableTag === "books"
                    ? (booksStore as unknown as Record<string, unknown>[])
                    : tableTag === "highlights"
                      ? (highlightsStore as unknown as Record<string, unknown>[])
                      : tableTag === "bookmarks"
                        ? (bookmarksStore as unknown as Record<string, unknown>[])
                        : tableTag === "chapter_indexes"
                          ? (chapterIndexesStore as unknown as Record<string, unknown>[])
                          : tableTag === "chapter_index_chapters"
                            ? (chapterSummariesStore as unknown as Record<string, unknown>[])
                        : []
                let rows = src.slice()
                if (predicate) rows = rows.filter((r) => matches(r, predicate!))
                if (order) {
                  rows.sort((a, b) => {
                    const av = a[order!.col] as number
                    const bv = b[order!.col] as number
                    return order!.dir === "desc" ? bv - av : av - bv
                  })
                }
                if (limit !== null) rows = rows.slice(0, limit)
                return rows
              },
            }
            return chain
          },
        }
      },
    }
  }
  return { createDb }
})

// ─── Auth state + ../auth + ../index mocks ───────────────────────────────────
const { authState } = vi.hoisted(() => ({
  authState: { userId: "user_alice" as string | null },
}))

function setUser(id: string | null) {
  authState.userId = id
}

vi.mock("../auth", () => ({
  createAuth: () => ({
    api: {
      getSession: async () => {
        if (!authState.userId) return null
        return {
          user: { id: authState.userId },
          session: { token: "tok_test" },
        }
      },
    },
  }),
}))

vi.mock("../index.ts", async () => {
  return {
    requireAuth: async (
      c: {
        set: (k: string, v: unknown) => void
        json: (b: unknown, s: number) => Response
      },
      next: () => Promise<void>,
    ) => {
      if (!authState.userId) {
        return c.json({ error: "Unauthorized" }, 401)
      }
      c.set("userId", authState.userId)
      return next()
    },
  }
})

// ─── Now import the route under test — this is the RED on first run ─────────
import { changesRoutes } from "./changes"

const env = {
  BETTER_AUTH_SECRET: "test-secret",
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  DB: {} as unknown,
} as unknown as Record<string, unknown>

interface SyncChange {
  kind: "book" | "highlight" | "bookmark" | "chapter_index"
  id: string
  payload: Record<string, unknown>
  updated_at: number
  deleted: boolean
}

async function callChanges(query: string = ""): Promise<Response> {
  const url = query ? `http://test.local/${query}` : "http://test.local/"
  const req = new Request(url, {
    method: "GET",
    headers: { "X-Rishi-Data-Use-Consent": "2026-07-29" },
  })
  return changesRoutes.fetch(req, env)
}

async function parseEnvelope(res: Response): Promise<{ changes: SyncChange[] }> {
  return (await res.json()) as { changes: SyncChange[] }
}

beforeEach(() => {
  resetStores()
  setUser("user_alice")
})

// ─── Tests ───────────────────────────────────────────────────────────────────

describe("GET /api/sync/changes", () => {
  it("pulls one ordered chapter_index envelope with version and source positions", async () => {
    seedChapterIndex()
    const res = await callChanges()
    expect(res.status).toBe(200)
    const env = await parseEnvelope(res)
    const change = env.changes.find((item) => item.kind === "chapter_index")!
    expect(change.id).toBe(UUID_BOOK_A)
    expect(change.payload).toMatchObject({ book_id: UUID_BOOK_A, content_version: "content-v1" })
    expect(change.payload.chapters).toEqual([
      expect.objectContaining({ id: "chapter-1", source_position: 0 }),
      expect.objectContaining({ id: "chapter-2", source_position: 1 }),
    ])
  })

  it("pulls only the newest valid chapter snapshot for a book", async () => {
    seedChapterIndex({ contentVersion: "content-v1", updatedAt: 1_700_000_300_000 })
    seedChapterIndex({ contentVersion: "content-v2", updatedAt: 1_700_000_400_000 })
    const res = await callChanges()
    const env = await parseEnvelope(res)
    const chapterChanges = env.changes.filter((item) => item.kind === "chapter_index")
    expect(chapterChanges).toHaveLength(1)
    expect(chapterChanges[0].payload.content_version).toBe("content-v2")
  })

  it("chapter_index honors the since cursor and user ownership", async () => {
    seedChapterIndex({ userId: "user_bob" })
    seedChapterIndex({ id: "other-index", updatedAt: 1_700_000_400_000 })
    const res = await callChanges("?since=2020-01-01T00:00:00Z")
    const env = await parseEnvelope(res)
    expect(env.changes.filter((item) => item.kind === "chapter_index")).toHaveLength(1)
    expect(env.changes.find((item) => item.kind === "chapter_index")?.id).toBe(UUID_BOOK_A)
  })

  it("selects the newest chapter version before applying the parent limit", async () => {
    for (let i = 0; i < 5000; i++) {
      seedChapterIndex({ contentVersion: `historical-${i}`, updatedAt: 1_700_000_000_000 + i })
    }
    seedChapterIndex({ contentVersion: "newest", updatedAt: 1_700_010_000_000 })
    const res = await callChanges()
    const env = await parseEnvelope(res)
    const chapterChanges = env.changes.filter((item) => item.kind === "chapter_index")
    expect(chapterChanges).toHaveLength(1)
    expect(chapterChanges[0].payload.content_version).toBe("newest")
  })

  it("marks a snapshot when its child array is truncated", async () => {
    seedChapterIndex({ contentVersion: "large" })
    chapterSummariesStore.length = 0
    for (let i = 0; i < 5001; i++) {
      chapterSummariesStore.push({
        id: `summary-${i}`, userId: "user_alice", bookId: UUID_BOOK_A, contentVersion: "large",
        chapterId: `chapter-${i}`, sourcePosition: i, name: `Chapter ${i}`, summary: "Summary",
        createdAt: 1_700_000_000_000, updatedAt: 1_700_000_000_000,
      })
    }
    const res = await callChanges()
    const env = await parseEnvelope(res)
    const chapter = env.changes.find((item) => item.kind === "chapter_index")!
    expect(chapter.payload.chapters).toHaveLength(5000)
    expect(chapter.payload.chapters_truncated).toBe(true)
  })
  it("unauthenticated -> 401, no DB read", async () => {
    setUser(null)
    seedBook()
    const res = await callChanges()
    expect(res.status).toBe(401)
    const body = (await res.json()) as { error: string }
    expect(body.error).toBe("Unauthorized")
  })

  it("no since cursor -> 200 + {changes} containing seeded book + highlight", async () => {
    seedBook({ id: UUID_BOOK_A, updatedAt: 1_700_000_000_000 })
    seedHighlight({ id: UUID_HL_A, updatedAt: 1_700_000_100_000 })
    const res = await callChanges()
    expect(res.status).toBe(200)
    const env = await parseEnvelope(res)
    expect(env.changes.length).toBe(2)
    for (const c of env.changes) {
      // Envelope keys MUST match iOS SyncChange CodingKeys exactly.
      expect(new Set(Object.keys(c).sort())).toEqual(
        new Set(["kind", "id", "payload", "updated_at", "deleted"].sort()),
      )
      expect(["book", "highlight"]).toContain(c.kind)
      expect(typeof c.id).toBe("string")
      expect(typeof c.payload).toBe("object")
      expect(typeof c.updated_at).toBe("number")
      expect(typeof c.deleted).toBe("boolean")
    }
  })

  it("since = old ISO8601 -> 200 + includes both pre-existing rows", async () => {
    const now = Date.now()
    seedBook({ id: UUID_BOOK_A, updatedAt: now })
    seedHighlight({ id: UUID_HL_A, updatedAt: now })
    const res = await callChanges("?since=2020-01-01T00:00:00Z")
    expect(res.status).toBe(200)
    const env = await parseEnvelope(res)
    expect(env.changes.length).toBe(2)
    const kinds = env.changes.map((c) => c.kind).sort()
    expect(kinds).toEqual(["book", "highlight"])
  })

  it("since = future ISO8601 -> 200 + {changes: []}", async () => {
    seedBook({ id: UUID_BOOK_A, updatedAt: 1_700_000_000_000 })
    seedHighlight({ id: UUID_HL_A, updatedAt: 1_700_000_100_000 })
    const res = await callChanges("?since=2099-01-01T00:00:00Z")
    expect(res.status).toBe(200)
    const env = await parseEnvelope(res)
    expect(env.changes.length).toBe(0)
  })

  it("since = garbage -> 400 with explicit error message", async () => {
    const res = await callChanges("?since=not-a-real-timestamp")
    expect(res.status).toBe(400)
    const body = (await res.json()) as { error: string }
    expect(body.error).toBe("since must be a valid ISO8601 timestamp")
  })

  it("cross-user isolation: user A sees only user A's rows", async () => {
    seedBook({
      id: UUID_BOOK_A,
      userId: "user_alice",
      updatedAt: 1_700_000_000_000,
    })
    seedBook({
      id: UUID_BOOK_B,
      userId: "user_bob",
      updatedAt: 1_700_000_000_000,
    })
    seedHighlight({
      id: UUID_HL_A,
      userId: "user_bob",
      updatedAt: 1_700_000_100_000,
    })
    setUser("user_alice")
    const res = await callChanges()
    expect(res.status).toBe(200)
    const env = await parseEnvelope(res)
    expect(env.changes.length).toBe(1)
    expect(env.changes[0].kind).toBe("book")
    expect(env.changes[0].id).toBe(UUID_BOOK_A)
  })

  it("soft-deleted rows are included with deleted: true", async () => {
    seedBook({
      id: UUID_BOOK_A,
      updatedAt: 1_700_000_000_000,
      isDeleted: true,
    })
    const res = await callChanges()
    expect(res.status).toBe(200)
    const env = await parseEnvelope(res)
    expect(env.changes.length).toBe(1)
    expect(env.changes[0].kind).toBe("book")
    expect(env.changes[0].id).toBe(UUID_BOOK_A)
    expect(env.changes[0].deleted).toBe(true)
  })

  it("book payload omits file_path + cover_path; highlight payload includes all cols", async () => {
    seedBook({
      id: UUID_BOOK_A,
      title: "X",
      filePath: "/local/path",
      coverPath: "/local/cover",
      updatedAt: 1_700_000_000_000,
    })
    seedHighlight({
      id: UUID_HL_A,
      cfiRange: "cfi:1",
      text: "quote",
      color: "yellow",
      updatedAt: 1_700_000_100_000,
    })
    const res = await callChanges()
    expect(res.status).toBe(200)
    const env = await parseEnvelope(res)
    const bookChange = env.changes.find((c) => c.kind === "book")!
    expect(bookChange).toBeDefined()
    // Camel + snake — neither shape may appear in the payload.
    expect(bookChange.payload.file_path).toBeUndefined()
    expect(bookChange.payload.filePath).toBeUndefined()
    expect(bookChange.payload.cover_path).toBeUndefined()
    expect(bookChange.payload.coverPath).toBeUndefined()
    // Other fields survive (in either casing — handler may pass through
    // schema camelCase).
    const titleField =
      (bookChange.payload.title as string | undefined) ??
      (bookChange.payload.Title as string | undefined)
    expect(titleField).toBe("X")

    const hlChange = env.changes.find((c) => c.kind === "highlight")!
    expect(hlChange).toBeDefined()
    // Highlights include EVERY column — sanity check the three the seed
    // set explicitly.
    const hlPayload = hlChange.payload as Record<string, unknown>
    const cfiField = hlPayload.cfi_range ?? hlPayload.cfiRange
    const textField = hlPayload.text
    const colorField = hlPayload.color
    expect(cfiField).toBe("cfi:1")
    expect(textField).toBe("quote")
    expect(colorField).toBe("yellow")
  })

  it("normalizes pulled book payloads to SyncPayloadCodec snake_case and includes sync metadata", async () => {
    seedBook({
      id: UUID_BOOK_A,
      userId: "user_alice",
      title: "X",
      author: "Y",
      format: "pdf",
      currentCfi: "epubcfi(/6/4)",
      currentPage: 7,
      lastProgressPercent: 0.42,
      fileR2Key: "books/user_alice/hash.pdf",
      coverR2Key: "covers/user_alice/hash.jpg",
      updatedAt: 1_700_000_000_000,
    })

    const res = await callChanges()
    expect(res.status).toBe(200)
    const env = await parseEnvelope(res)
    const payload = env.changes.find((c) => c.kind === "book")!.payload

    expect(payload).toMatchObject({
      id: UUID_BOOK_A,
      title: "X",
      author: "Y",
      format_type: "pdf",
      current_cfi: "epubcfi(/6/4)",
      current_page: 7,
      last_progress_percent: 0.42,
      file_r2_key: "books/user_alice/hash.pdf",
      cover_r2_key: "covers/user_alice/hash.jpg",
    })
    expect(payload).not.toHaveProperty("user_id")
    expect(payload).not.toHaveProperty("userId")
    expect(payload).not.toHaveProperty("currentCfi")
    expect(payload).not.toHaveProperty("filePath")
    expect(payload).not.toHaveProperty("coverPath")
  })

  it("rows ordered by updatedAt ASC", async () => {
    seedBook({ id: UUID_BOOK_A, updatedAt: 3000 })
    seedBook({ id: UUID_BOOK_B, updatedAt: 1000 })
    seedBook({ id: UUID_BOOK_C, updatedAt: 2000 })
    const res = await callChanges()
    expect(res.status).toBe(200)
    const env = await parseEnvelope(res)
    expect(env.changes.length).toBe(3)
    const updatedAts = env.changes.map((c) => c.updated_at)
    // Strictly ascending.
    for (let i = 1; i < updatedAts.length; i += 1) {
      expect(updatedAts[i]).toBeGreaterThan(updatedAts[i - 1])
    }
  })

  it("updated_at encoded as seconds-since-reference-date (2001-01-01)", async () => {
    // Reference-date offset: 978_307_200_000 ms = 2001-01-01T00:00:00Z.
    // Seed 1 second AFTER the reference date — expected wire = 1.
    //
    // Anti-cases the test must reject:
    //   - ms-epoch:                  978_307_201_000 (off by ~31y * ms factor)
    //   - seconds-since-1970:        978_307_201    (off by 31 years)
    //   - ISO string (typeof===str): would fail typeof === "number"
    const REFERENCE_DATE_OFFSET_MS = 978_307_200_000
    seedBook({
      id: UUID_BOOK_A,
      updatedAt: REFERENCE_DATE_OFFSET_MS + 1000,
    })
    const res = await callChanges()
    expect(res.status).toBe(200)
    const env = await parseEnvelope(res)
    expect(env.changes.length).toBe(1)
    expect(typeof env.changes[0].updated_at).toBe("number")
    expect(env.changes[0].updated_at).toBe(1)
  })

  it("emits a seeded bookmark as kind 'bookmark' with location->locator mapping", async () => {
    const REFERENCE_DATE_OFFSET_MS = 978_307_200_000
    seedBookmark({
      id: UUID_BM_A,
      bookId: UUID_BOOK_A,
      location: "epubcfi(/6/4!/4/8)",
      label: "Ch 1",
      snippet: "a saved excerpt",
      createdAt: REFERENCE_DATE_OFFSET_MS + 5000, // 2001-01-01 + 5s
      updatedAt: REFERENCE_DATE_OFFSET_MS + 2000, // wire = 2
      isDeleted: false,
    })
    const res = await callChanges()
    expect(res.status).toBe(200)
    const env = await parseEnvelope(res)
    expect(env.changes.length).toBe(1)
    const bm = env.changes[0]
    expect(bm.kind).toBe("bookmark")
    expect(bm.id).toBe(UUID_BM_A)
    // NAME MISMATCH lock: row.location -> payload.locator.
    expect(bm.payload.locator).toBe("epubcfi(/6/4!/4/8)")
    expect(bm.payload.book_id).toBe(UUID_BOOK_A)
    expect(bm.payload.label).toBe("Ch 1")
    expect(bm.payload.snippet).toBe("a saved excerpt")
    // payload.created_at is an ISO8601 STRING (SyncPayloadCodec .iso8601).
    expect(typeof bm.payload.created_at).toBe("string")
    expect(bm.payload.created_at).toBe(
      new Date(REFERENCE_DATE_OFFSET_MS + 5000).toISOString(),
    )
    // Envelope updated_at = seconds-since-2001 = 2.
    expect(typeof bm.updated_at).toBe("number")
    expect(bm.updated_at).toBe(2)
    expect(bm.deleted).toBe(false)
    // Envelope keys MUST match the SyncChange CodingKeys exactly.
    expect(new Set(Object.keys(bm).sort())).toEqual(
      new Set(["kind", "id", "payload", "updated_at", "deleted"].sort()),
    )
  })

  it("bookmark soft-delete is emitted with deleted: true", async () => {
    seedBookmark({ id: UUID_BM_A, isDeleted: true })
    const res = await callChanges()
    expect(res.status).toBe(200)
    const env = await parseEnvelope(res)
    const bm = env.changes.find((c) => c.kind === "bookmark")!
    expect(bm).toBeDefined()
    expect(bm.deleted).toBe(true)
  })

  it("cross-user isolation: user B's /changes excludes user A's bookmark", async () => {
    seedBookmark({ id: UUID_BM_A, userId: "user_alice" })
    setUser("user_bob")
    const res = await callChanges()
    expect(res.status).toBe(200)
    const env = await parseEnvelope(res)
    expect(env.changes.find((c) => c.kind === "bookmark")).toBeUndefined()
  })

  it("since-cursor: bookmark <= since excluded; > since included", async () => {
    // since = 2020-01-01; seed one before and one after.
    const sinceMs = Date.parse("2020-01-01T00:00:00Z")
    seedBookmark({ id: UUID_BM_A, updatedAt: sinceMs - 1000 }) // excluded
    const res = await callChanges("?since=2020-01-01T00:00:00Z")
    expect(res.status).toBe(200)
    const env = await parseEnvelope(res)
    expect(env.changes.find((c) => c.kind === "bookmark")).toBeUndefined()

    resetStores()
    setUser("user_alice")
    seedBookmark({ id: UUID_BM_A, updatedAt: sinceMs + 1000 }) // included
    const res2 = await callChanges("?since=2020-01-01T00:00:00Z")
    const env2 = await parseEnvelope(res2)
    expect(env2.changes.find((c) => c.kind === "bookmark")?.id).toBe(UUID_BM_A)
  })
})

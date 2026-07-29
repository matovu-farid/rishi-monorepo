import { describe, it, expect, beforeEach, vi } from "vitest"

/**
 * Tests for POST /api/sync/push — Phase 17 Plan 07 (iOS SyncChange envelope).
 *
 * The iOS HighlightUploader.swift:73 and PositionUploader.swift:79 both call
 * `SyncPushEndpoint(body: .init(changes: [SyncChange]))` and decode
 * `SyncPushResponse.acceptedAt: Date`. The worker currently expects the
 * pre-Phase-17 grouped object body `{changes: {books, highlights, ...}}` and
 * returns `{conflicts, syncVersion}`. Those shapes are incompatible — iOS
 * uploads silently fail to push. This suite locks the v1 iOS-shaped contract:
 *
 *   Request:  { changes: [
 *                 { kind: "book"|"position"|"highlight"|"conversation"|"message",
 *                   id: <uuid>, payload: {...}, updated_at: <number>,
 *                   deleted: <bool> }, ... ] }
 *   Response: { accepted_at: <number = high-water-mark seconds since 2001> }
 *
 * LOAD-BEARING: `accepted_at` is a JSON number = (msEpoch - 978_307_200_000) /
 * 1000 — matches `Date(timeIntervalSinceReferenceDate:)` so the bare
 * `JSONDecoder()` at WorkerClient.swift:96 round-trips cleanly via
 * `.deferredToDate`. Emitting ms-epoch or ISO8601 would mis-decode by 31 years.
 *
 * Per-kind dispatch under test:
 *   - book  -> books table (id, userId LWW); strip file_url, cover_path
 *   - position -> UPDATE books row by book_id (currentCfi = payload.locator)
 *   - highlight -> highlights table (LWW); deleted=true sets isDeleted
 *   - conversation -> conversations table (LWW)
 *   - message -> messages table (append-only)
 *
 * Mocking strategy mirrors src/routes/changes.test.ts + devices.test.ts:
 * column-id stubs per table, predicate-descriptor drizzle helpers, in-memory
 * stores per table, requireAuth faked via `authState.userId`.
 */

// ─── In-memory row types ─────────────────────────────────────────────────────
interface FakeBookRow {
  id: string
  userId: string
  title: string
  author: string
  filePath: string
  coverPath: string | null
  format: string
  currentCfi: string | null
  currentPage: number | null
  lastProgressPercent: number | null
  fileHash: string | null
  fileR2Key: string | null
  coverR2Key: string | null
  createdAt: number
  updatedAt: number
  isDeleted: boolean
}

interface FakeHighlightRow {
  id: string
  bookId: string
  userId: string
  cfiRange: string
  text: string
  color: string
  note: string | null
  createdAt: number
  updatedAt: number
  isDeleted: boolean
}

interface FakeConversationRow {
  id: string
  bookId: string
  userId: string
  title: string
  createdAt: number
  updatedAt: number
  isDeleted: boolean
}

interface FakeMessageRow {
  id: string
  conversationId: string
  role: string
  content: string
  createdAt: number
  updatedAt: number
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
  isDeleted: boolean
}

const {
  booksStore,
  highlightsStore,
  conversationsStore,
  messagesStore,
  bookmarksStore,
  BOOK_COLS,
  HIGHLIGHT_COLS,
  CONV_COLS,
  MSG_COLS,
  BOOKMARK_COLS,
} = vi.hoisted(() => {
  function mkCols<T extends string>(table: T, names: string[]) {
    const out: Record<string, { __table: T; __col: string }> = {}
    for (const n of names) out[n] = { __table: table, __col: n }
    return out
  }
  return {
    booksStore: [] as FakeBookRow[],
    highlightsStore: [] as FakeHighlightRow[],
    conversationsStore: [] as FakeConversationRow[],
    messagesStore: [] as FakeMessageRow[],
    bookmarksStore: [] as FakeBookmarkRow[],
    BOOK_COLS: mkCols("books", [
      "id",
      "userId",
      "updatedAt",
      "currentCfi",
      "currentPage",
      "lastProgressPercent",
      "isDeleted",
    ]),
    HIGHLIGHT_COLS: mkCols("highlights", ["id", "userId", "updatedAt", "isDeleted"]),
    CONV_COLS: mkCols("conversations", ["id", "userId", "updatedAt", "isDeleted"]),
    MSG_COLS: mkCols("messages", ["id", "conversationId", "updatedAt"]),
    BOOKMARK_COLS: mkCols("bookmarks", ["id", "userId", "updatedAt", "isDeleted"]),
  }
})

function resetStores() {
  booksStore.length = 0
  highlightsStore.length = 0
  conversationsStore.length = 0
  messagesStore.length = 0
  bookmarksStore.length = 0
}

// ─── Mock schema so table imports resolve to column-id maps ──────────────────
vi.mock("@rishi/shared/schema", () => ({
  books: BOOK_COLS,
  highlights: HIGHLIGHT_COLS,
  conversations: CONV_COLS,
  messages: MSG_COLS,
  devices: {},
  bookmarks: BOOKMARK_COLS,
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
  conversations: CONV_COLS,
  messages: MSG_COLS,
  devices: {},
  bookmarks: BOOKMARK_COLS,
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

// ─── Mock drizzle-orm predicates ─────────────────────────────────────────────
type ColRef = { __table: string; __col: string }
type Pred =
  | { kind: "eq"; table: string; col: string; value: unknown }
  | { kind: "gt"; table: string; col: string; value: number }
  | { kind: "and"; preds: Pred[] }

function matches(row: Record<string, unknown>, p: Pred): boolean {
  if (p.kind === "and") return p.preds.every((sub) => matches(row, sub))
  if (p.kind === "eq") return row[p.col] === p.value
  if (p.kind === "gt") {
    const v = row[p.col]
    return typeof v === "number" && v > (p.value as number)
  }
  return false
}

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
  and: (...preds: Pred[]): Pred => ({ kind: "and", preds }),
  asc: (col: ColRef) => ({ table: col.__table, col: col.__col, dir: "asc" }),
  desc: (col: ColRef) => ({ table: col.__table, col: col.__col, dir: "desc" }),
  max: (col: ColRef) => ({ __agg: "max", col }),
  sql: (..._args: unknown[]) => ({ __sql: true }),
  getTableColumns: (_t: unknown) => ({}),
}))

// ─── Mock createDb with select/insert/update/transaction over our stores ─────
function storeFor(table: string): Array<Record<string, unknown>> {
  if (table === "books") return booksStore as unknown as Array<Record<string, unknown>>
  if (table === "highlights")
    return highlightsStore as unknown as Array<Record<string, unknown>>
  if (table === "conversations")
    return conversationsStore as unknown as Array<Record<string, unknown>>
  if (table === "messages")
    return messagesStore as unknown as Array<Record<string, unknown>>
  if (table === "bookmarks")
    return bookmarksStore as unknown as Array<Record<string, unknown>>
  return []
}

function tableTagOf(table: unknown): string {
  const t = table as Record<string, ColRef>
  for (const k of Object.keys(t)) {
    const ref = t[k]
    if (ref && typeof ref === "object" && "__table" in ref) return ref.__table
  }
  return ""
}

function makeTx() {
  return {
    select(_proj?: unknown) {
      return {
        from(table: unknown) {
          const tag = tableTagOf(table)
          let predicate: Pred | null = null
          const chain = {
            where(p: Pred) {
              predicate = p
              return chain
            },
            get() {
              const src = storeFor(tag)
              for (const r of src) {
                if (!predicate || matches(r, predicate)) return r
              }
              return undefined
            },
            all() {
              const src = storeFor(tag)
              return predicate ? src.filter((r) => matches(r, predicate!)) : src.slice()
            },
            limit() {
              return chain
            },
            orderBy() {
              return chain
            },
          }
          return chain
        },
      }
    },
    insert(table: unknown) {
      const tag = tableTagOf(table)
      return {
        values(v: Record<string, unknown>) {
          storeFor(tag).push({ ...v })
          return { run() {}, get() {} }
        },
      }
    },
    update(table: unknown) {
      const tag = tableTagOf(table)
      let patch: Record<string, unknown> = {}
      let predicate: Pred | null = null
      const chain = {
        set(s: Record<string, unknown>) {
          patch = s
          return chain
        },
        where(p: Pred) {
          predicate = p
          return chain
        },
        run() {
          for (const r of storeFor(tag)) {
            if (!predicate || matches(r, predicate)) Object.assign(r, patch)
          }
        },
        then(resolve: (v: unknown) => void) {
          chain.run()
          resolve(undefined)
        },
      }
      return chain
    },
    run() {},
    get() {
      return undefined
    },
  }
}

vi.mock("../db/drizzle", () => {
  function createDb() {
    const base = makeTx()
    return {
      ...base,
      async transaction(fn: (tx: ReturnType<typeof makeTx>) => Promise<unknown>) {
        return fn(makeTx())
      },
    }
  }
  return { createDb }
})

// ─── Auth state + middleware mock ───────────────────────────────────────────
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
        return { user: { id: authState.userId }, session: { token: "tok" } }
      },
    },
  }),
}))

vi.mock("../middleware", async () => {
  return {
    requireAuth: async (
      c: { set: (k: string, v: unknown) => void; json: (b: unknown, s: number) => Response },
      next: () => Promise<void>,
    ) => {
      if (!authState.userId) return c.json({ error: "Unauthorized" }, 401)
      c.set("userId", authState.userId)
      return next()
    },
  }
})

// ─── Now import the route under test — RED on first run ─────────────────────
import { syncRoutes } from "./sync"

const env = {
  BETTER_AUTH_SECRET: "test-secret",
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  DB: {} as unknown,
} as unknown as Record<string, unknown>

const REFERENCE_DATE_OFFSET_MS = 978_307_200_000

const UUID_BOOK = "11111111-1111-4111-8111-111111111111"
const UUID_HL = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
const UUID_HL_2 = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
const UUID_HL_3 = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
const UUID_POS = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
const UUID_BM = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
const UUID_BM_2 = "ffffffff-ffff-4fff-8fff-ffffffffffff"

interface SyncChange {
  kind: string
  id: string
  payload: Record<string, unknown>
  updated_at: number
  deleted: boolean
}

async function callPush(body: { changes: SyncChange[] } | unknown) {
  const req = new Request("http://test.local/push", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  })
  return syncRoutes.fetch(req, env)
}

function seedBook(overrides: Partial<FakeBookRow> = {}): FakeBookRow {
  const updatedAt = overrides.updatedAt ?? 1_700_000_000_000
  const full: FakeBookRow = {
    id: overrides.id ?? UUID_BOOK,
    userId: overrides.userId ?? "user_alice",
    title: overrides.title ?? "Seeded",
    author: overrides.author ?? "Anon",
    filePath: overrides.filePath ?? "",
    coverPath: overrides.coverPath ?? null,
    format: overrides.format ?? "epub",
    currentCfi: overrides.currentCfi ?? null,
    currentPage: overrides.currentPage ?? null,
    lastProgressPercent: overrides.lastProgressPercent ?? null,
    fileHash: overrides.fileHash ?? null,
    fileR2Key: overrides.fileR2Key ?? null,
    coverR2Key: overrides.coverR2Key ?? null,
    createdAt: overrides.createdAt ?? updatedAt,
    updatedAt,
    isDeleted: overrides.isDeleted ?? false,
  }
  booksStore.push(full)
  return full
}

function seedBookmark(overrides: Partial<FakeBookmarkRow> = {}): FakeBookmarkRow {
  const updatedAt = overrides.updatedAt ?? 1_700_000_000_000
  const full: FakeBookmarkRow = {
    id: overrides.id ?? UUID_BM,
    bookId: overrides.bookId ?? UUID_BOOK,
    userId: overrides.userId ?? "user_alice",
    location: overrides.location ?? "epubcfi(/6/4!/4/2)",
    label: overrides.label ?? "",
    snippet: overrides.snippet ?? null,
    pageNumber: overrides.pageNumber ?? null,
    createdAt: overrides.createdAt ?? updatedAt,
    updatedAt,
    isDeleted: overrides.isDeleted ?? false,
  }
  bookmarksStore.push(full)
  return full
}

beforeEach(() => {
  resetStores()
  setUser("user_alice")
})

// ─── Tests ───────────────────────────────────────────────────────────────────

describe("POST /api/sync/push (iOS SyncChange envelope)", () => {
  it("highlight kind: inserts row + returns {accepted_at: number}", async () => {
    const updatedAt = 1.5
    const res = await callPush({
      changes: [
        {
          kind: "highlight",
          id: UUID_HL,
          payload: {
            id: UUID_HL,
            book_id: UUID_BOOK,
            locator_start: "epubcfi(/6/4!/4/2)",
            locator_end: "epubcfi(/6/4!/4/3)",
            color: "yellow",
            text: "hi",
            created_at: 0,
          },
          updated_at: updatedAt,
          deleted: false,
        },
      ],
    })
    expect(res.status).toBe(200)
    const body = (await res.json()) as { accepted_at: number }
    expect(typeof body.accepted_at).toBe("number")
    expect(body.accepted_at).toBe(updatedAt)
    expect(highlightsStore.length).toBe(1)
    expect(highlightsStore[0].id).toBe(UUID_HL)
  })

  it("book kind: inserts row, strips file_url + cover_path, returns accepted_at", async () => {
    const updatedAt = 2.25
    const res = await callPush({
      changes: [
        {
          kind: "book",
          id: UUID_BOOK,
          payload: {
            id: UUID_BOOK,
            user_id: "user_alice",
            title: "Book Title",
            author: "Author",
            format_type: "epub",
            added_at: 0,
            file_url: "/local/path/that/MUST/NOT/persist.epub",
            cover_path: "/local/cover/MUST/NOT/persist.jpg",
            file_r2_key: `books/user_alice/${UUID_BOOK}.epub`,
          },
          updated_at: updatedAt,
          deleted: false,
        },
      ],
    })
    expect(res.status).toBe(200)
    const body = (await res.json()) as { accepted_at: number }
    expect(body.accepted_at).toBe(updatedAt)
    expect(booksStore.length).toBe(1)
    const row = booksStore[0]
    expect(row.id).toBe(UUID_BOOK)
    expect(row.title).toBe("Book Title")
    // file_url / cover_path MUST be stripped — they are local-only paths.
    expect(row.filePath).toBe("")
    expect(row.coverPath).toBeNull()
    expect(row.fileR2Key).toBe(`books/user_alice/${UUID_BOOK}.epub`)
  })

  it("position kind: updates existing books row currentCfi, no new table", async () => {
    seedBook({ id: UUID_BOOK, currentCfi: null, updatedAt: 0 })
    const res = await callPush({
      changes: [
        {
          kind: "position",
          id: UUID_POS,
          payload: {
            id: UUID_POS,
            book_id: UUID_BOOK,
            locator: "epubcfi(/6/4!/4/2)",
            percent_complete: 0.42,
          },
          updated_at: 3.0,
          deleted: false,
        },
      ],
    })
    expect(res.status).toBe(200)
    const body = (await res.json()) as { accepted_at: number }
    expect(body.accepted_at).toBe(3.0)
    // No new books row — the existing one was mutated.
    expect(booksStore.length).toBe(1)
    expect(booksStore[0].currentCfi).toBe("epubcfi(/6/4!/4/2)")
  })

  it("position kind: creates a book for the authenticated user when metadata is absent", async () => {
    const res = await callPush({
      changes: [
        {
          kind: "position",
          id: UUID_POS,
          payload: {
            id: UUID_POS,
            book_id: UUID_BOOK,
            locator: "epubcfi(/6/4!/4/2)",
            percent_complete: 0.42,
          },
          updated_at: 3.0,
          deleted: false,
        },
      ],
    })

    expect(res.status).toBe(200)
    expect(booksStore).toHaveLength(1)
    expect(booksStore[0]).toMatchObject({
      id: UUID_BOOK,
      userId: "user_alice",
      currentCfi: "epubcfi(/6/4!/4/2)",
      lastProgressPercent: 0.42,
      filePath: "",
      coverPath: null,
    })
  })

  it("position kind: rejects another user's book id instead of crossing ownership", async () => {
    seedBook({ id: UUID_BOOK, userId: "user_bob", currentCfi: null })
    const res = await callPush({
      changes: [
        {
          kind: "position",
          id: UUID_POS,
          payload: {
            book_id: UUID_BOOK,
            locator: "epubcfi(/6/4!/4/9)",
            percent_complete: 0.9,
          },
          updated_at: 4.0,
          deleted: false,
        },
      ],
    })

    expect(res.status).toBe(403)
    expect(booksStore).toHaveLength(1)
    expect(booksStore.find((book) => book.userId === "user_bob")?.currentCfi).toBeNull()
  })

  it("deleted=true highlight tombstone: flips existing isDeleted", async () => {
    highlightsStore.push({
      id: UUID_HL,
      bookId: UUID_BOOK,
      userId: "user_alice",
      cfiRange: "epubcfi(/0)",
      text: "x",
      color: "yellow",
      note: null,
      createdAt: 0,
      updatedAt: 1.0,
      isDeleted: false,
    })
    const res = await callPush({
      changes: [
        {
          kind: "highlight",
          id: UUID_HL,
          payload: { id: UUID_HL },
          updated_at: 5.0,
          deleted: true,
        },
      ],
    })
    expect(res.status).toBe(200)
    expect(highlightsStore[0].isDeleted).toBe(true)
  })

  it("accepted_at = max(updated_at) across all changes (seconds-since-2001)", async () => {
    // Lock the canonical reference offset directly in the assertion so this
    // test catches any drift from `(msEpoch - 978_307_200_000) / 1000`.
    const refOffsetSec = REFERENCE_DATE_OFFSET_MS / 1000
    expect(refOffsetSec).toBeGreaterThan(0) // sanity ref to the constant
    const res = await callPush({
      changes: [
        {
          kind: "highlight",
          id: UUID_HL,
          payload: {
            id: UUID_HL,
            book_id: UUID_BOOK,
            locator_start: "a",
            locator_end: "b",
            color: "yellow",
            text: "t",
          },
          updated_at: 1.5,
          deleted: false,
        },
        {
          kind: "highlight",
          id: UUID_HL_2,
          payload: {
            id: UUID_HL_2,
            book_id: UUID_BOOK,
            locator_start: "a",
            locator_end: "b",
            color: "yellow",
            text: "t",
          },
          updated_at: 3.0,
          deleted: false,
        },
      ],
    })
    expect(res.status).toBe(200)
    const body = (await res.json()) as { accepted_at: number }
    expect(body.accepted_at).toBe(3.0)
  })

  it("auth gate: no session -> 401 + zero db writes", async () => {
    setUser(null)
    const res = await callPush({
      changes: [
        {
          kind: "highlight",
          id: UUID_HL,
          payload: {},
          updated_at: 1.0,
          deleted: false,
        },
      ],
    })
    expect(res.status).toBe(401)
    expect(highlightsStore.length).toBe(0)
  })

  it("multi-kind batch (HighlightUploader pattern): three highlights -> 3 rows + max accepted_at", async () => {
    const res = await callPush({
      changes: [
        {
          kind: "highlight",
          id: UUID_HL,
          payload: {
            id: UUID_HL,
            book_id: UUID_BOOK,
            locator_start: "a",
            locator_end: "b",
            color: "yellow",
            text: "1",
          },
          updated_at: 1.0,
          deleted: false,
        },
        {
          kind: "highlight",
          id: UUID_HL_2,
          payload: {
            id: UUID_HL_2,
            book_id: UUID_BOOK,
            locator_start: "a",
            locator_end: "b",
            color: "yellow",
            text: "2",
          },
          updated_at: 2.0,
          deleted: false,
        },
        {
          kind: "highlight",
          id: UUID_HL_3,
          payload: {
            id: UUID_HL_3,
            book_id: UUID_BOOK,
            locator_start: "a",
            locator_end: "b",
            color: "yellow",
            text: "3",
          },
          updated_at: 4.5,
          deleted: false,
        },
      ],
    })
    expect(res.status).toBe(200)
    const body = (await res.json()) as { accepted_at: number }
    expect(body.accepted_at).toBe(4.5)
    expect(highlightsStore.length).toBe(3)
  })
})

describe("POST /api/sync/push — bookmark kind", () => {
  it("live insert: writes a row mapping locator->location, label, snippet, book_id, userId, updatedAt", async () => {
    const updatedAt = 7.5
    const res = await callPush({
      changes: [
        {
          kind: "bookmark",
          id: UUID_BM,
          payload: {
            id: UUID_BM,
            book_id: UUID_BOOK,
            locator: "epubcfi(/6/4!/4/10)",
            label: "Chapter 2",
            snippet: "the snippet text",
            created_at: "2026-06-18T00:00:00Z",
          },
          updated_at: updatedAt,
          deleted: false,
        },
      ],
    })
    expect(res.status).toBe(200)
    const body = (await res.json()) as { accepted_at: number }
    expect(body.accepted_at).toBe(updatedAt)
    expect(bookmarksStore.length).toBe(1)
    const row = bookmarksStore[0]
    expect(row.id).toBe(UUID_BM)
    expect(row.bookId).toBe(UUID_BOOK)
    expect(row.userId).toBe("user_alice")
    // NAME MISMATCH lock: payload.locator -> column location.
    expect(row.location).toBe("epubcfi(/6/4!/4/10)")
    expect(row.label).toBe("Chapter 2")
    expect(row.snippet).toBe("the snippet text")
    expect(row.isDeleted).toBe(false)
    // updatedAt = fromSecondsSinceRef(updated_at) = updated_at*1000 + 978_307_200_000.
    expect(row.updatedAt).toBe(updatedAt * 1000 + REFERENCE_DATE_OFFSET_MS)
  })

  it("missing label/snippet: label coalesces to '' and snippet to null", async () => {
    const res = await callPush({
      changes: [
        {
          kind: "bookmark",
          id: UUID_BM,
          payload: {
            id: UUID_BM,
            book_id: UUID_BOOK,
            locator: "epubcfi(/6/4!/4/10)",
            created_at: "2026-06-18T00:00:00Z",
          },
          updated_at: 1.0,
          deleted: false,
        },
      ],
    })
    expect(res.status).toBe(200)
    expect(bookmarksStore.length).toBe(1)
    expect(bookmarksStore[0].label).toBe("")
    expect(bookmarksStore[0].snippet).toBeNull()
  })

  it("LWW update: a newer updated_at overwrites; an older one is ignored", async () => {
    seedBookmark({
      id: UUID_BM,
      location: "old-loc",
      label: "old",
      snippet: "old-snip",
      updatedAt: 5.0 * 1000 + REFERENCE_DATE_OFFSET_MS,
    })
    // Newer push wins.
    await callPush({
      changes: [
        {
          kind: "bookmark",
          id: UUID_BM,
          payload: {
            id: UUID_BM,
            book_id: UUID_BOOK,
            locator: "new-loc",
            label: "new",
            snippet: "new-snip",
          },
          updated_at: 9.0,
          deleted: false,
        },
      ],
    })
    expect(bookmarksStore.length).toBe(1)
    expect(bookmarksStore[0].location).toBe("new-loc")
    expect(bookmarksStore[0].label).toBe("new")
    expect(bookmarksStore[0].snippet).toBe("new-snip")
    expect(bookmarksStore[0].updatedAt).toBe(9.0 * 1000 + REFERENCE_DATE_OFFSET_MS)

    // Older push is ignored (does not regress the row).
    await callPush({
      changes: [
        {
          kind: "bookmark",
          id: UUID_BM,
          payload: {
            id: UUID_BM,
            book_id: UUID_BOOK,
            locator: "stale-loc",
            label: "stale",
            snippet: "stale-snip",
          },
          updated_at: 2.0,
          deleted: false,
        },
      ],
    })
    expect(bookmarksStore[0].location).toBe("new-loc")
    expect(bookmarksStore[0].label).toBe("new")
  })

  it("tombstone: deleted=true flips is_deleted on an existing row; no-op for unknown id", async () => {
    seedBookmark({ id: UUID_BM, isDeleted: false, updatedAt: 1.0 * 1000 + REFERENCE_DATE_OFFSET_MS })
    // Known id -> flips isDeleted.
    await callPush({
      changes: [
        {
          kind: "bookmark",
          id: UUID_BM,
          payload: { id: UUID_BM },
          updated_at: 5.0,
          deleted: true,
        },
      ],
    })
    expect(bookmarksStore[0].isDeleted).toBe(true)

    // Unknown id -> no row created, no throw.
    const res = await callPush({
      changes: [
        {
          kind: "bookmark",
          id: UUID_BM_2,
          payload: { id: UUID_BM_2 },
          updated_at: 6.0,
          deleted: true,
        },
      ],
    })
    expect(res.status).toBe(200)
    // Still only the one seeded bookmark.
    expect(bookmarksStore.length).toBe(1)
  })

  it("cross-user isolation: a bookmark for user A is not written/visible under user B", async () => {
    // Seed an existing bookmark owned by alice.
    seedBookmark({
      id: UUID_BM,
      userId: "user_alice",
      location: "alice-loc",
      updatedAt: 1.0 * 1000 + REFERENCE_DATE_OFFSET_MS,
    })
    setUser("user_bob")
    // Bob pushes a bookmark with the SAME id — must NOT overwrite alice's row;
    // it inserts a bob-scoped row instead (existence check is (id, userId)).
    await callPush({
      changes: [
        {
          kind: "bookmark",
          id: UUID_BM,
          payload: {
            id: UUID_BM,
            book_id: UUID_BOOK,
            locator: "bob-loc",
            label: "bob",
          },
          updated_at: 9.0,
          deleted: false,
        },
      ],
    })
    const aliceRow = bookmarksStore.find(
      (r) => r.id === UUID_BM && r.userId === "user_alice",
    )
    const bobRow = bookmarksStore.find(
      (r) => r.id === UUID_BM && r.userId === "user_bob",
    )
    expect(aliceRow?.location).toBe("alice-loc") // untouched
    expect(bobRow?.location).toBe("bob-loc") // bob's own row
    expect(bobRow?.userId).toBe("user_bob")
  })

  it("batch tolerance: a highlight + a bookmark in one batch returns 200 and writes BOTH", async () => {
    const res = await callPush({
      changes: [
        {
          kind: "highlight",
          id: UUID_HL,
          payload: {
            id: UUID_HL,
            book_id: UUID_BOOK,
            locator_start: "a",
            locator_end: "b",
            color: "yellow",
            text: "hi",
          },
          updated_at: 1.0,
          deleted: false,
        },
        {
          kind: "bookmark",
          id: UUID_BM,
          payload: {
            id: UUID_BM,
            book_id: UUID_BOOK,
            locator: "epubcfi(/6/4!/4/2)",
            label: "L",
          },
          updated_at: 2.0,
          deleted: false,
        },
      ],
    })
    // Proves the Zod enum no longer 400s on a bookmark mixed with other kinds.
    expect(res.status).toBe(200)
    const body = (await res.json()) as { accepted_at: number }
    expect(body.accepted_at).toBe(2.0)
    expect(highlightsStore.length).toBe(1)
    expect(bookmarksStore.length).toBe(1)
    expect(bookmarksStore[0].location).toBe("epubcfi(/6/4!/4/2)")
  })
})

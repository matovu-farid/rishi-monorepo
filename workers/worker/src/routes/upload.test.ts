import { describe, it, expect, beforeEach, vi } from "vitest"

/**
 * Tests for /api/sync/upload-url — Cloudflare Worker endpoint that issues
 * presigned R2 PUT URLs. This test file exercises the new storage-limit
 * checks added on top of the existing dedup-by-hash path:
 *
 *   1. per-file size cap        → 413 FILE_TOO_LARGE
 *   2. per-user book count cap  → 507 BOOK_LIMIT_REACHED
 *   3. per-user storage bytes   → 507 STORAGE_LIMIT_REACHED
 *
 * Strategy: stub the Drizzle DB with an in-memory books store keyed by user,
 * stub aws4fetch so the route never tries to actually sign an R2 URL against
 * a real bucket, and stub createAuth so requireAuth resolves to a known user.
 */

// ─── In-memory "books" store ──────────────────────────────────────────────────
interface FakeBookRow {
  id: string
  userId: string
  fileHash: string | null
  fileR2Key: string | null
  fileSize: number | null
  isDeleted: boolean
}

// vi.hoisted lets us define module-scope bindings that survive vi.mock factory
// hoisting (factories run before regular top-level code).
const { bookStore, COLS } = vi.hoisted(() => {
  const COLS = {
    fileR2Key: { __col: "fileR2Key" } as const,
    fileHash: { __col: "fileHash" } as const,
    userId: { __col: "userId" } as const,
    isDeleted: { __col: "isDeleted" } as const,
    id: { __col: "id" } as const,
    fileSize: { __col: "fileSize" } as const,
  }
  return { bookStore: [] as FakeBookRow[], COLS }
})

function resetStore() {
  bookStore.length = 0
}

// ─── Mock @rishi/shared/schema so `books` resolves to our column ids ─────────
// We don't need the real Drizzle schema in this test — only the column
// references so the route's queries (`eq(books.userId, ...)`, etc.) work.
vi.mock("@rishi/shared/schema", () => ({
  books: COLS,
  // Also export the other tables referenced by sync.ts (imported transitively
  // via ../index → ./routes/sync) so that import doesn't blow up.
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
}))

// ─── Mock drizzle-orm helpers so they return predicate descriptors ────────────
type Pred =
  | { kind: "eq"; col: keyof typeof COLS; value: unknown }
  | { kind: "and"; preds: Pred[] }

vi.mock("drizzle-orm", () => ({
  eq: (col: { __col: keyof typeof COLS }, value: unknown): Pred => ({
    kind: "eq",
    col: col.__col,
    value,
  }),
  and: (...preds: Pred[]): Pred => ({ kind: "and", preds }),
  sql: (strings: TemplateStringsArray, ...values: unknown[]) => ({
    __sql: strings.join("?"),
    values,
  }),
  count: () => ({ __agg: "count" as const }),
  sum: (col: { __col: string }) => ({ __agg: "sum" as const, col: col.__col }),
}))

// Helper to evaluate a predicate against a row.
function evalPred(pred: Pred, row: FakeBookRow): boolean {
  if (pred.kind === "eq") {
    return (row as unknown as Record<string, unknown>)[pred.col] === pred.value
  }
  if (pred.kind === "and") {
    return pred.preds.every((p) => evalPred(p, row))
  }
  return false
}

// ─── Mock createDb to return a tiny query builder ─────────────────────────────
vi.mock("../db/drizzle", () => {
  function createDb() {
    return {
      select(fields?: Record<string, unknown>) {
        const selectFields = fields
        return {
          from(_table: unknown) {
            const ctx: { pred?: Pred } = {}
            const builder = {
              where(pred: Pred) {
                ctx.pred = pred
                return builder
              },
              get() {
                const match = bookStore.find((r) => (ctx.pred ? evalPred(ctx.pred, r) : true))
                // Projection: handle aggregate fields (count / sum) or column refs
                if (!selectFields) return match
                const out: Record<string, unknown> = {}
                for (const [key, val] of Object.entries(selectFields)) {
                  const v = val as { __col?: string; __agg?: string; col?: string }
                  if (v.__agg === "count") {
                    const all = bookStore.filter((r) =>
                      ctx.pred ? evalPred(ctx.pred, r) : true,
                    )
                    out[key] = all.length
                  } else if (v.__agg === "sum") {
                    const all = bookStore.filter((r) =>
                      ctx.pred ? evalPred(ctx.pred, r) : true,
                    )
                    out[key] = all.reduce((acc, r) => {
                      const colName = v.col as string
                      const value = (r as unknown as Record<string, unknown>)[colName]
                      return acc + (typeof value === "number" ? value : 0)
                    }, 0)
                  } else if (v.__col) {
                    if (!match) return undefined
                    out[key] = (match as unknown as Record<string, unknown>)[v.__col]
                  }
                }
                return out
              },
              all() {
                return bookStore.filter((r) =>
                  ctx.pred ? evalPred(ctx.pred, r) : true,
                )
              },
            }
            return builder
          },
        }
      },
    }
  }
  return { createDb }
})

// ─── Mock aws4fetch so we don't sign a real R2 URL ────────────────────────────
vi.mock("aws4fetch", () => ({
  AwsClient: class {
    constructor(_cfg: unknown) {}
    async sign(req: Request) {
      return new Request(req.url + "?signed=1", req)
    }
  },
}))

// ─── Mock createAuth so requireAuth (defined in ../index) sees a session ─────
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

// ─── Mock ../index to avoid circular Hono app construction ────────────────────
// upload.ts imports `requireAuth` from ../index, which at module load wires up
// every other route via app.route() — and some of those routes pull in deps
// (axios / sentry / ai-sdk) that don't play well with vitest's worker pool.
// We stub a tiny requireAuth that calls our mocked createAuth and sets userId,
// matching the behavior of the real requireAuth in src/index.ts.
vi.mock("../index", async () => {
  // We deliberately do NOT import the real ../index here. We re-export the
  // CloudflareBindings type via a `type` interface that upload.ts only uses
  // for typing (erased at runtime).
  return {
    requireAuth: async (c: { set: (k: string, v: unknown) => void }, next: () => Promise<void>) => {
      if (!authState.userId) {
        // mimic real behavior: 401 if no session
        // Hono context exposes .json — but we forward via a thrown response in tests
        return new Response(JSON.stringify({ error: "Unauthorized" }), {
          status: 401,
          headers: { "Content-Type": "application/json" },
        })
      }
      c.set("userId", authState.userId)
      return next()
    },
  }
})

// Now import the route under test (after mocks are in place).
import { uploadRoutes } from "./upload"

const baseEnv = {
  BETTER_AUTH_SECRET: "test-secret",
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  R2_ACCESS_KEY_ID: "test-key",
  R2_SECRET_ACCESS_KEY: "test-secret",
  CLOUDFLARE_ACCOUNT_ID: "test-acct",
  DB: {} as unknown,
  BOOK_STORAGE: {} as unknown,
} as unknown as Record<string, unknown>

async function callUpload(
  body: unknown,
  envOverrides: Record<string, unknown> = {},
) {
  const env = { ...baseEnv, ...envOverrides }
  const req = new Request("http://test.local/upload-url", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  })
  return uploadRoutes.fetch(req, env)
}

const FAKE_HASH = "a".repeat(64) // valid 64-char hex

function seedBook(partial: Partial<FakeBookRow>): FakeBookRow {
  const row: FakeBookRow = {
    id: partial.id ?? crypto.randomUUID(),
    userId: partial.userId ?? "user_alice",
    fileHash: partial.fileHash ?? null,
    fileR2Key: partial.fileR2Key ?? null,
    fileSize: partial.fileSize ?? 0,
    isDeleted: partial.isDeleted ?? false,
  }
  bookStore.push(row)
  return row
}

beforeEach(() => {
  resetStore()
  setUser("user_alice")
})

describe("POST /upload-url — fileSize cap (FILE_TOO_LARGE)", () => {
  it("rejects fileSize > BOOK_MAX_FILE_BYTES with 413 + FILE_TOO_LARGE", async () => {
    const res = await callUpload(
      {
        fileHash: FAKE_HASH,
        contentType: "application/epub+zip",
        fileSize: 838860800 + 1, // 800 MB + 1 (default cap)
      },
    )
    expect(res.status).toBe(413)
    const body = (await res.json()) as { code: string; limit: number; error: string }
    expect(body.code).toBe("FILE_TOO_LARGE")
    expect(body.limit).toBe(838860800)
    expect(typeof body.error).toBe("string")
  })

  it("rejects fileSize <= 0 with 413 + FILE_TOO_LARGE", async () => {
    const res = await callUpload({
      fileHash: FAKE_HASH,
      contentType: "application/epub+zip",
      fileSize: 0,
    })
    expect(res.status).toBe(413)
    const body = (await res.json()) as { code: string }
    expect(body.code).toBe("FILE_TOO_LARGE")
  })

  it("respects BOOK_MAX_FILE_BYTES env override (1024 → 2048-byte file rejected)", async () => {
    const res = await callUpload(
      {
        fileHash: FAKE_HASH,
        contentType: "application/epub+zip",
        fileSize: 2048,
      },
      { BOOK_MAX_FILE_BYTES: "1024" },
    )
    expect(res.status).toBe(413)
    const body = (await res.json()) as { code: string; limit: number }
    expect(body.code).toBe("FILE_TOO_LARGE")
    expect(body.limit).toBe(1024)
  })
})

describe("POST /upload-url — per-user book count cap (BOOK_LIMIT_REACHED)", () => {
  it("rejects when user already at BOOK_MAX_PER_USER with 507 + BOOK_LIMIT_REACHED", async () => {
    // Seed 3 books for the user, set cap to 3.
    seedBook({ userId: "user_alice", fileHash: "h1", fileSize: 100 })
    seedBook({ userId: "user_alice", fileHash: "h2", fileSize: 200 })
    seedBook({ userId: "user_alice", fileHash: "h3", fileSize: 300 })

    const res = await callUpload(
      {
        fileHash: FAKE_HASH,
        contentType: "application/epub+zip",
        fileSize: 1000,
      },
      { BOOK_MAX_PER_USER: "3" },
    )
    expect(res.status).toBe(507)
    const body = (await res.json()) as {
      code: string
      limit: number
      current: number
    }
    expect(body.code).toBe("BOOK_LIMIT_REACHED")
    expect(body.limit).toBe(3)
    expect(body.current).toBe(3)
  })

  it("ignores soft-deleted books when counting against BOOK_MAX_PER_USER", async () => {
    seedBook({ userId: "user_alice", fileHash: "h1", fileSize: 100 })
    seedBook({
      userId: "user_alice",
      fileHash: "h2",
      fileSize: 200,
      isDeleted: true,
    })

    const res = await callUpload(
      {
        fileHash: FAKE_HASH,
        contentType: "application/epub+zip",
        fileSize: 1000,
      },
      { BOOK_MAX_PER_USER: "2" },
    )
    // 1 non-deleted book < cap=2 → allowed
    expect(res.status).toBe(200)
  })
})

describe("POST /upload-url — per-user storage cap (STORAGE_LIMIT_REACHED)", () => {
  it("rejects when sum + fileSize > BOOK_MAX_USER_BYTES with 507 + STORAGE_LIMIT_REACHED", async () => {
    seedBook({ userId: "user_alice", fileHash: "h1", fileSize: 800 })
    seedBook({ userId: "user_alice", fileHash: "h2", fileSize: 200 })
    // current = 1000

    const res = await callUpload(
      {
        fileHash: FAKE_HASH,
        contentType: "application/epub+zip",
        fileSize: 100,
      },
      {
        BOOK_MAX_USER_BYTES: "1050",
        BOOK_MAX_FILE_BYTES: "100000",
        BOOK_MAX_PER_USER: "100",
      },
    )
    expect(res.status).toBe(507)
    const body = (await res.json()) as {
      code: string
      limit: number
      current: number
    }
    expect(body.code).toBe("STORAGE_LIMIT_REACHED")
    expect(body.limit).toBe(1050)
    expect(body.current).toBe(1000)
  })

  it("ignores soft-deleted books when summing storage usage", async () => {
    seedBook({ userId: "user_alice", fileHash: "h1", fileSize: 800 })
    seedBook({
      userId: "user_alice",
      fileHash: "h2",
      fileSize: 9999,
      isDeleted: true,
    })

    const res = await callUpload(
      {
        fileHash: FAKE_HASH,
        contentType: "application/epub+zip",
        fileSize: 100,
      },
      {
        BOOK_MAX_USER_BYTES: "1000",
        BOOK_MAX_FILE_BYTES: "100000",
        BOOK_MAX_PER_USER: "100",
      },
    )
    // non-deleted sum = 800 + 100 = 900 < 1000 → allowed
    expect(res.status).toBe(200)
  })
})

describe("POST /upload-url — happy path", () => {
  it("allows upload when all three limits are ok", async () => {
    const res = await callUpload({
      fileHash: FAKE_HASH,
      contentType: "application/epub+zip",
      fileSize: 1024 * 1024, // 1 MB — well under default 800 MB
    })
    expect(res.status).toBe(200)
    const body = (await res.json()) as {
      exists: boolean
      uploadUrl?: string
      r2Key: string
      expiresIn?: number
    }
    expect(body.exists).toBe(false)
    expect(body.r2Key).toContain("books/user_alice/")
    expect(body.uploadUrl).toBeTruthy()
  })
})

describe("POST /upload-url — dedup path (exists: true)", () => {
  it("bypasses count + storage checks but NOT the size check", async () => {
    // Seed a dedup target for this user with this hash.
    seedBook({
      userId: "user_alice",
      fileHash: FAKE_HASH,
      fileSize: 1000,
      fileR2Key: `books/user_alice/${FAKE_HASH}`,
    })
    // Add many other books so per-user count would normally trip.
    for (let i = 0; i < 5; i++) {
      seedBook({
        userId: "user_alice",
        fileHash: `other-${i}`,
        fileSize: 500,
        fileR2Key: `books/user_alice/other-${i}`,
      })
    }

    const res = await callUpload(
      {
        fileHash: FAKE_HASH,
        contentType: "application/epub+zip",
        fileSize: 1000,
      },
      {
        // count cap tight enough to reject if it WERE enforced
        BOOK_MAX_PER_USER: "1",
        BOOK_MAX_USER_BYTES: "100",
      },
    )
    expect(res.status).toBe(200)
    const body = (await res.json()) as { exists: boolean; r2Key: string }
    expect(body.exists).toBe(true)
    expect(body.r2Key).toBe(`books/user_alice/${FAKE_HASH}`)
  })

  it("still enforces size cap even on dedup hits", async () => {
    seedBook({
      userId: "user_alice",
      fileHash: FAKE_HASH,
      fileSize: 1000,
      fileR2Key: `books/user_alice/${FAKE_HASH}`,
    })
    const res = await callUpload(
      {
        fileHash: FAKE_HASH,
        contentType: "application/epub+zip",
        fileSize: 2048,
      },
      { BOOK_MAX_FILE_BYTES: "1024" },
    )
    expect(res.status).toBe(413)
    const body = (await res.json()) as { code: string }
    expect(body.code).toBe("FILE_TOO_LARGE")
  })
})

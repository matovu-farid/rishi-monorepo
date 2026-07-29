import { describe, it, expect, beforeEach, vi } from "vitest"

/**
 * Tests for POST /api/sync/upload-url — Phase 17 plan 17-08 (Gap 3).
 *
 * iOS BookUploader.swift:54 calls SyncUploadURLEndpoint with body
 *   { key: "books/<userId>/<bookId>.<ext>", content_type: "<mime>" }
 * and decodes the response as PresignedURLResponse
 *   { url: String, expires_at: Date }            // wire: expires_at = number
 *
 * Worker currently reads {fileHash, fileSize} and returns
 *   {exists, uploadUrl, r2Key, expiresIn}
 * which iOS cannot decode. This test file locks in the iOS contract.
 *
 * Date wire format = seconds since 2001-01-01 reference date — matches
 * iOS WorkerClient.swift:96 `JSONDecoder()` (.deferredToDate). See
 * routes/changes.ts and routes/devices.test.ts for the canonical pattern.
 *
 * Strategy mirrors src/routes/devices.test.ts and src/routes/upload.test.ts:
 *  - In-memory `books` store with column-id stubs
 *  - drizzle-orm helpers return predicate descriptors
 *  - createDb / aws4fetch / createAuth / ../index all mocked so the route
 *    runs in isolation.
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

// ─── Mock ../db/schema so `books` resolves to our column ids ────────────────
vi.mock("../db/schema", () => ({
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

function evalPred(pred: Pred, row: FakeBookRow): boolean {
  if (pred.kind === "eq") {
    return (row as unknown as Record<string, unknown>)[pred.col] === pred.value
  }
  if (pred.kind === "and") {
    return pred.preds.every((p) => evalPred(p, row))
  }
  return false
}

// ─── Mock createDb with a tiny select/from/where builder ─────────────────────
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
                const match = bookStore.find((r) =>
                  ctx.pred ? evalPred(ctx.pred, r) : true,
                )
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
// Returns a stub URL containing X-Amz-Signed-Url-Stub so the handler can return
// `signed.url.toString()` as the `url` field.
vi.mock("aws4fetch", () => ({
  AwsClient: class {
    constructor(_cfg: unknown) {}
    async sign(req: Request) {
      return {
        url: new URL(
          req.url +
            (req.url.includes("?") ? "&" : "?") +
            "X-Amz-Signed-Url-Stub=1&X-Amz-Expires=300",
        ),
      }
    }
  },
}))

// ─── Mock createAuth so requireAuth sees a session ────────────────────────────
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

// ─── Mock ../middleware to avoid real JWT verification ─────────────────────
vi.mock("../middleware", async () => {
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

// ─── Now import the route under test ─────────────────────────────────────────
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

async function callUploadUrl(
  body: unknown,
  envOverrides: Record<string, unknown> = {},
) {
  const env = { ...baseEnv, ...envOverrides }
  const req = new Request("http://test.local/upload-url", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Rishi-Data-Use-Consent": "2026-07-29",
    },
    body: JSON.stringify(body),
  })
  return uploadRoutes.fetch(req, env)
}

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

const AUTHED_USER = "user_alice"
const BOOK_ID = "11111111-2222-3333-4444-555555555555"
const REFERENCE_DATE_OFFSET_MS = 978_307_200_000

beforeEach(() => {
  resetStore()
  setUser(AUTHED_USER)
})

// ─── Tests ───────────────────────────────────────────────────────────────────

describe("POST /api/sync/upload-url — iOS contract", () => {
  it("happy path: accepts {key, content_type} and returns {url, expires_at: <seconds-since-2001 number>}", async () => {
    const before = (Date.now() + 300_000 - REFERENCE_DATE_OFFSET_MS) / 1000
    const res = await callUploadUrl({
      key: `books/${AUTHED_USER}/${BOOK_ID}.epub`,
      content_type: "application/epub+zip",
    })
    expect(res.status).toBe(200)
    const body = (await res.json()) as Record<string, unknown>

    // Response shape: exactly {url, expires_at} — no legacy keys.
    expect(typeof body.url).toBe("string")
    expect((body.url as string).length).toBeGreaterThan(0)
    expect(typeof body.expires_at).toBe("number")

    // No legacy keys leaking through.
    expect(body).not.toHaveProperty("uploadUrl")
    expect(body).not.toHaveProperty("r2Key")
    expect(body).not.toHaveProperty("expiresIn")
    expect(body).not.toHaveProperty("exists")

    // expires_at = seconds since 2001-01-01, ~5 minutes (300s) ahead of now.
    const expiresAt = body.expires_at as number
    expect(expiresAt).toBeGreaterThan(0)
    expect(Math.abs(expiresAt - before)).toBeLessThan(5)
  })

  it("rejects path traversal in the supplied key with 403", async () => {
    const res = await callUploadUrl({
      key: `books/${AUTHED_USER}/../other.epub`,
      content_type: "application/epub+zip",
    })
    expect(res.status).toBe(403)
  })

  it("rejects keys that target a different user's prefix with 403", async () => {
    const res = await callUploadUrl({
      key: `books/some-other-user/${BOOK_ID}.epub`,
      content_type: "application/epub+zip",
    })
    expect(res.status).toBe(403)
  })

  it("rejects missing content_type with 400 bad_request", async () => {
    const res = await callUploadUrl({
      key: `books/${AUTHED_USER}/${BOOK_ID}.epub`,
    })
    expect(res.status).toBe(400)
    const body = (await res.json()) as { error: string }
    expect(body.error).toBe("bad_request")
  })

  it("rejects unauthenticated callers with 401", async () => {
    setUser(null)
    const res = await callUploadUrl({
      key: `books/${AUTHED_USER}/${BOOK_ID}.epub`,
      content_type: "application/epub+zip",
    })
    expect(res.status).toBe(401)
  })

  it("still enforces per-user storage cap → 507 STORAGE_LIMIT_REACHED", async () => {
    // Seed the user at the storage cap.
    seedBook({
      userId: AUTHED_USER,
      fileHash: "existing-hash",
      fileSize: 1000,
      fileR2Key: `books/${AUTHED_USER}/existing.epub`,
    })
    const res = await callUploadUrl(
      {
        key: `books/${AUTHED_USER}/${BOOK_ID}.epub`,
        content_type: "application/epub+zip",
      },
      {
        BOOK_MAX_USER_BYTES: "500", // current sum 1000 already exceeds 500
        BOOK_MAX_PER_USER: "100",
        BOOK_MAX_FILE_BYTES: "100000",
      },
    )
    expect(res.status).toBe(507)
    const body = (await res.json()) as { code: string }
    expect(body.code).toBe("STORAGE_LIMIT_REACHED")
  })
})

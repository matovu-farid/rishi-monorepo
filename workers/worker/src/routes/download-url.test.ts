import { describe, it, expect, beforeEach, vi } from "vitest"

/**
 * Tests for POST /api/sync/download-url — Phase 17 plan 17-09 (Gap 4).
 *
 * iOS DownloadCoordinator calls SyncDownloadURLEndpoint with body
 *   { key: "books/<userId>/<bookId>.<ext>" }
 * and decodes the response as PresignedURLResponse
 *   { url: String, expires_at: Date }            // wire: expires_at = number
 *
 * Worker currently reads {r2Key} and returns {downloadUrl, expiresIn},
 * which iOS cannot decode. This test file locks in the iOS contract.
 *
 * Date wire format = seconds since 2001-01-01 reference date — matches
 * iOS WorkerClient.swift:96 `JSONDecoder()` (.deferredToDate). See
 * routes/changes.ts and routes/devices.test.ts for the canonical pattern.
 *
 * Strategy mirrors src/routes/upload-url.test.ts (17-08):
 *  - drizzle-orm helpers stubbed (download handler does not query DB, but
 *    sibling imports in upload.ts still resolve the mocks at module load)
 *  - createDb / aws4fetch / createAuth / ../index all mocked so the route
 *    runs in isolation.
 */

// ─── Mock @rishi/shared/schema (download handler does not touch DB but
//     module-level imports in upload.ts need resolvable stubs) ────────────────
vi.mock("@rishi/shared/schema", () => ({
  books: {},
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

// ─── Mock drizzle-orm helpers (transitive imports) ──────────────────────────
vi.mock("drizzle-orm", () => ({
  eq: (_col: unknown, _value: unknown) => ({ kind: "eq" }),
  and: (..._preds: unknown[]) => ({ kind: "and" }),
  sql: (strings: TemplateStringsArray, ...values: unknown[]) => ({
    __sql: strings.join("?"),
    values,
  }),
  count: () => ({ __agg: "count" as const }),
  sum: (_col: unknown) => ({ __agg: "sum" as const }),
}))

// ─── Mock createDb (download handler does not call it; stub anyway) ─────────
vi.mock("../db/drizzle", () => {
  function createDb() {
    return {
      select() {
        return {
          from() {
            const builder = {
              where() {
                return builder
              },
              get() {
                return undefined
              },
              all() {
                return []
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
const { signCalls } = vi.hoisted(() => ({
  signCalls: [] as Array<{ url: string; method: string; expires: string | null }>,
}))

vi.mock("aws4fetch", () => ({
  AwsClient: class {
    constructor(_cfg: unknown) {}
    async sign(req: Request) {
      signCalls.push({
        url: req.url,
        method: req.method,
        // Expiry is a query param on the URL being signed (not a sign header).
        expires: new URL(req.url).searchParams.get("X-Amz-Expires"),
      })
      return {
        url: new URL(
          req.url +
            (req.url.includes("?") ? "&" : "?") +
            "X-Amz-Signed-Url-Stub=1&X-Amz-Expires=600",
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

// ─── Mock ../index to avoid pulling the real Hono app + every route ──────────
vi.mock("../index", async () => {
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

async function callDownloadUrl(
  body: unknown,
  envOverrides: Record<string, unknown> = {},
) {
  const env = { ...baseEnv, ...envOverrides }
  const init: RequestInit = {
    method: "POST",
    headers: { "Content-Type": "application/json" },
  }
  if (body !== undefined) {
    init.body = JSON.stringify(body)
  }
  const req = new Request("http://test.local/download-url", init)
  return uploadRoutes.fetch(req, env)
}

const AUTHED_USER = "user_alice"
const BOOK_ID = "11111111-2222-3333-4444-555555555555"
const REFERENCE_DATE_OFFSET_MS = 978_307_200_000

beforeEach(() => {
  signCalls.length = 0
  setUser(AUTHED_USER)
})

// ─── Tests ───────────────────────────────────────────────────────────────────

describe("POST /api/sync/download-url — iOS contract", () => {
  it("happy path: accepts {key} and returns {url, expires_at: <seconds-since-2001 number>}", async () => {
    const before = (Date.now() + 600_000 - REFERENCE_DATE_OFFSET_MS) / 1000
    const res = await callDownloadUrl({
      key: `books/${AUTHED_USER}/${BOOK_ID}.epub`,
    })
    expect(res.status).toBe(200)
    const body = (await res.json()) as Record<string, unknown>

    // Response shape: exactly {url, expires_at} — no legacy keys.
    expect(typeof body.url).toBe("string")
    expect((body.url as string).length).toBeGreaterThan(0)
    expect(typeof body.expires_at).toBe("number")

    // No legacy keys leaking through.
    expect(body).not.toHaveProperty("downloadUrl")
    expect(body).not.toHaveProperty("expiresIn")
    expect(body).not.toHaveProperty("r2Key")

    // expires_at = seconds since 2001-01-01, ~10 minutes (600s) ahead of now.
    const expiresAt = body.expires_at as number
    expect(expiresAt).toBeGreaterThan(0)
    expect(Math.abs(expiresAt - before)).toBeLessThan(5)

    // Signing used GET + 600s expiry.
    expect(signCalls.length).toBe(1)
    expect(signCalls[0].method).toBe("GET")
    expect(signCalls[0].expires).toBe("600")
  })

  it("rejects path traversal in the supplied key with 403", async () => {
    const res = await callDownloadUrl({
      key: `books/${AUTHED_USER}/../other.epub`,
    })
    expect(res.status).toBe(403)
  })

  it("rejects keys that target a different user's prefix with 403", async () => {
    const res = await callDownloadUrl({
      key: `books/some-other-user/${BOOK_ID}.epub`,
    })
    expect(res.status).toBe(403)
  })

  it("rejects missing key with 403", async () => {
    const res = await callDownloadUrl({})
    expect(res.status).toBe(403)
  })

  it("rejects unauthenticated callers with 401", async () => {
    setUser(null)
    const res = await callDownloadUrl({
      key: `books/${AUTHED_USER}/${BOOK_ID}.epub`,
    })
    expect(res.status).toBe(401)
  })
})

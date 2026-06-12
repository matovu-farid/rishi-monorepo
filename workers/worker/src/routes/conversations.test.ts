import { describe, it, expect, beforeEach, vi } from "vitest"

/**
 * Tests for /api/sync/conversations — Phase 16-03 Task 1.
 *
 * The iOS ConversationUploader (Phase 16-04) posts dirty conversation rows
 * to POST /api/sync/conversations; SyncEngine inbound merges results from
 * GET /api/sync/conversations?since=<ms>. Both routes sit behind Better
 * Auth's `requireAuth` middleware (mirrored from devices.ts) and enforce
 * server-side userId override on the upsert path so a client cannot
 * impersonate another user by setting `user_id` in the body.
 *
 * Coverage (7 cases — RED before conversations.ts exists):
 *
 *  1. Unauth POST -> 401, zero rows written.
 *  2. Happy POST -> 200 { applied_count: 2 } and both rows belong to the
 *     caller (server overrides any client-sent user_id).
 *  3. Idempotent POST -> SAME id twice yields exactly 1 row; LWW updates
 *     title + updated_at on the second push.
 *  4. Validation -> missing `conversations` key returns 400 bad_request.
 *  5. GET happy -> caller-scoped rows only (bob's row excluded).
 *  6. GET since cursor -> only rows with updated_at > since.
 *  7. GET cross-user isolation -> alice's GET never returns bob's rows
 *     even when both share a since cursor.
 *
 * Mocking strategy mirrors devices.test.ts: column-id stubs for the
 * `conversations` table, a tiny predicate parser for eq/and/gt, an
 * in-memory `conversationStore`, and `requireAuth` faked via the same
 * `authState.userId` boolean gate.
 */

// ─── In-memory conversation store ─────────────────────────────────────────────
interface FakeConvRow {
  id: string
  userId: string
  bookId: string
  title: string
  createdAt: number
  updatedAt: number
  syncVersion: number
  isDirty: boolean
  isDeleted: boolean
}

const { conversationStore, COLS } = vi.hoisted(() => {
  const COLS = {
    id: { __col: "id" } as const,
    userId: { __col: "userId" } as const,
    bookId: { __col: "bookId" } as const,
    title: { __col: "title" } as const,
    createdAt: { __col: "createdAt" } as const,
    updatedAt: { __col: "updatedAt" } as const,
    syncVersion: { __col: "syncVersion" } as const,
    isDirty: { __col: "isDirty" } as const,
    isDeleted: { __col: "isDeleted" } as const,
  }
  return { conversationStore: [] as FakeConvRow[], COLS }
})

function resetStore() {
  conversationStore.length = 0
}

function seedConversation(row: Partial<FakeConvRow> & {
  id: string
  userId: string
  updatedAt: number
}) {
  const full: FakeConvRow = {
    id: row.id,
    userId: row.userId,
    bookId: row.bookId ?? "book-1",
    title: row.title ?? "seeded",
    createdAt: row.createdAt ?? row.updatedAt,
    updatedAt: row.updatedAt,
    syncVersion: row.syncVersion ?? 0,
    isDirty: row.isDirty ?? false,
    isDeleted: row.isDeleted ?? false,
  }
  conversationStore.push(full)
}

// ─── Mock @rishi/shared/schema so `conversations` resolves to column ids ─────
vi.mock("@rishi/shared/schema", () => ({
  conversations: COLS,
  // Sibling tables touched by transitive imports — empty stubs.
  devices: {},
  books: {},
  highlights: {},
  messages: {},
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
}))

// ─── Mock drizzle-orm helpers as predicate descriptors ────────────────────────
type Pred =
  | { kind: "eq"; col: keyof typeof COLS; value: unknown }
  | { kind: "gt"; col: keyof typeof COLS; value: number }
  | { kind: "and"; preds: Pred[] }

type OrderBy = { col: keyof typeof COLS; dir: "asc" | "desc" }

vi.mock("drizzle-orm", () => ({
  eq: (col: { __col: keyof typeof COLS }, value: unknown): Pred => ({
    kind: "eq",
    col: col.__col,
    value,
  }),
  gt: (col: { __col: keyof typeof COLS }, value: number): Pred => ({
    kind: "gt",
    col: col.__col,
    value,
  }),
  and: (...preds: Pred[]): Pred => ({ kind: "and", preds }),
  desc: (col: { __col: keyof typeof COLS }): OrderBy => ({
    col: col.__col,
    dir: "desc",
  }),
}))

// ─── Mock createDb with a tiny insert / select builder ───────────────────────
function matches(row: FakeConvRow, p: Pred): boolean {
  if (p.kind === "and") return p.preds.every((sub) => matches(row, sub))
  if (p.kind === "eq")
    return (row as unknown as Record<string, unknown>)[p.col] === p.value
  if (p.kind === "gt") {
    const v = (row as unknown as Record<string, unknown>)[p.col]
    return typeof v === "number" && v > (p.value as number)
  }
  return false
}

vi.mock("../db/drizzle", () => {
  function createDb() {
    return {
      insert(_table: unknown) {
        let pendingValues: Record<string, unknown> = {}
        let conflictTarget: keyof typeof COLS | null = null
        let conflictSet: Record<string, unknown> = {}
        const builder = {
          values(v: Record<string, unknown>) {
            pendingValues = v
            return builder
          },
          onConflictDoUpdate(opts: {
            target: { __col: keyof typeof COLS } | Array<{ __col: keyof typeof COLS }>
            set: Record<string, unknown>
          }) {
            const t = Array.isArray(opts.target) ? opts.target[0] : opts.target
            conflictTarget = t.__col
            conflictSet = opts.set
            // Drizzle returns a thenable — auto-execute on await.
            return {
              then(resolve: (v: unknown) => void) {
                const existing = conflictTarget
                  ? conversationStore.find(
                      (r) =>
                        (r as unknown as Record<string, unknown>)[conflictTarget!] ===
                        (pendingValues as Record<string, unknown>)[conflictTarget!],
                    )
                  : undefined
                if (existing) {
                  Object.assign(existing, conflictSet)
                } else {
                  conversationStore.push(pendingValues as unknown as FakeConvRow)
                }
                resolve(undefined)
              },
            }
          },
        }
        return builder
      },
      select(_proj?: unknown) {
        return {
          from(_table: unknown) {
            let predicate: Pred | null = null
            let order: OrderBy | null = null
            const chain = {
              where(p: Pred) {
                predicate = p
                return chain
              },
              orderBy(o: OrderBy) {
                order = o
                return chain
              },
              all() {
                let rows = conversationStore.slice()
                if (predicate) rows = rows.filter((r) => matches(r, predicate!))
                if (order) {
                  rows.sort((a, b) => {
                    const av = (a as unknown as Record<string, unknown>)[order!.col] as number
                    const bv = (b as unknown as Record<string, unknown>)[order!.col] as number
                    return order!.dir === "desc" ? bv - av : av - bv
                  })
                }
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

vi.mock("../index", async () => {
  return {
    requireAuth: async (
      c: { set: (k: string, v: unknown) => void; json: (b: unknown, s: number) => Response },
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

// ─── Now import the route under test ────────────────────────────────────────
import { conversationsRoutes } from "./conversations"

const env = {
  BETTER_AUTH_SECRET: "test-secret",
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  DB: {} as unknown,
} as unknown as Record<string, unknown>

async function callPost(body: unknown) {
  const req = new Request("http://test.local/", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  })
  return conversationsRoutes.fetch(req, env)
}

async function callGet(query: string = "") {
  const req = new Request(`http://test.local/${query}`, { method: "GET" })
  return conversationsRoutes.fetch(req, env)
}

const UUID_A = "11111111-1111-4111-8111-111111111111"
const UUID_B = "22222222-2222-4222-8222-222222222222"
const UUID_C = "33333333-3333-4333-8333-333333333333"

function validRow(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    id: UUID_A,
    user_id: "user_alice",
    book_id: "book-1",
    title: "Hello",
    archived: false,
    created_at: 1_700_000_000_000,
    updated_at: 1_700_000_500_000,
    ...overrides,
  }
}

beforeEach(() => {
  resetStore()
  setUser("user_alice")
})

// ─── Tests ───────────────────────────────────────────────────────────────────

describe("POST /api/sync/conversations", () => {
  it("unauthenticated -> 401 + zero rows written", async () => {
    setUser(null)
    const res = await callPost({ conversations: [validRow()] })
    expect(res.status).toBe(401)
    const body = (await res.json()) as { error: string }
    expect(body.error).toBe("Unauthorized")
    expect(conversationStore.length).toBe(0)
  })

  it("happy path -> 200 { applied_count: N } and rows belong to caller", async () => {
    const res = await callPost({
      conversations: [
        validRow({ id: UUID_A }),
        // Hostile client tries to claim a row for someone else; server
        // MUST override user_id to the session user (user_alice).
        validRow({ id: UUID_B, user_id: "user_eve", title: "Second" }),
      ],
    })
    expect(res.status).toBe(200)
    const body = (await res.json()) as { applied_count: number }
    expect(body.applied_count).toBe(2)
    expect(conversationStore.length).toBe(2)
    expect(conversationStore.every((r) => r.userId === "user_alice")).toBe(true)
  })

  it("idempotent upsert -> same id twice yields exactly 1 row (LWW)", async () => {
    const first = await callPost({
      conversations: [validRow({ id: UUID_A, title: "First", updated_at: 100 })],
    })
    expect(first.status).toBe(200)
    expect(conversationStore.length).toBe(1)

    const second = await callPost({
      conversations: [validRow({ id: UUID_A, title: "Second", updated_at: 200 })],
    })
    expect(second.status).toBe(200)
    expect(conversationStore.length).toBe(1)
    expect(conversationStore[0].title).toBe("Second")
    expect(conversationStore[0].updatedAt).toBe(200)
  })

  it("validation: missing `conversations` key -> 400 bad_request", async () => {
    const res = await callPost({})
    expect(res.status).toBe(400)
    const body = (await res.json()) as { error: string }
    expect(body.error).toBe("bad_request")
  })
})

describe("GET /api/sync/conversations", () => {
  it("happy path -> returns caller's rows only", async () => {
    seedConversation({ id: UUID_A, userId: "user_alice", updatedAt: 100, title: "a1" })
    seedConversation({ id: UUID_B, userId: "user_alice", updatedAt: 200, title: "a2" })
    seedConversation({ id: UUID_C, userId: "user_bob", updatedAt: 300, title: "b1" })

    const res = await callGet("")
    expect(res.status).toBe(200)
    const body = (await res.json()) as { rows: Array<{ id: string; user_id: string }> }
    expect(body.rows.length).toBe(2)
    expect(body.rows.every((r) => r.user_id === "user_alice")).toBe(true)
    // Sorted desc by updated_at -> a2 first.
    expect(body.rows[0].id).toBe(UUID_B)
    expect(body.rows[1].id).toBe(UUID_A)
  })

  it("since cursor -> returns only rows with updated_at > since", async () => {
    seedConversation({ id: UUID_A, userId: "user_alice", updatedAt: 100 })
    seedConversation({ id: UUID_B, userId: "user_alice", updatedAt: 200 })
    seedConversation({ id: UUID_C, userId: "user_alice", updatedAt: 300 })

    const res = await callGet("?since=150")
    expect(res.status).toBe(200)
    const body = (await res.json()) as { rows: Array<{ id: string; updated_at: number }> }
    expect(body.rows.length).toBe(2)
    expect(body.rows.every((r) => r.updated_at > 150)).toBe(true)
  })

  it("cross-user isolation -> alice's GET excludes bob's rows", async () => {
    seedConversation({ id: UUID_A, userId: "user_alice", updatedAt: 200, title: "alice" })
    seedConversation({ id: UUID_B, userId: "user_bob", updatedAt: 200, title: "bob" })

    const res = await callGet("?since=100")
    expect(res.status).toBe(200)
    const body = (await res.json()) as { rows: Array<{ id: string; user_id: string }> }
    expect(body.rows.length).toBe(1)
    expect(body.rows[0].user_id).toBe("user_alice")
    expect(body.rows.find((r) => r.id === UUID_B)).toBeUndefined()
  })
})

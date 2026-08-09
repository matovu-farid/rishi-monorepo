import { describe, it, expect, beforeEach, vi } from "vitest"

vi.mock("cloudflare:workers", () => ({ DurableObject: class {} }));
(vi as any).hoisted ??= <T>(factory: () => T) => factory()

/**
 * Tests for /api/sync/messages — Phase 16-03 Task 2.
 *
 * Layered on top of /api/sync/conversations with one extra security check:
 * the POST handler MUST verify that each message's parent conversation
 * belongs to the caller. Cross-user-targeted rows are SILENTLY DROPPED
 * (no 403) so the route never leaks the existence of someone else's
 * conversation id.
 *
 * Coverage (8 cases — RED before messages.ts exists):
 *
 *  1. Unauth POST -> 401, zero rows written.
 *  2. Happy POST -> 200 { applied_count: 2 } for messages whose parent
 *     conversation belongs to the caller.
 *  3. Idempotent POST -> SAME id twice yields exactly 1 row; LWW updates
 *     content + updated_at.
 *  4. Stale/equal POST retries cannot overwrite a newer row.
 *  5. Validation -> missing `messages` key returns 400 bad_request.
 *  6. Parent-ownership: messages targeting another user's conversation are
 *     SILENTLY dropped — applied_count == 1, no 403, no leak.
 *  7. GET since cursor -> only messages from caller's conversations with
 *     updated_at > since; bob's row excluded.
 *  8. GET cross-user isolation -> rows.every(r => r.conversation_id is
 *     caller-owned).
 */

// ─── In-memory stores ─────────────────────────────────────────────────────────
interface FakeConvRow {
  id: string
  userId: string
}

interface FakeMsgRow {
  id: string
  conversationId: string
  role: string
  content: string
  createdAt: number
  updatedAt: number
  syncVersion: number
  isDirty: boolean
  isDeleted: boolean
}

const { conversationStore, messageStore, CONV_COLS, MSG_COLS } = vi.hoisted(() => {
  const CONV_COLS = {
    id: { __col: "id", __table: "conv" } as const,
    userId: { __col: "userId", __table: "conv" } as const,
  }
  const MSG_COLS = {
    id: { __col: "id", __table: "msg" } as const,
    conversationId: { __col: "conversationId", __table: "msg" } as const,
    role: { __col: "role", __table: "msg" } as const,
    content: { __col: "content", __table: "msg" } as const,
    createdAt: { __col: "createdAt", __table: "msg" } as const,
    updatedAt: { __col: "updatedAt", __table: "msg" } as const,
    syncVersion: { __col: "syncVersion", __table: "msg" } as const,
    isDirty: { __col: "isDirty", __table: "msg" } as const,
    isDeleted: { __col: "isDeleted", __table: "msg" } as const,
  }
  return {
    conversationStore: [] as FakeConvRow[],
    messageStore: [] as FakeMsgRow[],
    CONV_COLS,
    MSG_COLS,
  }
})

function resetStores() {
  conversationStore.length = 0
  messageStore.length = 0
}

function seedConversation(row: { id: string; userId: string }) {
  conversationStore.push({ id: row.id, userId: row.userId })
}

function seedMessage(row: Partial<FakeMsgRow> & {
  id: string
  conversationId: string
  updatedAt: number
}) {
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
  })
}

// ─── Mock ../db/schema so both tables resolve to column ids ─────────────────
vi.mock("../db/schema", () => ({
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
}))

// ─── Mock drizzle-orm helpers as predicate descriptors ────────────────────────
type AnyCol = { __col: string; __table: string }
type Pred =
  | { kind: "eq"; col: AnyCol; value: unknown }
  | { kind: "gt"; col: AnyCol; value: number }
  | { kind: "lt"; col: AnyCol; value: number }
  | { kind: "inArray"; col: AnyCol; values: unknown[] }
  | { kind: "and"; preds: Pred[] }

type OrderBy = { col: AnyCol; dir: "asc" | "desc" }

vi.mock("drizzle-orm", () => ({
  eq: (col: AnyCol, value: unknown): Pred => ({ kind: "eq", col, value }),
  gt: (col: AnyCol, value: number): Pred => ({ kind: "gt", col, value }),
  lt: (col: AnyCol, value: number): Pred => ({ kind: "lt", col, value }),
  inArray: (col: AnyCol, values: unknown[]): Pred => ({
    kind: "inArray",
    col,
    values,
  }),
  and: (...preds: Pred[]): Pred => ({ kind: "and", preds }),
  desc: (col: AnyCol): OrderBy => ({ col, dir: "desc" }),
}))

function rowMatches(
  row: Record<string, unknown>,
  p: Pred,
): boolean {
  if (p.kind === "and") return p.preds.every((sub) => rowMatches(row, sub))
  if (p.kind === "eq") return row[p.col.__col] === p.value
  if (p.kind === "gt") {
    const v = row[p.col.__col]
    return typeof v === "number" && v > (p.value as number)
  }
  if (p.kind === "lt") {
    const v = row[p.col.__col]
    return typeof v === "number" && v < (p.value as number)
  }
  if (p.kind === "inArray") return p.values.includes(row[p.col.__col])
  return false
}

function tableOf(p: Pred): "conv" | "msg" | null {
  if (p.kind === "and") {
    for (const sub of p.preds) {
      const t = tableOf(sub)
      if (t) return t
    }
    return null
  }
  return p.col.__table as "conv" | "msg"
}

// ─── Mock createDb ───────────────────────────────────────────────────────────
vi.mock("../db/drizzle", () => {
  function createDb() {
    return {
      insert(table: unknown) {
        // Only the messages table is inserted into in the messages route.
        let pendingValues: Record<string, unknown> = {}
        let conflictTarget: string | null = null
        let conflictSet: Record<string, unknown> = {}
        let conflictWhere: Pred | null = null
        const builder = {
          values(v: Record<string, unknown>) {
            pendingValues = v
            return builder
          },
          onConflictDoUpdate(opts: {
            target: AnyCol | AnyCol[]
            set: Record<string, unknown>
            where?: Pred
          }) {
            const t = Array.isArray(opts.target) ? opts.target[0] : opts.target
            conflictTarget = t.__col
            conflictSet = opts.set
            conflictWhere = opts.where ?? null
            return {
              then(resolve: (v: unknown) => void) {
                // Only handle inserts targeting the messages table.
                void table
                const existing = conflictTarget
                  ? messageStore.find(
                      (r) =>
                        (r as unknown as Record<string, unknown>)[conflictTarget!] ===
                        (pendingValues as Record<string, unknown>)[conflictTarget!],
                    )
                  : undefined
                if (existing && (!conflictWhere || rowMatches(existing as unknown as Record<string, unknown>, conflictWhere))) {
                  Object.assign(existing, conflictSet)
                } else if (!existing) {
                  messageStore.push(pendingValues as unknown as FakeMsgRow)
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
                const t = predicate ? tableOf(predicate) : null
                let source: Record<string, unknown>[] = []
                if (t === "conv") {
                  source = conversationStore as unknown as Record<string, unknown>[]
                } else if (t === "msg") {
                  source = messageStore as unknown as Record<string, unknown>[]
                } else {
                  // No predicate at all — shouldn't happen in messages.ts
                  source = messageStore as unknown as Record<string, unknown>[]
                }
                let rows = source.slice()
                if (predicate) rows = rows.filter((r) => rowMatches(r, predicate!))
                if (order) {
                  rows.sort((a, b) => {
                    const av = a[order!.col.__col] as number
                    const bv = b[order!.col.__col] as number
                    return order!.dir === "desc" ? bv - av : av - bv
                  })
                }
                return rows
              },
              get() {
                const t = predicate ? tableOf(predicate) : null
                const source =
                  t === "conv"
                    ? (conversationStore as unknown as Record<string, unknown>[])
                    : (messageStore as unknown as Record<string, unknown>[])
                if (!predicate) return source[0] ?? null
                return source.find((r) => rowMatches(r, predicate!)) ?? null
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

// ─── Auth state + middleware mocks ────────────────────────────────────────────
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

vi.mock("../middleware", async () => {
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
import { messagesRoutes } from "./messages"

const env = {
  BETTER_AUTH_SECRET: "test-secret",
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  DB: {} as unknown,
} as unknown as Record<string, unknown>

async function callPost(body: unknown) {
  const req = new Request("http://test.local/", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Rishi-Data-Use-Consent": "2026-07-29",
    },
    body: JSON.stringify(body),
  })
  return messagesRoutes.fetch(req, env)
}

async function callGet(query: string = "") {
  const req = new Request(`http://test.local/${query}`, {
    method: "GET",
    headers: { "X-Rishi-Data-Use-Consent": "2026-07-29" },
  })
  return messagesRoutes.fetch(req, env)
}

const MSG_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
const MSG_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
const MSG_C = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

function validRow(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    id: MSG_A,
    conversation_id: "conv-alice",
    role: "user",
    content: "Hello",
    created_at: 1_700_000_000_000,
    updated_at: 1_700_000_500_000,
    ...overrides,
  }
}

beforeEach(() => {
  resetStores()
  setUser("user_alice")
})

// ─── Tests ───────────────────────────────────────────────────────────────────

describe("POST /api/sync/messages", () => {
  it("unauthenticated -> 401 + zero rows written", async () => {
    setUser(null)
    seedConversation({ id: "conv-alice", userId: "user_alice" })
    const res = await callPost({ messages: [validRow()] })
    expect(res.status).toBe(401)
    const body = (await res.json()) as { error: string }
    expect(body.error).toBe("Unauthorized")
    expect(messageStore.length).toBe(0)
  })

  it("happy path -> 200 { applied_count: 2 } for caller-owned conversation", async () => {
    seedConversation({ id: "conv-alice", userId: "user_alice" })
    const res = await callPost({
      messages: [
        validRow({ id: MSG_A, content: "first" }),
        validRow({ id: MSG_B, content: "second" }),
      ],
    })
    expect(res.status).toBe(200)
    const body = (await res.json()) as { applied_count: number }
    expect(body.applied_count).toBe(2)
    expect(messageStore.length).toBe(2)
  })

  it("idempotent upsert -> same id twice yields exactly 1 row (LWW)", async () => {
    seedConversation({ id: "conv-alice", userId: "user_alice" })
    const first = await callPost({
      messages: [validRow({ id: MSG_A, content: "v1", updated_at: 100 })],
    })
    expect(first.status).toBe(200)
    expect(messageStore.length).toBe(1)

    const second = await callPost({
      messages: [validRow({ id: MSG_A, content: "v2", updated_at: 200 })],
    })
    expect(second.status).toBe(200)
    expect(messageStore.length).toBe(1)
    expect(messageStore[0].content).toBe("v2")
    expect(messageStore[0].updatedAt).toBe(200)
  })

  it("stale and equal retries do not overwrite a newer row", async () => {
    seedConversation({ id: "conv-alice", userId: "user_alice" })
    seedMessage({
      id: MSG_A,
      conversationId: "conv-alice",
      updatedAt: 200,
      content: "newest",
    })

    const stale = await callPost({
      messages: [validRow({ id: MSG_A, content: "stale", updated_at: 100 })],
    })
    const equal = await callPost({
      messages: [validRow({ id: MSG_A, content: "equal", updated_at: 200 })],
    })

    expect(stale.status).toBe(200)
    expect(equal.status).toBe(200)
    expect(messageStore).toHaveLength(1)
    expect(messageStore[0].content).toBe("newest")
    expect(messageStore[0].updatedAt).toBe(200)
  })

  it("validation: missing `messages` key -> 400 bad_request", async () => {
    const res = await callPost({})
    expect(res.status).toBe(400)
    const body = (await res.json()) as { error: string }
    expect(body.error).toBe("bad_request")
  })

  it("parent-ownership: cross-user-targeted rows are SILENTLY dropped", async () => {
    seedConversation({ id: "conv-alice", userId: "user_alice" })
    seedConversation({ id: "conv-bob", userId: "user_bob" })

    const res = await callPost({
      messages: [
        validRow({ id: MSG_A, conversation_id: "conv-alice", content: "ok" }),
        validRow({ id: MSG_B, conversation_id: "conv-bob", content: "forbidden" }),
      ],
    })
    // 200 with applied_count=1 — the bob-targeted row is silently dropped.
    // NO 403 thrown: we do not leak the existence of someone else's conv id.
    expect(res.status).toBe(200)
    const body = (await res.json()) as { applied_count: number }
    expect(body.applied_count).toBe(1)
    expect(messageStore.length).toBe(1)
    expect(messageStore[0].conversationId).toBe("conv-alice")
    expect(messageStore.find((m) => m.id === MSG_B)).toBeUndefined()
  })
})

describe("GET /api/sync/messages", () => {
  it("since cursor -> returns only messages newer than since for caller's convs", async () => {
    seedConversation({ id: "conv-alice", userId: "user_alice" })
    seedConversation({ id: "conv-bob", userId: "user_bob" })
    seedMessage({ id: MSG_A, conversationId: "conv-alice", updatedAt: 100 })
    seedMessage({ id: MSG_B, conversationId: "conv-alice", updatedAt: 200 })
    seedMessage({ id: MSG_C, conversationId: "conv-alice", updatedAt: 300 })
    seedMessage({ id: "bob-msg", conversationId: "conv-bob", updatedAt: 250 })

    const res = await callGet("?since=150")
    expect(res.status).toBe(200)
    const body = (await res.json()) as {
      rows: Array<{ id: string; conversation_id: string; updated_at: number }>
    }
    expect(body.rows.length).toBe(2)
    expect(body.rows.every((r) => r.updated_at > 150)).toBe(true)
    expect(body.rows.every((r) => r.conversation_id === "conv-alice")).toBe(true)
  })

  it("cross-user isolation -> alice's GET excludes bob's messages", async () => {
    seedConversation({ id: "conv-alice", userId: "user_alice" })
    seedConversation({ id: "conv-bob", userId: "user_bob" })
    seedMessage({ id: MSG_A, conversationId: "conv-alice", updatedAt: 200 })
    seedMessage({ id: "bob-msg", conversationId: "conv-bob", updatedAt: 200 })

    const res = await callGet("?since=100")
    expect(res.status).toBe(200)
    const body = (await res.json()) as {
      rows: Array<{ id: string; conversation_id: string }>
    }
    expect(body.rows.length).toBe(1)
    expect(body.rows.every((r) => r.conversation_id === "conv-alice")).toBe(true)
  })
})

import { describe, it, expect, beforeEach, vi } from "vitest"
import { hashPassword } from "better-auth/crypto"

/**
 * Tests for /test/* — test-only auth routes. HARD GATED by:
 *
 *   a. c.env.ENABLE_TEST_AUTH === 'true'   (string, since wrangler passes vars
 *                                          as strings; missing → 404)
 *   b. X-Test-Auth-Secret header matches c.env.TEST_AUTH_SECRET (constant time)
 *   c. TEST_AUTH_EMAIL_DOMAIN, when configured, restricts disposable emails
 *
 * Any failure of any gate returns 404 (NOT 401/403) so probers see "no
 * such endpoint". This file exercises both POST /test/sign-in (fresh account
 * creation plus email+password session) and DELETE /test/users/:email (full account
 * teardown — books, R2 objects, highlights, conversations, messages,
 * bookmarks, and Better-Auth rows).
 */

// ─── In-memory stores shared via vi.hoisted ───────────────────────────────────
interface FakeBook {
  id: string
  userId: string
  fileR2Key: string | null
  coverR2Key: string | null
}

interface FakeUser {
  id: string
  email: string
}

const { state, COLS, deleteCalls, grantTrialIfAbsent, getByName, deleteAccount } = vi.hoisted(() => {
  const COLS = {
    id: { __col: "id" } as const,
    email: { __col: "email" } as const,
    providerId: { __col: "providerId" } as const,
    userId: { __col: "userId" } as const,
    password: { __col: "password" } as const,
    fileR2Key: { __col: "fileR2Key" } as const,
    coverR2Key: { __col: "coverR2Key" } as const,
    bookId: { __col: "bookId" } as const,
    conversationId: { __col: "conversationId" } as const,
  }
  const grantTrialIfAbsent = vi.fn()
  const getByName = vi.fn(() => ({ grantTrialIfAbsent }))
  return {
    state: {
      users: [] as Array<{ id: string; email: string; name?: string }>,
      books: [] as Array<FakeBook>,
      highlights: [] as Array<{ id: string; userId: string }>,
      conversations: [] as Array<{ id: string; userId: string }>,
      messages: [] as Array<{ id: string; conversationId: string }>,
      bookmarks: [] as Array<{ id: string; userId: string }>,
      sessions: [] as Array<{ id: string; userId: string; token?: string }>,
      accounts: [] as Array<{ id: string; userId: string; providerId?: string; password?: string }>,
    },
    COLS,
    deleteCalls: { r2: [] as string[] },
    grantTrialIfAbsent,
    getByName,
    deleteAccount: vi.fn().mockResolvedValue({ alreadyDeleted: false }),
  }
})

function resetState() {
  state.users.length = 0
  state.books.length = 0
  state.highlights.length = 0
  state.conversations.length = 0
  state.messages.length = 0
  state.bookmarks.length = 0
  state.sessions.length = 0
  state.accounts.length = 0
  deleteCalls.r2.length = 0
}

// ─── Mock schema ──────────────────────────────────────────────────────────────
vi.mock("../db/schema", () => ({
  books: { ...COLS, __table: "books" },
  highlights: { ...COLS, __table: "highlights" },
  conversations: { ...COLS, __table: "conversations" },
  messages: { ...COLS, __table: "messages" },
  bookmarks: { ...COLS, __table: "bookmarks" },
  user: { ...COLS, __table: "user" },
  session: { ...COLS, __table: "session" },
  account: { ...COLS, __table: "account" },
  verification: { ...COLS, __table: "verification" },
  passkey: { ...COLS, __table: "passkey" },
  syncMeta: { ...COLS, __table: "syncMeta" },
}))

// ─── Mock drizzle-orm ────────────────────────────────────────────────────────
type Pred = { kind: "eq"; col: string; value: unknown }

vi.mock("drizzle-orm", () => ({
  eq: (col: { __col: string }, value: unknown): Pred => ({
    kind: "eq",
    col: col.__col,
    value,
  }),
  and: (...preds: Pred[]) => ({ kind: "and", preds } as unknown as Pred),
  sql: (s: TemplateStringsArray) => ({ __sql: s.join("?") }),
  count: () => ({ __agg: "count" }),
  sum: () => ({ __agg: "sum" }),
}))

function tableKey(table: { __table?: string }): keyof typeof state | null {
  switch (table.__table) {
    case "books":
      return "books"
    case "highlights":
      return "highlights"
    case "conversations":
      return "conversations"
    case "messages":
      return "messages"
    case "bookmarks":
      return "bookmarks"
    case "user":
      return "users"
    case "session":
      return "sessions"
    case "account":
      return "accounts"
    default:
      return null
  }
}

function evalPred(pred: Pred | { kind: "and"; preds: Pred[] }, row: Record<string, unknown>): boolean {
  if ((pred as Pred).kind === "eq") {
    const p = pred as Pred
    return row[p.col] === p.value
  }
  if ((pred as { kind: "and" }).kind === "and") {
    return (pred as { preds: Pred[] }).preds.every((p) => evalPred(p, row))
  }
  return false
}

vi.mock("../db/drizzle", () => {
  function createDb() {
    return {
      select(_fields?: unknown) {
        return {
          from(table: { __table?: string }) {
            const key = tableKey(table)
            const ctx: { pred?: Pred } = {}
            const builder = {
              where(pred: Pred) {
                ctx.pred = pred
                return builder
              },
              get() {
                if (!key) return undefined
                return state[key].find((r) =>
                  ctx.pred
                    ? evalPred(ctx.pred, r as Record<string, unknown>)
                    : true,
                )
              },
              all() {
                if (!key) return []
                return state[key].filter((r) =>
                  ctx.pred
                    ? evalPred(ctx.pred, r as Record<string, unknown>)
                    : true,
                )
              },
            }
            return builder
          },
        }
      },
      delete(table: { __table?: string }) {
        const key = tableKey(table)
        const ctx: { pred?: Pred } = {}
        const builder = {
          where(pred: Pred) {
            ctx.pred = pred
            return builder
          },
          async run() {
            if (!key) return
            const arr = state[key]
            for (let i = arr.length - 1; i >= 0; i--) {
              if (
                ctx.pred &&
                evalPred(ctx.pred, arr[i] as Record<string, unknown>)
              ) {
                arr.splice(i, 1)
              }
            }
          },
        }
        return builder
      },
      insert(table: { __table?: string }) {
        const key = tableKey(table)
        return {
          values(values: Record<string, unknown>) {
            return {
              async run() {
                if (!key) return
                state[key].push(values as never)
              },
            }
          },
        }
      },
    }
  }
  return { createDb }
})

// ─── Mock createAuth (Better-Auth internal adapter) ──────────────────────────
const { authBehavior } = vi.hoisted(() => {
  const authBehavior = {
    createUser: vi.fn(async (data: { id: string; email: string; name: string }) => {
      state.users.push(data)
      return data
    }),
    createAccount: vi.fn(async (data: { id: string; userId: string; providerId: string }) => {
      state.accounts.push(data)
      return data
    }),
    createSession: vi.fn(async (userId: string) => {
      const created = {
        id: `session-${state.sessions.length + 1}`,
        userId,
        token: `tok-${state.sessions.length + 1}`,
      }
      state.sessions.push(created)
      return { ...created, expiresAt: new Date(), createdAt: new Date(), updatedAt: new Date() }
    }),
  }
  return { authBehavior }
})

vi.mock("../auth", () => ({
  createAuth: () => ({
    $context: Promise.resolve({
      internalAdapter: {
        createUser: authBehavior.createUser,
        createAccount: authBehavior.createAccount,
        createSession: authBehavior.createSession,
      },
    }),
  }),
}))

vi.mock("../account-deletion", async (importOriginal) => ({
  ...await importOriginal<typeof import("../account-deletion")>(),
  deleteAccount,
}))

// ─── Now import the route under test ──────────────────────────────────────────
import { testAuthRoutes } from "./test-auth"

// ─── R2 stub ──────────────────────────────────────────────────────────────────
const fakeR2 = {
  delete: vi.fn(async (key: string) => {
    deleteCalls.r2.push(key)
  }),
}

const baseEnv = {
  BETTER_AUTH_SECRET: "test-secret",
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  TEST_AUTH_EMAIL_DOMAIN: "x.co",
  DB: {} as unknown,
  BOOK_STORAGE: fakeR2 as unknown,
  USER_USAGE_LEDGER: { getByName },
} as unknown as Record<string, unknown>

const SECRET = "super-secret-token"

function envWithGate(opts: { enabled?: boolean; secret?: string | null } = {}) {
  const env: Record<string, unknown> = { ...baseEnv }
  if (opts.enabled !== false) {
    env.ENABLE_TEST_AUTH = opts.enabled === undefined ? "true" : "true"
  }
  if (opts.secret !== null) {
    env.TEST_AUTH_SECRET = opts.secret ?? SECRET
  }
  return env
}

async function call(
  path: string,
  init: RequestInit = {},
  env: Record<string, unknown> = envWithGate(),
) {
  const url = `http://test.local${path}`
  return testAuthRoutes.fetch(new Request(url, init), env)
}

beforeEach(() => {
  resetState()
  authBehavior.createUser.mockReset()
  authBehavior.createUser.mockImplementation(async (data: { id: string; email: string; name: string }) => {
    state.users.push(data)
    return data
  })
  authBehavior.createAccount.mockReset()
  authBehavior.createAccount.mockImplementation(async (data: { id: string; userId: string; providerId: string }) => {
    state.accounts.push(data)
    return data
  })
  authBehavior.createSession.mockReset()
  authBehavior.createSession.mockImplementation(async (userId: string) => {
    const created = {
      id: `session-${state.sessions.length + 1}`,
      userId,
      token: `tok-${state.sessions.length + 1}`,
    }
    state.sessions.push(created)
    return { ...created, expiresAt: new Date(), createdAt: new Date(), updatedAt: new Date() }
  })
  grantTrialIfAbsent.mockReset()
  getByName.mockClear()
  deleteAccount.mockClear()
  fakeR2.delete.mockClear()
})

// ─── Gating: POST /test/sign-in ───────────────────────────────────────────────
describe("POST /test/sign-in — gating", () => {
  it("returns 404 when ENABLE_TEST_AUTH is unset", async () => {
    const env: Record<string, unknown> = { ...baseEnv, TEST_AUTH_SECRET: SECRET }
    // ENABLE_TEST_AUTH intentionally absent
    const res = await call(
      "/sign-in",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Test-Auth-Secret": SECRET,
        },
        body: JSON.stringify({ email: "a@b.co", password: "p" }),
      },
      env,
    )
    expect(res.status).toBe(404)
  })

  it("returns 404 when X-Test-Auth-Secret header is missing", async () => {
    const res = await call("/sign-in", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: "a@b.co", password: "p" }),
    })
    expect(res.status).toBe(404)
  })

  it("returns 404 when X-Test-Auth-Secret header is wrong", async () => {
    const res = await call("/sign-in", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Test-Auth-Secret": "nope",
      },
      body: JSON.stringify({ email: "a@b.co", password: "p" }),
    })
    expect(res.status).toBe(404)
  })

  it("returns 404 when ENABLE_TEST_AUTH is 'false' (any non-'true' string)", async () => {
    const env: Record<string, unknown> = {
      ...baseEnv,
      ENABLE_TEST_AUTH: "false",
      TEST_AUTH_SECRET: SECRET,
    }
    const res = await call(
      "/sign-in",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Test-Auth-Secret": SECRET,
        },
        body: JSON.stringify({ email: "a@b.co", password: "p" }),
      },
      env,
    )
    expect(res.status).toBe(404)
  })

  it("returns 404 when TEST_AUTH_SECRET is unset (header can't match)", async () => {
    const env: Record<string, unknown> = {
      ...baseEnv,
      ENABLE_TEST_AUTH: "true",
    }
    const res = await call(
      "/sign-in",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Test-Auth-Secret": SECRET,
        },
        body: JSON.stringify({ email: "a@b.co", password: "p" }),
      },
      env,
    )
    expect(res.status).toBe(404)
  })

  it("keeps the legacy secret-gated flow working when no email domain is configured", async () => {
    const { TEST_AUTH_EMAIL_DOMAIN: _domain, ...envWithoutDomain } = envWithGate()
    const res = await call(
      "/sign-in",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Test-Auth-Secret": SECRET,
        },
        body: JSON.stringify({ email: "new@x.co", password: "pw12345678" }),
      },
      envWithoutDomain,
    )
    expect(res.status).toBe(200)
  })
})

// ─── Happy paths: POST /test/sign-in ──────────────────────────────────────────
describe("POST /test/sign-in — happy paths", () => {
  it("rejects addresses outside the configured test domain", async () => {
    const res = await call("/sign-in", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Test-Auth-Secret": SECRET,
      },
      body: JSON.stringify({ email: "new@outside.example", password: "pw12345678" }),
    })

    expect(res.status).toBe(400)
    expect(await res.json()).toEqual({
      error: "email must use the configured test domain",
    })
    expect(authBehavior.createUser).not.toHaveBeenCalled()
  })

  it("creates a new user when one doesn't exist + returns session token", async () => {
    const res = await call("/sign-in", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Test-Auth-Secret": SECRET,
      },
      body: JSON.stringify({ email: "new@x.co", password: "pw12345678" }),
    })
    expect(res.status).toBe(200)
    const body = (await res.json()) as {
      token: string
      userId: string
      email: string
    }
    expect(body.token).toBe(state.sessions[0]?.token)
    expect(body.token).toEqual(expect.any(String))
    expect(body.userId).toMatch(/^[0-9a-f-]{36}$/)
    expect(body.email).toBe("new@x.co")
    expect(state.users).toHaveLength(1)
    expect(state.accounts).toHaveLength(1)
    expect(state.sessions).toHaveLength(1)
    expect(state.sessions[0]?.token).toBe(body.token)
    expect(getByName).toHaveBeenCalledWith(body.userId)
    expect(grantTrialIfAbsent).toHaveBeenCalledOnce()
  })

  it("allows a disposable account to sign in again", async () => {
    state.users.push({ id: "user_existing", email: "old@x.co", name: "old" })
    state.accounts.push({
      id: "account-existing",
      userId: "user_existing",
      providerId: "credential",
      password: await hashPassword("pw12345678"),
    })

    const res = await call("/sign-in", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Test-Auth-Secret": SECRET,
      },
      body: JSON.stringify({ email: "old@x.co", password: "pw12345678" }),
    })
    expect(res.status).toBe(200)
    expect(((await res.json()) as { userId: string }).userId).toBe("user_existing")
    expect(state.users).toHaveLength(1)
    expect(state.accounts).toHaveLength(1)
    expect(state.sessions).toHaveLength(1)
    expect(state.sessions[0]?.userId).toBe("user_existing")
    expect(grantTrialIfAbsent).toHaveBeenCalledOnce()
  })

  it("does not create a session for an existing test account with the wrong password", async () => {
    state.users.push({ id: "user_existing", email: "old@x.co", name: "old" })
    state.accounts.push({
      id: "account-existing",
      userId: "user_existing",
      providerId: "credential",
      password: await hashPassword("the-correct-password"),
    })

    const res = await call("/sign-in", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Test-Auth-Secret": SECRET,
      },
      body: JSON.stringify({ email: "old@x.co", password: "wrong-password" }),
    })

    expect(res.status).toBe(401)
    expect(state.sessions).toHaveLength(0)
    expect(grantTrialIfAbsent).not.toHaveBeenCalled()
  })

  it("returns 503 without creating a session when the ledger binding is missing", async () => {
    const { USER_USAGE_LEDGER: _ledger, ...envWithoutLedger } = envWithGate()

    const res = await call(
      "/sign-in",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Test-Auth-Secret": SECRET,
        },
        body: JSON.stringify({ email: "new@x.co", password: "pw12345678" }),
      },
      envWithoutLedger,
    )

    expect(res.status).toBe(503)
    expect(await res.json()).toEqual({
      error: "Trial credit provisioning is temporarily unavailable",
    })
    expect(state.users).toHaveLength(0)
    expect(state.sessions).toHaveLength(0)
  })

  it("reports missing ledger before validating the preflight body", async () => {
    const { USER_USAGE_LEDGER: _ledger, ...envWithoutLedger } = envWithGate()
    const res = await call(
      "/sign-in",
      {
        method: "POST",
        headers: { "X-Test-Auth-Secret": SECRET },
        body: "{}",
      },
      envWithoutLedger,
    )

    expect(res.status).toBe(503)
    expect(await res.json()).toEqual({
      error: "Trial credit provisioning is temporarily unavailable",
    })
    expect(authBehavior.createUser).not.toHaveBeenCalled()
    expect(grantTrialIfAbsent).not.toHaveBeenCalled()
  })

  it("returns 503 when trial credit provisioning fails", async () => {
    grantTrialIfAbsent.mockRejectedValueOnce(new Error("ledger unavailable"))

    const res = await call("/sign-in", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Test-Auth-Secret": SECRET,
      },
      body: JSON.stringify({ email: "new@x.co", password: "pw12345678" }),
    })

    expect(res.status).toBe(503)
    expect(await res.json()).toEqual({
      error: "Trial credit provisioning is temporarily unavailable",
    })
    expect(getByName).toHaveBeenCalled()
    expect(deleteAccount).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ DB: baseEnv.DB }),
      expect.any(String),
    )
  })

  it("returns 500 when credit-grant rollback cannot delete the newly created account", async () => {
    grantTrialIfAbsent.mockRejectedValueOnce(new Error("ledger unavailable"))
    deleteAccount.mockRejectedValueOnce(new Error("cleanup unavailable"))

    const res = await call("/sign-in", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Test-Auth-Secret": SECRET,
      },
      body: JSON.stringify({ email: "new@x.co", password: "pw12345678" }),
    })

    expect(res.status).toBe(500)
    expect(await res.json()).toEqual({ error: "test account cleanup failed" })
  })

  it("rejects malformed body with 400 (still gated — but past the gate)", async () => {
    const res = await call("/sign-in", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Test-Auth-Secret": SECRET,
      },
      body: JSON.stringify({ email: "not-an-email" }),
    })
    expect(res.status).toBe(400)
  })
})

// ─── Gating: DELETE /test/users/:email ────────────────────────────────────────
describe("DELETE /test/users/:email — gating", () => {
  it("returns 404 with bad gating", async () => {
    state.users.push({ id: "u1", email: "del@x.co" })
    const env: Record<string, unknown> = { ...baseEnv, TEST_AUTH_SECRET: SECRET }
    const res = await call(
      "/users/del@x.co",
      {
        method: "DELETE",
        // No X-Test-Auth-Secret header
      },
      env,
    )
    expect(res.status).toBe(404)
  })

  it("returns 404 when X-Test-Auth-Secret header is wrong", async () => {
    state.users.push({ id: "u1", email: "del@x.co" })
    const res = await call("/users/del@x.co", {
      method: "DELETE",
      headers: { "X-Test-Auth-Secret": "nope" },
    })
    expect(res.status).toBe(404)
  })
})

// ─── Happy path: DELETE /test/users/:email ────────────────────────────────────
describe("DELETE /test/users/:email — happy paths", () => {
  it("does not delete an account outside the configured test domain", async () => {
    state.users.push({ id: "u1", email: "victim@outside.example" })

    const res = await call("/users/victim@outside.example", {
      method: "DELETE",
      headers: { "X-Test-Auth-Secret": SECRET },
    })

    expect(res.status).toBe(404)
    expect(deleteAccount).not.toHaveBeenCalled()
    expect(state.users).toEqual([{ id: "u1", email: "victim@outside.example" }])
  })

  it("delegates teardown to the canonical account deletion workflow", async () => {
    state.users.push({ id: "u1", email: "del@x.co" })
    deleteAccount.mockResolvedValueOnce({
      deletionId: "deletion-1",
      alreadyDeleted: false,
      revocationStatus: "legacy_no_token",
      r2ObjectsRemoved: 3,
    })

    const res = await call("/users/del@x.co", {
      method: "DELETE",
      headers: { "X-Test-Auth-Secret": SECRET },
    })

    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({
      deleted: true,
      userId: "u1",
      deletionId: "deletion-1",
      alreadyDeleted: false,
      revocationStatus: "legacy_no_token",
      r2ObjectsRemoved: 3,
    })
    expect(deleteAccount).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ DB: baseEnv.DB }),
      "u1",
    )
  })

  it("returns 404 when user doesn't exist", async () => {
    const res = await call("/users/ghost@x.co", {
      method: "DELETE",
      headers: { "X-Test-Auth-Secret": SECRET },
    })
    expect(res.status).toBe(404)
  })

  it("fails closed when canonical teardown fails", async () => {
    state.users.push({ id: "u1", email: "del@x.co" })
    deleteAccount.mockRejectedValueOnce(new Error("R2 down"))
    const res = await call("/users/del@x.co", {
      method: "DELETE",
      headers: { "X-Test-Auth-Secret": SECRET },
    })
    expect(res.status).toBe(500)
    expect(await res.json()).toMatchObject({
      code: "ACCOUNT_DELETION_UNAVAILABLE",
      retryable: true,
      action: "retry",
    })
  })

  it("preserves retryable account-deletion status for the E2E client's retry loop", async () => {
    state.users.push({ id: "u1", email: "del@x.co" })
    deleteAccount.mockRejectedValueOnce(Object.assign(new Error("pending"), {
      code: "ACCOUNT_DELETION_PENDING",
      status: 503,
      retryable: true,
      retryAt: 123456789,
    }))

    const res = await call("/users/del@x.co", {
      method: "DELETE",
      headers: { "X-Test-Auth-Secret": SECRET },
    })

    expect(res.status).toBe(503)
    expect(await res.json()).toMatchObject({
      code: "ACCOUNT_DELETION_PENDING",
      retryable: true,
      action: "retry",
      retryAt: 123456789,
    })
  })
})

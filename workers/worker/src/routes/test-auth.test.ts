import { describe, it, expect, beforeEach, vi } from "vitest"

/**
 * Tests for /test/* — test-only auth routes. HARD GATED by:
 *
 *   a. c.env.ENABLE_TEST_AUTH === 'true'   (string, since wrangler passes vars
 *                                          as strings; missing → 404)
 *   b. X-Test-Auth-Secret header matches c.env.TEST_AUTH_SECRET (constant time)
 *   c. ENABLE_TEST_AUTH must be present at all
 *
 * Any failure of any gate returns 404 (NOT 401/403) so probers see "no
 * such endpoint". This file exercises both POST /test/sign-in (sign up or
 * sign in via email+password) and DELETE /test/users/:email (full account
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

interface FakeSessionInvite {
  id: string
  ownerUserId: string
  sessionId: string
}

const { state, COLS, deleteCalls, dbCalls, deleteAccount, sharingService, SessionSharingService } = vi.hoisted(() => {
  const COLS = {
    id: { __col: "id" } as const,
    email: { __col: "email" } as const,
    userId: { __col: "userId" } as const,
    ownerUserId: { __col: "ownerUserId" } as const,
    sessionId: { __col: "sessionId" } as const,
    fileR2Key: { __col: "fileR2Key" } as const,
    coverR2Key: { __col: "coverR2Key" } as const,
    bookId: { __col: "bookId" } as const,
    conversationId: { __col: "conversationId" } as const,
  }
  return {
    state: {
      users: [] as Array<{ id: string; email: string }>,
      books: [] as Array<FakeBook>,
      highlights: [] as Array<{ id: string; userId: string }>,
      conversations: [] as Array<{ id: string; userId: string }>,
      messages: [] as Array<{ id: string; conversationId: string }>,
      bookmarks: [] as Array<{ id: string; userId: string }>,
      sessions: [] as Array<{ id: string; userId: string }>,
      accounts: [] as Array<{ id: string; userId: string }>,
      sessionInvites: [] as Array<FakeSessionInvite>,
    },
    COLS,
    deleteCalls: { r2: [] as string[] },
    dbCalls: { createDb: 0 },
    deleteAccount: vi.fn(),
    sharingService: {
      getRoomStatus: vi.fn(),
      endRoom: vi.fn(),
      purgeAppleRoom: vi.fn(),
    },
    SessionSharingService: vi.fn(function SessionSharingService() {
      return sharingService
    }),
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
  state.sessionInvites.length = 0
  deleteCalls.r2.length = 0
  dbCalls.createDb = 0
}

// ─── Mock schema ──────────────────────────────────────────────────────────────
vi.mock("@rishi/shared/schema", () => ({
  books: { ...COLS, __table: "books" },
  highlights: { ...COLS, __table: "highlights" },
  conversations: { ...COLS, __table: "conversations" },
  messages: { ...COLS, __table: "messages" },
  bookmarks: { ...COLS, __table: "bookmarks" },
  user: { ...COLS, __table: "user" },
  session: { ...COLS, __table: "session" },
  account: { ...COLS, __table: "account" },
  sessionInvites: { ...COLS, __table: "sessionInvites" },
  verification: { ...COLS, __table: "verification" },
  passkey: { ...COLS, __table: "passkey" },
  syncMeta: { ...COLS, __table: "syncMeta" },
}))

// ─── Mock drizzle-orm ────────────────────────────────────────────────────────
type Pred =
  | { kind: "eq"; col: string; value: unknown }
  | { kind: "inArray"; col: string; values: unknown[] }

vi.mock("drizzle-orm", () => ({
  eq: (col: { __col: string }, value: unknown): Pred => ({
    kind: "eq",
    col: col.__col,
    value,
  }),
  inArray: (col: { __col: string }, values: unknown[]): Pred => ({
    kind: "inArray",
    col: col.__col,
    values,
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
    case "sessionInvites":
      return "sessionInvites"
    default:
      return null
  }
}

function evalPred(pred: Pred | { kind: "and"; preds: Pred[] }, row: Record<string, unknown>): boolean {
  if ((pred as Pred).kind === "eq") {
    const p = pred as Extract<Pred, { kind: "eq" }>
    return row[p.col] === p.value
  }
  if ((pred as { kind?: string }).kind === "inArray") {
    const p = pred as Extract<Pred, { kind: "inArray" }>
    return p.values.includes(row[p.col])
  }
  if ((pred as { kind: "and" }).kind === "and") {
    return (pred as { preds: Pred[] }).preds.every((p) => evalPred(p, row))
  }
  return false
}

vi.mock("../db/drizzle", () => {
  function createDb() {
    dbCalls.createDb += 1
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
    }
  }
  return { createDb }
})

// ─── Mock createAuth (Better-Auth API) ────────────────────────────────────────
const { authBehavior, createAuthMock } = vi.hoisted(() => ({
  authBehavior: {
    signUpEmail: vi.fn(),
    signInEmail: vi.fn(),
  },
  createAuthMock: vi.fn(),
}))

vi.mock("../auth", () => ({
  createAuth: () => {
    createAuthMock()
    return {
      api: {
        signUpEmail: authBehavior.signUpEmail,
        signInEmail: authBehavior.signInEmail,
      },
    }
  },
}))

vi.mock("../account-deletion", () => ({ deleteAccount }))

vi.mock("../session-sharing-service", () => ({
  SessionSharingService,
  isSessionSharingServiceError: () => false,
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
  DB: {} as unknown,
  BOOK_STORAGE: fakeR2 as unknown,
  SHARING_WORKER: {} as unknown,
  SHARING_INTERNAL_SECRET: "test-sharing-secret",
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

const OWNER_EMAIL = "rishi-e2e-owner@example.test"
const PARTICIPANT_EMAIL = "rishi-e2e-participant@example.test"
const OWNER_ID = "e2e-owner"
const PARTICIPANT_ID = "e2e-participant"

function roomStatus(
  sessionId: string,
  status: "waiting" | "active" | "ended",
  controllerUserId = OWNER_ID,
  controllerGeneration = 1,
) {
  return { sessionId, status, controllerUserId, controllerGeneration }
}

function seedGeneratedUsers() {
  state.users.push(
    { id: OWNER_ID, email: OWNER_EMAIL },
    { id: PARTICIPANT_ID, email: PARTICIPANT_EMAIL },
  )
}

function cleanupCall(
  body: Record<string, unknown> = { emails: [OWNER_EMAIL, PARTICIPANT_EMAIL] },
  env: Record<string, unknown> = envWithGate(),
) {
  return call("/rooms/cleanup", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Test-Auth-Secret": SECRET,
    },
    body: JSON.stringify(body),
  }, env)
}

function cleanupLifecycleCallOrder(): string[] {
  return [
    ...sharingService.getRoomStatus.mock.invocationCallOrder.map((order: number) => ({ order, name: "status" })),
    ...sharingService.endRoom.mock.invocationCallOrder.map((order: number) => ({ order, name: "end" })),
    ...sharingService.purgeAppleRoom.mock.invocationCallOrder.map((order: number) => ({ order, name: "purge" })),
  ].sort((left, right) => left.order - right.order).map(({ name }) => name)
}

beforeEach(() => {
  resetState()
  authBehavior.signUpEmail.mockReset()
  authBehavior.signInEmail.mockReset()
  createAuthMock.mockClear()
  fakeR2.delete.mockClear()
  deleteAccount.mockReset()
  sharingService.getRoomStatus.mockReset()
  sharingService.endRoom.mockReset()
  sharingService.purgeAppleRoom.mockReset()
  SessionSharingService.mockClear()
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
})

// ─── Happy paths: POST /test/sign-in ──────────────────────────────────────────
describe("POST /test/sign-in — happy paths", () => {
  it("creates a new user when one doesn't exist + returns session token", async () => {
    authBehavior.signUpEmail.mockResolvedValue({
      user: { id: "user_new", email: "rishi-e2e-new@example.test" },
      token: "tok_new",
    })
    authBehavior.signInEmail.mockResolvedValue({
      user: { id: "user_new", email: "rishi-e2e-new@example.test" },
      token: "tok_new",
    })

    const res = await call("/sign-in", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Test-Auth-Secret": SECRET,
      },
      body: JSON.stringify({ email: "rishi-e2e-new@example.test", password: "pw12345678" }),
    })
    expect(res.status).toBe(200)
    const body = (await res.json()) as {
      token: string
      userId: string
      email: string
    }
    expect(body.token).toBe("tok_new")
    expect(body.userId).toBe("user_new")
    expect(body.email).toBe("rishi-e2e-new@example.test")
    expect(authBehavior.signUpEmail).toHaveBeenCalledOnce()
  })

  it("rejects an address outside the generated namespace before createAuth", async () => {
    const res = await call("/sign-in", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Test-Auth-Secret": SECRET,
      },
      body: JSON.stringify({ email: "new@x.co", password: "pw12345678" }),
    })

    expect(res.status).toBe(400)
    expect(createAuthMock).not.toHaveBeenCalled()
    expect(authBehavior.signUpEmail).not.toHaveBeenCalled()
    expect(authBehavior.signInEmail).not.toHaveBeenCalled()
  })

  it("signs in an existing user when signUpEmail rejects with 'user exists'", async () => {
    // signUpEmail throws when user already exists — caller falls through to signInEmail.
    authBehavior.signUpEmail.mockRejectedValue(new Error("user already exists"))
    authBehavior.signInEmail.mockResolvedValue({
      user: { id: "user_existing", email: "rishi-e2e-existing@example.test" },
      token: "tok_existing",
    })

    const res = await call("/sign-in", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Test-Auth-Secret": SECRET,
      },
      body: JSON.stringify({ email: "rishi-e2e-existing@example.test", password: "pw12345678" }),
    })
    expect(res.status).toBe(200)
    const body = (await res.json()) as { token: string; userId: string }
    expect(body.token).toBe("tok_existing")
    expect(body.userId).toBe("user_existing")
    expect(authBehavior.signInEmail).toHaveBeenCalledOnce()
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

// ─── Gated remote room cleanup ───────────────────────────────────────────────
describe("POST /test/rooms/cleanup", () => {
  it("returns the same 404 as an unknown route when its gate is not satisfied", async () => {
    const blocked = await call("/rooms/cleanup", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ emails: [OWNER_EMAIL, PARTICIPANT_EMAIL] }),
    })
    const unknown = await call("/not-a-test-route", { method: "POST" })

    expect({ status: blocked.status, body: await blocked.text() }).toEqual({
      status: unknown.status,
      body: await unknown.text(),
    })
  })

  it("rejects a non-generated address before opening D1 or the sharing service", async () => {
    const response = await cleanupCall({ emails: ["person@example.test", PARTICIPANT_EMAIL] })

    expect(response.status).toBe(400)
    expect(dbCalls.createDb).toBe(0)
    expect(SessionSharingService).not.toHaveBeenCalled()
  })

  it("ends, verifies, purges, and authoritatively verifies an active generated room", async () => {
    seedGeneratedUsers()
    state.sessionInvites.push({ id: "invite-1", ownerUserId: OWNER_ID, sessionId: "room-1" })
    sharingService.getRoomStatus
      .mockResolvedValueOnce(roomStatus("room-1", "active"))
      .mockResolvedValueOnce(roomStatus("room-1", "ended"))
      .mockResolvedValueOnce(null)
    sharingService.endRoom.mockResolvedValue(roomStatus("room-1", "ended"))
    sharingService.purgeAppleRoom.mockResolvedValue(undefined)

    const response = await cleanupCall({
      emails: [OWNER_EMAIL, PARTICIPANT_EMAIL],
      sessionIds: ["caller-controlled-room"],
      userIds: ["caller-controlled-user"],
    })

    expect(response.status).toBe(200)
    expect(sharingService.endRoom).toHaveBeenCalledWith({
      sessionId: "room-1",
      actingUserId: OWNER_ID,
      expectedControllerGeneration: 1,
    })
    expect(sharingService.purgeAppleRoom).toHaveBeenCalledWith({ sessionId: "room-1" })
    expect(sharingService.getRoomStatus).toHaveBeenCalledTimes(3)
    expect(cleanupLifecycleCallOrder()).toEqual(["status", "end", "status", "purge", "status"])
  })

  it("treats already-ended and already-absent generated rooms as idempotent successes", async () => {
    seedGeneratedUsers()
    state.sessionInvites.push(
      { id: "invite-ended", ownerUserId: OWNER_ID, sessionId: "ended-room" },
      { id: "invite-absent", ownerUserId: PARTICIPANT_ID, sessionId: "absent-room" },
    )
    sharingService.getRoomStatus
      .mockResolvedValueOnce(roomStatus("ended-room", "ended", "unknown-controller"))
      .mockResolvedValueOnce(roomStatus("ended-room", "ended", "unknown-controller"))
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce(null)
    sharingService.purgeAppleRoom.mockResolvedValue(undefined)

    const response = await cleanupCall()

    expect(response.status).toBe(200)
    expect(sharingService.endRoom).not.toHaveBeenCalled()
    expect(sharingService.purgeAppleRoom).toHaveBeenCalledTimes(1)
  })

  it("refreshes once after a stale controller generation and retries as the transferred generated controller", async () => {
    seedGeneratedUsers()
    state.sessionInvites.push({ id: "invite-1", ownerUserId: OWNER_ID, sessionId: "room-1" })
    sharingService.getRoomStatus
      .mockResolvedValueOnce(roomStatus("room-1", "active", OWNER_ID, 1))
      .mockResolvedValueOnce(roomStatus("room-1", "active", PARTICIPANT_ID, 2))
      .mockResolvedValueOnce(roomStatus("room-1", "ended", PARTICIPANT_ID, 2))
      .mockResolvedValueOnce(null)
    sharingService.endRoom
      .mockRejectedValueOnce({ code: "STALE_CONTROLLER_GENERATION" })
      .mockResolvedValueOnce(roomStatus("room-1", "ended", PARTICIPANT_ID, 2))
    sharingService.purgeAppleRoom.mockResolvedValue(undefined)

    const response = await cleanupCall()

    expect(response.status).toBe(200)
    expect(sharingService.endRoom).toHaveBeenNthCalledWith(1, {
      sessionId: "room-1",
      actingUserId: OWNER_ID,
      expectedControllerGeneration: 1,
    })
    expect(sharingService.endRoom).toHaveBeenNthCalledWith(2, {
      sessionId: "room-1",
      actingUserId: PARTICIPANT_ID,
      expectedControllerGeneration: 2,
    })
    expect(cleanupLifecycleCallOrder()).toEqual([
      "status",
      "end",
      "status",
      "end",
      "status",
      "purge",
      "status",
    ])
  })

  it("fails closed for an unknown refreshed controller or a second stale-generation response", async () => {
    seedGeneratedUsers()
    state.sessionInvites.push({ id: "invite-1", ownerUserId: OWNER_ID, sessionId: "room-1" })
    sharingService.getRoomStatus
      .mockResolvedValueOnce(roomStatus("room-1", "active", OWNER_ID, 1))
      .mockResolvedValueOnce(roomStatus("room-1", "active", "unknown-controller", 2))
    sharingService.endRoom.mockRejectedValueOnce({ code: "STALE_CONTROLLER_GENERATION" })

    const unknownController = await cleanupCall()

    expect(unknownController.status).toBe(500)
    expect(sharingService.endRoom).toHaveBeenCalledTimes(1)
    expect(sharingService.purgeAppleRoom).not.toHaveBeenCalled()

    sharingService.getRoomStatus.mockReset()
    sharingService.endRoom.mockReset()
    sharingService.getRoomStatus
      .mockResolvedValueOnce(roomStatus("room-1", "active", OWNER_ID, 1))
      .mockResolvedValueOnce(roomStatus("room-1", "active", PARTICIPANT_ID, 2))
    sharingService.endRoom
      .mockRejectedValueOnce({ code: "STALE_CONTROLLER_GENERATION" })
      .mockRejectedValueOnce({ code: "STALE_CONTROLLER_GENERATION" })

    const secondStale = await cleanupCall()

    expect(secondStale.status).toBe(500)
    expect(sharingService.endRoom).toHaveBeenCalledTimes(2)
    expect(sharingService.purgeAppleRoom).not.toHaveBeenCalled()
  })

  it("retains each cleanup failure for conflict, failed end verification, failed purge, or non-authoritative absence", async () => {
    seedGeneratedUsers()
    state.sessionInvites.push({ id: "invite-1", ownerUserId: OWNER_ID, sessionId: "room-1" })
    const cases = [
      {
        name: "conflict",
        statuses: [roomStatus("room-1", "active")],
        end: () => sharingService.endRoom.mockRejectedValueOnce({ code: "CONFLICT" }),
        purge: () => undefined,
      },
      {
        name: "end verification",
        statuses: [roomStatus("room-1", "active"), roomStatus("room-1", "active")],
        end: () => sharingService.endRoom.mockResolvedValueOnce(roomStatus("room-1", "active")),
        purge: () => undefined,
      },
      {
        name: "purge",
        statuses: [roomStatus("room-1", "active"), roomStatus("room-1", "ended")],
        end: () => sharingService.endRoom.mockResolvedValueOnce(roomStatus("room-1", "ended")),
        purge: () => sharingService.purgeAppleRoom.mockRejectedValueOnce(new Error("purge failed")),
      },
      {
        name: "absence verification",
        statuses: [roomStatus("room-1", "active"), roomStatus("room-1", "ended"), roomStatus("room-1", "ended")],
        end: () => sharingService.endRoom.mockResolvedValueOnce(roomStatus("room-1", "ended")),
        purge: () => sharingService.purgeAppleRoom.mockResolvedValueOnce(undefined),
      },
    ]

    for (const testCase of cases) {
      sharingService.getRoomStatus.mockReset()
      sharingService.endRoom.mockReset()
      sharingService.purgeAppleRoom.mockReset()
      sharingService.getRoomStatus.mockResolvedValueOnce(testCase.statuses.shift())
      for (const status of testCase.statuses) sharingService.getRoomStatus.mockResolvedValueOnce(status)
      testCase.end()
      testCase.purge()

      const response = await cleanupCall()
      const body = await response.json() as { failures: Array<{ sessionId: string }> }

      expect(response.status, testCase.name).toBe(500)
      expect(body.failures).toEqual(expect.arrayContaining([
        expect.objectContaining({ sessionId: "room-1" }),
      ]))
      expect(deleteAccount).not.toHaveBeenCalled()
    }
  })

  it("attempts every owned room and accumulates failures without suppressing later cleanup", async () => {
    seedGeneratedUsers()
    state.sessionInvites.push(
      { id: "invite-bad", ownerUserId: OWNER_ID, sessionId: "room-bad" },
      { id: "invite-good", ownerUserId: PARTICIPANT_ID, sessionId: "room-good" },
    )
    const statuses = new Map<string, Array<ReturnType<typeof roomStatus> | null>>([
      ["room-bad", [roomStatus("room-bad", "active", "unknown-controller")]],
      ["room-good", [roomStatus("room-good", "active"), roomStatus("room-good", "ended"), null]],
    ])
    sharingService.getRoomStatus.mockImplementation(async ({ sessionId }: { sessionId: string }) => statuses.get(sessionId)?.shift())
    sharingService.endRoom.mockResolvedValue(roomStatus("room-good", "ended"))
    sharingService.purgeAppleRoom.mockResolvedValue(undefined)

    const response = await cleanupCall()
    const body = await response.json() as { failures: Array<{ sessionId: string }> }

    expect(response.status).toBe(500)
    expect(body.failures).toEqual([{ sessionId: "room-bad", code: "UNKNOWN_CONTROLLER" }])
    expect(sharingService.endRoom).toHaveBeenCalledWith({
      sessionId: "room-good",
      actingUserId: OWNER_ID,
      expectedControllerGeneration: 1,
    })
    expect(sharingService.purgeAppleRoom).toHaveBeenCalledWith({ sessionId: "room-good" })
  })
})

// ─── Canonical gated account deletion ────────────────────────────────────────
describe("DELETE /test/users/:email — canonical deletion", () => {
  it("delegates to canonical deletion and reports success only after it completes", async () => {
    state.users.push({ id: OWNER_ID, email: OWNER_EMAIL })
    deleteAccount.mockResolvedValue({
      deletionId: "delete-1",
      alreadyDeleted: false,
      revocationStatus: "legacy_no_token",
      r2ObjectsRemoved: 2,
    })

    const response = await call(`/users/${OWNER_EMAIL}`, {
      method: "DELETE",
      headers: { "X-Test-Auth-Secret": SECRET },
    })

    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({ deleted: true, userId: OWNER_ID, r2ObjectsRemoved: 2 })
    expect(deleteAccount).toHaveBeenCalledWith(expect.anything(), expect.anything(), OWNER_ID)
  })

  it("returns non-2xx without deleting account state when canonical R2 cleanup fails", async () => {
    state.users.push({ id: OWNER_ID, email: OWNER_EMAIL })
    deleteAccount.mockRejectedValue(new Error("temporary R2 failure"))

    const response = await call(`/users/${OWNER_EMAIL}`, {
      method: "DELETE",
      headers: { "X-Test-Auth-Secret": SECRET },
    })

    expect(response.status).toBe(500)
    expect(state.users).toContainEqual({ id: OWNER_ID, email: OWNER_EMAIL })
    expect(deleteAccount).toHaveBeenCalledOnce()
  })

  it("returns the exact authoritative second-delete 404 after canonical deletion removes the user", async () => {
    state.users.push({ id: OWNER_ID, email: OWNER_EMAIL })
    deleteAccount.mockImplementation(async (_db: unknown, _env: unknown, userId: string) => {
      const index = state.users.findIndex((user) => user.id === userId)
      if (index >= 0) state.users.splice(index, 1)
      return {
        deletionId: "delete-2",
        alreadyDeleted: false,
        revocationStatus: "legacy_no_token",
        r2ObjectsRemoved: 0,
      }
    })

    const first = await call(`/users/${OWNER_EMAIL}`, {
      method: "DELETE",
      headers: { "X-Test-Auth-Secret": SECRET },
    })
    expect(first.status).toBe(200)
    expect(state.users).not.toContainEqual({ id: OWNER_ID, email: OWNER_EMAIL })
    expect(deleteAccount).toHaveBeenCalledOnce()

    const second = await call(`/users/${OWNER_EMAIL}`, {
      method: "DELETE",
      headers: { "X-Test-Auth-Secret": SECRET },
    })

    expect(second.status).toBe(404)
    expect(await second.json()).toEqual({ error: "user not found" })
    expect(deleteAccount).toHaveBeenCalledOnce()
  })
})

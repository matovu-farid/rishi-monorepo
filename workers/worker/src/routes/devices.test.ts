import { describe, it, expect, beforeEach, vi } from "vitest"

/**
 * Tests for POST /api/devices/register — Quick-VPX Task 2 (GAP 2).
 *
 * The iOS APNsDeviceRegistrar (RishiSync/Background/APNsDeviceRegistrar.swift)
 * posts to this endpoint every time iOS hands the app a fresh APNs device
 * token. The worker persists the (userId, deviceToken) pair so the silent-push
 * sync fan-out (SYNC-06) can wake every OTHER device for the same user.
 *
 * Contract under test:
 *
 *  1. Happy path: valid Better Auth session + valid body ->
 *     200 { device_id: uuid, registered_at: ISO8601 }, exactly ONE row.
 *  2. Unauthenticated: no session AND no dev-bypass header ->
 *     401 { error: "Unauthorized" }, zero rows written.
 *  3. Idempotent upsert: same (userId, deviceToken) pair twice ->
 *     both calls return 200, table count stays at exactly 1.
 *  4. Body validation: missing device_token -> 400 zod-error envelope.
 *
 * Strategy mirrors src/routes/upload.test.ts: stub the Drizzle DB with an
 * in-memory devices store, mock ../index to provide a fake requireAuth
 * that flips on `authState.userId` so the unauthenticated path is
 * exercised without spinning up the real createAuth Better Auth call.
 */

// ─── In-memory devices store ──────────────────────────────────────────────────
interface FakeDeviceRow {
  id: string
  userId: string
  deviceToken: string
  platform: string
  appVersion: string
  bundleId: string
  topic: string
  env: string
  createdAt: Date
  updatedAt: Date
}

const { deviceStore, COLS } = vi.hoisted(() => {
  const COLS = {
    id: { __col: "id" } as const,
    userId: { __col: "userId" } as const,
    deviceToken: { __col: "deviceToken" } as const,
    platform: { __col: "platform" } as const,
    appVersion: { __col: "appVersion" } as const,
    bundleId: { __col: "bundleId" } as const,
    topic: { __col: "topic" } as const,
    env: { __col: "env" } as const,
    createdAt: { __col: "createdAt" } as const,
    updatedAt: { __col: "updatedAt" } as const,
  }
  return { deviceStore: [] as FakeDeviceRow[], COLS }
})

function resetStore() {
  deviceStore.length = 0
}

// ─── Mock @rishi/shared/schema so `devices` resolves to our column ids ───────
vi.mock("@rishi/shared/schema", () => ({
  devices: COLS,
  // Other tables referenced transitively by sibling imports — empty stubs.
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
}))

// ─── Mock createDb with a tiny in-memory insert/onConflict builder ───────────
vi.mock("../db/drizzle", () => {
  function createDb() {
    return {
      insert(_table: unknown) {
        let pendingValues: Record<string, unknown> = {}
        let conflictTargets: Array<keyof typeof COLS> = []
        let conflictSet: Record<string, unknown> = {}
        const builder = {
          values(v: Record<string, unknown>) {
            pendingValues = v
            return builder
          },
          onConflictDoUpdate(opts: {
            target: Array<{ __col: keyof typeof COLS }> | { __col: keyof typeof COLS }
            set: Record<string, unknown>
          }) {
            const targets = Array.isArray(opts.target) ? opts.target : [opts.target]
            conflictTargets = targets.map((t) => t.__col)
            conflictSet = opts.set
            return builder
          },
          returning(_fields: Record<string, unknown>) {
            return {
              get() {
                // Find existing row matching ALL conflict-target columns.
                const existing = deviceStore.find((r) =>
                  conflictTargets.every(
                    (col) =>
                      (r as unknown as Record<string, unknown>)[col] ===
                      (pendingValues as Record<string, unknown>)[col],
                  ),
                )
                if (existing) {
                  // Apply the set patch — upsert, no new row.
                  Object.assign(existing, conflictSet)
                  return {
                    id: existing.id,
                    createdAt: existing.createdAt,
                  }
                }
                // Fresh insert.
                const row = pendingValues as unknown as FakeDeviceRow
                deviceStore.push(row)
                return {
                  id: row.id,
                  createdAt: row.createdAt,
                }
              },
            }
          },
        }
        return builder
      },
      _store: deviceStore,
    }
  }
  return { createDb }
})

// ─── Mock createAuth so the requireAuth stub below sees a session ────────────
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
import { devicesRoutes } from "./devices"

const env = {
  BETTER_AUTH_SECRET: "test-secret",
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  DB: {} as unknown,
} as unknown as Record<string, unknown>

async function callRegister(body: unknown) {
  const req = new Request("http://test.local/register", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  })
  return devicesRoutes.fetch(req, env)
}

const VALID_TOKEN = "a".repeat(64)

function validBody(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    device_token: VALID_TOKEN,
    platform: "ios",
    app_version: "1.0.0",
    bundle_id: "org.fidexa.rishi",
    topic: "org.fidexa.rishi",
    ...overrides,
  }
}

beforeEach(() => {
  resetStore()
  setUser("user_alice")
})

// ─── Tests ───────────────────────────────────────────────────────────────────

describe("POST /api/devices/register", () => {
  it("happy path: authenticated + valid body -> 200 { device_id, registered_at }", async () => {
    const res = await callRegister(validBody())
    expect(res.status).toBe(200)
    // Date wire format = seconds since 2001-01-01 reference date — matches
    // iOS WorkerClient.swift:96 .deferredToDate. See routes/changes.ts.
    const body = (await res.json()) as { device_id: string; registered_at: number }
    expect(typeof body.device_id).toBe("string")
    expect(body.device_id).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
    )
    expect(typeof body.registered_at).toBe("number")
    const expectedNowSec = (Date.now() - 978_307_200_000) / 1000
    expect(Math.abs(body.registered_at - expectedNowSec)).toBeLessThan(5.0)
    expect(deviceStore.length).toBe(1)
    const row = deviceStore[0]
    expect(row.userId).toBe("user_alice")
    expect(row.deviceToken).toBe(VALID_TOKEN)
    expect(row.platform).toBe("ios")
  })

  it("unauthenticated: no session -> 401 + zero rows written", async () => {
    setUser(null)
    const res = await callRegister(validBody())
    expect(res.status).toBe(401)
    const body = (await res.json()) as { error: string }
    expect(body.error).toBe("Unauthorized")
    expect(deviceStore.length).toBe(0)
  })

  it("idempotent upsert: same (userId, deviceToken) twice -> exactly 1 row, both 200", async () => {
    const first = await callRegister(validBody({ app_version: "1.0.0" }))
    expect(first.status).toBe(200)
    expect(deviceStore.length).toBe(1)

    // Second call with the SAME token but a refreshed app_version simulates
    // an in-place update on the same device. Must hit onConflictDoUpdate,
    // NOT throw a UNIQUE-constraint error.
    const second = await callRegister(validBody({ app_version: "1.0.1" }))
    expect(second.status).toBe(200)

    expect(deviceStore.length).toBe(1)
    expect(deviceStore[0].appVersion).toBe("1.0.1") // upsert applied
    expect(deviceStore[0].userId).toBe("user_alice")
    expect(deviceStore[0].deviceToken).toBe(VALID_TOKEN)
  })

  it("body validation: missing device_token -> 400 zod-error envelope", async () => {
    const { device_token: _drop, ...without } = validBody()
    void _drop
    const res = await callRegister(without)
    expect(res.status).toBe(400)
    const body = (await res.json()) as { error: string }
    expect(body.error).toBe("bad_request")
  })
})

import { describe, it, expect, beforeEach, vi } from "vitest";
const { deviceStore, COLS } = vi.hoisted(() => {
    const COLS = {
        id: { __col: "id" },
        userId: { __col: "userId" },
        deviceToken: { __col: "deviceToken" },
        platform: { __col: "platform" },
        appVersion: { __col: "appVersion" },
        bundleId: { __col: "bundleId" },
        topic: { __col: "topic" },
        env: { __col: "env" },
        createdAt: { __col: "createdAt" },
        updatedAt: { __col: "updatedAt" },
    };
    return { deviceStore: [], COLS };
});
function resetStore() {
    deviceStore.length = 0;
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
}));
vi.mock("drizzle-orm", () => ({
    eq: (col, value) => ({
        kind: "eq",
        col: col.__col,
        value,
    }),
    and: (...preds) => ({ kind: "and", preds }),
}));
// ─── Mock createDb with a tiny in-memory insert/onConflict builder ───────────
vi.mock("../db/drizzle", () => {
    function createDb() {
        return {
            insert(_table) {
                let pendingValues = {};
                let conflictTargets = [];
                let conflictSet = {};
                const builder = {
                    values(v) {
                        pendingValues = v;
                        return builder;
                    },
                    onConflictDoUpdate(opts) {
                        const targets = Array.isArray(opts.target) ? opts.target : [opts.target];
                        conflictTargets = targets.map((t) => t.__col);
                        conflictSet = opts.set;
                        return builder;
                    },
                    returning(_fields) {
                        return {
                            get() {
                                // Find existing row matching ALL conflict-target columns.
                                const existing = deviceStore.find((r) => conflictTargets.every((col) => r[col] ===
                                    pendingValues[col]));
                                if (existing) {
                                    // Apply the set patch — upsert, no new row.
                                    Object.assign(existing, conflictSet);
                                    return {
                                        id: existing.id,
                                        createdAt: existing.createdAt,
                                    };
                                }
                                // Fresh insert.
                                const row = pendingValues;
                                deviceStore.push(row);
                                return {
                                    id: row.id,
                                    createdAt: row.createdAt,
                                };
                            },
                        };
                    },
                };
                return builder;
            },
            _store: deviceStore,
        };
    }
    return { createDb };
});
// ─── Mock createAuth so the requireAuth stub below sees a session ────────────
const { authState } = vi.hoisted(() => ({
    authState: { userId: "user_alice" },
}));
function setUser(id) {
    authState.userId = id;
}
vi.mock("../auth", () => ({
    createAuth: () => ({
        api: {
            getSession: async () => {
                if (!authState.userId)
                    return null;
                return {
                    user: { id: authState.userId },
                    session: { token: "tok_test" },
                };
            },
        },
    }),
}));
// ─── Mock ../index to avoid pulling the real Hono app + every route ──────────
vi.mock("../index", async () => {
    return {
        requireAuth: async (c, next) => {
            if (!authState.userId) {
                return c.json({ error: "Unauthorized" }, 401);
            }
            c.set("userId", authState.userId);
            return next();
        },
    };
});
// ─── Now import the route under test ────────────────────────────────────────
import { devicesRoutes } from "./devices";
const env = {
    BETTER_AUTH_SECRET: "test-secret",
    PUBLIC_API_URL: "https://api.fidexa.org",
    PUBLIC_WEB_URL: "https://rishi.fidexa.org",
    DB: {},
};
async function callRegister(body) {
    const req = new Request("http://test.local/register", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
    });
    return devicesRoutes.fetch(req, env);
}
const VALID_TOKEN = "a".repeat(64);
function validBody(overrides = {}) {
    return {
        device_token: VALID_TOKEN,
        platform: "ios",
        app_version: "1.0.0",
        bundle_id: "org.fidexa.rishi",
        topic: "org.fidexa.rishi",
        ...overrides,
    };
}
beforeEach(() => {
    resetStore();
    setUser("user_alice");
});
// ─── Tests ───────────────────────────────────────────────────────────────────
describe("POST /api/devices/register", () => {
    it("happy path: authenticated + valid body -> 200 { device_id, registered_at }", async () => {
        const res = await callRegister(validBody());
        expect(res.status).toBe(200);
        // Date wire format = seconds since 2001-01-01 reference date — matches
        // iOS WorkerClient.swift:96 .deferredToDate. See routes/changes.ts.
        const body = (await res.json());
        expect(typeof body.device_id).toBe("string");
        expect(body.device_id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
        expect(typeof body.registered_at).toBe("number");
        const expectedNowSec = (Date.now() - 978_307_200_000) / 1000;
        expect(Math.abs(body.registered_at - expectedNowSec)).toBeLessThan(5.0);
        expect(deviceStore.length).toBe(1);
        const row = deviceStore[0];
        expect(row.userId).toBe("user_alice");
        expect(row.deviceToken).toBe(VALID_TOKEN);
        expect(row.platform).toBe("ios");
    });
    it("unauthenticated: no session -> 401 + zero rows written", async () => {
        setUser(null);
        const res = await callRegister(validBody());
        expect(res.status).toBe(401);
        const body = (await res.json());
        expect(body.error).toBe("Unauthorized");
        expect(deviceStore.length).toBe(0);
    });
    it("idempotent upsert: same (userId, deviceToken) twice -> exactly 1 row, both 200", async () => {
        const first = await callRegister(validBody({ app_version: "1.0.0" }));
        expect(first.status).toBe(200);
        expect(deviceStore.length).toBe(1);
        // Second call with the SAME token but a refreshed app_version simulates
        // an in-place update on the same device. Must hit onConflictDoUpdate,
        // NOT throw a UNIQUE-constraint error.
        const second = await callRegister(validBody({ app_version: "1.0.1" }));
        expect(second.status).toBe(200);
        expect(deviceStore.length).toBe(1);
        expect(deviceStore[0].appVersion).toBe("1.0.1"); // upsert applied
        expect(deviceStore[0].userId).toBe("user_alice");
        expect(deviceStore[0].deviceToken).toBe(VALID_TOKEN);
    });
    it("body validation: missing device_token -> 400 zod-error envelope", async () => {
        const { device_token: _drop, ...without } = validBody();
        void _drop;
        const res = await callRegister(without);
        expect(res.status).toBe(400);
        const body = (await res.json());
        expect(body.error).toBe("bad_request");
    });
});

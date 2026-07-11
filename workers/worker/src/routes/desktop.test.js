import { describe, it, expect, beforeEach, vi } from "vitest";
/**
 * Tests for /desktop/* auth endpoints — specifically the idempotency contract
 * for POST /desktop/start/complete. A stale browser tab from the original
 * sign-in flow must be able to re-POST without erroring "state_expired", as
 * long as it's the same authenticated user that completed the handoff. A
 * different user must still get 400 — the single-use property protects against
 * one user overwriting another's session.
 */
// ─── Redis stub ───────────────────────────────────────────────────────────────
const redisStore = new Map();
vi.mock("@upstash/redis/cloudflare", () => {
    class FakeRedis {
        async get(key) {
            return redisStore.get(key) ?? null;
        }
        async set(key, value, _opts) {
            redisStore.set(key, value);
            return "OK";
        }
        async del(...keys) {
            let n = 0;
            for (const k of keys) {
                if (redisStore.delete(k))
                    n++;
            }
            return n;
        }
    }
    return {
        Redis: {
            fromEnv: () => new FakeRedis(),
        },
    };
});
// ─── createAuth stub ──────────────────────────────────────────────────────────
// The "Cookie" header drives which fake session we hand back, so we can simulate
// two different signed-in browsers POSTing the same state.
const sessionByCookie = new Map();
const setSessionFor = (cookie, s) => {
    sessionByCookie.set(cookie, s);
};
vi.mock("../auth", () => ({
    createAuth: () => ({
        api: {
            getSession: async ({ headers }) => {
                const cookie = headers.get("cookie") || "";
                for (const [k, v] of sessionByCookie) {
                    if (cookie.includes(k))
                        return v;
                }
                return null;
            },
        },
    }),
}));
import { desktopRoutes } from "./desktop";
const env = {
    PUBLIC_WEB_URL: "https://rishi.fidexa.org",
    PUBLIC_API_URL: "https://api.fidexa.org",
    UPSTASH_REDIS_REST_URL: "https://example-redis",
    UPSTASH_REDIS_REST_TOKEN: "test-token",
    BETTER_AUTH_SECRET: "test-secret",
};
async function call(path, init = {}) {
    const url = `http://test.local${path}`;
    const req = new Request(url, init);
    return desktopRoutes.fetch(req, env);
}
async function sha256Base64Url(input) {
    const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
    return btoa(String.fromCharCode(...new Uint8Array(buf)))
        .replace(/\+/g, "-")
        .replace(/\//g, "_")
        .replace(/=+$/, "");
}
function makeVerifier() {
    const bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}
const uuid = () => crypto.randomUUID();
beforeEach(() => {
    redisStore.clear();
    sessionByCookie.clear();
});
// ─── POST /desktop/start/complete ─────────────────────────────────────────────
describe("POST /desktop/start/complete", () => {
    it("happy path: state exists -> 200, writes result, deletes state, writes completed sentinel", async () => {
        const verifier = makeVerifier();
        const challenge = await sha256Base64Url(verifier);
        const state = uuid();
        redisStore.set(`desktop:state:${state}`, {
            code_challenge: challenge,
            mode: "oauth-google",
            createdAt: Date.now(),
        });
        setSessionFor("web-signed-in=alice", {
            user: { id: "user_alice" },
            session: { token: "tok_alice" },
        });
        const res = await call("/start/complete", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                Cookie: "web-signed-in=alice",
            },
            body: JSON.stringify({ state }),
        });
        expect(res.status).toBe(200);
        expect((await res.json())).toEqual({ ok: true });
        // result record written for the desktop poll
        const result = redisStore.get(`desktop:result:${state}`);
        expect(result).toBeTruthy();
        expect(result.session_token).toBe("tok_alice");
        expect(result.user_id).toBe("user_alice");
        // state record consumed
        expect(redisStore.has(`desktop:state:${state}`)).toBe(false);
        // completed sentinel written for the same user
        const sentinel = redisStore.get(`desktop:completed:${state}`);
        expect(sentinel).toBeTruthy();
        expect(sentinel.user_id).toBe("user_alice");
        expect(typeof sentinel.createdAt).toBe("number");
    });
    it("second call by SAME user after state was consumed -> 200, does not touch result", async () => {
        const verifier = makeVerifier();
        const challenge = await sha256Base64Url(verifier);
        const state = uuid();
        setSessionFor("web-signed-in=alice", {
            user: { id: "user_alice" },
            session: { token: "tok_alice" },
        });
        // First call: seeded state, runs the full path.
        redisStore.set(`desktop:state:${state}`, {
            code_challenge: challenge,
            mode: "oauth-google",
            createdAt: Date.now(),
        });
        const first = await call("/start/complete", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                Cookie: "web-signed-in=alice",
            },
            body: JSON.stringify({ state }),
        });
        expect(first.status).toBe(200);
        // Simulate the desktop having already polled and consumed the result.
        redisStore.delete(`desktop:result:${state}`);
        const second = await call("/start/complete", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                Cookie: "web-signed-in=alice",
            },
            body: JSON.stringify({ state }),
        });
        expect(second.status).toBe(200);
        expect((await second.json())).toEqual({ ok: true });
        // Idempotent: must NOT re-write the result record (desktop has already
        // consumed it; rewriting would let a replay hand out a stale token).
        expect(redisStore.has(`desktop:result:${state}`)).toBe(false);
    });
    it("second call by DIFFERENT user after state was consumed -> 400 state_expired", async () => {
        const verifier = makeVerifier();
        const challenge = await sha256Base64Url(verifier);
        const state = uuid();
        setSessionFor("web-signed-in=alice", {
            user: { id: "user_alice" },
            session: { token: "tok_alice" },
        });
        setSessionFor("web-signed-in=bob", {
            user: { id: "user_bob" },
            session: { token: "tok_bob" },
        });
        redisStore.set(`desktop:state:${state}`, {
            code_challenge: challenge,
            mode: "oauth-google",
            createdAt: Date.now(),
        });
        const first = await call("/start/complete", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                Cookie: "web-signed-in=alice",
            },
            body: JSON.stringify({ state }),
        });
        expect(first.status).toBe(200);
        const resultBefore = redisStore.get(`desktop:result:${state}`);
        const attacker = await call("/start/complete", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                Cookie: "web-signed-in=bob",
            },
            body: JSON.stringify({ state }),
        });
        expect(attacker.status).toBe(400);
        const body = (await attacker.json());
        expect(body.error).toBe("state_expired");
        // Critically: Bob did not overwrite Alice's result.
        expect(redisStore.get(`desktop:result:${state}`)).toEqual(resultBefore);
    });
    it("no completion ever recorded -> 400 state_expired", async () => {
        setSessionFor("web-signed-in=alice", {
            user: { id: "user_alice" },
            session: { token: "tok_alice" },
        });
        const res = await call("/start/complete", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                Cookie: "web-signed-in=alice",
            },
            body: JSON.stringify({ state: uuid() }),
        });
        expect(res.status).toBe(400);
        const body = (await res.json());
        expect(body.error).toBe("state_expired");
    });
});
// ─── POST /desktop/cancel ─────────────────────────────────────────────────────
describe("POST /desktop/cancel", () => {
    it("removes the completed sentinel along with state and result keys", async () => {
        const stateA = uuid();
        const stateB = uuid();
        redisStore.set(`desktop:state:${stateA}`, { dummy: true });
        redisStore.set(`desktop:result:${stateA}`, { dummy: true });
        redisStore.set(`desktop:completed:${stateA}`, {
            user_id: "user_alice",
            createdAt: Date.now(),
        });
        redisStore.set(`desktop:state:${stateB}`, { dummy: true });
        redisStore.set(`desktop:completed:${stateB}`, {
            user_id: "user_alice",
            createdAt: Date.now(),
        });
        const res = await call("/cancel", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ states: [stateA, stateB] }),
        });
        expect(res.status).toBe(200);
        expect(redisStore.has(`desktop:state:${stateA}`)).toBe(false);
        expect(redisStore.has(`desktop:result:${stateA}`)).toBe(false);
        expect(redisStore.has(`desktop:completed:${stateA}`)).toBe(false);
        expect(redisStore.has(`desktop:state:${stateB}`)).toBe(false);
        expect(redisStore.has(`desktop:completed:${stateB}`)).toBe(false);
    });
});

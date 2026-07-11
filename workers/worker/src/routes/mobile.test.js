import { describe, it, expect, beforeEach, vi } from "vitest";
/**
 * Tests for /mobile/* auth endpoints — the mobile-app counterpart to
 * /desktop/* that Electron uses.
 *
 * Design choice (matches workers/worker/src/routes/desktop.ts and the
 * .parity/AUTH-WORKER-READINESS.md canonical decisions):
 *
 *   1. POST /mobile/start              — stores PKCE challenge + state in Redis,
 *                                        returns { state, authUrl } where
 *                                        authUrl bounces through the web app
 *                                        (mirrors /desktop/start oauth-google).
 *   2. POST /mobile/start/complete     — called by the web app after the user
 *                                        signs in via OAuth (web session cookie
 *                                        attached); writes the result into
 *                                        Redis keyed by state. Same as desktop.
 *   3. GET  /mobile/start/complete     — same path used as the user-agent
 *                                        redirect target after the web app
 *                                        finishes; 302s to
 *                                        rishimobile://auth/callback?state=...
 *                                        (NO token in URL — PKCE not yet proven).
 *   4. POST /mobile/start/verify       — mobile sends { state, code_verifier },
 *                                        worker proves PKCE and returns
 *                                        { session_token, user_id }. This is
 *                                        the verifier-exchange the readiness
 *                                        doc describes.
 *
 * The token is therefore NOT in the deep-link URL. The readiness doc's example
 * (`rishimobile://auth/callback?token=...`) is documented in BATCH-1A-NOTES.md
 * as the deviation, per the executor instruction:
 *
 *   "If that conflicts with Better-Auth conventions, follow whatever pattern
 *    workers/worker/src/routes/desktop.ts already uses for /desktop/start/complete
 *    — consistency with electron is more important than the spec wording."
 */
// ─── Redis stub ───────────────────────────────────────────────────────────────
// Shared mutable map that vi.mock factories close over.
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
// We stub `createAuth` so the mobile routes can rely on:
//   auth.api.getSession({ headers })   — returns a session for "web-signed-in"
//                                         cookie, null otherwise
// No actual Better-Auth instance is constructed in tests.
let fakeSession = null;
const setSession = (s) => {
    fakeSession = s;
};
vi.mock("../auth", () => ({
    createAuth: () => ({
        api: {
            getSession: async ({ headers }) => {
                const cookie = headers.get("cookie") || "";
                if (cookie.includes("web-signed-in=1")) {
                    return fakeSession;
                }
                return null;
            },
        },
    }),
}));
// Now import the route under test (after mocks are in place).
import { mobileRoutes } from "./mobile";
import { desktopRoutes } from "./desktop";
// ─── helpers ──────────────────────────────────────────────────────────────────
const env = {
    PUBLIC_WEB_URL: "https://rishi.fidexa.org",
    PUBLIC_API_URL: "https://api.fidexa.org",
    UPSTASH_REDIS_REST_URL: "https://example-redis",
    UPSTASH_REDIS_REST_TOKEN: "test-token",
    BETTER_AUTH_SECRET: "test-secret",
};
async function call(routes, path, init = {}) {
    // Hono's fetch takes a Request and an env binding object.
    const url = `http://test.local${path}`;
    const req = new Request(url, init);
    return routes.fetch(req, env);
}
async function sha256Base64Url(input) {
    const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
    return btoa(String.fromCharCode(...new Uint8Array(buf)))
        .replace(/\+/g, "-")
        .replace(/\//g, "_")
        .replace(/=+$/, "");
}
// A valid PKCE verifier is 43-128 chars [A-Z a-z 0-9 - . _ ~].
function makeVerifier() {
    // 64 hex chars (32 random bytes) is well within bounds and uses safe chars.
    const bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}
// z.uuid() in zod v4 only accepts properly-versioned UUIDs (v1-v8), not
// arbitrary 8-4-4-4-12 hex strings. Use crypto.randomUUID() in tests so the
// schema validation matches the production path (where state is also minted
// via crypto.randomUUID()).
const uuid = () => crypto.randomUUID();
beforeEach(() => {
    redisStore.clear();
    setSession(null);
});
// ─── /mobile/start ────────────────────────────────────────────────────────────
describe("POST /mobile/start", () => {
    it("returns { state, authUrl } for a valid PKCE challenge + provider", async () => {
        const verifier = makeVerifier();
        const challenge = await sha256Base64Url(verifier);
        const res = await call(mobileRoutes, "/start", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                code_challenge: challenge,
                provider: "google",
            }),
        });
        expect(res.status).toBe(200);
        const body = (await res.json());
        expect(typeof body.state).toBe("string");
        expect(body.state.length).toBeGreaterThan(0);
        expect(body.authUrl).toMatch(/^https:\/\/rishi\.fidexa\.org\//);
        // authUrl must propagate the mobile-flow state so the web app can complete it.
        expect(body.authUrl).toContain(`state=${encodeURIComponent(body.state)}`);
        // and signal it's a mobile flow, so DesktopHandoffListener doesn't pick it up.
        expect(body.authUrl).toMatch(/(client=mobile|flow=mobile)/);
    });
    it("rejects malformed body with 400", async () => {
        const res = await call(mobileRoutes, "/start", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ code_challenge: "too-short" }),
        });
        expect(res.status).toBe(400);
    });
    it("rejects unknown provider with 400", async () => {
        const verifier = makeVerifier();
        const challenge = await sha256Base64Url(verifier);
        const res = await call(mobileRoutes, "/start", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                code_challenge: challenge,
                provider: "myspace",
            }),
        });
        expect(res.status).toBe(400);
    });
    it("defaults provider to google when omitted", async () => {
        const verifier = makeVerifier();
        const challenge = await sha256Base64Url(verifier);
        const res = await call(mobileRoutes, "/start", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ code_challenge: challenge }),
        });
        expect(res.status).toBe(200);
        const body = (await res.json());
        expect(body.authUrl).toContain("provider=google");
    });
});
// ─── GET /mobile/start/complete (302 to rishimobile://) ───────────────────────
describe("GET /mobile/start/complete", () => {
    it("302s to rishimobile://auth/callback?state=... when state is valid", async () => {
        // Pre-seed Redis with a result record as if the POST /complete had already run.
        const verifier = makeVerifier();
        const challenge = await sha256Base64Url(verifier);
        const state = uuid();
        redisStore.set(`mobile:result:${state}`, {
            code_challenge: challenge,
            session_token: "tok_test",
            user_id: "user_test",
            createdAt: Date.now(),
        });
        const res = await call(mobileRoutes, `/start/complete?state=${state}`, {
            method: "GET",
            redirect: "manual",
        });
        expect(res.status).toBe(302);
        const loc = res.headers.get("Location") || "";
        expect(loc.startsWith("rishimobile://auth/callback")).toBe(true);
        const parsed = new URL(loc);
        expect(parsed.searchParams.get("state")).toBe(state);
        // The token MUST NOT leak through the URL — verifier exchange returns it.
        expect(parsed.searchParams.has("token")).toBe(false);
    });
    it("400s when state is unknown / expired", async () => {
        const res = await call(mobileRoutes, `/start/complete?state=${uuid()}`, { method: "GET", redirect: "manual" });
        expect(res.status).toBe(400);
    });
    it("400s when state query param is missing", async () => {
        const res = await call(mobileRoutes, `/start/complete`, {
            method: "GET",
            redirect: "manual",
        });
        expect(res.status).toBe(400);
    });
});
// ─── POST /mobile/start/complete (web app -> worker) ──────────────────────────
describe("POST /mobile/start/complete", () => {
    it("writes a result record when the web session is valid and state exists", async () => {
        const verifier = makeVerifier();
        const challenge = await sha256Base64Url(verifier);
        const state = uuid();
        redisStore.set(`mobile:state:${state}`, {
            code_challenge: challenge,
            provider: "google",
            createdAt: Date.now(),
        });
        setSession({ user: { id: "user_test" }, session: { token: "tok_test" } });
        const res = await call(mobileRoutes, "/start/complete", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                Cookie: "web-signed-in=1",
            },
            body: JSON.stringify({ state }),
        });
        expect(res.status).toBe(200);
        const stored = redisStore.get(`mobile:result:${state}`);
        expect(stored).toBeTruthy();
        expect(stored.session_token).toBe("tok_test");
        expect(stored.user_id).toBe("user_test");
        expect(stored.code_challenge).toBe(challenge);
        // state record should be consumed (single-use).
        expect(redisStore.has(`mobile:state:${state}`)).toBe(false);
    });
    it("401s when no web session is attached", async () => {
        const res = await call(mobileRoutes, "/start/complete", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ state: uuid() }),
        });
        expect(res.status).toBe(401);
    });
    it("400s when state is unknown / expired", async () => {
        setSession({ user: { id: "user_test" }, session: { token: "tok_test" } });
        const res = await call(mobileRoutes, "/start/complete", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                Cookie: "web-signed-in=1",
            },
            body: JSON.stringify({ state: uuid() }),
        });
        expect(res.status).toBe(400);
    });
});
// ─── POST /mobile/start/verify (PKCE-bound token exchange) ────────────────────
describe("POST /mobile/start/verify", () => {
    it("returns { session_token } when verifier matches the stored challenge", async () => {
        const verifier = makeVerifier();
        const challenge = await sha256Base64Url(verifier);
        const state = uuid();
        redisStore.set(`mobile:result:${state}`, {
            code_challenge: challenge,
            session_token: "tok_mobile",
            user_id: "user_mobile",
            createdAt: Date.now(),
        });
        const res = await call(mobileRoutes, "/start/verify", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ state, code_verifier: verifier }),
        });
        expect(res.status).toBe(200);
        const body = (await res.json());
        expect(body.session_token).toBe("tok_mobile");
        expect(body.user_id).toBe("user_mobile");
        // Single-use: result record must be cleared so a replay 403s.
        expect(redisStore.has(`mobile:result:${state}`)).toBe(false);
    });
    it("403s when code_verifier does not match the stored challenge (PKCE mismatch)", async () => {
        const verifier = makeVerifier();
        const challenge = await sha256Base64Url(verifier);
        const otherVerifier = makeVerifier();
        const state = uuid();
        redisStore.set(`mobile:result:${state}`, {
            code_challenge: challenge,
            session_token: "tok_mobile",
            user_id: "user_mobile",
            createdAt: Date.now(),
        });
        const res = await call(mobileRoutes, "/start/verify", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ state, code_verifier: otherVerifier }),
        });
        expect(res.status).toBe(403);
        // Result record must NOT be consumed on a failed verify — otherwise an
        // attacker who guesses state can wipe a legit user's pending exchange.
        expect(redisStore.has(`mobile:result:${state}`)).toBe(true);
    });
    it("410s when the result record is gone (expired / never written)", async () => {
        const verifier = makeVerifier();
        const res = await call(mobileRoutes, "/start/verify", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                state: uuid(),
                code_verifier: verifier,
            }),
        });
        expect(res.status).toBe(410);
    });
    it("400s on malformed body", async () => {
        const res = await call(mobileRoutes, "/start/verify", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ state: "not-a-uuid", code_verifier: "x" }),
        });
        expect(res.status).toBe(400);
    });
});
// ─── State mismatch regression (start with one state, verify with another) ───
describe("State binding", () => {
    it("verify with a different state from start does not return a token", async () => {
        const verifier = makeVerifier();
        const challenge = await sha256Base64Url(verifier);
        const ownerState = uuid();
        const attackerState = uuid();
        // Start with one state…
        redisStore.set(`mobile:result:${ownerState}`, {
            code_challenge: challenge,
            session_token: "tok_owner",
            user_id: "user_owner",
            createdAt: Date.now(),
        });
        // …but verify against a different (unknown) state.
        const res = await call(mobileRoutes, "/start/verify", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                state: attackerState,
                code_verifier: verifier,
            }),
        });
        expect(res.status).toBe(410);
    });
});
// ─── Regression: desktop route still wired up the same way ────────────────────
describe("Regression: /desktop/start (Electron)", () => {
    it("still rejects malformed bodies with 400 (route untouched by Batch 1A)", async () => {
        const res = await call(desktopRoutes, "/start", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ nope: true }),
        });
        expect(res.status).toBe(400);
    });
    it("still accepts a well-formed oauth-google start and returns state + web_url", async () => {
        const verifier = makeVerifier();
        const challenge = await sha256Base64Url(verifier);
        const res = await call(desktopRoutes, "/start", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                code_challenge: challenge,
                mode: "oauth-google",
            }),
        });
        expect(res.status).toBe(200);
        const body = (await res.json());
        expect(body.state).toMatch(/^[0-9a-f-]{36}$/i);
        expect(body.web_url).toContain("provider=google");
        // Critically, the desktop flow does NOT add client=mobile / flow=mobile.
        expect(body.web_url).not.toContain("client=mobile");
        expect(body.web_url).not.toContain("flow=mobile");
    });
});

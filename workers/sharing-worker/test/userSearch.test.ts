import { describe, expect, it, beforeEach, afterEach } from "vitest";
import app from "../src/index";

const env = {
  WORKER_HMAC_SECRET: "test_secret_at_least_32_chars_long_xx",
  AUTH_BASE_URL: "https://auth.example.com",
  SESSION_ROOM: {} as unknown as DurableObjectNamespace,
};

beforeEach(() => {
  (globalThis as unknown as { __TEST_AUTH__: unknown }).__TEST_AUTH__ = {
    userId: "u_caller", displayName: "Caller", avatarUrl: undefined,
  };
  (globalThis as unknown as { __TEST_FETCH__?: typeof fetch }).__TEST_FETCH__ =
    (async (url: string) => {
      const u = new URL(url);
      if (u.pathname === "/api/users/search") {
        return new Response(JSON.stringify([
          { userId: "u_alice", email: "alice@x.y", displayName: "Alice" },
          { userId: "u_andy", email: "andy@x.y", displayName: "Andy" },
        ]), { status: 200, headers: { "content-type": "application/json" } });
      }
      return new Response("nope", { status: 404 });
    }) as typeof fetch;
});

afterEach(() => {
  delete (globalThis as unknown as { __TEST_AUTH__?: unknown }).__TEST_AUTH__;
  delete (globalThis as unknown as { __TEST_FETCH__?: typeof fetch }).__TEST_FETCH__;
});

describe("POST /v1/users/search", () => {
  it("rejects missing body with 400", async () => {
    const res = await app.fetch(new Request("https://x/v1/users/search", {
      method: "POST", headers: { "content-type": "application/json" },
      body: "{}",
    }), env);
    expect(res.status).toBe(400);
  });

  it("returns proxied users for a valid query", async () => {
    const res = await app.fetch(new Request("https://x/v1/users/search", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ q: "al" }),
    }), env);
    expect(res.status).toBe(200);
    const body = await res.json() as { users: Array<{ userId: string }> };
    expect(body.users.length).toBeGreaterThan(0);
    expect(body.users[0].userId).toBe("u_alice");
  });

  it("rate-limits the caller", async () => {
    let last = 200;
    for (let i = 0; i < 40; i++) {
      const res = await app.fetch(new Request("https://x/v1/users/search", {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ q: "al" }),
      }), env);
      last = res.status;
      if (last === 429) break;
    }
    expect(last).toBe(429);
  });

  it("rejects unauthenticated callers", async () => {
    delete (globalThis as unknown as { __TEST_AUTH__?: unknown }).__TEST_AUTH__;
    const res = await app.fetch(new Request("https://x/v1/users/search", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ q: "al" }),
    }), env);
    expect(res.status).toBe(401);
  });
});

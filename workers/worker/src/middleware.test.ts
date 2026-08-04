import { describe, expect, it, vi } from "vitest";
import { Effect } from "effect";
import { Hono } from "hono";

const { state } = vi.hoisted(() => ({
  state: {
    allocation: vi.fn(),
    user: { id: "user-1", name: "Reader One" },
  },
}));

vi.mock("./jwt", () => ({
  verifyAccessToken: vi.fn(() => Effect.succeed({ userId: "user-1" })),
}));

vi.mock("./usernames", () => ({
  ensureUsername: (...args: unknown[]) => state.allocation(...args),
  UsernameAllocationError: class UsernameAllocationError extends Error {},
}));

vi.mock("./db/drizzle", () => ({
  createDb: vi.fn(() => ({
    select: () => ({
      from: () => ({
        where: () => ({
          get: async () => state.user,
        }),
      }),
    }),
  })),
}));

import { makeRequireAuth } from "./middleware";

const env = { DB: {} as D1Database } as unknown as Env;

function app() {
  const instance = new Hono<{ Bindings: Env }>();
  instance.get("/protected", makeRequireAuth(), (c) => c.json({ ok: true }));
  return instance;
}

describe("requireAuth username repair", () => {
  it("repairs a legacy authenticated user before the route runs", async () => {
    state.allocation.mockResolvedValueOnce("reader_one");

    const response = await app().fetch(new Request("http://test/protected", {
      headers: { Authorization: "Bearer token" },
    }), env);

    expect(response.status).toBe(200);
    expect(state.allocation).toHaveBeenCalledWith(expect.anything(), "user-1", "Reader One");
  });

  it("returns 503 when username allocation remains unavailable", async () => {
    const { UsernameAllocationError } = await import("./usernames");
    state.allocation.mockRejectedValueOnce(new UsernameAllocationError());

    const response = await app().fetch(new Request("http://test/protected", {
      headers: { Authorization: "Bearer token" },
    }), env);

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      error: "Username service unavailable",
      code: "USERNAME_UNAVAILABLE",
    });
  });
});

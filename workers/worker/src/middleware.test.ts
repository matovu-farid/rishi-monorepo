import { beforeEach, describe, expect, it, vi } from "vitest";
import { Effect } from "effect";
import { Hono } from "hono";

const { state } = vi.hoisted(() => ({
  state: {
    allocation: vi.fn(),
    user: { id: "user-1", name: "Reader One" },
  },
}));

const { authSession } = vi.hoisted(() => ({
  authSession: vi.fn(),
}));

vi.mock("./jwt", () => ({
  verifyAccessToken: vi.fn(() => Effect.succeed({ userId: "user-1" })),
}));

vi.mock("./auth", () => ({
  createAuth: vi.fn(async () => ({
    api: { getSession: authSession },
  })),
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
import { verifyAccessToken } from "./jwt";

const env = { DB: {} as D1Database } as unknown as Env;

function app() {
  const instance = new Hono<{ Bindings: Env }>();
  instance.get("/protected", makeRequireAuth(), (c) => c.json({ ok: true }));
  return instance;
}

beforeEach(() => {
  state.allocation.mockReset();
  authSession.mockReset().mockResolvedValue(null);
  vi.mocked(verifyAccessToken).mockReset().mockReturnValue(Effect.succeed({ userId: "user-1" }));
  state.user = { id: "user-1", name: "Reader One" };
});

describe("requireAuth username repair", () => {
  it("repairs a legacy authenticated user before the route runs", async () => {
    state.allocation.mockResolvedValueOnce("reader_one");

    const response = await app().fetch(new Request("http://test/protected", {
      headers: { Authorization: "Bearer token" },
    }), env);

    expect(response.status).toBe(200);
    expect(state.allocation).toHaveBeenCalledWith(expect.anything(), "user-1", "Reader One");
    expect(authSession).not.toHaveBeenCalled();
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

  it("accepts a Better Auth bearer session after custom JWT verification fails", async () => {
    vi.mocked(verifyAccessToken).mockReturnValueOnce(
      Effect.fail(new Error("not custom jwt")) as unknown as ReturnType<typeof verifyAccessToken>,
    );
    authSession.mockImplementationOnce(({ headers }: { headers: Headers }) => {
      expect(headers.get("Authorization")).toBe("Bearer better-auth-session-token");
      expect(headers.get("Cookie")).toBeNull();
      return { user: { id: "better-user" } };
    });
    state.user = { id: "better-user", name: "Better Reader" };

    const response = await app().fetch(new Request("http://test/protected", {
      headers: {
        Authorization: "Bearer better-auth-session-token",
        Cookie: "better-auth.session_token=must-not-be-used",
      },
    }), env);

    expect(response.status).toBe(200);
    expect(authSession).toHaveBeenCalledTimes(1);
    expect(state.allocation).toHaveBeenCalledWith(expect.anything(), "better-user", "Better Reader");
  });

  it("rejects an invalid bearer when Better Auth has no matching session", async () => {
    vi.mocked(verifyAccessToken).mockReturnValueOnce(
      Effect.fail(new Error("invalid")) as unknown as ReturnType<typeof verifyAccessToken>,
    );
    authSession.mockResolvedValueOnce(null);

    const response = await app().fetch(new Request("http://test/protected", {
      headers: { Authorization: "Bearer invalid-token" },
    }), env);

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "Unauthorized" });
  });

  it("does not allow cookie-only Better Auth sessions", async () => {
    authSession.mockResolvedValueOnce({ user: { id: "cookie-user" } });

    const response = await app().fetch(new Request("http://test/protected", {
      headers: { Cookie: "better-auth.session_token=cookie" },
    }), env);

    expect(response.status).toBe(401);
    expect(authSession).not.toHaveBeenCalled();
  });
});

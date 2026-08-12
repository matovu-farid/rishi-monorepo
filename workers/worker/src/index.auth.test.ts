import { beforeEach, describe, expect, it, vi } from "vitest";

const { authHandler } = vi.hoisted(() => ({
  authHandler: vi.fn(),
}));

vi.mock("./auth", () => ({
  createAuth: vi.fn(async () => ({
    api: { getSession: vi.fn().mockResolvedValue(null) },
    handler: authHandler,
  })),
}));

import { Hono } from "hono";
import { authCompatRoutes } from "./routes/auth-compat";
import { registerBetterAuthRoutes } from "./routes/better-auth";

const env = {
  DB: {} as D1Database,
  CF_VERSION_METADATA: { id: "test" },
} as unknown as Env;

function app() {
  const instance = new Hono<{ Bindings: Env; Variables: { userId: string } }>();
  instance.route("/api/auth", authCompatRoutes);
  registerBetterAuthRoutes(instance);
  return instance;
}

describe("mounted Better Auth compatibility routes", () => {
  beforeEach(() => {
    authHandler.mockReset();
  });

  it("delegates session requests to Better Auth", async () => {
    authHandler.mockResolvedValueOnce(new Response(JSON.stringify({ user: null }), {
      status: 200,
      headers: { "content-type": "application/json" },
    }));

    const request = new Request("https://api.fidexa.org/api/auth/get-session", {
      headers: {
        Authorization: "Bearer better-auth-session",
        Origin: "http://127.0.0.1:47823",
      },
    });
    const response = await app().fetch(request, env);

    expect(response.status).toBe(200);
    expect(authHandler).toHaveBeenCalledWith(request);
  });

  it("does not send the exact delete route through Better Auth", async () => {
    const response = await app().fetch(
      new Request("https://api.fidexa.org/api/auth/delete-user", {
        method: "POST",
        headers: { Authorization: "Bearer invalid" },
      }),
      env,
    );

    expect(response.status).toBe(401);
    expect(authHandler).not.toHaveBeenCalled();
  });
});

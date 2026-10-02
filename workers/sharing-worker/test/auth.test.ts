import { describe, expect, it, vi } from "vitest";
import { Effect } from "effect";
import { verifyAuth, verifyAuthAuthorizationEffect } from "../src/auth";
import { makeSharingWorkerLayer } from "../src/session-sharing-effect";

describe("verifyAuth", () => {
  it("returns user on valid session", async () => {
    const fetcher = vi.fn(async () =>
      new Response(JSON.stringify({ user: { id: "u_42", email: "x@y.z", name: "X" } }), { status: 200 }),
    );
    const out = await verifyAuth(
      { headers: new Headers({ authorization: "Bearer abc" }) } as Request,
      { AUTH_BASE_URL: "https://auth.example", fetcher } as any,
    );
    expect(out).toEqual({ userId: "u_42", email: "x@y.z", displayName: "X" });
    expect(fetcher).toHaveBeenCalledOnce();
  });
  it("throws on missing auth header", async () => {
    await expect(verifyAuth({ headers: new Headers() } as Request, { AUTH_BASE_URL: "x", fetcher: vi.fn() } as any))
      .rejects.toThrow(/missing/i);
  });
  it("throws on 401", async () => {
    const fetcher = vi.fn(async () => new Response("no", { status: 401 }));
    await expect(verifyAuth(
      { headers: new Headers({ authorization: "Bearer bad" }) } as Request,
      { AUTH_BASE_URL: "x", fetcher } as any,
    )).rejects.toThrow(/unauthorized/i);
  });

  describe("TEST_AUTH_ALLOWED shortcut", () => {
    it("decodes `userId--DisplayName` bearer without contacting auth", async () => {
      const fetcher = vi.fn();
      const out = await verifyAuth(
        { headers: new Headers({ authorization: "Bearer e2e-host--E2E_Host" }) } as Request,
        { AUTH_BASE_URL: "x", fetcher, TEST_AUTH_ALLOWED: "1" } as any,
      );
      expect(out.userId).toBe("e2e-host");
      expect(out.displayName).toBe("E2E Host");
      expect(fetcher).not.toHaveBeenCalled();
    });

    it("decodes display names with multiple words", async () => {
      const out = await verifyAuth(
        { headers: new Headers({ authorization: "Bearer u_42--Alice_Q_Bob" }) } as Request,
        { AUTH_BASE_URL: "x", fetcher: vi.fn(), TEST_AUTH_ALLOWED: "1" } as any,
      );
      expect(out.userId).toBe("u_42");
      expect(out.displayName).toBe("Alice Q Bob");
    });

    it("falls back to remote verify when bearer doesn't match the shortcut shape", async () => {
      const fetcher = vi.fn(async () =>
        new Response(JSON.stringify({ user: { id: "u", email: "e", name: "N" } }), { status: 200 }),
      );
      const out = await verifyAuth(
        { headers: new Headers({ authorization: "Bearer notashortcut" }) } as Request,
        { AUTH_BASE_URL: "x", fetcher, TEST_AUTH_ALLOWED: "1" } as any,
      );
      expect(out.userId).toBe("u");
      expect(fetcher).toHaveBeenCalledOnce();
    });
  });
});

describe("verifyAuthAuthorizationEffect", () => {
  async function rejectWith(status: number, body = "provider failure") {
    const correlationId = "076e9342-c595-4c6a-9caa-119640ce9303";
    const fetcher = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      expect(new Headers(init?.headers).get("x-rishi-correlation-id")).toBe(correlationId);
      return new Response(body, { status });
    });
    const layer = makeSharingWorkerLayer({ AUTH_BASE_URL: "https://api.example" }, fetcher);
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const result = await Effect.runPromise(Effect.either(Effect.provide(
        verifyAuthAuthorizationEffect("Bearer opaque-token", correlationId),
        layer,
      )));
      if (result._tag === "Right") throw new Error("expected identity verification to fail");
      return result.left;
    } finally {
      warn.mockRestore();
    }
  }

  it("keeps a real 401 as an authentication failure", async () => {
    expect(await rejectWith(401)).toMatchObject({
      code: "AUTH_REQUIRED", status: 401, upstreamStatus: 401,
    });
  });

  it("keeps a 403 as forbidden instead of prompting for sign-in", async () => {
    expect(await rejectWith(403)).toMatchObject({
      code: "FORBIDDEN", status: 403, upstreamStatus: 403,
    });
  });

  it("treats a missing auth-context route as a service deployment failure", async () => {
    expect(await rejectWith(404)).toMatchObject({
      code: "SERVICE_UNAVAILABLE", status: 503, upstreamStatus: 404,
    });
  });

  it("surfaces deleted accounts as terminal account errors", async () => {
    expect(await rejectWith(410)).toMatchObject({
      code: "ACCOUNT_DELETED", status: 410, upstreamStatus: 410,
    });
  });

  it("surfaces accounts being deleted as a terminal account-state error", async () => {
    expect(await rejectWith(423)).toMatchObject({
      code: "ACCOUNT_DELETION_IN_PROGRESS", status: 423, upstreamStatus: 423,
    });
  });

  it("retains upstream status when the auth provider returns a malformed success body", async () => {
    expect(await rejectWith(200, JSON.stringify({ user: null }))).toMatchObject({
      code: "INTERNAL_ERROR", status: 502, upstreamStatus: 200,
    });
  });
});

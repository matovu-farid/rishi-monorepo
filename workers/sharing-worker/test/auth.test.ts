import { describe, expect, it, vi } from "vitest";
import { verifyAuth } from "../src/auth";

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

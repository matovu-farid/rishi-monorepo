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
});

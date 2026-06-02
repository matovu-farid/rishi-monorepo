import { describe, expect, it, vi } from "vitest";
import { verifyAuthToken } from "../src/auth";

describe("verifyAuthToken (production path)", () => {
  it("returns user on 200 with valid body", async () => {
    const fetcher = vi.fn(async () => new Response(
      JSON.stringify({ user: { id: "u_99", email: "p@x.y", name: "Prod" } }),
      { status: 200 },
    ));
    const u = await verifyAuthToken("eyABC.xyz", { AUTH_BASE_URL: "https://auth.example", fetcher } as any);
    expect(u).toEqual({ userId: "u_99", email: "p@x.y", displayName: "Prod" });
    const call = fetcher.mock.calls[0]!;
    expect(call[1]?.headers).toMatchObject({ authorization: "Bearer eyABC.xyz" });
  });

  it("throws on non-200", async () => {
    const fetcher = vi.fn(async () => new Response("no", { status: 401 }));
    await expect(verifyAuthToken("bad", { AUTH_BASE_URL: "x", fetcher } as any))
      .rejects.toThrow(/unauthorized/i);
  });

  it("throws when body has no user", async () => {
    const fetcher = vi.fn(async () => new Response("{}", { status: 200 }));
    await expect(verifyAuthToken("ok", { AUTH_BASE_URL: "x", fetcher } as any))
      .rejects.toThrow(/unauthorized/i);
  });
});

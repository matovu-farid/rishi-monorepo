import { SELF, env } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";

// Mock auth to skip the Better Auth round-trip in tests.
beforeEach(() => {
  vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" });
});

const VALID_BODY = {
  bookContext: { bookId: "b_1", contentHash: "sha", format: "epub" },
  requiresApproval: true,
};

describe("POST /v1/sessions", () => {
  it("creates a session and returns ids + joinUrl", async () => {
    const res = await SELF.fetch("https://x/v1/sessions", {
      method: "POST",
      headers: { authorization: "Bearer test", "content-type": "application/json" },
      body: JSON.stringify(VALID_BODY),
    });
    expect(res.status).toBe(200);
    const body = await res.json() as any;
    expect(body.sessionId).toMatch(/^s_/);
    expect(typeof body.joinToken).toBe("string");
    expect(body.joinUrl).toContain("rishi://sharing/join");
    expect(body.wsUrl).toContain("/wss");
  });

  it("rejects malformed body", async () => {
    const res = await SELF.fetch("https://x/v1/sessions", {
      method: "POST",
      headers: { authorization: "Bearer test", "content-type": "application/json" },
      body: "{}",
    });
    expect(res.status).toBe(400);
  });
});

import { SELF } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";

beforeEach(() => {
  vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" });
});

async function createSession() {
  const r = await SELF.fetch("https://x/v1/sessions", {
    method: "POST",
    headers: { authorization: "Bearer t", "content-type": "application/json" },
    body: JSON.stringify({
      bookContext: { bookId: "b", contentHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", format: "epub" },
      requiresApproval: false,
    }),
  });
  return r.json() as Promise<{ sessionId: string; joinToken: string; wsUrl: string }>;
}

describe("POST /v1/sessions/:id/redeem", () => {
  it("returns session info on valid token", async () => {
    const { sessionId, joinToken } = await createSession();
    vi.stubGlobal("__TEST_AUTH__", { userId: "u_viewer", email: "v@x.y", displayName: "Viewer" });
    const r = await SELF.fetch(`https://x/v1/sessions/${sessionId}/redeem`, {
      method: "POST",
      headers: { authorization: "Bearer v", "content-type": "application/json" },
      body: JSON.stringify({ joinToken }),
    });
    expect(r.status).toBe(200);
    const body = await r.json() as any;
    expect(body.sessionId).toBe(sessionId);
    expect(body.bookContext.bookId).toBe("b");
    expect(body.requiresApproval).toBe(false);
    expect(body.hostProfile.displayName).toBe("Host");
    expect(body.wsUrl).toContain("/wss");
  });

  it("rejects mismatched sessionId in token", async () => {
    const { joinToken } = await createSession();
    const r = await SELF.fetch(`https://x/v1/sessions/s_wrong/redeem`, {
      method: "POST",
      headers: { authorization: "Bearer v", "content-type": "application/json" },
      body: JSON.stringify({ joinToken }),
    });
    expect(r.status).toBe(400);
  });

  it("404s when session does not exist", async () => {
    const r = await SELF.fetch(`https://x/v1/sessions/s_missing/redeem`, {
      method: "POST",
      headers: { authorization: "Bearer v", "content-type": "application/json" },
      body: JSON.stringify({ joinToken: "garbage" }),
    });
    expect([400, 404]).toContain(r.status);
  });
});

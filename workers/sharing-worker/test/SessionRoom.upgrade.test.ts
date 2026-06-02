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
  return r.json() as Promise<{ sessionId: string; wsUrl: string }>;
}

describe("WS upgrade", () => {
  it("rejects non-Upgrade requests", async () => {
    const { sessionId } = await createSession();
    const r = await SELF.fetch(`https://x/v1/sessions/${sessionId}/wss`);
    expect(r.status).toBe(426);
  });
  it("rejects bad subprotocol", async () => {
    const { sessionId } = await createSession();
    const r = await SELF.fetch(`https://x/v1/sessions/${sessionId}/wss`, {
      headers: { upgrade: "websocket", "sec-websocket-protocol": "wrong" },
    });
    expect(r.status).toBe(400);
  });
  it("accepts with rishi.sharing.v1 + jwt.<base64url(token)>", async () => {
    const { sessionId } = await createSession();
    // "test" → "dGVzdA" (base64url, no padding). The bearer is encoded so any
    // token shape stays valid as an RFC 6455 subprotocol token.
    const r = await SELF.fetch(`https://x/v1/sessions/${sessionId}/wss`, {
      headers: {
        upgrade: "websocket",
        "sec-websocket-protocol": "rishi.sharing.v1, jwt.dGVzdA",
      },
    });
    expect(r.status).toBe(101);
  });
});

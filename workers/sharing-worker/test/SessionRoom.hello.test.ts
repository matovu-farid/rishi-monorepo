import { SELF } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { openWs, send, nextMsg } from "./helpers/wsClient";

async function createSession(requiresApproval = false) {
  const r = await SELF.fetch("https://x/v1/sessions", {
    method: "POST",
    headers: { authorization: "Bearer t", "content-type": "application/json" },
    body: JSON.stringify({
      bookContext: { bookId: "b", contentHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", format: "epub" },
      requiresApproval,
    }),
  });
  return r.json() as Promise<{ sessionId: string; wsUrl: string }>;
}

describe("hello/welcome", () => {
  beforeEach(() => {
    vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" });
  });

  it("host gets welcome + roster on hello", async () => {
    const { wsUrl } = await createSession();
    // The DO test bypass: pass user info via subprotocol jwt.<userId>--<DisplayName>
    // (double-dash separator keeps the bearer valid as an RFC 6455 subprotocol)
    const ws = await openWs(wsUrl, "u_host--Host");
    send(ws, { t: "hello", hasBookFile: true });
    const welcome = await nextMsg(ws, (m) => m.t === "welcome");
    expect(welcome.you).toBe("u_host");
    expect(welcome.role).toBe("host");
    expect(welcome.sharerId).toBe("u_host");
    const roster = await nextMsg(ws, (m) => m.t === "roster");
    expect(roster.participants.length).toBe(1);
  });
});

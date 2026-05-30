import { SELF } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { openWs, send, nextMsg } from "./helpers/wsClient";

beforeEach(() => {
  vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" });
});

async function created(requiresApproval = false) {
  const r = await SELF.fetch("https://x/v1/sessions", {
    method: "POST",
    headers: { authorization: "Bearer t", "content-type": "application/json" },
    body: JSON.stringify({
      bookContext: { bookId: "b", contentHash: "h", format: "epub" },
      requiresApproval,
    }),
  });
  return r.json() as any;
}

describe("roster lifecycle", () => {
  it("emits peer.joined when a new viewer connects", async () => {
    const c = await created();
    const host = await openWs(c.wsUrl, "u_host:Host");
    send(host, { t: "hello", hasBookFile: true });
    await nextMsg(host, (m) => m.t === "welcome");
    await nextMsg(host, (m) => m.t === "roster");
    const viewer = await openWs(c.wsUrl, "u_v:Viewer");
    send(viewer, { t: "hello", hasBookFile: true });
    const joined = await nextMsg(host, (m) => m.t === "peer.joined");
    expect(joined.userId).toBe("u_v");
  });

  it("emits peer.left { left } on explicit leave", async () => {
    const c = await created();
    const host = await openWs(c.wsUrl, "u_host:Host");
    send(host, { t: "hello", hasBookFile: true });
    await nextMsg(host, (m) => m.t === "welcome");
    await nextMsg(host, (m) => m.t === "roster");
    const v = await openWs(c.wsUrl, "u_v:V");
    send(v, { t: "hello", hasBookFile: true });
    await nextMsg(host, (m) => m.t === "peer.joined");
    send(v, { t: "leave" });
    const left = await nextMsg(host, (m) => m.t === "peer.left");
    expect(left.reason).toBe("left");
  });

  it("rejects 6th joiner with cap_reached", async () => {
    const c = await created();
    const host = await openWs(c.wsUrl, "u_host:Host");
    send(host, { t: "hello", hasBookFile: true });
    await nextMsg(host, (m) => m.t === "welcome");
    await nextMsg(host, (m) => m.t === "roster");
    for (let i = 0; i < 4; i++) {
      const v = await openWs(c.wsUrl, `u_${i}:V${i}`);
      send(v, { t: "hello", hasBookFile: true });
      await nextMsg(v, (m) => m.t === "welcome");
    }
    const sixth = await openWs(c.wsUrl, "u_x:X");
    send(sixth, { t: "hello", hasBookFile: true });
    const err = await nextMsg(sixth, (m) => m.t === "error");
    expect(err.code).toBe("cap_reached");
  });
});

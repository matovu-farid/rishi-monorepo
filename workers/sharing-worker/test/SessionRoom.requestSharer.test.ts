import { SELF } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { openWs, send, nextMsg } from "./helpers/wsClient";

beforeEach(() => vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" }));

async function pair() {
  const c = await SELF.fetch("https://x/v1/sessions", {
    method: "POST", headers: { authorization: "Bearer t", "content-type": "application/json" },
    body: JSON.stringify({ bookContext: { bookId: "b", contentHash: "h", format: "epub" }, requiresApproval: false }),
  }).then(r => r.json() as any);
  const host = await openWs(c.wsUrl, "u_host:Host");
  send(host, { t: "hello", hasBookFile: true });
  await nextMsg(host, m => m.t === "welcome");
  await nextMsg(host, m => m.t === "roster");
  const viewer = await openWs(c.wsUrl, "u_v:V");
  send(viewer, { t: "hello", hasBookFile: false });
  await nextMsg(viewer, m => m.t === "welcome");
  await nextMsg(host, m => m.t === "peer.joined");
  return { host, viewer };
}

describe("request.sharer & has.book", () => {
  it("forwards request.sharer to host as peer.updated request flag", async () => {
    const { host, viewer } = await pair();
    send(viewer, { t: "request.sharer" });
    const m = await nextMsg(host, x => x.t === "peer.updated" && x.userId === "u_v");
    expect(m.patch.requestingSharer).toBe(true);
  });
  it("rate-limits repeated requests", async () => {
    const { viewer } = await pair();
    send(viewer, { t: "request.sharer" });
    send(viewer, { t: "request.sharer" });
    const err = await nextMsg(viewer, m => m.t === "error");
    expect(err.code).toBe("rate_limited");
  });
  it("has.book toggles participant flag and broadcasts patch", async () => {
    const { host, viewer } = await pair();
    send(viewer, { t: "has.book", value: true });
    const m = await nextMsg(host, x => x.t === "peer.updated" && x.userId === "u_v");
    expect(m.patch.hasBookFile).toBe(true);
  });
});

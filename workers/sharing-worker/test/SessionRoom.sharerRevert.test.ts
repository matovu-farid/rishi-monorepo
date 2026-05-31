import { SELF } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { openWs, send, nextMsg } from "./helpers/wsClient";

beforeEach(() => vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" }));

describe("sharer revert", () => {
  it("on non-host sharer drop, sharer reverts to host", async () => {
    const c = await SELF.fetch("https://x/v1/sessions", {
      method: "POST", headers: { authorization: "Bearer t", "content-type": "application/json" },
      body: JSON.stringify({ bookContext: { bookId: "b", contentHash: "h", format: "epub" }, requiresApproval: false }),
    }).then(r => r.json() as any);
    const host = await openWs(c.wsUrl, "u_host--Host");
    send(host, { t: "hello", hasBookFile: true });
    await nextMsg(host, m => m.t === "welcome");
    await nextMsg(host, m => m.t === "roster");
    const viewer = await openWs(c.wsUrl, "u_v--V");
    send(viewer, { t: "hello", hasBookFile: true });
    await nextMsg(viewer, m => m.t === "welcome");
    await nextMsg(host, m => m.t === "peer.joined");
    send(host, { t: "pass.sharer", to: "u_v" });
    await nextMsg(host, m => m.t === "role.transferred" && m.newSharerId === "u_v");
    send(viewer, { t: "leave" });
    // Expect: peer.left for u_v AND role.transferred back to u_host
    const seen: string[] = [];
    while (seen.length < 2) {
      const m = await nextMsg(host, x => x.t === "peer.left" || x.t === "role.transferred");
      seen.push(m.t);
    }
    expect(seen).toContain("peer.left");
    expect(seen).toContain("role.transferred");
  });
});

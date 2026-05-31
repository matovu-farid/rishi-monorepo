import { SELF } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { openWs, send, nextMsg } from "./helpers/wsClient";

beforeEach(() => vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" }));

describe("end-to-end happy path", () => {
  it("create → join → SDP exchange → pass → mute → leave → revert", async () => {
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

    // SDP exchange
    send(host, { t: "sdp.offer", to: "u_v", sdp: "v=0" });
    await nextMsg(viewer, m => m.t === "sdp.offer");
    send(viewer, { t: "sdp.answer", to: "u_host", sdp: "v=0" });
    await nextMsg(host, m => m.t === "sdp.answer");

    // Pass sharer
    send(host, { t: "pass.sharer", to: "u_v" });
    await nextMsg(viewer, m => m.t === "role.transferred" && m.newSharerId === "u_v");

    // Host mutes the new sharer
    send(host, { t: "mute.peer", userId: "u_v", muted: true });
    const mute = await nextMsg(viewer, m => m.t === "peer.updated" && m.patch.micState === "host-muted");
    expect(mute.userId).toBe("u_v");

    // Viewer leaves; sharer reverts to host
    send(viewer, { t: "leave" });
    const left = await nextMsg(host, m => m.t === "peer.left");
    expect(left.userId).toBe("u_v");
    const reverted = await nextMsg(host, m => m.t === "role.transferred");
    expect(reverted.newSharerId).toBe("u_host");
  });
});

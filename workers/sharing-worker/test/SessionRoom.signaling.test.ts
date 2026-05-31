import { SELF } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { openWs, send, nextMsg } from "./helpers/wsClient";

beforeEach(() => {
  vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" });
});

async function joinPair() {
  const created = await SELF.fetch("https://x/v1/sessions", {
    method: "POST",
    headers: { authorization: "Bearer t", "content-type": "application/json" },
    body: JSON.stringify({
      bookContext: { bookId: "b", contentHash: "h", format: "epub" },
      requiresApproval: false,
    }),
  }).then((r) => r.json() as any);
  const host = await openWs(created.wsUrl, "u_host--Host");
  send(host, { t: "hello", hasBookFile: true });
  await nextMsg(host, (m) => m.t === "welcome");
  await nextMsg(host, (m) => m.t === "roster");
  const viewer = await openWs(created.wsUrl, "u_viewer--Viewer");
  send(viewer, { t: "hello", hasBookFile: true });
  await nextMsg(viewer, (m) => m.t === "welcome");
  await nextMsg(host, (m) => m.t === "roster" && m.participants.length === 2);
  return { host, viewer };
}

describe("signaling relay", () => {
  it("forwards sdp.offer with from set", async () => {
    const { host, viewer } = await joinPair();
    send(host, { t: "sdp.offer", to: "u_viewer", sdp: "v=0" });
    const got = await nextMsg(viewer, (m) => m.t === "sdp.offer");
    expect(got.from).toBe("u_host");
    expect(got.sdp).toBe("v=0");
  });
  it("forwards ice candidates", async () => {
    const { host, viewer } = await joinPair();
    send(viewer, { t: "ice", to: "u_host", candidate: { candidate: "x" } });
    const got = await nextMsg(host, (m) => m.t === "ice");
    expect(got.from).toBe("u_viewer");
  });
  it("drops relays to unknown peers", async () => {
    const { host } = await joinPair();
    send(host, { t: "sdp.offer", to: "u_ghost", sdp: "x" });
    const err = await nextMsg(host, (m) => m.t === "error");
    expect(err.code).toBe("no_such_peer");
  });
});

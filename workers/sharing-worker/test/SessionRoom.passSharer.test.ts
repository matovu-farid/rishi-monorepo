import { SELF } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { openWs, send, nextMsg } from "./helpers/wsClient";

beforeEach(() => vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" }));

async function pair() {
  const c = await SELF.fetch("https://x/v1/sessions", {
    method: "POST", headers: { authorization: "Bearer t", "content-type": "application/json" },
    body: JSON.stringify({ bookContext: { bookId: "b", contentHash: "h", format: "epub" }, requiresApproval: false }),
  }).then((r) => r.json() as any);
  const host = await openWs(c.wsUrl, "u_host--Host");
  send(host, { t: "hello", hasBookFile: true });
  await nextMsg(host, (m) => m.t === "welcome");
  await nextMsg(host, (m) => m.t === "roster");
  const viewer = await openWs(c.wsUrl, "u_v--V");
  send(viewer, { t: "hello", hasBookFile: true });
  await nextMsg(viewer, (m) => m.t === "welcome");
  await nextMsg(host, (m) => m.t === "peer.joined");
  return { host, viewer };
}

describe("pass.sharer", () => {
  it("transfers role when host requests", async () => {
    const { host, viewer } = await pair();
    send(host, { t: "pass.sharer", to: "u_v" });
    const m = await nextMsg(viewer, (x) => x.t === "role.transferred");
    expect(m.newSharerId).toBe("u_v");
    const h = await nextMsg(host, (x) => x.t === "role.transferred");
    expect(h.newSharerId).toBe("u_v");
  });
  it("rejects when non-host attempts", async () => {
    const { host, viewer } = await pair();
    send(viewer, { t: "pass.sharer", to: "u_host" });
    const err = await nextMsg(viewer, (x) => x.t === "error");
    expect(err.code).toBe("forbidden");
  });
  it("rejects when target is reconnecting (not currently connected)", async () => {
    // The viewer goes offline mid-session → state.participants[viewer] is
    // still present (within the reconnect grace window) but their WS is
    // gone. Passing the sharer role there would silently mute the
    // session, so the worker must surface `target_offline`.
    const { host, viewer } = await pair();
    // 1001 = "going away" — a valid client-initiated close that the
    // RFC 6455 stack accepts. (1006 is reserved for abnormal close and
    // cannot be sent explicitly.) The worker's `webSocketClose` handler
    // treats anything but code 1000 as a non-graceful drop → flips
    // connectionState to 'reconnecting' rather than removing the peer.
    viewer.close(1001, "network blip");
    // Allow the close handler to flip the participant to reconnecting.
    await nextMsg(host, (m) => m.t === "peer.updated" && m.patch?.connectionState === "reconnecting");
    send(host, { t: "pass.sharer", to: "u_v" });
    const err = await nextMsg(host, (m) => m.t === "error");
    expect(err.code).toBe("target_offline");
  });

  it("rejects when target lacks book", async () => {
    const c = await SELF.fetch("https://x/v1/sessions", {
      method: "POST", headers: { authorization: "Bearer t", "content-type": "application/json" },
      body: JSON.stringify({ bookContext: { bookId: "b", contentHash: "h", format: "epub" }, requiresApproval: false }),
    }).then((r) => r.json() as any);
    const host = await openWs(c.wsUrl, "u_host--Host");
    send(host, { t: "hello", hasBookFile: true });
    await nextMsg(host, (m) => m.t === "welcome");
    await nextMsg(host, (m) => m.t === "roster");
    const viewer = await openWs(c.wsUrl, "u_v--V");
    send(viewer, { t: "hello", hasBookFile: false });
    await nextMsg(host, (m) => m.t === "peer.joined");
    send(host, { t: "pass.sharer", to: "u_v" });
    const err = await nextMsg(host, (m) => m.t === "error");
    expect(err.code).toBe("target_lacks_book");
  });
});

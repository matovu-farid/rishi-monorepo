import { SELF } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { openWs, send, nextMsg } from "./helpers/wsClient";

beforeEach(() => {
  vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" });
});

async function pair() {
  const c = await SELF.fetch("https://x/v1/sessions", {
    method: "POST",
    headers: { authorization: "Bearer t", "content-type": "application/json" },
    body: JSON.stringify({
      bookContext: { bookId: "b", contentHash: "h", format: "epub" },
      requiresApproval: false,
    }),
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

describe("moderation", () => {
  it("host mutes a peer", async () => {
    const { host, viewer } = await pair();
    send(host, { t: "mute.peer", userId: "u_v", muted: true });
    const m = await nextMsg(viewer, (x) => x.t === "peer.updated" && x.patch.micState === "host-muted");
    expect(m.userId).toBe("u_v");
  });
  it("host kicks a peer; peer gets 'kicked' message", async () => {
    const { host, viewer } = await pair();
    send(host, { t: "kick.peer", userId: "u_v" });
    const k = await nextMsg(viewer, (m) => m.t === "kicked");
    expect(k.reason).toBeDefined();
  });
  it("non-host kick is forbidden", async () => {
    const { viewer } = await pair();
    send(viewer, { t: "kick.peer", userId: "u_host" });
    const err = await nextMsg(viewer, (m) => m.t === "error");
    expect(err.code).toBe("forbidden");
  });
});

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

describe("data.channel.relay", () => {
  it("forwards relay to the target peer stamped with from=sender", async () => {
    const { host, viewer } = await joinPair();
    send(host, {
      t: "data.channel.relay",
      to: "u_viewer",
      channel: "files",
      payload: "aGVsbG8=", // "hello"
    });
    const got = await nextMsg(viewer, (m) => m.t === "data.channel.relay");
    expect(got.from).toBe("u_host");
    expect(got.channel).toBe("files");
    expect(got.payload).toBe("aGVsbG8=");
  });

  it("returns no_such_peer when target is not connected", async () => {
    const { host } = await joinPair();
    send(host, {
      t: "data.channel.relay",
      to: "u_ghost",
      channel: "sync",
      payload: "x",
    });
    const err = await nextMsg(host, (m) => m.t === "error");
    expect(err.code).toBe("no_such_peer");
  });
});

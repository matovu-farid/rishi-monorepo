import { SELF } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { openWs, send, nextMsg } from "./helpers/wsClient";
import { isDataChannelRelayAllowed } from "../src/SessionRoom";

beforeEach(() => {
  vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" });
});

async function joinPair() {
  const created = await SELF.fetch("https://x/v1/sessions", {
    method: "POST",
    headers: { authorization: "Bearer t", "content-type": "application/json" },
    body: JSON.stringify({
      bookContext: { bookId: "b", contentHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", format: "epub" },
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

describe("isDataChannelRelayAllowed gate", () => {
  // Production hardening: `data.channel.relay` is an E2E-only bridge for
  // the fake RTC adapter. The worker MUST reject it when the test flag is
  // unset so a production client can't (a) bypass the RTCDataChannel
  // path or (b) starve the per-user RateBucket shared with sync.frame.
  it("rejects when TEST_AUTH_ALLOWED is unset", () => {
    expect(isDataChannelRelayAllowed(undefined)).toBe(false);
  });
  it("rejects when TEST_AUTH_ALLOWED is any value other than '1'", () => {
    expect(isDataChannelRelayAllowed("0")).toBe(false);
    expect(isDataChannelRelayAllowed("true")).toBe(false);
    expect(isDataChannelRelayAllowed("")).toBe(false);
  });
  it("allows when TEST_AUTH_ALLOWED is '1'", () => {
    expect(isDataChannelRelayAllowed("1")).toBe(true);
  });
});

import { SELF } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { openWs, send, nextMsg } from "./helpers/wsClient";

beforeEach(() => vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" }));

async function createApproved() {
  const c = await SELF.fetch("https://x/v1/sessions", {
    method: "POST", headers: { authorization: "Bearer t", "content-type": "application/json" },
    body: JSON.stringify({ bookContext: { bookId: "b", contentHash: "h", format: "epub" }, requiresApproval: true }),
  }).then(r => r.json() as any);
  return c;
}

describe("approval queue", () => {
  it("viewer waits, host gets join.requested, approval lets them in", async () => {
    const c = await createApproved();
    const host = await openWs(c.wsUrl, "u_host:Host");
    send(host, { t: "hello", hasBookFile: true });
    await nextMsg(host, m => m.t === "welcome");
    await nextMsg(host, m => m.t === "roster");
    const viewer = await openWs(c.wsUrl, "u_v:V");
    send(viewer, { t: "hello", hasBookFile: true });
    const req = await nextMsg(host, m => m.t === "join.requested");
    expect(req.userId).toBe("u_v");
    send(host, { t: "approve.join", userId: "u_v" });
    const result = await nextMsg(viewer, m => m.t === "approval.result");
    expect(result.approved).toBe(true);
    const welcome = await nextMsg(viewer, m => m.t === "welcome");
    expect(welcome.you).toBe("u_v");
  });

  it("reject closes the viewer with approval.result { approved: false }", async () => {
    const c = await createApproved();
    const host = await openWs(c.wsUrl, "u_host:Host");
    send(host, { t: "hello", hasBookFile: true });
    await nextMsg(host, m => m.t === "welcome");
    await nextMsg(host, m => m.t === "roster");
    const viewer = await openWs(c.wsUrl, "u_v:V");
    send(viewer, { t: "hello", hasBookFile: true });
    await nextMsg(host, m => m.t === "join.requested");
    send(host, { t: "reject.join", userId: "u_v" });
    const r = await nextMsg(viewer, m => m.t === "approval.result");
    expect(r.approved).toBe(false);
  });
});

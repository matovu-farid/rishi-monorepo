import { SELF, env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { openWs, send, nextMsg } from "./helpers/wsClient";

beforeEach(() => vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" }));

async function viewerInSession() {
  const c = await SELF.fetch("https://x/v1/sessions", {
    method: "POST", headers: { authorization: "Bearer t", "content-type": "application/json" },
    body: JSON.stringify({ bookContext: { bookId: "b", contentHash: "h", format: "epub" }, requiresApproval: false }),
  }).then(r => r.json() as any);
  const host = await openWs(c.wsUrl, "u_host--Host");
  send(host, { t: "hello", hasBookFile: true });
  const welcome = await nextMsg(host, m => m.t === "welcome");
  await nextMsg(host, m => m.t === "roster");
  const viewer = await openWs(c.wsUrl, "u_v--V");
  send(viewer, { t: "hello", hasBookFile: true });
  await nextMsg(viewer, m => m.t === "welcome");
  await nextMsg(host, m => m.t === "peer.joined");
  return { c, host, viewer, hostRt: welcome.reconnectToken };
}

describe("host grace", () => {
  it("host close → host.suspended broadcast", async () => {
    const { host, viewer } = await viewerInSession();
    host.close(3000, "lost");
    const m = await nextMsg(viewer, x => x.t === "host.suspended");
    expect(typeof m.until).toBe("number");
  });

  it("host reconnects → host.resumed; sharer NOT auto-reclaimed", async () => {
    const { c, host, viewer, hostRt } = await viewerInSession();
    // Pass sharer to viewer first
    send(host, { t: "pass.sharer", to: "u_v" });
    await nextMsg(host, m => m.t === "role.transferred");
    host.close(3000, "lost");
    await nextMsg(viewer, m => m.t === "host.suspended");
    // Pre-register the viewer's host.resumed listener BEFORE triggering the reconnect.
    const resumedP = nextMsg(viewer, m => m.t === "host.resumed");
    const host2 = await openWs(c.wsUrl, "u_host--Host", hostRt);
    send(host2, { t: "hello", hasBookFile: true });
    await nextMsg(host2, m => m.t === "welcome");
    const resumed = await resumedP;
    expect(resumed).toBeTruthy();
    // sharer is still u_v
    const id = (env.SESSION_ROOM as DurableObjectNamespace).idFromName(c.sessionId);
    const stub = (env.SESSION_ROOM as DurableObjectNamespace).get(id);
    const state = await runInDurableObject(stub, async (_inst, ctx) => ctx.storage.get("state"));
    expect((state as any).sharerUserId).toBe("u_v");
  });

  it("after host grace expires → session.ended { host_grace_expired }", async () => {
    const { c, host, viewer } = await viewerInSession();
    host.close(3000, "lost");
    await nextMsg(viewer, m => m.t === "host.suspended");
    const id = (env.SESSION_ROOM as DurableObjectNamespace).idFromName(c.sessionId);
    const stub = (env.SESSION_ROOM as DurableObjectNamespace).get(id);
    await runInDurableObject(stub, async (_inst, ctx) => {
      const state = (await ctx.storage.get("state")) as any;
      state.hostSuspendedUntil = Date.now() - 1_000;
      await ctx.storage.put("state", state);
      await ctx.storage.setAlarm(Date.now());
    });
    const ended = await nextMsg(viewer, m => m.t === "session.ended");
    expect(ended.reason).toBe("host_grace_expired");
  });
});

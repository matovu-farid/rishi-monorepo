import { SELF, env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { openWs, send, nextMsg } from "./helpers/wsClient";

beforeEach(() => vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" }));

describe("approval timeout", () => {
  it("after the alarm fires, viewer gets approval.result rejected", async () => {
    const c = await SELF.fetch("https://x/v1/sessions", {
      method: "POST", headers: { authorization: "Bearer t", "content-type": "application/json" },
      body: JSON.stringify({ bookContext: { bookId: "b", contentHash: "h", format: "epub" }, requiresApproval: true }),
    }).then(r => r.json() as any);
    const host = await openWs(c.wsUrl, "u_host--Host");
    send(host, { t: "hello", hasBookFile: true });
    await nextMsg(host, m => m.t === "welcome");
    await nextMsg(host, m => m.t === "roster");
    const viewer = await openWs(c.wsUrl, "u_v--V");
    send(viewer, { t: "hello", hasBookFile: true });
    await nextMsg(host, m => m.t === "join.requested");

    // Simulate 120s of wait by aging the pending joiner, then trigger the alarm.
    const id = (env.SESSION_ROOM as DurableObjectNamespace).idFromName(c.sessionId);
    const stub = (env.SESSION_ROOM as DurableObjectNamespace).get(id);
    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = (await ctx.storage.get("state")) as any;
      for (const k of Object.keys(state.pendingJoiners)) {
        state.pendingJoiners[k].requestedAt = Date.now() - 200_000;
      }
      await ctx.storage.put("state", state);
      await ctx.storage.setAlarm(Date.now());
    });

    const r = await nextMsg(viewer, m => m.t === "approval.result");
    expect(r.approved).toBe(false);
    expect(r.reason).toMatch(/timeout/i);
  });
});

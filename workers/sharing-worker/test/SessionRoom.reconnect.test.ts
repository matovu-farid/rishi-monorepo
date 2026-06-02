import { SELF, env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { openWs, send, nextMsg } from "./helpers/wsClient";

beforeEach(() => vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" }));

async function created() {
  return SELF.fetch("https://x/v1/sessions", {
    method: "POST",
    headers: { authorization: "Bearer t", "content-type": "application/json" },
    body: JSON.stringify({ bookContext: { bookId: "b", contentHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", format: "epub" }, requiresApproval: false }),
  }).then(r => r.json() as any);
}

describe("reconnect", () => {
  it("dropped viewer's slot is held; rejoin with reconnectToken restores them", async () => {
    const c = await created();
    const host = await openWs(c.wsUrl, "u_host--Host");
    send(host, { t: "hello", hasBookFile: true });
    await nextMsg(host, m => m.t === "welcome");
    await nextMsg(host, m => m.t === "roster");
    const v1 = await openWs(c.wsUrl, "u_v--V");
    send(v1, { t: "hello", hasBookFile: true });
    const welcome = await nextMsg(v1, m => m.t === "welcome");
    const rt = welcome.reconnectToken;
    v1.close(3000, "lost");
    // Host should see peer.updated connectionState=reconnecting, NOT peer.left
    const upd = await nextMsg(host, m => m.t === "peer.updated" && m.userId === "u_v");
    expect(upd.patch.connectionState).toBe("reconnecting");
    // Rejoin with reconnect token
    const v2 = await openWs(c.wsUrl, "u_v--V", rt);
    send(v2, { t: "hello", hasBookFile: true });
    await nextMsg(v2, m => m.t === "welcome");
    const resumed = await nextMsg(host, m => m.t === "peer.updated" && m.userId === "u_v" && m.patch.connectionState === "connected");
    expect(resumed.patch.connectionState).toBe("connected");
  });

  it("slot expires after VIEWER_SLOT_GRACE_MS — peer.left { dropped }", async () => {
    const c = await created();
    const host = await openWs(c.wsUrl, "u_host--Host");
    send(host, { t: "hello", hasBookFile: true });
    await nextMsg(host, m => m.t === "welcome");
    await nextMsg(host, m => m.t === "roster");
    const v = await openWs(c.wsUrl, "u_v--V");
    send(v, { t: "hello", hasBookFile: true });
    await nextMsg(v, m => m.t === "welcome");
    v.close(3000, "lost");
    await nextMsg(host, m => m.t === "peer.updated");

    // Age the reservation, then trigger alarm.
    const id = (env.SESSION_ROOM as DurableObjectNamespace).idFromName(c.sessionId);
    const stub = (env.SESSION_ROOM as DurableObjectNamespace).get(id);
    await runInDurableObject(stub, async (_inst, ctx) => {
      const state = (await ctx.storage.get("state")) as any;
      for (const k of Object.keys(state.participants)) {
        if (state.participants[k].reservedUntil) state.participants[k].reservedUntil = Date.now() - 1_000;
      }
      await ctx.storage.put("state", state);
      await ctx.storage.setAlarm(Date.now());
    });

    const left = await nextMsg(host, m => m.t === "peer.left");
    expect(left.reason).toBe("dropped");
  });
});

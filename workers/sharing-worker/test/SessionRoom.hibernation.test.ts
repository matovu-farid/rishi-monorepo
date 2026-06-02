import { SELF, env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { openWs, send, nextMsg } from "./helpers/wsClient";

beforeEach(() => vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" }));

describe("hibernation rehydration", () => {
  it("approve.join still admits the pending viewer after in-memory state was cleared (simulated hibernation)", async () => {
    const c = await SELF.fetch("https://x/v1/sessions", {
      method: "POST", headers: { authorization: "Bearer t", "content-type": "application/json" },
      body: JSON.stringify({ bookContext: { bookId: "b", contentHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", format: "epub" }, requiresApproval: true }),
    }).then(r => r.json() as any);

    const host = await openWs(c.wsUrl, "u_host--Host");
    send(host, { t: "hello", hasBookFile: true });
    await nextMsg(host, m => m.t === "welcome");
    await nextMsg(host, m => m.t === "roster");

    const viewer = await openWs(c.wsUrl, "u_v--V");
    send(viewer, { t: "hello", hasBookFile: true });
    await nextMsg(host, m => m.t === "join.requested");

    // Simulate hibernation: wipe the in-memory pendingSockets map. The DO
    // would normally re-instantiate on wake; we approximate by clearing the
    // map directly. Real hibernation also discards `lastRequestSharer` and
    // `frameBuckets`; this test focuses on the pendingSockets path because
    // that's the one with observable correctness failure.
    const id = (env.SESSION_ROOM as DurableObjectNamespace).idFromName(c.sessionId);
    const stub = (env.SESSION_ROOM as DurableObjectNamespace).get(id);
    await runInDurableObject(stub, async (instance) => {
      const room = instance as any;
      room.pendingSockets.clear();
      room._pendingHydrated = false;
    });

    // Host approves; without rehydration the pending viewer would be silently
    // dropped (delete from state.pendingJoiners but never sent approval.result).
    send(host, { t: "approve.join", userId: "u_v" });
    const result = await nextMsg(viewer, m => m.t === "approval.result");
    expect(result.approved).toBe(true);
    const welcome = await nextMsg(viewer, m => m.t === "welcome");
    expect(welcome.you).toBe("u_v");
  });

  it("reject.join still notifies the pending viewer after simulated hibernation", async () => {
    const c = await SELF.fetch("https://x/v1/sessions", {
      method: "POST", headers: { authorization: "Bearer t", "content-type": "application/json" },
      body: JSON.stringify({ bookContext: { bookId: "b", contentHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", format: "epub" }, requiresApproval: true }),
    }).then(r => r.json() as any);

    const host = await openWs(c.wsUrl, "u_host--Host");
    send(host, { t: "hello", hasBookFile: true });
    await nextMsg(host, m => m.t === "welcome");
    await nextMsg(host, m => m.t === "roster");

    const viewer = await openWs(c.wsUrl, "u_v--V");
    send(viewer, { t: "hello", hasBookFile: false });
    await nextMsg(host, m => m.t === "join.requested");

    const id = (env.SESSION_ROOM as DurableObjectNamespace).idFromName(c.sessionId);
    const stub = (env.SESSION_ROOM as DurableObjectNamespace).get(id);
    await runInDurableObject(stub, async (instance) => {
      const room = instance as any;
      room.pendingSockets.clear();
      room._pendingHydrated = false;
    });

    send(host, { t: "reject.join", userId: "u_v" });
    const r = await nextMsg(viewer, m => m.t === "approval.result");
    expect(r.approved).toBe(false);
  });
});

import { SELF, env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";

beforeEach(() => vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" }));

describe("session cleanup", () => {
  it("purges DO storage when alarm fires while status='ended'", async () => {
    const c = await SELF.fetch("https://x/v1/sessions", {
      method: "POST", headers: { authorization: "Bearer t", "content-type": "application/json" },
      body: JSON.stringify({ bookContext: { bookId: "b", contentHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", format: "epub" }, requiresApproval: false }),
    }).then(r => r.json() as any);
    const id = (env.SESSION_ROOM as DurableObjectNamespace).idFromName(c.sessionId);
    const stub = (env.SESSION_ROOM as DurableObjectNamespace).get(id);
    await runInDurableObject(stub, async (inst, ctx) => {
      const s = (await ctx.storage.get("state")) as any;
      s.status = "ended";
      await ctx.storage.put("state", s);
      await (inst as any).alarm();
      const after = await ctx.storage.get("state");
      expect(after).toBeUndefined();
    });
  });
});

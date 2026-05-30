import { describe, expect, it } from "vitest";
import { sign, verify } from "../src/hmac";

const SECRET = "test-secret";

describe("hmac", () => {
  it("round-trips a payload", async () => {
    const payload = { sessionId: "s_1", userId: "u_1", reservedUntil: 999 };
    const token = await sign(payload, SECRET);
    const back = await verify<typeof payload>(token, SECRET);
    expect(back).toEqual(payload);
  });
  it("rejects a tampered payload", async () => {
    const token = await sign({ a: 1 }, SECRET);
    const [headerB64, payloadB64, sigB64] = token.split(".");
    const tampered = `${headerB64}.${btoa(JSON.stringify({ a: 2 }))}.${sigB64}`;
    await expect(verify(tampered, SECRET)).rejects.toThrow(/invalid/i);
  });
  it("rejects a wrong secret", async () => {
    const token = await sign({ a: 1 }, SECRET);
    await expect(verify(token, "other")).rejects.toThrow(/invalid/i);
  });
});

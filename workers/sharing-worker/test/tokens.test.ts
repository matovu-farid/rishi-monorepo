import { describe, expect, it } from "vitest";
import { issueJoinToken, verifyJoinToken, issueReconnectToken, verifyReconnectToken } from "../src/tokens";

const SECRET = "t";

describe("joinToken", () => {
  it("round-trips and exposes sessionId", async () => {
    const { token, payload } = await issueJoinToken({ sessionId: "s_1", ttlMs: 60_000 }, SECRET);
    const v = await verifyJoinToken(token, SECRET);
    expect(v.sessionId).toBe("s_1");
    expect(v.expiresAt).toBe(payload.expiresAt);
  });
  it("rejects expired", async () => {
    const { token } = await issueJoinToken({ sessionId: "s_1", ttlMs: -1 }, SECRET);
    await expect(verifyJoinToken(token, SECRET)).rejects.toThrow(/expired/);
  });
});

describe("reconnectToken", () => {
  it("round-trips", async () => {
    const t = await issueReconnectToken({ sessionId: "s_1", userId: "u_1", reservedUntil: Date.now() + 30_000 }, SECRET);
    const v = await verifyReconnectToken(t, SECRET);
    expect(v.userId).toBe("u_1");
  });
  it("rejects past-reservedUntil", async () => {
    const t = await issueReconnectToken({ sessionId: "s_1", userId: "u_1", reservedUntil: Date.now() - 1_000 }, SECRET);
    await expect(verifyReconnectToken(t, SECRET)).rejects.toThrow(/expired/);
  });
});

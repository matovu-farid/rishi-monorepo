import { describe, expect, it } from "vitest";
import { ClientMsg, ServerMsg } from "../src/schemas";

describe("ClientMsg schema", () => {
  it("accepts a valid hello", () => {
    const parsed = ClientMsg.safeParse({ v: 1, t: "hello", hasBookFile: true });
    expect(parsed.success).toBe(true);
  });
  it("rejects unknown t", () => {
    const parsed = ClientMsg.safeParse({ v: 1, t: "weird" });
    expect(parsed.success).toBe(false);
  });
  it("rejects mismatched v", () => {
    const parsed = ClientMsg.safeParse({ v: 2, t: "hello", hasBookFile: true });
    expect(parsed.success).toBe(false);
  });
  it("accepts sdp.offer with to/sdp", () => {
    const parsed = ClientMsg.safeParse({ v: 1, t: "sdp.offer", to: "u_1", sdp: "v=0..." });
    expect(parsed.success).toBe(true);
  });
});

describe("ServerMsg schema", () => {
  it("accepts welcome", () => {
    const parsed = ServerMsg.safeParse({
      v: 1, t: "welcome", you: "u_1", role: "host",
      sharerId: "u_1", reconnectToken: "rt", reservedUntil: 1234,
    });
    expect(parsed.success).toBe(true);
  });
});

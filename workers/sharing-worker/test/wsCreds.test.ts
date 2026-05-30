import { describe, expect, it } from "vitest";
import { parseSubprotocols } from "../src/wsCreds";

describe("parseSubprotocols", () => {
  it("extracts jwt and reconnect", () => {
    const out = parseSubprotocols("rishi.sharing.v1, jwt.abc.def, reconnect.xyz");
    expect(out).toEqual({ valid: true, jwt: "abc.def", reconnectToken: "xyz" });
  });
  it("requires the protocol marker", () => {
    expect(parseSubprotocols("jwt.abc").valid).toBe(false);
  });
  it("missing jwt fails", () => {
    expect(parseSubprotocols("rishi.sharing.v1").valid).toBe(false);
  });
});

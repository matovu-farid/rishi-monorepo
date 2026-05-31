import { describe, expect, it } from "vitest";
import { parseSubprotocols } from "../src/wsCreds";

function b64url(s: string): string {
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

describe("parseSubprotocols", () => {
  it("extracts base64url-encoded jwt and reconnect", () => {
    const header = `rishi.sharing.v1, jwt.${b64url("abc.def")}, reconnect.${b64url("xyz")}`;
    const out = parseSubprotocols(header);
    expect(out).toEqual({ valid: true, jwt: "abc.def", reconnectToken: "xyz" });
  });
  it("decodes a bearer that contains subprotocol-illegal chars (`:` + space)", () => {
    const raw = "e2e-host:E2E Host";
    const out = parseSubprotocols(`rishi.sharing.v1, jwt.${b64url(raw)}`);
    expect(out.valid).toBe(true);
    if (out.valid) expect(out.jwt).toBe(raw);
  });
  it("decodes a bearer containing the `--` test-mode separator", () => {
    const raw = "e2e-host--E2E_Host";
    const out = parseSubprotocols(`rishi.sharing.v1, jwt.${b64url(raw)}`);
    expect(out.valid).toBe(true);
    if (out.valid) expect(out.jwt).toBe(raw);
  });
  it("requires the protocol marker", () => {
    expect(parseSubprotocols(`jwt.${b64url("abc")}`).valid).toBe(false);
  });
  it("missing jwt fails", () => {
    expect(parseSubprotocols("rishi.sharing.v1").valid).toBe(false);
  });
  it("rejects a jwt segment with invalid base64url", () => {
    // `*` is outside the base64url alphabet; atob will throw.
    expect(parseSubprotocols("rishi.sharing.v1, jwt.***").valid).toBe(false);
  });
});

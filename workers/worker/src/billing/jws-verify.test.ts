import { describe, it, expect, beforeAll } from "vitest";
import { importSPKI } from "jose";
import { verifyAppleJWS, JWSInvalid } from "./jws-verify";
import { buildTestKit, type TestKit } from "./jws-fixtures";

let kit: TestKit;
beforeAll(async () => {
  kit = await buildTestKit();
});

/**
 * Test-only leaf-key resolver. Production wraps x5c[0] in a CERTIFICATE PEM
 * and calls importX509. The fixture parks SPKI bytes in x5c[0] instead (real
 * X.509 builder is out of scope for unit tests — RESEARCH §10.2), so the
 * resolver imports the kit's SPKI PEM directly.
 */
const testLeafResolver = async (_x5c: string[]) => {
  return importSPKI(kit.leafSpkiPem, "ES256");
};

describe("verifyAppleJWS", () => {
  it("verifies a valid JWS signed by the test root chain", async () => {
    const jws = await kit.signFixture({
      sub: "tx-123",
      productId: "org.fidexa.rishi.pro.monthly",
    });
    const payload = await verifyAppleJWS<{ sub: string; productId: string }>(
      jws,
      { rootCa: kit.rootDer, leafKeyResolver: testLeafResolver },
    );
    expect(payload.sub).toBe("tx-123");
    expect(payload.productId).toBe("org.fidexa.rishi.pro.monthly");
  });

  it("throws JWSInvalid('payload') when payload is tampered", async () => {
    const jws = await kit.signFixture({ sub: "tx-123" });
    // Flip bytes in the middle segment (payload). The signature was computed
    // over the original payload, so signature verification must fail.
    const parts = jws.split(".");
    parts[1] = parts[1].slice(0, -4) + "AAAA";
    const tampered = parts.join(".");
    await expect(
      verifyAppleJWS(tampered, {
        rootCa: kit.rootDer,
        leafKeyResolver: testLeafResolver,
      }),
    ).rejects.toMatchObject({ name: "JWSInvalid", reason: "payload" });
  });

  it("throws JWSInvalid('root_mismatch') when root pin does not match x5c[2]", async () => {
    const jws = await kit.signFixture({ sub: "tx-123" });
    // All-zero "root" — guaranteed not to match the kit's random rootDer.
    const wrongRoot = new Uint8Array(64);
    await expect(
      verifyAppleJWS(jws, {
        rootCa: wrongRoot,
        leafKeyResolver: testLeafResolver,
      }),
    ).rejects.toMatchObject({ name: "JWSInvalid", reason: "root_mismatch" });
  });

  it("throws JWSInvalid('alg') when header alg is not ES256", async () => {
    const jws = await kit.signFixture({ sub: "tx-123" }, { alg: "HS256" });
    await expect(
      verifyAppleJWS(jws, {
        rootCa: kit.rootDer,
        leafKeyResolver: testLeafResolver,
      }),
    ).rejects.toMatchObject({ name: "JWSInvalid", reason: "alg" });
  });

  it("throws JWSInvalid('x5c') when header x5c is missing", async () => {
    const jws = await kit.signFixture({ sub: "tx-123" }, { omitX5c: true });
    await expect(
      verifyAppleJWS(jws, {
        rootCa: kit.rootDer,
        leafKeyResolver: testLeafResolver,
      }),
    ).rejects.toMatchObject({ name: "JWSInvalid", reason: "x5c" });
  });

  it("decodes x5c entries as base64 STANDARD, not base64url (Pitfall 1)", async () => {
    // SPKI bytes for a fresh ES256 pubkey almost always contain `+` or `/`
    // when standard-base64'd. We assert that and check verify still works —
    // proving the verifier uses atob (standard b64), not base64url.
    const jws = await kit.signFixture({ sub: "tx-pitfall1" });
    const header = JSON.parse(
      Buffer.from(jws.split(".")[0], "base64url").toString("utf-8"),
    );
    const x5c0: string = header.x5c[0];
    expect(/[+/]/.test(x5c0)).toBe(true); // x5c entry uses standard b64 chars
    const payload = await verifyAppleJWS<{ sub: string }>(jws, {
      rootCa: kit.rootDer,
      leafKeyResolver: testLeafResolver,
    });
    expect(payload.sub).toBe("tx-pitfall1");
  });
});

describe("JWSInvalid", () => {
  it("exposes a typed reason field", () => {
    const e = new JWSInvalid("alg", "test");
    expect(e.name).toBe("JWSInvalid");
    expect(e.reason).toBe("alg");
    expect(e.message).toBe("test");
  });
});

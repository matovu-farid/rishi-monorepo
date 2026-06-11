import { describe, it, expect, beforeAll } from "vitest";
import { verifyAppleJWS, JWSInvalid } from "./jws-verify";
import { buildTestKit, type TestKit } from "./jws-fixtures";

let kit: TestKit;
beforeAll(async () => {
  kit = await buildTestKit();
});

describe("verifyAppleJWS — happy path", () => {
  it("verifies a valid JWS signed by the test root chain", async () => {
    const jws = await kit.signFixture({
      sub: "tx-123",
      productId: "org.fidexa.rishi.pro.monthly",
    });
    const payload = await verifyAppleJWS<{ sub: string; productId: string }>(
      jws,
      { rootCa: kit.rootDer },
    );
    expect(payload.sub).toBe("tx-123");
    expect(payload.productId).toBe("org.fidexa.rishi.pro.monthly");
  });

  it("decodes x5c entries as base64 STANDARD, not base64url (Pitfall 1)", async () => {
    // Real X.509 DERs almost always contain at least one byte that triggers
    // `+` or `/` in standard base64. We assert that and that verify still
    // succeeds — proving the verifier uses atob (standard b64), not base64url.
    const jws = await kit.signFixture({ sub: "tx-pitfall1" });
    const header = JSON.parse(
      Buffer.from(jws.split(".")[0], "base64url").toString("utf-8"),
    );
    const x5c0: string = header.x5c[0];
    expect(/[+/]/.test(x5c0)).toBe(true);
    const payload = await verifyAppleJWS<{ sub: string }>(jws, {
      rootCa: kit.rootDer,
    });
    expect(payload.sub).toBe("tx-pitfall1");
  });
});

describe("verifyAppleJWS — header rejects", () => {
  it("throws JWSInvalid('payload') when payload is tampered", async () => {
    const jws = await kit.signFixture({ sub: "tx-123" });
    const parts = jws.split(".");
    parts[1] = parts[1].slice(0, -4) + "AAAA";
    const tampered = parts.join(".");
    await expect(
      verifyAppleJWS(tampered, { rootCa: kit.rootDer }),
    ).rejects.toMatchObject({ name: "JWSInvalid", reason: "payload" });
  });

  it("throws JWSInvalid('root_mismatch') when root pin does not match x5c[2]", async () => {
    const jws = await kit.signFixture({ sub: "tx-123" });
    const wrongRoot = new Uint8Array(64);
    await expect(
      verifyAppleJWS(jws, { rootCa: wrongRoot }),
    ).rejects.toMatchObject({ name: "JWSInvalid", reason: "root_mismatch" });
  });

  it("throws JWSInvalid('alg') when header alg is not ES256", async () => {
    const jws = await kit.signFixture({ sub: "tx-123" }, { alg: "HS256" });
    await expect(
      verifyAppleJWS(jws, { rootCa: kit.rootDer }),
    ).rejects.toMatchObject({ name: "JWSInvalid", reason: "alg" });
  });

  it("throws JWSInvalid('x5c') when header x5c is missing", async () => {
    const jws = await kit.signFixture({ sub: "tx-123" }, { omitX5c: true });
    await expect(
      verifyAppleJWS(jws, { rootCa: kit.rootDer }),
    ).rejects.toMatchObject({ name: "JWSInvalid", reason: "x5c" });
  });
});

/**
 * Security-review hardening: the 4 forge scenarios from 14-02b plan.
 *
 * The byte-compare-only verifier (pre-hardening) accepts every JWS in this
 * describe block because `x5c[2]` always byte-matches the pinned root. The
 * hardened verifier rejects all four, each with a tagged JWSInvalid reason.
 */
describe("verifyAppleJWS — X.509 chain validation (security review)", () => {
  it("rejects forged-leaf attack (attacker leaf at x5c[0], real Apple root at x5c[2])", async () => {
    const jws = await kit.signForgedLeafFixture({
      sub: "tx-attacker",
      productId: "fake.premium",
    });
    // The forged JWS embeds the REAL pinned root at x5c[2] (byte-compare
    // passes) but the leaf cert was self-signed by an attacker keypair, not
    // by the kit's intermediate. Full chain walk catches this; byte-compare
    // alone does not.
    await expect(
      verifyAppleJWS(jws, { rootCa: kit.rootDer }),
    ).rejects.toMatchObject({ name: "JWSInvalid", reason: "chain" });
  });

  it("rejects tampered intermediate (x5c[1] swapped to unrelated cert)", async () => {
    const jws = await kit.signWithTamperedIntermediate({ sub: "tx-tampered" });
    // x5c[0] is the real leaf (signed by real intermediate), x5c[1] is now an
    // unrelated self-signed cert, x5c[2] is the real root. Leaf signature
    // doesn't trace back to root through the bogus intermediate.
    await expect(
      verifyAppleJWS(jws, { rootCa: kit.rootDer }),
    ).rejects.toMatchObject({ name: "JWSInvalid", reason: "chain" });
  });

  it("rejects expired leaf certificate", async () => {
    const jws = await kit.signWithExpiredLeaf({ sub: "tx-expired" });
    // Leaf was signed by the real intermediate (chain signatures verify) but
    // notAfter is in the past, so cert-validity check must reject.
    await expect(
      verifyAppleJWS(jws, { rootCa: kit.rootDer }),
    ).rejects.toMatchObject({ name: "JWSInvalid", reason: "expired" });
  });

  it("rejects chain-length mismatch (x5c only [leaf, intermediate], no root)", async () => {
    const jws = await kit.signWithShortChain({ sub: "tx-short" });
    // The hardened verifier requires a 3-entry chain so it can byte-pin the
    // root. A 2-entry chain — even if cryptographically valid up to the
    // intermediate — is rejected because there is no x5c[2] to compare.
    await expect(
      verifyAppleJWS(jws, { rootCa: kit.rootDer }),
    ).rejects.toMatchObject({ name: "JWSInvalid", reason: "x5c" });
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

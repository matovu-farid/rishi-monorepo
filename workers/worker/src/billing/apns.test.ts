import { describe, it, expect } from "vitest";
import { signApnsJwt } from "./apns";

// Generate a P-256 key and export it to PKCS8 PEM so we can exercise the
// real ES256 signing path without a real Apple .p8 credential.
async function generateP8Pem(): Promise<string> {
  const pair = (await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const pkcs8 = (await crypto.subtle.exportKey(
    "pkcs8",
    pair.privateKey,
  )) as ArrayBuffer;
  const b64 = Buffer.from(new Uint8Array(pkcs8)).toString("base64");
  const lines = b64.match(/.{1,64}/g)!.join("\n");
  return `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----\n`;
}

function decodeSegment(seg: string): any {
  // base64url -> JSON
  const b64 = seg.replace(/-/g, "+").replace(/_/g, "/");
  const pad = b64.length % 4 === 0 ? "" : "=".repeat(4 - (b64.length % 4));
  return JSON.parse(Buffer.from(b64 + pad, "base64").toString("utf8"));
}

describe("signApnsJwt", () => {
  it("produces 3 base64url segments with ES256 header and iss/iat payload", async () => {
    const keyP8 = await generateP8Pem();
    const jwt = await signApnsJwt({
      keyP8,
      keyId: "ABC1234567",
      teamId: "TEAM123456",
    });

    const segments = jwt.split(".");
    expect(segments).toHaveLength(3);
    // base64url has no +, /, or = padding.
    for (const seg of segments) {
      expect(seg).not.toMatch(/[+/=]/);
      expect(seg.length).toBeGreaterThan(0);
    }

    const header = decodeSegment(segments[0]);
    expect(header.alg).toBe("ES256");
    expect(header.kid).toBe("ABC1234567");

    const payload = decodeSegment(segments[1]);
    expect(payload.iss).toBe("TEAM123456");
    expect(typeof payload.iat).toBe("number");
    // iat is seconds-since-epoch, within a minute of now.
    const nowSec = Math.floor(Date.now() / 1000);
    expect(payload.iat).toBeGreaterThanOrEqual(nowSec - 60);
    expect(payload.iat).toBeLessThanOrEqual(nowSec + 60);
  });
});

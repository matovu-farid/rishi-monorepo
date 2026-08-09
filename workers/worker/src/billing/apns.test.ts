import { describe, it, expect, vi } from "vitest";
import { createApnsSender, signApnsJwt } from "./apns";

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

describe("createApnsSender", () => {
  it("sends a visible alert push with the share notification contract", async () => {
    const keyP8 = await generateP8Pem();
    const fetchMock = vi.fn(async () => new Response(null, { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    try {
      const sender = createApnsSender({
        keyP8,
        keyId: "ABC1234567",
        teamId: "TEAM123456",
      });
      await sender.sendAlertPush({
        deviceToken: "device-token",
        topic: "org.fidexa.rishi",
        env: "production",
        title: "New books shared with you",
        body: "2 books were shared with you.",
        payload: { rishi: { kind: "share.created", package_id: "package-1" } },
      });

      expect(fetchMock).toHaveBeenCalledWith(
        "https://api.push.apple.com/3/device/device-token",
        expect.objectContaining({
          headers: expect.objectContaining({
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-topic": "org.fidexa.rishi",
          }),
          body: expect.stringContaining('"share.created"'),
        }),
      );
      const request = (fetchMock as unknown as {
        mock: { calls: Array<[string, RequestInit]> };
      }).mock.calls[0]?.[1];
      expect(JSON.parse(String(request.body))).toMatchObject({
        aps: {
          alert: {
            title: "New books shared with you",
            body: "2 books were shared with you.",
          },
          sound: "default",
        },
        rishi: { kind: "share.created", package_id: "package-1" },
      });
    } finally {
      vi.unstubAllGlobals();
    }
  });
});

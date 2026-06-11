/**
 * Offline JWS fixture builder for `jws-verify.test.ts`.
 *
 * Production `verifyAppleJWS` expects x5c[0] to be a base64-standard-encoded
 * X.509 leaf certificate. Building a synthetic X.509 chain in WebCrypto is
 * out of scope for unit tests (RESEARCH §10.2 — defer real cert-chain
 * regression to a daily reconciliation cron in 14-09).
 *
 * Workaround: tests use the `leafKeyResolver` DI seam on `verifyAppleJWS` to
 * import x5c[0] as SPKI (instead of as an X.509 cert). This exercises every
 * code path the production verifier walks — header decode, alg check, x5c
 * presence, base64-standard decode of x5c[2] (Pitfall 1), root byte-pin
 * compare, jwtVerify against the leaf key — without forging X.509.
 *
 * For "real" cert-chain coverage, RESEARCH §12 describes a daily
 * reconciliation cron that hits Apple S2S and flags any verification drift
 * within 24h — that catches root-rotation faster than a synthetic CA builder.
 */
import { SignJWT, generateKeyPair, type JWTPayload } from "jose";

export interface SignFixtureOpts {
  /** Override the protected header alg (e.g. "HS256" to exercise the alg reject path). */
  alg?: string;
  /** Drop x5c from the protected header entirely. */
  omitX5c?: boolean;
  /** Replace x5c[2] with a different b64 blob (simulates a wrong-root chain). */
  tamperRoot?: boolean;
}

export interface TestKit {
  /**
   * Pinned "root" bytes for this kit. Random 64 bytes — the production
   * verifier just byte-compares x5c[2] to this, so content is unimportant.
   */
  rootDer: Uint8Array;
  /**
   * Build a JWS Compact Serialization (header.payload.sig) signed by the
   * fixture's leaf key. Header includes a 3-entry x5c shaped like Apple's
   * (base64 STANDARD, not base64url — Pitfall 1).
   */
  signFixture: (payload: JWTPayload, opts?: SignFixtureOpts) => Promise<string>;
  /**
   * Test-only helper. The kit's leaf public key in SPKI PEM form — pass via
   * `leafKeyResolver` so `verifyAppleJWS` can import it instead of running
   * `importX509` on the (non-X.509) x5c[0] entry.
   */
  leafSpkiPem: string;
}

/** Encode bytes as STANDARD base64 (NOT base64url) — Pitfall 1 regression. */
function bytesToB64Std(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

function randomBytes(n: number): Uint8Array {
  const out = new Uint8Array(n);
  crypto.getRandomValues(out);
  return out;
}

export async function buildTestKit(): Promise<TestKit> {
  // Real ES256 keypair — matches Apple's signing alg.
  const { publicKey, privateKey } = await generateKeyPair("ES256", {
    extractable: true,
  });

  // Export leaf public key as SPKI DER. We park these bytes in x5c[0] so the
  // base64-standard decode + import path is exercised end-to-end.
  const leafSpkiDer = new Uint8Array(
    await crypto.subtle.exportKey("spki", publicKey as CryptoKey),
  );
  const leafSpkiB64Std = bytesToB64Std(leafSpkiDer);

  // SPKI PEM the test resolver will hand to `importSPKI`.
  // Use 64-char-per-line wrap (standard PEM).
  const wrapped = leafSpkiB64Std.match(/.{1,64}/g)?.join("\n") ?? leafSpkiB64Std;
  const leafSpkiPem = `-----BEGIN PUBLIC KEY-----\n${wrapped}\n-----END PUBLIC KEY-----\n`;

  // Intermediate stand-in: 96 random bytes. Verifier doesn't validate it in
  // this iteration (chain walk deferred per RESEARCH §7.2).
  const intermediateDer = randomBytes(96);

  // Root pin: 64 random bytes. The kit hands these to the test's `rootCa`
  // option, and emits them as x5c[2] so byte-equality holds.
  const rootDer = randomBytes(64);

  async function signFixture(
    payload: JWTPayload,
    opts: SignFixtureOpts = {},
  ): Promise<string> {
    const x5c = [
      leafSpkiB64Std,
      bytesToB64Std(intermediateDer),
      opts.tamperRoot
        ? bytesToB64Std(randomBytes(64))
        : bytesToB64Std(rootDer),
    ];

    // Pre-build the protected header — we may need to bypass jose's
    // alg-vs-key check (it refuses to sign HS256 with an EC key). For the
    // alg-reject test we forge the header by re-serializing.
    const headerObj: Record<string, unknown> = { alg: opts.alg ?? "ES256" };
    if (!opts.omitX5c) headerObj.x5c = x5c;

    if (opts.alg && opts.alg !== "ES256") {
      // Forge a JWS with the requested alg in the header but a real ES256
      // signature body. Verifier rejects on header.alg before checking the
      // signature, so the signature content is irrelevant.
      const headerB64Url = base64UrlEncode(
        new TextEncoder().encode(JSON.stringify(headerObj)),
      );
      const payloadB64Url = base64UrlEncode(
        new TextEncoder().encode(JSON.stringify(payload)),
      );
      // Empty signature is fine — verifier rejects before reaching it.
      return `${headerB64Url}.${payloadB64Url}.`;
    }

    // Happy path: real ES256 signature.
    const signer = new SignJWT(payload).setProtectedHeader(
      headerObj as unknown as Parameters<SignJWT["setProtectedHeader"]>[0],
    );
    return await signer.sign(privateKey as CryptoKey);
  }

  return { rootDer, signFixture, leafSpkiPem };
}

/** base64url (no padding) of raw bytes — used for forged JWS headers. */
function base64UrlEncode(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

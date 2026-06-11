/**
 * Apple JWS verification for App Store Server API + Server Notifications V2.
 *
 * Implements the algorithm from RESEARCH §7.1 + §7.2 (full chain walk):
 *   1. Decode protected header; assert alg=ES256, x5c present and 3 entries.
 *   2. Decode x5c entries with STANDARD base64 (Pitfall 1).
 *   3. Byte-compare x5c[2] to the pinned root CA (identity pin).
 *   4. Parse all three x5c entries as X.509 certs (@peculiar/x509).
 *   5. Verify cryptographic chain:
 *        a. leaf cert signed by intermediate cert's public key
 *        b. intermediate cert signed by root cert's public key
 *      (Uses crypto.subtle.verify ECDSA-P256/SHA-256 under the hood.)
 *   6. Verify cert validity window (notBefore <= now <= notAfter) on all three.
 *   7. Resolve the leaf public key (production: importX509(PEM(x5c[0]))).
 *   8. jwtVerify(jws, leafKey, { algorithms: ["ES256"] }) -> payload.
 *
 * Hardened in 14-02b after a security review of plan 14-02 surfaced an
 * authentication bypass: the previous implementation only byte-compared
 * x5c[2] to the pinned root, never verifying that the leaf was actually
 * signed by the intermediate or that the intermediate was actually signed
 * by the root. An attacker could substitute their own self-signed leaf at
 * x5c[0], keep the genuine Apple root at x5c[2], and have the verifier
 * accept a JWS they signed themselves.
 *
 * Library choice: jose 6.x for JWS verification (Workers-native WebCrypto),
 * @peculiar/x509 for cert parsing + chain signature verification. Apple's
 * own server library + its Node-only crypto deps are not verified to run on
 * the Cloudflare Workers runtime (RESEARCH §2, Pitfall 8).
 */
import "reflect-metadata";
import { decodeProtectedHeader, importX509, jwtVerify, type JWTPayload } from "jose";
import * as x509 from "@peculiar/x509";
import { APPLE_ROOT_CA_G3_DER } from "./apple-root-ca-g3";

// Ensure @peculiar/x509 uses the Workers/Node WebCrypto instance.
x509.cryptoProvider.set(crypto);

export type JWSInvalidReason =
  | "alg"
  | "x5c"
  | "root_mismatch"
  | "chain"
  | "expired"
  | "payload";

export class JWSInvalid extends Error {
  readonly name = "JWSInvalid" as const;
  constructor(
    public readonly reason: JWSInvalidReason,
    message?: string,
  ) {
    super(message ?? `JWS invalid: ${reason}`);
  }
}

export interface VerifyOpts {
  /** Pinned root CA DER bytes. Defaults to APPLE_ROOT_CA_G3_DER. */
  rootCa?: Uint8Array;
  /**
   * Test-only override. Production omits — the verifier wraps x5c[0] in a
   * CERTIFICATE PEM and calls jose.importX509. Tests can still inject a
   * resolver to import an alternate key form. Retained for API stability;
   * the in-tree test suite no longer relies on it now that fixtures emit
   * real X.509 certs.
   */
  leafKeyResolver?: (x5c: string[]) => Promise<CryptoKey>;
  /**
   * Override "now" for validity-window checks. Default `new Date()`. Exposed
   * for time-travel tests; production omits.
   */
  now?: Date;
}

/** Constant-time byte-array equality. */
function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/**
 * Decode STANDARD base64 (NOT base64url — Pitfall 1) to bytes.
 * Apple's x5c entries use `+` / `/` / `=` (the standard alphabet), even
 * though the surrounding JWS header is base64url-encoded.
 */
function b64StdToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** True iff `now` falls within [cert.notBefore, cert.notAfter]. */
function isWithinValidity(cert: x509.X509Certificate, now: Date): boolean {
  return now >= cert.notBefore && now <= cert.notAfter;
}

/**
 * Verify an Apple-signed JWS Compact Serialization against a pinned root.
 *
 * @param jws Apple-signed JWS in `header.payload.sig` form.
 * @param opts Verification options. `rootCa` defaults to AppleRootCA-G3.
 * @returns The decoded JWT payload, narrowed to `T`.
 * @throws {JWSInvalid} with a tagged `reason` on any verification failure.
 */
export async function verifyAppleJWS<T extends JWTPayload>(
  jws: string,
  opts: VerifyOpts = {},
): Promise<T> {
  const rootCa = opts.rootCa ?? APPLE_ROOT_CA_G3_DER;
  const now = opts.now ?? new Date();

  // Step 1: decode protected header.
  let header: ReturnType<typeof decodeProtectedHeader>;
  try {
    header = decodeProtectedHeader(jws);
  } catch (e) {
    throw new JWSInvalid("payload", `decodeProtectedHeader failed: ${String(e)}`);
  }

  // Step 2a: alg must be ES256. Apple signs with ES256 across S2S + ASSN V2.
  if (header.alg !== "ES256") {
    throw new JWSInvalid("alg", `expected ES256, got ${String(header.alg)}`);
  }

  // Step 2b: x5c must be present AND contain exactly the [leaf, intermediate,
  // root] chain. Apple always ships 3 entries (RESEARCH §7.1); rejecting
  // short chains forecloses the "we can't byte-pin the root if it's missing"
  // attack surface.
  const x5cRaw = (header as { x5c?: unknown }).x5c;
  if (!Array.isArray(x5cRaw) || x5cRaw.length < 3) {
    throw new JWSInvalid(
      "x5c",
      `x5c header missing or has fewer than 3 entries (got ${
        Array.isArray(x5cRaw) ? x5cRaw.length : "none"
      })`,
    );
  }
  const x5c = x5cRaw as string[];

  // Step 3: pin the root identity. Byte-compare the wire root against the
  // pinned bytes BEFORE any signature work — fastest reject for the most
  // common forge attempt (substituted root).
  let sentRootBytes: Uint8Array;
  try {
    sentRootBytes = b64StdToBytes(x5c[2]);
  } catch (e) {
    throw new JWSInvalid("x5c", `x5c[2] base64 decode failed: ${String(e)}`);
  }
  if (!bytesEqual(sentRootBytes, rootCa)) {
    throw new JWSInvalid("root_mismatch", "x5c[2] does not match pinned root");
  }

  // Step 4: parse all three X.509 certs.
  let leafCert: x509.X509Certificate;
  let intermediateCert: x509.X509Certificate;
  let rootCert: x509.X509Certificate;
  try {
    leafCert = new x509.X509Certificate(b64StdToBytes(x5c[0]));
    intermediateCert = new x509.X509Certificate(b64StdToBytes(x5c[1]));
    rootCert = new x509.X509Certificate(sentRootBytes);
  } catch (e) {
    throw new JWSInvalid("chain", `x5c parse failed: ${String(e)}`);
  }

  // Step 5: walk the chain.
  //
  // X509Certificate#verify({ publicKey }) calls crypto.subtle.verify with
  // the parent cert's public key on the child cert's signed-TBS bytes. This
  // is the exact crypto.subtle.verify ECDSA-P256/SHA-256 pattern from
  // RESEARCH §7.2; @peculiar/x509 does the TBS extraction + ASN.1 signature
  // unpacking for us so we don't hand-roll DER walking.
  //
  // We pass `signatureOnly: true` to keep the signature check separate from
  // the validity-window check — the latter we apply uniformly to all three
  // certs in Step 6 so the "expired" reason isn't masked by "chain".
  try {
    const leafSigOk = await leafCert.verify({
      publicKey: intermediateCert.publicKey,
      signatureOnly: true,
    });
    if (!leafSigOk) {
      throw new JWSInvalid("chain", "leaf cert not signed by intermediate");
    }
    const intSigOk = await intermediateCert.verify({
      publicKey: rootCert.publicKey,
      signatureOnly: true,
    });
    if (!intSigOk) {
      throw new JWSInvalid(
        "chain",
        "intermediate cert not signed by pinned root",
      );
    }
  } catch (e) {
    if (e instanceof JWSInvalid) throw e;
    throw new JWSInvalid("chain", `chain signature verify failed: ${String(e)}`);
  }

  // Step 6: cert validity windows. All three certs must be currently valid;
  // tagging this separately from `chain` lets callers distinguish a forged
  // chain (chain) from a stale-but-otherwise-genuine chain (expired).
  if (!isWithinValidity(leafCert, now)) {
    throw new JWSInvalid(
      "expired",
      `leaf cert outside validity window (${leafCert.notBefore.toISOString()} .. ${leafCert.notAfter.toISOString()})`,
    );
  }
  if (!isWithinValidity(intermediateCert, now)) {
    throw new JWSInvalid("expired", "intermediate cert outside validity window");
  }
  if (!isWithinValidity(rootCert, now)) {
    throw new JWSInvalid("expired", "root cert outside validity window");
  }

  // Step 7: resolve the leaf public key for jose.
  // Production path: wrap x5c[0] in a CERT PEM and let jose.importX509 parse
  // the SubjectPublicKeyInfo (it already passed full X.509 parse + chain
  // walk above).
  // Test path: caller supplies leafKeyResolver to import an alternate key.
  let leafKey: CryptoKey;
  try {
    if (opts.leafKeyResolver) {
      leafKey = await opts.leafKeyResolver(x5c);
    } else {
      const leafPem = `-----BEGIN CERTIFICATE-----\n${x5c[0]}\n-----END CERTIFICATE-----\n`;
      leafKey = (await importX509(leafPem, "ES256")) as CryptoKey;
    }
  } catch (e) {
    throw new JWSInvalid("chain", `leaf key import failed: ${String(e)}`);
  }

  // Step 8: verify the JWS signature and decode the payload.
  try {
    const { payload } = await jwtVerify(jws, leafKey, {
      algorithms: ["ES256"],
    });
    return payload as T;
  } catch (e) {
    throw new JWSInvalid("payload", `jwtVerify failed: ${String(e)}`);
  }
}

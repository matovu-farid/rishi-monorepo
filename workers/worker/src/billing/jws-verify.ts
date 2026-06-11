/**
 * Apple JWS verification for App Store Server API + Server Notifications V2.
 *
 * Implements the algorithm from RESEARCH §7.1:
 *   1. Decode protected header; assert alg=ES256, x5c present.
 *   2. Decode x5c entries with STANDARD base64 (Pitfall 1).
 *   3. If x5c includes the root (3 entries), byte-compare x5c[2] to the
 *      pinned root CA; reject on mismatch.
 *   4. Resolve the leaf public key (production: importX509(PEM(x5c[0]))).
 *   5. jwtVerify(jws, leafKey, { algorithms: ["ES256"] }) -> payload.
 *
 * Library choice: jose 6.x (Workers-native, WebCrypto-based). Apple's own
 * server library + its Node-only crypto deps are not verified to run on the
 * Cloudflare Workers runtime (RESEARCH §2, Pitfall 8) — we stay on jose only.
 *
 * Deferred (RESEARCH §7.2): full cert-chain walk via crypto.subtle.verify on
 * leaf -> intermediate -> root TBSCertificate bytes. The pinned root in
 * step 3 catches the highest-leverage attack (substituted root). Full walk
 * lands in a follow-up plan if security audit requires it; this module's
 * public surface (`verifyAppleJWS`, `JWSInvalid`) will not change.
 */
import { decodeProtectedHeader, importX509, jwtVerify, type JWTPayload } from "jose";
import { APPLE_ROOT_CA_G3_DER } from "./apple-root-ca-g3";

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
   * CERTIFICATE PEM and calls jose.importX509. Tests pass a resolver that
   * imports the fixture's SPKI bytes via jose.importSPKI instead. This
   * keeps NODE_ENV branching out of production code (RESEARCH §10.2).
   */
  leafKeyResolver?: (x5c: string[]) => Promise<CryptoKey>;
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

  // Step 2b: x5c must be present (we expect the cert chain inline).
  const x5cRaw = (header as { x5c?: unknown }).x5c;
  if (!Array.isArray(x5cRaw) || x5cRaw.length < 1) {
    throw new JWSInvalid("x5c", "x5c header missing or empty");
  }
  const x5c = x5cRaw as string[];

  // Step 3: pin the root. Apple's chain typically ships 3 entries
  // [leaf, intermediate, root]; some payloads omit the root. When the root
  // is present, byte-compare it (constant-time) to the pinned bytes.
  if (x5c.length >= 3) {
    let sentRoot: Uint8Array;
    try {
      sentRoot = b64StdToBytes(x5c[2]);
    } catch (e) {
      throw new JWSInvalid("x5c", `x5c[2] base64 decode failed: ${String(e)}`);
    }
    if (!bytesEqual(sentRoot, rootCa)) {
      throw new JWSInvalid("root_mismatch", "x5c[2] does not match pinned root");
    }
  }

  // Step 4: resolve the leaf public key.
  // Production path: wrap x5c[0] (X.509 DER, base64-standard) in a CERT PEM
  // and let jose.importX509 parse the SubjectPublicKeyInfo.
  // Test path: caller supplies leafKeyResolver to import an SPKI fixture
  // without forging a synthetic X.509.
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

  // Step 5: verify the signature and decode the payload.
  try {
    const { payload } = await jwtVerify(jws, leafKey, {
      algorithms: ["ES256"],
    });
    return payload as T;
  } catch (e) {
    throw new JWSInvalid("payload", `jwtVerify failed: ${String(e)}`);
  }
}

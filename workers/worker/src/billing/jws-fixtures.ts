/**
 * Offline X.509 chain + JWS fixture builder for `jws-verify.test.ts`.
 *
 * Generates a REAL three-link ECDSA-P256 X.509 chain (root self-signed,
 * intermediate signed by root, leaf signed by intermediate) using
 * `@peculiar/x509`, then emits Apple-shaped JWS Compact Serializations with
 * the real cert DERs base64-standard encoded in the x5c header.
 *
 * This shape exercises the full hardened verifier:
 *   - importX509 on x5c[0] (production path; no test-only seam needed)
 *   - leaf-signed-by-intermediate signature check
 *   - intermediate-signed-by-root signature check
 *   - root identity pin (byte-compare on x5c[2])
 *   - notBefore/notAfter window check on every cert
 *   - ES256 signature on the JWS payload
 *
 * Forge helpers (`signForgedLeafFixture`, `signWithTamperedIntermediate`,
 * `signWithExpiredLeaf`, `signWithShortChain`) build the four attack
 * scenarios in the security review. They share the same root identity so
 * `rootDer` byte-compare alone can't distinguish them — the chain walk has to.
 */
import "reflect-metadata";
import { SignJWT, type JWTPayload } from "jose";
import * as x509 from "@peculiar/x509";

x509.cryptoProvider.set(crypto);

const ALG = { name: "ECDSA", namedCurve: "P-256" } as const;
const SIGN_ALG = { name: "ECDSA", hash: "SHA-256" } as const;

export interface SignFixtureOpts {
  /** Override the protected header alg (e.g. "HS256" to exercise the alg reject path). */
  alg?: string;
  /** Drop x5c from the protected header entirely. */
  omitX5c?: boolean;
}

export interface TestKit {
  /** Pinned root DER bytes — matches x5c[2] in legitimate fixtures. */
  rootDer: Uint8Array;
  /** Real X509 certs (handy for assertions). */
  rootCert: x509.X509Certificate;
  intermediateCert: x509.X509Certificate;
  leafCert: x509.X509Certificate;
  /** Build a legitimate JWS signed by the real leaf key. */
  signFixture: (payload: JWTPayload, opts?: SignFixtureOpts) => Promise<string>;
  /**
   * Forged-leaf attack JWS: attacker generates their own keypair + self-signed
   * leaf cert, parks it at x5c[0], puts the REAL kit intermediate + root at
   * x5c[1..2], and signs the payload with the attacker key. A verifier that
   * only byte-compares x5c[2] accepts this; a verifier that walks the chain
   * rejects (the attacker leaf is not signed by the kit intermediate).
   */
  signForgedLeafFixture: (payload: JWTPayload) => Promise<string>;
  /** Tampered intermediate JWS: x5c[1] swapped to an unrelated cert. */
  signWithTamperedIntermediate: (payload: JWTPayload) => Promise<string>;
  /** Expired-leaf JWS: leaf's notAfter is in the past. */
  signWithExpiredLeaf: (payload: JWTPayload) => Promise<string>;
  /** Short chain (only [leaf, intermediate]) — missing root. */
  signWithShortChain: (payload: JWTPayload) => Promise<string>;
}

function derToB64Std(der: ArrayBuffer): string {
  const bytes = new Uint8Array(der);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

interface IssuedCert {
  cert: x509.X509Certificate;
  privateKey: CryptoKey;
  publicKey: CryptoKey;
}

async function issueRoot(name: string, notBefore: Date, notAfter: Date): Promise<IssuedCert> {
  const keys = (await crypto.subtle.generateKey(
    ALG,
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const cert = await x509.X509CertificateGenerator.createSelfSigned({
    name: `CN=${name}`,
    keys,
    notBefore,
    notAfter,
    signingAlgorithm: SIGN_ALG,
    extensions: [
      new x509.BasicConstraintsExtension(true, undefined, true),
      new x509.KeyUsagesExtension(
        x509.KeyUsageFlags.keyCertSign | x509.KeyUsageFlags.cRLSign,
        true,
      ),
    ],
  });
  return { cert, privateKey: keys.privateKey, publicKey: keys.publicKey };
}

async function issueChild(
  subject: string,
  issuer: x509.X509Certificate,
  issuerPrivKey: CryptoKey,
  notBefore: Date,
  notAfter: Date,
  isCA: boolean,
): Promise<IssuedCert> {
  const keys = (await crypto.subtle.generateKey(
    ALG,
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const extensions: x509.Extension[] = [];
  if (isCA) {
    extensions.push(new x509.BasicConstraintsExtension(true, undefined, true));
    extensions.push(
      new x509.KeyUsagesExtension(
        x509.KeyUsageFlags.keyCertSign | x509.KeyUsageFlags.cRLSign,
        true,
      ),
    );
  } else {
    extensions.push(new x509.BasicConstraintsExtension(false, undefined, true));
    extensions.push(
      new x509.KeyUsagesExtension(
        x509.KeyUsageFlags.digitalSignature,
        true,
      ),
    );
  }
  const cert = await x509.X509CertificateGenerator.create({
    serialNumber: `0${Math.floor(Math.random() * 1e9).toString(16)}`,
    subject: `CN=${subject}`,
    issuer: issuer.subject,
    notBefore,
    notAfter,
    signingAlgorithm: SIGN_ALG,
    publicKey: keys.publicKey,
    signingKey: issuerPrivKey,
    extensions,
  });
  return { cert, privateKey: keys.privateKey, publicKey: keys.publicKey };
}

export async function buildTestKit(): Promise<TestKit> {
  const now = new Date();
  const farFuture = new Date(now.getTime() + 365 * 24 * 60 * 60 * 1000);
  const past = new Date(now.getTime() - 24 * 60 * 60 * 1000);

  // Real 3-link chain.
  const root = await issueRoot("Test Root CA", new Date(now.getTime() - 60_000), farFuture);
  const intermediate = await issueChild(
    "Test Intermediate CA",
    root.cert,
    root.privateKey,
    new Date(now.getTime() - 60_000),
    farFuture,
    true,
  );
  const leaf = await issueChild(
    "Test Leaf",
    intermediate.cert,
    intermediate.privateKey,
    new Date(now.getTime() - 60_000),
    farFuture,
    false,
  );

  const rootDer = new Uint8Array(root.cert.rawData);
  const intermediateB64 = derToB64Std(intermediate.cert.rawData);
  const rootB64 = derToB64Std(root.cert.rawData);
  const leafB64 = derToB64Std(leaf.cert.rawData);

  async function buildJws(
    leafCertB64: string,
    intermediateB64Override: string,
    rootB64Override: string,
    signingKey: CryptoKey,
    payload: JWTPayload,
    opts: SignFixtureOpts = {},
    includeRoot = true,
  ): Promise<string> {
    const x5c: string[] = [leafCertB64, intermediateB64Override];
    if (includeRoot) x5c.push(rootB64Override);

    const headerObj: Record<string, unknown> = { alg: opts.alg ?? "ES256" };
    if (!opts.omitX5c) headerObj.x5c = x5c;

    if (opts.alg && opts.alg !== "ES256") {
      // Forge a JWS with non-ES256 alg header; signature body is empty since
      // verifier rejects on header.alg before checking signature.
      const headerB64Url = base64UrlEncode(
        new TextEncoder().encode(JSON.stringify(headerObj)),
      );
      const payloadB64Url = base64UrlEncode(
        new TextEncoder().encode(JSON.stringify(payload)),
      );
      return `${headerB64Url}.${payloadB64Url}.`;
    }

    const signer = new SignJWT(payload).setProtectedHeader(
      headerObj as unknown as Parameters<SignJWT["setProtectedHeader"]>[0],
    );
    return await signer.sign(signingKey);
  }

  return {
    rootDer,
    rootCert: root.cert,
    intermediateCert: intermediate.cert,
    leafCert: leaf.cert,
    signFixture: (payload, opts = {}) =>
      buildJws(leafB64, intermediateB64, rootB64, leaf.privateKey, payload, opts),
    signForgedLeafFixture: async (payload) => {
      // Attacker forges a self-signed leaf cert using their own key, then
      // ships [attackerLeaf, realIntermediate, realRoot]. JWS is signed with
      // the attacker's key.
      const attacker = await issueRoot(
        "Attacker Forged Leaf",
        new Date(now.getTime() - 60_000),
        farFuture,
      );
      const attackerLeafB64 = derToB64Std(attacker.cert.rawData);
      return buildJws(
        attackerLeafB64,
        intermediateB64,
        rootB64,
        attacker.privateKey,
        payload,
      );
    },
    signWithTamperedIntermediate: async (payload) => {
      // Replace intermediate with an unrelated self-signed cert. Leaf
      // signature won't trace back to root through this stand-in.
      const stranger = await issueRoot(
        "Stranger Intermediate",
        new Date(now.getTime() - 60_000),
        farFuture,
      );
      const strangerB64 = derToB64Std(stranger.cert.rawData);
      return buildJws(leafB64, strangerB64, rootB64, leaf.privateKey, payload);
    },
    signWithExpiredLeaf: async (payload) => {
      // Issue a leaf with notAfter in the past, signed by the real intermediate.
      const expired = await issueChild(
        "Expired Leaf",
        intermediate.cert,
        intermediate.privateKey,
        new Date(now.getTime() - 2 * 24 * 60 * 60 * 1000),
        past,
        false,
      );
      const expiredB64 = derToB64Std(expired.cert.rawData);
      return buildJws(
        expiredB64,
        intermediateB64,
        rootB64,
        expired.privateKey,
        payload,
      );
    },
    signWithShortChain: (payload) =>
      buildJws(
        leafB64,
        intermediateB64,
        rootB64,
        leaf.privateKey,
        payload,
        {},
        /* includeRoot */ false,
      ),
  };
}

/** base64url (no padding) of raw bytes — used for forged JWS headers. */
function base64UrlEncode(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

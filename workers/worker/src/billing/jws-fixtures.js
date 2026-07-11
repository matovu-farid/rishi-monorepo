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
import { SignJWT } from "jose";
import * as x509 from "@peculiar/x509";
x509.cryptoProvider.set(crypto);
const ALG = { name: "ECDSA", namedCurve: "P-256" };
const SIGN_ALG = { name: "ECDSA", hash: "SHA-256" };
function derToB64Std(der) {
    const bytes = new Uint8Array(der);
    let bin = "";
    for (let i = 0; i < bytes.length; i++)
        bin += String.fromCharCode(bytes[i]);
    return btoa(bin);
}
async function issueRoot(name, notBefore, notAfter) {
    const keys = (await crypto.subtle.generateKey(ALG, true, ["sign", "verify"]));
    const cert = await x509.X509CertificateGenerator.createSelfSigned({
        name: `CN=${name}`,
        keys,
        notBefore,
        notAfter,
        signingAlgorithm: SIGN_ALG,
        extensions: [
            new x509.BasicConstraintsExtension(true, undefined, true),
            new x509.KeyUsagesExtension(x509.KeyUsageFlags.keyCertSign | x509.KeyUsageFlags.cRLSign, true),
        ],
    });
    return { cert, privateKey: keys.privateKey, publicKey: keys.publicKey };
}
async function issueChild(subject, issuer, issuerPrivKey, notBefore, notAfter, isCA) {
    const keys = (await crypto.subtle.generateKey(ALG, true, ["sign", "verify"]));
    const extensions = [];
    if (isCA) {
        extensions.push(new x509.BasicConstraintsExtension(true, undefined, true));
        extensions.push(new x509.KeyUsagesExtension(x509.KeyUsageFlags.keyCertSign | x509.KeyUsageFlags.cRLSign, true));
    }
    else {
        extensions.push(new x509.BasicConstraintsExtension(false, undefined, true));
        extensions.push(new x509.KeyUsagesExtension(x509.KeyUsageFlags.digitalSignature, true));
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
export async function buildTestKit() {
    const now = new Date();
    const farFuture = new Date(now.getTime() + 365 * 24 * 60 * 60 * 1000);
    const past = new Date(now.getTime() - 24 * 60 * 60 * 1000);
    // Real 3-link chain.
    const root = await issueRoot("Test Root CA", new Date(now.getTime() - 60_000), farFuture);
    const intermediate = await issueChild("Test Intermediate CA", root.cert, root.privateKey, new Date(now.getTime() - 60_000), farFuture, true);
    const leaf = await issueChild("Test Leaf", intermediate.cert, intermediate.privateKey, new Date(now.getTime() - 60_000), farFuture, false);
    const rootDer = new Uint8Array(root.cert.rawData);
    const intermediateB64 = derToB64Std(intermediate.cert.rawData);
    const rootB64 = derToB64Std(root.cert.rawData);
    const leafB64 = derToB64Std(leaf.cert.rawData);
    async function buildJws(leafCertB64, intermediateB64Override, rootB64Override, signingKey, payload, opts = {}, includeRoot = true) {
        const x5c = [leafCertB64, intermediateB64Override];
        if (includeRoot)
            x5c.push(rootB64Override);
        const headerObj = { alg: opts.alg ?? "ES256" };
        if (!opts.omitX5c)
            headerObj.x5c = x5c;
        if (opts.alg && opts.alg !== "ES256") {
            // Forge a JWS with non-ES256 alg header; signature body is empty since
            // verifier rejects on header.alg before checking signature.
            const headerB64Url = base64UrlEncode(new TextEncoder().encode(JSON.stringify(headerObj)));
            const payloadB64Url = base64UrlEncode(new TextEncoder().encode(JSON.stringify(payload)));
            return `${headerB64Url}.${payloadB64Url}.`;
        }
        const signer = new SignJWT(payload).setProtectedHeader(headerObj);
        return await signer.sign(signingKey);
    }
    return {
        rootDer,
        rootCert: root.cert,
        intermediateCert: intermediate.cert,
        leafCert: leaf.cert,
        signFixture: (payload, opts = {}) => buildJws(leafB64, intermediateB64, rootB64, leaf.privateKey, payload, opts),
        signForgedLeafFixture: async (payload) => {
            // Attacker forges a self-signed leaf cert using their own key, then
            // ships [attackerLeaf, realIntermediate, realRoot]. JWS is signed with
            // the attacker's key.
            const attacker = await issueRoot("Attacker Forged Leaf", new Date(now.getTime() - 60_000), farFuture);
            const attackerLeafB64 = derToB64Std(attacker.cert.rawData);
            return buildJws(attackerLeafB64, intermediateB64, rootB64, attacker.privateKey, payload);
        },
        signWithTamperedIntermediate: async (payload) => {
            // Replace intermediate with an unrelated self-signed cert. Leaf
            // signature won't trace back to root through this stand-in.
            const stranger = await issueRoot("Stranger Intermediate", new Date(now.getTime() - 60_000), farFuture);
            const strangerB64 = derToB64Std(stranger.cert.rawData);
            return buildJws(leafB64, strangerB64, rootB64, leaf.privateKey, payload);
        },
        signWithExpiredLeaf: async (payload) => {
            // Issue a leaf with notAfter in the past, signed by the real intermediate.
            const expired = await issueChild("Expired Leaf", intermediate.cert, intermediate.privateKey, new Date(now.getTime() - 2 * 24 * 60 * 60 * 1000), past, false);
            const expiredB64 = derToB64Std(expired.cert.rawData);
            return buildJws(expiredB64, intermediateB64, rootB64, expired.privateKey, payload);
        },
        signWithShortChain: (payload) => buildJws(leafB64, intermediateB64, rootB64, leaf.privateKey, payload, {}, 
        /* includeRoot */ false),
    };
}
/** base64url (no padding) of raw bytes — used for forged JWS headers. */
function base64UrlEncode(bytes) {
    let bin = "";
    for (let i = 0; i < bytes.length; i++)
        bin += String.fromCharCode(bytes[i]);
    return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const enc = new TextEncoder();

function toBase64Url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64Url(s: string): Uint8Array {
  const padded = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function importNonceKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

function nonceMessage(rishiSessionId: string, userId: string, issuedAtMs: number): Uint8Array {
  return enc.encode(`voice-session-nonce:v1:${rishiSessionId}:${userId}:${issuedAtMs}`);
}

export interface MintedNonce {
  /** The opaque token returned to the caller of `createVoiceSession`. */
  nonce: string;
  /** Persisted alongside the session row so `verifyRegistrationNonce` doesn't need to re-derive it. */
  issuedAtMs: number;
  signatureB64Url: string;
}

export async function mintRegistrationNonce(
  rishiSessionId: string,
  userId: string,
  secret: string,
  issuedAtMs: number = Date.now(),
): Promise<MintedNonce> {
  const key = await importNonceKey(secret);
  const signature = await crypto.subtle.sign("HMAC", key, nonceMessage(rishiSessionId, userId, issuedAtMs));
  const signatureB64Url = toBase64Url(new Uint8Array(signature));
  return { nonce: `${issuedAtMs}.${signatureB64Url}`, issuedAtMs, signatureB64Url };
}

/**
 * Verifies a client-supplied nonce against the record minted for this
 * session. Returns `false` (never throws) on any malformed input, expired
 * mismatch, or cryptographic failure — the caller decides which
 * `VoiceSessionError` code to raise.
 */
export async function verifyRegistrationNonce(
  suppliedNonce: string,
  rishiSessionId: string,
  userId: string,
  secret: string,
  expected: { issuedAtMs: number; signatureB64Url: string },
): Promise<boolean> {
  const parts = suppliedNonce.split(".");
  if (parts.length !== 2) return false;
  const [issuedAtStr, signatureB64Url] = parts;
  const issuedAtMs = Number(issuedAtStr);
  if (!Number.isFinite(issuedAtMs) || issuedAtMs !== expected.issuedAtMs) return false;
  if (signatureB64Url !== expected.signatureB64Url) return false;

  const key = await importNonceKey(secret);
  return crypto.subtle.verify(
    "HMAC",
    key,
    fromBase64Url(signatureB64Url),
    nonceMessage(rishiSessionId, userId, issuedAtMs),
  );
}

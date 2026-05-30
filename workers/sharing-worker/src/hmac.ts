const enc = new TextEncoder();
const dec = new TextDecoder();

function b64u(buf: ArrayBuffer | Uint8Array): string {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function unb64u(s: string): Uint8Array {
  s = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function key(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"]
  );
}

export async function sign(payload: unknown, secret: string): Promise<string> {
  const headerB64 = b64u(enc.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const payloadB64 = b64u(enc.encode(JSON.stringify(payload)));
  const data = `${headerB64}.${payloadB64}`;
  const sig = await crypto.subtle.sign("HMAC", await key(secret), enc.encode(data));
  return `${data}.${b64u(sig)}`;
}

export async function verify<T>(token: string, secret: string): Promise<T> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("invalid token format");
  const [headerB64, payloadB64, sigB64] = parts;
  const data = `${headerB64}.${payloadB64}`;
  const ok = await crypto.subtle.verify(
    "HMAC",
    await key(secret),
    unb64u(sigB64),
    enc.encode(data)
  );
  if (!ok) throw new Error("invalid signature");
  return JSON.parse(dec.decode(unb64u(payloadB64))) as T;
}

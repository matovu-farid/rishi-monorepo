export const SHARE_EXPIRY_MS = 7 * 24 * 60 * 60 * 1000;

function encodeBase64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function createShareToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return encodeBase64URL(bytes);
}

export async function createShareTokenFromSecret(
  secret: string,
  senderUserId: string,
  idempotencyKey: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`rishi-share:${senderUserId}:${idempotencyKey}`),
  );
  return encodeBase64URL(new Uint8Array(signature));
}

export async function hashShareToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return encodeBase64URL(new Uint8Array(digest));
}

export function shareExpiry(now = Date.now()): Date {
  return new Date(now + SHARE_EXPIRY_MS);
}

export function isShareExpired(expiresAt: Date, now = Date.now()): boolean {
  return expiresAt.getTime() <= now;
}

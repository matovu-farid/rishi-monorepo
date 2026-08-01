const encoder = new TextEncoder();

function encodeBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function decodeBase64(value: string): Uint8Array {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

async function keyFromSecret(secret: string): Promise<CryptoKey> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(secret));
  return crypto.subtle.importKey("raw", digest, "AES-GCM", false, ["encrypt", "decrypt"]);
}

export interface EncryptedSiwaRefreshToken {
  ciphertext: string;
  nonce: string;
}

export async function encryptSiwaRefreshToken(
  token: string,
  secret: string,
): Promise<EncryptedSiwaRefreshToken> {
  if (!secret) throw new Error("SIWA token encryption secret is not configured");
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const key = await keyFromSecret(secret);
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce },
    key,
    encoder.encode(token),
  );
  return {
    ciphertext: encodeBase64(new Uint8Array(ciphertext)),
    nonce: encodeBase64(nonce),
  };
}

export async function decryptSiwaRefreshToken(
  encrypted: EncryptedSiwaRefreshToken,
  secret: string,
): Promise<string> {
  if (!secret) throw new Error("SIWA token encryption secret is not configured");
  const key = await keyFromSecret(secret);
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: decodeBase64(encrypted.nonce) as unknown as ArrayBuffer },
    key,
    decodeBase64(encrypted.ciphertext) as unknown as ArrayBuffer,
  );
  return new TextDecoder().decode(plaintext);
}

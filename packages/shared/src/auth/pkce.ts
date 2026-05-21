/**
 * Portable PKCE helper. Uses Web Crypto (`crypto.subtle`, `crypto.getRandomValues`)
 * so it works in:
 *
 *   - Node 19+ / 20+ (global `crypto`)
 *   - Cloudflare Workers
 *   - Modern browsers
 *   - React Native, IF a `crypto.getRandomValues` polyfill is loaded at boot.
 *     `expo-crypto` provides this — see `apps/mobile/lib/auth.ts` for the
 *     import-side-effect.
 *
 * Mirrors the algorithm used by the worker route at
 * `workers/worker/src/routes/mobile.ts` so the same challenge/verifier
 * round-trips cleanly.
 */

export interface PkcePair {
  code_verifier: string
  code_challenge: string
}

function base64url(bytes: Uint8Array): string {
  // btoa is available in browsers, Workers, RN, and Node 16+ as a global.
  let bin = ''
  for (let i = 0; i < bytes.length; i++) {
    bin += String.fromCharCode(bytes[i])
  }
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function getCrypto(): Crypto {
  // `crypto` is a global on Workers, Node 19+, browsers, and RN with polyfill.
  const c = (globalThis as { crypto?: Crypto }).crypto
  if (!c || typeof c.getRandomValues !== 'function' || !c.subtle) {
    throw new Error(
      '[pkce] global crypto.subtle / crypto.getRandomValues unavailable. ' +
        'In React Native, import "react-native-get-random-values" (or use expo-crypto) at app entry.',
    )
  }
  return c
}

export async function generatePkcePair(): Promise<PkcePair> {
  const c = getCrypto()
  // 32 random bytes → 43-char base64url, RFC-7636 compliant.
  const buf = new Uint8Array(32)
  c.getRandomValues(buf)
  const code_verifier = base64url(buf)
  const code_challenge = await sha256Base64Url(code_verifier)
  return { code_verifier, code_challenge }
}

export async function verifyPkce(verifier: string, challenge: string): Promise<boolean> {
  const expected = await sha256Base64Url(verifier)
  return expected === challenge
}

async function sha256Base64Url(input: string): Promise<string> {
  const c = getCrypto()
  const digest = await c.subtle.digest('SHA-256', new TextEncoder().encode(input))
  return base64url(new Uint8Array(digest))
}

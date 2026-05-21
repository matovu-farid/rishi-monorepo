/**
 * Smoke test that the shared @rishi/shared/auth/pkce package is reachable
 * from mobile and that its Web-Crypto path works under ts-jest (node env).
 *
 * The exhaustive PKCE assertions live in packages/shared/src/auth/pkce.test.ts —
 * here we only verify that the cross-package import resolves and the algorithm
 * round-trips, which is the contract mobile relies on.
 */

// Polyfill: Node 18+ has webcrypto under `node:crypto`. RN has it via expo-crypto.
const nodeCrypto = require('node:crypto').webcrypto
if (!(globalThis as { crypto?: Crypto }).crypto) {
  ;(globalThis as { crypto?: Crypto }).crypto = nodeCrypto
}

import { generatePkcePair, verifyPkce } from '@rishi/shared/auth/pkce'

describe('shared PKCE (consumed from mobile)', () => {
  it('round-trips: the generated challenge verifies its own verifier', async () => {
    const { code_verifier, code_challenge } = await generatePkcePair()
    expect(code_verifier.length).toBeGreaterThanOrEqual(43)
    expect(code_verifier.length).toBeLessThanOrEqual(128)
    expect(code_challenge).toMatch(/^[A-Za-z0-9_-]+$/)
    expect(await verifyPkce(code_verifier, code_challenge)).toBe(true)
  })

  it('mismatched verifier fails to verify', async () => {
    const { code_challenge } = await generatePkcePair()
    expect(await verifyPkce('not-the-real-verifier', code_challenge)).toBe(false)
  })
})

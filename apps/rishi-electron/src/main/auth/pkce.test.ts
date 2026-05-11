import { describe, it, expect } from 'vitest'
import { generatePkcePair, verifyPkce } from './pkce'

describe('PKCE', () => {
  it('generates a code_verifier between 43 and 128 chars (RFC 7636)', () => {
    const { code_verifier } = generatePkcePair()
    expect(code_verifier.length).toBeGreaterThanOrEqual(43)
    expect(code_verifier.length).toBeLessThanOrEqual(128)
  })

  it('generates a code_verifier using only the unreserved character set', () => {
    const { code_verifier } = generatePkcePair()
    expect(code_verifier).toMatch(/^[A-Za-z0-9\-._~]+$/)
  })

  it('the code_challenge is base64url(sha256(code_verifier))', async () => {
    const { code_verifier, code_challenge } = generatePkcePair()
    expect(await verifyPkce(code_verifier, code_challenge)).toBe(true)
  })

  it('verifyPkce rejects mismatched verifier', async () => {
    const { code_challenge } = generatePkcePair()
    expect(await verifyPkce('wrong-verifier', code_challenge)).toBe(false)
  })

  it('each call returns a unique pair', () => {
    const a = generatePkcePair()
    const b = generatePkcePair()
    expect(a.code_verifier).not.toBe(b.code_verifier)
    expect(a.code_challenge).not.toBe(b.code_challenge)
  })
})

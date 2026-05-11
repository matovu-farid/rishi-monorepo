import { createHash, randomBytes } from 'node:crypto'

export interface PkcePair {
  code_verifier: string
  code_challenge: string
}

function base64url(input: Buffer): string {
  return input.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export function generatePkcePair(): PkcePair {
  // 32 random bytes → 43-char base64url, RFC-7636 compliant
  const code_verifier = base64url(randomBytes(32))
  const code_challenge = base64url(createHash('sha256').update(code_verifier).digest())
  return { code_verifier, code_challenge }
}

export async function verifyPkce(verifier: string, challenge: string): Promise<boolean> {
  const expected = base64url(createHash('sha256').update(verifier).digest())
  return expected === challenge
}

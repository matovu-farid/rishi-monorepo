import { describe, it, expect } from 'vitest';
import { generatePkcePair, verifyPkce } from './pkce';
describe('PKCE (shared, web-crypto)', () => {
    it('generates a code_verifier between 43 and 128 chars (RFC 7636)', async () => {
        const { code_verifier } = await generatePkcePair();
        expect(code_verifier.length).toBeGreaterThanOrEqual(43);
        expect(code_verifier.length).toBeLessThanOrEqual(128);
    });
    it('generates a code_verifier using only the unreserved character set', async () => {
        const { code_verifier } = await generatePkcePair();
        // base64url uses A-Z, a-z, 0-9, '-', '_'
        expect(code_verifier).toMatch(/^[A-Za-z0-9_-]+$/);
    });
    it('the code_challenge is base64url(sha256(code_verifier))', async () => {
        const { code_verifier, code_challenge } = await generatePkcePair();
        expect(await verifyPkce(code_verifier, code_challenge)).toBe(true);
    });
    it('verifyPkce rejects a mismatched verifier', async () => {
        const { code_challenge } = await generatePkcePair();
        expect(await verifyPkce('wrong-verifier', code_challenge)).toBe(false);
    });
    it('each call returns a unique pair', async () => {
        const a = await generatePkcePair();
        const b = await generatePkcePair();
        expect(a.code_verifier).not.toBe(b.code_verifier);
        expect(a.code_challenge).not.toBe(b.code_challenge);
    });
    it('generates a base64url challenge with no padding', async () => {
        const { code_challenge } = await generatePkcePair();
        expect(code_challenge).not.toContain('=');
        expect(code_challenge).not.toContain('+');
        expect(code_challenge).not.toContain('/');
    });
    it('challenge matches the worker route hash (interop with /mobile/start/verify)', async () => {
        // Same algorithm the worker uses in mobile.ts:sha256Base64Url
        async function workerHash(input) {
            const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
            return btoa(String.fromCharCode(...new Uint8Array(buf)))
                .replace(/\+/g, '-')
                .replace(/\//g, '_')
                .replace(/=+$/, '');
        }
        const { code_verifier, code_challenge } = await generatePkcePair();
        expect(await workerHash(code_verifier)).toBe(code_challenge);
    });
});

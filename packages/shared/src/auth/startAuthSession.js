/**
 * Mobile / desktop client helpers for the `/mobile/*` PKCE auth flow served
 * by `workers/worker/src/routes/mobile.ts`.
 *
 *   1. `startAuthSession()`  — generates a verifier, POSTs the challenge to
 *      `${apiUrl}/mobile/start`, and returns `{ authUrl, state, verifier }`.
 *      The caller is responsible for opening `authUrl` in a browser
 *      (e.g. `expo-web-browser.openAuthSessionAsync`) and observing the
 *      deep-link return.
 *
 *   2. `completeAuthSession()` — POSTs `{ state, code_verifier }` to
 *      `${apiUrl}/mobile/start/verify` and returns the bearer session token.
 *      Called by mobile *after* it receives the `rishimobile://auth/callback?state=…`
 *      deep link.
 *
 * Token is deliberately NOT carried inside the deep link URL — see
 * `.parity/BATCH-1A-NOTES.md` for the rationale.
 */
import { generatePkcePair } from './pkce';
export async function startAuthSession(args) {
    const fetchImpl = args.fetch ?? fetch;
    const provider = args.provider ?? 'google';
    const { code_verifier, code_challenge } = await generatePkcePair();
    const body = { code_challenge, provider };
    if (args.state)
        body.state = args.state;
    const res = await fetchImpl(`${args.apiUrl}/mobile/start`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
    });
    if (!res.ok) {
        let detail = '';
        try {
            detail = await res.text();
        }
        catch {
            // ignore — body may have been consumed
        }
        throw new Error(`POST /mobile/start failed: ${res.status} ${detail}`);
    }
    const data = (await res.json());
    return { authUrl: data.authUrl, state: data.state, verifier: code_verifier };
}
export async function completeAuthSession(args) {
    const fetchImpl = args.fetch ?? fetch;
    const res = await fetchImpl(`${args.apiUrl}/mobile/start/verify`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ state: args.state, code_verifier: args.verifier }),
    });
    if (!res.ok) {
        let detail = '';
        try {
            detail = await res.text();
        }
        catch {
            // ignore
        }
        if (res.status === 403) {
            throw new Error(`PKCE pkce_mismatch (403): ${detail}`);
        }
        if (res.status === 410) {
            throw new Error(`session expired (410): ${detail}`);
        }
        throw new Error(`POST /mobile/start/verify failed: ${res.status} ${detail}`);
    }
    return (await res.json());
}

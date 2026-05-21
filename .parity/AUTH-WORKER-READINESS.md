# Auth Worker Readiness (2026-05-21)

**Verdict: small worker change required, fully backward-compatible with Electron.**

## Current state

- Worker uses Better-Auth (`workers/worker/src/auth.ts`) with the `bearer()` plugin enabled, so both clients can terminate at the same session-token model.
- Existing auth flow endpoints beyond `/api/auth/*`:
  - `/desktop/start` (POST)
  - `/desktop/start/complete` (POST)
  - `/desktop/poll` (POST)
  - `/desktop/cancel` (POST)
  - All mounted in `workers/worker/src/index.ts:132-135` via `workers/worker/src/routes/desktop.ts`.
- `/desktop/start` body schema is fixed in `src/routes/desktop.ts:9-14` — repurposing it for mobile would risk breaking Electron.
- **No `/mobile/*` route exists, no `rishimobile://` reference anywhere in the worker.**
- **`/api/auth/exchange` does not exist** — `apps/mobile/lib/auth.ts:29` calls a non-existent endpoint. The current Clerk → Worker JWT exchange is dead and can be removed wholesale.
- `trustedOrigins` in `src/auth.ts:16` only lists `PUBLIC_WEB_URL` and `rishi-electron://`.

## Diff plan (all changes additive)

### 1. `workers/worker/src/auth.ts`

Add `rishimobile://` (lowercase, no hyphen, to match the no-hyphen convention of `rishi-electron://` — final canonical scheme: **`rishimobile://`** per gap analysis) to `trustedOrigins`:

```ts
trustedOrigins: [env.PUBLIC_WEB_URL, 'rishi-electron://', 'rishimobile://'],
```

### 2. New file `workers/worker/src/routes/mobile.ts`

Modeled on `workers/worker/src/routes/desktop.ts` but **redirect-based, not Redis-polling**:

- `POST /mobile/start`
  - Body: `{ challenge: string, state: string, provider?: 'google' | 'apple' | 'password' }`
  - Stores the PKCE challenge + state in KV (TTL ~15min), same as desktop.
  - Returns `{ authUrl }` — the OAuth provider URL that, when completed, redirects back to `${WORKER_URL}/mobile/start/complete?state=<state>&code=<oauthCode>`.

- `GET /mobile/start/complete`
  - Query: `state`, `code` (from OAuth provider), `code_verifier` (sent by mobile client after the redirect via a follow-up POST, NOT in the OAuth callback URL — see verifier-exchange below).
  - On success: 302 redirect to `rishimobile://auth/callback?token=<bearer_token>&state=<state>`.
  - On state/verifier mismatch: 400.

- Verifier exchange (PKCE-safe): mobile sends the `code_verifier` separately via `POST /mobile/start/verify { state, code_verifier }` after receiving the redirect. The worker matches it against the stored challenge and returns the bearer token. This avoids putting the verifier in the URL.

(Final endpoint shape to be confirmed against Better-Auth handler signatures; match what `routes/desktop.ts` does.)

### 3. `workers/worker/src/index.ts`

Mount the new route alongside `/desktop/*`:

```ts
app.route('/mobile', mobileRoute)
```

### 4. Tests

Add `workers/worker/test/routes/mobile.test.ts` (or wherever existing route tests live) covering:
- Happy path: start → redirect → verify → bearer token returned
- State mismatch → 400
- Code-verifier mismatch → 400
- Regression: `/desktop/start` and `/desktop/poll` still work

## Backward compatibility

Electron's `/desktop/start` + `/desktop/poll` flow is unchanged. No shared state between desktop and mobile flows except the underlying Better-Auth session machinery.

## Open question for executor

Whether Better-Auth exposes a "redirect with token in query" helper out-of-the-box, or if the mobile route needs to manually mint the bearer token via `auth.api.getSession()`. Check `node_modules/better-auth` source and follow whatever pattern `routes/desktop.ts` uses for issuance.

# Batch 1A — Implementation Notes (2026-05-21)

Worker `/mobile/*` auth endpoints — landed.

## Files added

- `workers/worker/src/routes/mobile.ts` (new)
- `workers/worker/src/routes/mobile.test.ts` (new)

## Files modified (purely additive)

- `workers/worker/src/auth.ts` — added `rishimobile://` to `trustedOrigins`.
- `workers/worker/src/index.ts` — imported and mounted `mobileRoutes` at `/mobile`.

## Files NOT modified

- `workers/worker/src/routes/desktop.ts` — verified unchanged (`git diff` is empty;
  latest commit touching it is pre-Batch-1A: `9274cb01 fix(electron): align
  processJob vector index name with read path (#5)`).

## Test results

- `pnpm -C workers/worker test`: **22 passed** (17 new mobile + 5 existing
  realtime regression). Baseline was 5 — net gain 17.
- `npx tsc --noEmit` (no `typecheck` script exists in worker `package.json`):
  clean.

## Deviation from the diff plan

### Token NOT in deep-link URL — verifier exchange instead

`.parity/AUTH-WORKER-READINESS.md` lines 39-43 describe the redirect as:

> 302 redirect to `rishimobile://auth/callback?token=<bearer_token>&state=<state>`

Implemented instead as: `GET /mobile/start/complete` redirects to
`rishimobile://auth/callback?state=<state>` (NO token), and the mobile app
proves PKCE via a follow-up `POST /mobile/start/verify { state, code_verifier }`
to receive `{ session_token, user_id }`.

**Why:** Putting the bearer token in the deep-link URL would let any app on
the device that hijacks the `rishimobile://` scheme observe the token in the
URL bar / activity record. `routes/desktop.ts` /poll deliberately requires
the PKCE verifier before returning the session token for exactly this reason.

**Authorization for the deviation:** the executor brief explicitly says:

> If that conflicts with Better-Auth conventions, follow whatever pattern
> `workers/worker/src/routes/desktop.ts` already uses for
> `/desktop/start/complete` — consistency with electron is more important
> than the spec wording.

The readiness doc itself also calls out (lines 41-43) that the verifier
"is sent by mobile client after the redirect via a follow-up POST, NOT in
the OAuth callback URL — see verifier-exchange below". So the deviation
is only with the doc's _example URL_, not its prose. The implementation
follows the prose.

**Impact on Batch 1C (mobile-side auth swap):** the mobile client must do
two HTTP calls, not one:
1. Open `authUrl` from `/mobile/start` via `expo-web-browser.openAuthSessionAsync(..., 'rishimobile://auth/callback')`.
2. On deep-link return, extract `state` from the URL and call
   `POST /mobile/start/verify { state, code_verifier }` to receive the
   session token.

### Endpoint surface — small additions over the readiness doc

The doc lists `/mobile/start` + `/mobile/start/complete`. I added two extra
shapes for clarity:

- `POST /mobile/start/complete` — web app -> worker handoff (mirrors
  `POST /desktop/start/complete`; needs Better-Auth web session cookie).
- `GET  /mobile/start/complete` — user-agent redirect target (302 to
  `rishimobile://...`).
- `POST /mobile/start/verify` — verifier-bound token exchange.

Both `/start/complete` variants share the path so the web app's existing
`DesktopHandoffListener` can be extended (or a new `MobileHandoffListener`
added) without inventing a new endpoint name. The GET vs POST split keeps
"the browser redirects here" and "the SPA fetches here" cleanly separated.

### `provider` field — values

Limited to `["google", "apple", "password"]` per the readiness doc body
schema. `google` is the default when omitted. `apple` and `password` will
work mechanically (state stored, web app handles the actual provider), but
the web app side (Batch 1B/1C scope) will need its own handlers — out of
scope here.

### `state` is optional in the request body

The doc shows the client supplying `state`. I made it optional with a
server-generated `crypto.randomUUID()` fallback, matching how `/desktop/start`
mints state. This is purely an ergonomic extension; clients can still supply
their own state and it's threaded through.

### `z.uuid()` strictness (test fixture bug, not implementation)

Initial test fixtures used hand-typed hex strings like
`"11111111-2222-3333-4444-555555555555"`. zod v4's `z.uuid()` requires a
properly-versioned UUID (v1-v8), so these failed validation with 400 instead
of reaching the route's real branches. Switched all test fixtures to
`crypto.randomUUID()`. The production path was already correct — desktop.ts
also uses `crypto.randomUUID()` for state.

## Skipped scenarios

None of the requested scenarios were skipped. The "code-verifier mismatch
→ 400" scenario from the executor brief is implemented as **403** (not 400),
matching `routes/desktop.ts /poll`'s convention (400 = malformed body, 403 =
PKCE proof failed). The test asserts 403.

## Commits

- `df3ee0b2` test(worker): add failing /mobile/* auth route tests
- `218aadcd` feat(worker): add /mobile/* PKCE auth routes for mobile clients
- `97cb6540` feat(worker): mount /mobile route and trust rishimobile:// origin

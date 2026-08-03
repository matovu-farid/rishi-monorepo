# Google Sign-In Design

**Date:** 2026-08-03  
**Scope:** Native Google sign-in for the iOS and Mac Catalyst Rishi target, using the existing Rishi session contract.

## Goal

Add a second native authentication method that lets a user sign in with Google, then lands in the same authenticated Rishi experience as Sign in with Apple: the worker verifies the provider credential, issues Rishi access and refresh tokens, and the app stores the resulting session in its existing Keychain-backed path.

## Current constraints

- The live mobile API contract is the custom `POST /auth/apple` route plus Rishi HS256 access/refresh JWTs.
- `workers/worker/src/auth.ts` configures Better Auth and its tests exercise `/api/auth/sign-in/social`, but the Better Auth catch-all is not mounted in `workers/worker/src/index.ts`.
- `workers/worker/src/middleware.ts` validates the custom Rishi access JWT, not a Better Auth bearer token.
- The existing `account` table is Better Auth-shaped and may contain non-UUID user IDs; it must not be reused by the native flow without a production-data migration.
- The repository contains no Google client-ID values. Google client IDs are public configuration, but client secrets remain worker secrets and must never be committed.

## Chosen architecture

Use the official `GoogleSignIn-iOS` Swift package through Xcode Swift Package Manager. The app uses `GIDSignIn` to obtain a Google ID token, sends only that token to a new `POST /auth/google` endpoint, and never treats the Google token as an Rishi API session.

The worker verifies the token using Google’s rotating JWKS and checks:

- issuer is `https://accounts.google.com` or `accounts.google.com`;
- audience equals the configured Google server/client ID;
- signature and expiry are valid;
- the token contains a non-empty stable `sub`.

After verification, the worker looks up a dedicated `google_users` row keyed by the Google `sub`. Existing native identities reuse their UUID-backed Rishi user. A new Google identity creates a UUID-backed Rishi `user` row and a corresponding `google_users` row. Email is profile data only and is never used to auto-link an Apple or Google identity. The worker rejects identities whose account is already fenced for deletion, applies the existing KV-backed abuse limiter by IP, then issues the existing Rishi access and refresh JWTs and returns the same response shape consumed by the Apple client path.

The app adds a Google button to the signed-out view, configures Google with an iOS client ID plus the worker’s server client ID, handles the reversed-client-ID callback URL, sends the returned ID token to `/auth/google`, and reuses the existing Keychain/session, current-user, sync, consent, and entitlement refresh sequence.

## Configuration

The worker already declares `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`; the implementation will use `GOOGLE_CLIENT_ID` as the server-side token audience. The deployed secret names must be checked without exposing their values.

The Apple target needs:

- `GIDClientID`: the public iOS OAuth client ID;
- `GIDServerClientID`: the public server/web OAuth client ID, matching worker `GOOGLE_CLIENT_ID`;
- a `CFBundleURLTypes` entry for the reversed iOS client ID.

Because the actual iOS client ID is not in the repository, source-controlled configuration will use an explicit build setting placeholder and fail with a user-facing configuration error if it is absent. The client ID itself may be supplied through the project’s build configuration; no secret is committed.

## Error and safety behavior

- Missing or malformed Google tokens return a generic 400/401 response and never reveal verification details.
- Google JWKS failures are treated as temporary verification failures and return 401 without creating a user.
- Concurrent first sign-ins for the same Google `sub` are resolved by re-reading the account after a unique-conflict failure; no duplicate provider identity is created.
- A Google sign-in never auto-links by matching email. Explicit account linking is out of scope.
- If local session persistence fails, the app clears the partially written access token, refresh token, user ID, and session blob, matching Apple behavior.
- Cancellation is not shown as an authentication failure when the SDK reports a user-cancelled flow.

## Verification

Worker tests will cover valid Google token exchange, wrong audience, wrong issuer, expired token, missing subject, repeat sign-in reuse, and no email-based auto-linking. Apple tests and existing worker tests must remain green.

The Apple target will be verified with an Xcode build and focused auth tests. A real-device or Catalyst manual smoke test is required for the browser callback because Google OAuth credentials and a signed app are external runtime prerequisites.

## Deployment

After implementation and verification, deploy the worker with the repository’s Bun/Wrangler workflow. Deployment is considered complete only when the deployed worker reports success and the Google secret names are present; the app build still requires the public iOS client ID to be configured in Xcode.

## Adversarial review — research/design round 1

### Findings

1. **High — treating the Google ID token as the API bearer token would bypass the worker’s current auth contract.** Resolved by requiring `/auth/google` to issue the existing Rishi JWT pair.
2. **High — using Better Auth only for Google would create two session systems.** Resolved by keeping the native route on the current custom contract and explicitly deferring a full Better Auth migration.
3. **High — email-based linking could merge unrelated Apple and Google accounts.** Resolved by keying the provider identity by Google `sub` and requiring explicit linking for future merges.
4. **Medium — the worker’s configured client ID may be the web/server ID while the app also needs a separate iOS ID.** Resolved by making the two roles explicit and requiring `GIDServerClientID` to match the worker audience.
5. **Medium — source-controlled Xcode configuration may accidentally contain a secret.** Resolved by committing only build-setting placeholders and documenting that client IDs are public while client secrets stay in Cloudflare secrets.

### Re-review verdict

PASS WITH NOTES: no open Critical or High findings remain. The remaining external prerequisites are the generated Drizzle migration, configuration of the public iOS client ID, and confirmation that the worker’s `GOOGLE_CLIENT_ID` is the matching server/web client ID.

# Worker Contract — Sign in with Apple (Better Auth)

> This is the cross-team contract the worker team implements to serve the iOS-side Sign-in-with-Apple flow plus session hydration. Downstream teams (Android, web, future Electron auth re-add) MUST read against the contract here rather than guessing from Better Auth's upstream docs — version drift is real.
>
> **Owned by:** iOS team (`apps/apple/Packages/RishiAuth/`, `apps/apple/Packages/RishiAPI/`).
> **Implemented by:** worker team (`workers/worker/src/auth.ts`).
> **Last updated:** Phase 15 Plan 10.

Companion to [`RUNBOOK-BILLING-WORKER.md`](./RUNBOOK-BILLING-WORKER.md) Section SIWA Provider — that doc tells the operator how to deploy the SIWA secrets and verify; this doc tells the worker dev (and downstream platform devs) what the deployed wire shape is.

This auth contract is also the source of truth for `user.id` format. Apple's `sub` (a string like `001234.abcdef.5678`) flows through verbatim into `user.id`. The Phase 14 `apple_subscriptions.user_id` FK join (see [`WORKER-CONTRACT-IAP.md`](./WORKER-CONTRACT-IAP.md) Section 3) is keyed against THIS `user.id` string — not a UUID. If a downstream consumer needs to join the two systems, the join column is a string, not a `uuid`.

---

## 0. Summary

iOS does ONE thing requiring worker support for auth in v1:

1. **On every successful Sign in with Apple sheet:** iOS posts the Apple-issued ID token (a JWT) + a CSRF-binding nonce to `POST /api/auth/sign-in/social` with `provider: "apple"`. Better Auth's first-party Apple social provider verifies the JWT against Apple's JWKS, upserts the user row keyed on Apple's `sub`, links a row in the standard Better Auth `account` table, and issues a bearer token + the `rishi.session_token` cookie. iOS persists the bearer token in the Keychain and uses it on every subsequent worker request.

Plus one out-of-band hydration:

2. **On every app launch:** iOS hits `GET /api/auth/get-session` with the stored bearer token to confirm the session is still valid. The worker returns either the live `ProfileResponse` envelope OR the JSON literal `null` (NOT a 401) — iOS decodes either into a Swift `Optional<ProfileResponse>` and treats `nil` as "no session, free tier".

Account deletion (`DELETE /api/user`) is wired through the authenticated worker user route — see `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/Endpoints/AuthAPI.swift` for the endpoint shape.

Apple-only v1: the worker's `socialProviders.google` block stays configured for future web/Android use, but iOS does NOT exercise it. The Google button + coordinator + endpoint were removed from the iOS app in Phase 15 (see [`RUNBOOK-BILLING-WORKER.md`](./RUNBOOK-BILLING-WORKER.md) Section SIWA Provider).

---

## 1. Provider Configuration

The worker enables the Apple provider when ALL four of these wrangler secrets are present (see Section 7):

```typescript
// workers/worker/src/auth.ts
socialProviders: {
  google: { /* unchanged; not used by iOS */ },
  ...(appleConfigured && appleClientSecret
    ? {
        apple: {
          clientId: env.APPLE_SIWA_CLIENT_ID,            // "org.fidexa.rishi" (iOS bundle ID)
          appBundleIdentifier: env.APPLE_SIWA_CLIENT_ID, // resolves the JWT audience check
          clientSecret: appleClientSecret,               // pre-minted ES256 JWT — see Section 8
        },
      }
    : {}),
},
```

Key facts verified against installed `@better-auth/core@1.6.10`:

- `clientId` is set to the **iOS bundle ID** (`org.fidexa.rishi`) — NOT a separate Services ID. The Apple `aud` claim on a native iOS-issued ID token equals the bundle ID, and Better Auth resolves the JWT audience check at `apple.mjs:51-52` via the order `audience ?? appBundleIdentifier ?? clientId`. For iOS-only v1, no Services ID is required.
- `clientSecret` is the Apple-spec ES256 JWT minted at worker startup by `mintAppleClientSecret` (see Section 8). For the native iOS ID-token branch (`POST /api/auth/sign-in/social`), this secret is NOT consumed at runtime — Better Auth verifies the device-supplied JWT against Apple's JWKS directly. The mint is required only to satisfy the provider's typed config and to keep the future web-redirect (`/api/auth/callback/apple`) branch ready.
- Better Auth's `/api/auth/*` catch-all at `workers/worker/src/index.ts:163` picks up the new social routes automatically. No new Hono route handlers were added for SIWA.

---

## 2. Endpoint: `POST /api/auth/sign-in/social`

### 2.1 Auth

- NONE at the HTTP layer (it IS the sign-in endpoint).
- The trust anchor is the Apple-issued ID token's JWS signature verified against Apple's JWKS (`https://appleid.apple.com/auth/keys`) plus the nonce binding in Section 2.3.
- A `401 INVALID_TOKEN` here means JWS verification failed (signature, audience, issuer, expiry, OR nonce mismatch) — NOT that the caller is unauthenticated. iOS surfaces this to the user as "sign in failed; try again."

### 2.2 Request

```http
POST /api/auth/sign-in/social HTTP/1.1
Host: api.fidexa.org
Content-Type: application/json

{
  "provider": "apple",
  "idToken": {
    "token": "eyJhbGciOiJSUzI1NiI...",
    "nonce": "6dcd4ce23d88e2ee9568ba546c007c63d9131c1b9b2c7a4d4b2c2c4f3c8e9b7c",
    "user": {
      "name": { "firstName": "Jane", "lastName": "Appleseed" },
      "email": "jane@example.com"
    }
  },
  "disableRedirect": true
}
```

Schema (verified against `better-auth@1.6.10/dist/api/routes/sign-in.mjs:14-38`, `socialSignInBodySchema`):

| Field                        | Type      | Notes                                                                                                                                          |
| ---------------------------- | --------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `provider`                   | `string`  | MUST be `"apple"`. Other values produce `400 INVALID_PROVIDER`.                                                                                |
| `idToken`                    | `object`  | **An OBJECT, not a top-level string.** The string goes in `idToken.token`. Most common contract mistake.                                       |
| `idToken.token`              | `string`  | The raw JWT decoded from `ASAuthorizationAppleIDCredential.identityToken` via `String(data: identityToken, encoding: .utf8)`. NOT base64-wrapped. |
| `idToken.nonce`              | `string`  | SHA-256 hex digest of the raw client nonce. See Section 2.3.                                                                                          |
| `idToken.user`               | `object?` | Present ONLY on first sign-in (when Apple discloses the user's name + email — see Section 9.1). Omit on subsequent re-authorizations.                  |
| `idToken.user.name.firstName`| `string?` | Apple's `PersonNameComponents.givenName`.                                                                                                       |
| `idToken.user.name.lastName` | `string?` | Apple's `PersonNameComponents.familyName`.                                                                                                      |
| `idToken.user.email`         | `string?` | Apple-disclosed email. May be a private-relay alias — see Section 9.2.                                                                                |
| `disableRedirect`            | `boolean` | Set `true` on native. Affects the web-redirect branch only; harmless to send for ID-token sign-in.                                              |

Second-sign-in body (same user, no fresh disclosure):

```json
{
  "provider": "apple",
  "idToken": {
    "token": "eyJhbGciOiJSUzI1NiI...",
    "nonce": "0b3a8f1e2d4c5b6a..."
  },
  "disableRedirect": true
}
```

`idToken.user` is OMITTED entirely (the key does not appear in the JSON). Better Auth then finds the existing user via Apple `sub` — no name/email overwrite happens. iOS achieves this via Swift's auto-synthesized `Encodable` `encodeIfPresent` behaviour: `user: nil` produces no `"user"` key, NOT JSON `null`.

Wire shape comes verbatim from `apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/AuthAPI.swift` (Plan 15-07).

### 2.3 Nonce binding (CSRF)

The iOS client generates a fresh nonce per sign-in, hashes it once, and sends the SAME hash to BOTH legs:

```swift
// apps/apple/Packages/RishiAuth/Sources/RishiAuth/Coordinators/Nonce.swift
let (raw, sha256Hex) = Nonce.generate()  // 16 random bytes hex, then SHA-256 hex
appleIDRequest.nonce = sha256Hex          // Apple stores the hex VERBATIM in the JWT nonce claim
// later, after the Apple sheet:
let body = SignInSocialEndpoint.Body(
    provider: "apple",
    idToken: .init(token: jwt, nonce: sha256Hex, user: …),
    disableRedirect: true
)
```

Better Auth verifies at `apple.mjs:58`:

```js
if (nonce && jwtClaims.nonce !== nonce) return false;
```

This is a string-equality check on whatever Apple put in the JWT `nonce` claim. Since Apple stores the iOS-supplied nonce VERBATIM (not re-hashed — the docs recommend pre-hashing precisely so the developer controls what bytes end up in the claim), both sides see the same 64-character lowercase hex string.

**Common pitfall:** sending the raw nonce to Better Auth and the hash to Apple (or vice-versa). The check fails and the worker returns `401 INVALID_TOKEN` with no further detail. See `apps/apple/Packages/RishiAuth/Tests/RishiAuthTests/SiwaFlowTests.swift::nonceIsBoundToBothApplePromptAndBetterAuthBody` for the iOS-side regression test.

### 2.4 Response

Success (verified `sign-in.mjs:122-127`):

```json
{
  "redirect": false,
  "token": "eyJ...",
  "url": null,
  "user": {
    "id": "001234.abcdef0123456789.1234",
    "email": "jane@example.com",
    "name": "Jane Appleseed",
    "emailVerified": true,
    "image": null
  }
}
```

Schema:

| Field                | Type      | Notes                                                                                                                                |
| -------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `redirect`           | `boolean` | Always `false` for the native idToken branch.                                                                                        |
| `token`              | `string`  | Bearer token. SAME value also set on the `rishi.session_token` cookie (see Section 5). iOS persists this in the Keychain — does NOT read the cookie. |
| `url`                | `null`    | Always `null` for the native idToken branch.                                                                                         |
| `user.id`            | `string`  | Apple's `sub`. NEVER a UUID. Flows verbatim into iOS `Session.userId: String` (Phase 15 Plan 02 widened this from `UUID`).            |
| `user.email`         | `string?` | Apple-disclosed email (may be private-relay).                                                                                        |
| `user.name`          | `string?` | Better Auth concatenates `firstName + " " + lastName` from the first-sign-in `user.name` block. Empty on subsequent sign-ins.         |
| `user.emailVerified` | `boolean?`| Apple sets this on the JWT.                                                                                                          |
| `user.image`         | `string?` | Apple does not provide a profile image; this is `null` for SIWA users.                                                               |

HTTP status: `200`.

### 2.5 Error responses

| Status | Body                                        | Meaning                                                                                              | iOS behavior                                |
| ------ | ------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| `400`  | `{"error":"INVALID_PROVIDER"}`              | `provider` was something other than a registered social provider name.                               | Crash-in-CI bug; should never happen in prod. |
| `401`  | `{"error":"INVALID_TOKEN"}`                 | Better Auth's `verifyIdToken(token, nonce)` returned `false` — nonce mismatch, JWS signature failure, `aud` mismatch, `iss` mismatch, OR `exp` in the past. | Surface "sign in failed; try again" to user; no retry without a fresh Apple sheet. |
| `500`  | `{"error":"…"}`                             | Worker-side: client-secret minting threw, DB unavailable, or unexpected exception in the OAuth user-info flow. | Treat as transient; ask user to retry.      |

The single `INVALID_TOKEN` reason covers every JWS verification failure — the worker does NOT distinguish nonce mismatch from signature failure in the response body. Distinguish in worker logs (`apple.verifyIdToken` returns `false` for all five cases; the Sentry breadcrumb names which).

### 2.6 Idempotency

The endpoint is naturally idempotent on `idToken.token` + Apple `sub`:

- A duplicate POST of the same JWT for the same Apple `sub` returns `200` with the SAME `user.id` and a freshly-issued bearer `token`.
- The standard Better Auth `account` table (`provider_id="apple"`, `account_id=<sub>`) provides the dedupe — the second call finds the existing account row and short-circuits the user upsert.
- Apple's JWTs have short expiry (~10 minutes) — replay beyond that fails at `apple.mjs:74` (`decodeJwt` followed by `jwtVerify` with `currentDate` check). No additional replay defense is required at the worker layer.

---

## 3. Endpoint: `GET /api/auth/get-session`

### 3.1 Auth

- Bearer-only on iOS. Send `Authorization: Bearer <token>` with the value stored in the Keychain from Section 2.4.
- The `rishi.session_token` cookie is ALSO accepted (web/electron use this path), but iOS never sends it.

### 3.2 Authenticated response

```json
{
  "user": {
    "id": "001234.abcdef0123456789.1234",
    "email": "jane@example.com",
    "display_name": "Jane Appleseed",
    "avatar_url": null
  },
  "has_pro": false
}
```

HTTP status: `200`. Note the snake-case wire keys (`display_name`, `avatar_url`, `has_pro`) — they are mapped to camelCase Swift fields via `CodingKeys` on `SessionUser` / `ProfileResponse` in `AuthAPI.swift`. The worker MUST keep snake-case here.

### 3.3 Unauthenticated response

```http
HTTP/1.1 200 OK
Content-Type: application/json

null
```

The body is the JSON literal `null` — NOT `{}`, NOT `{"user": null}`, NOT a 401. This is Better Auth's standard contract for `getSession` on a no-session request.

### 3.4 iOS Optional decode contract

iOS handles `null` via Swift `Optional`:

```swift
// AuthAPI.swift (Plan 15-05/15-07)
public struct GetSessionEndpoint: WorkerEndpoint {
    public typealias Response = ProfileResponse?   // <- Optional, decodes literal null as nil
    ...
}
```

Consumers treat `nil` as "no session, free tier":

```swift
let response = try await workerClient.send(GetSessionEndpoint())
let hasPro = response?.hasPro ?? false
```

See `apps/apple/Packages/RishiBilling/Sources/RishiBilling/Service/EntitlementService.swift` for the canonical call site. Plan 15-05 added the regression test `getSessionResponseDecodesNullAsNil` to lock the decoder behaviour.

**Do NOT change the worker side to return 401 or `{user: null}`** — iOS is the side that adapted. Any change here would re-break the existing fix.

---

## 4. Endpoint: `POST /api/auth/sign-out`, `DELETE /api/user`

These are documented in `AuthAPI.swift` and were wired in Phase 3. Quick summary:

- `POST /api/auth/sign-out` — Bearer auth; returns `{"ok": true}`. Worker invalidates the bearer token + clears the cookie.
- `DELETE /api/user` — Bearer auth; returns `{"ok": true}` and deletes the authenticated user row. iOS does not send account identifiers; the worker derives identity from the bearer token.

Neither endpoint changed in Phase 15.

---

## 5. Session Cookie

Even though iOS uses the bearer token path, the worker also sets a session cookie for parity with web/electron consumers.

| Attribute   | Value                                                                                              |
| ----------- | -------------------------------------------------------------------------------------------------- |
| Name        | `rishi.session_token` (prefix `rishi` from `auth.ts:157` `advanced: { cookiePrefix: "rishi" }`)    |
| `HttpOnly`  | `true`                                                                                             |
| `Secure`    | `true`                                                                                             |
| `SameSite`  | `Lax`                                                                                              |
| `Path`      | `/`                                                                                                |
| `Domain`    | Inferred from the request host (`api.fidexa.org` in production)                                    |
| `Max-Age`   | 30 days (`auth.ts:153` `session.expiresIn = 60 * 60 * 24 * 30`)                                    |

The cookie value is identical to the `token` field in the Section 2.4 response body. Iiis NOT a JWT — it is an opaque random token whose only purpose is to look up a row in Better Auth's `session` D1 table.

---

## 6. Account Linking

Better Auth calls `handleOAuthUserInfo` at `sign-in.mjs:100-116` with `account: { providerId: "apple", accountId: String(userInfo.user.id), accessToken: undefined }`. `userInfo.user.id` is set to `profile.sub` at `apple.mjs:87`. Concretely:

- On FIRST sign-in for a given Apple `sub`:
  - A new `user` row is inserted with `user.id = <sub>`, `user.email = <Apple-disclosed email>`, `user.name = "<firstName> <lastName>".trim()`, `user.emailVerified = true` (Apple verified it).
  - A new `account` row is inserted with `provider_id = "apple"`, `account_id = <sub>`, `user_id = <sub>` (same value).
- On SUBSEQUENT sign-ins for the same `sub`:
  - The existing `account` row is found; no user/account writes happen; a fresh `session` row is created.
  - `idToken.user` MUST be omitted (Apple does not re-disclose; sending an empty/missing name would overwrite the existing row with empty strings — see Pitfall 8 in `15-RESEARCH.md`).

Critical: `user.id` is a **string** (not a UUID). The Phase 14 `apple_subscriptions.user_id` FK in `workers/worker/drizzle/migrations/0007_apple_iap.sql` is `text`, and Plan 15-02 widened iOS `Session.userId` from `UUID` to `String` to match. **This contract is the source of truth for `user.id`'s string-typed-ness.**

---

## 7. Wrangler Secrets

The worker requires these four secrets to enable the Apple provider. Names only — values live in operator memory and the `~/Downloads/AuthKey_*.p8` file.

| Secret                    | Source                                                                                                          | Shared? |
| ------------------------- | --------------------------------------------------------------------------------------------------------------- | ------- |
| `APPLE_SIWA_CLIENT_ID`    | Static value: the iOS bundle identifier (`org.fidexa.rishi`)                                                    | New     |
| `APPLE_SIWA_KEY_ID`       | Apple Developer Console > Certificates, IDs & Profiles > Keys > pick the SIWA-capable key                       | New     |
| `APPLE_SIWA_PRIVATE_KEY`  | PKCS8 PEM contents of the downloaded `.p8` file (full block including `-----BEGIN/END PRIVATE KEY-----` markers) | New     |
| `APPLE_TEAM_ID`           | Apple Developer Console > Membership > Team ID                                                                  | Shared with Phase 14 IAP — already deployed |

If any of the four is missing, the worker silently omits the Apple provider from `socialProviders` (see `auth.ts:35-48`). `POST /api/auth/sign-in/social` with `provider: "apple"` then returns `400 INVALID_PROVIDER`. This is the canonical "did the operator forget to deploy the secrets?" signal.

Operational setup steps live in [`RUNBOOK-BILLING-WORKER.md`](./RUNBOOK-BILLING-WORKER.md) Section SIWA Provider. Do NOT duplicate the deploy commands here.

---

## 8. Client-Secret Minting

The Apple `clientSecret` is an ES256 JWT, minted by:

```typescript
// workers/worker/src/auth-apple-secret.ts
export async function mintAppleClientSecret(env: AppleSecretEnv): Promise<string> {
  const pkcs8 = await importPKCS8(env.APPLE_SIWA_PRIVATE_KEY, "ES256");
  return await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: env.APPLE_SIWA_KEY_ID })
    .setIssuer(env.APPLE_TEAM_ID)
    .setSubject(env.APPLE_SIWA_CLIENT_ID)
    .setAudience("https://appleid.apple.com")
    .setIssuedAt()
    .setExpirationTime("180d")
    .sign(pkcs8);
}
```

Apple constraints (verified against Apple Developer docs):

- `alg = ES256`
- Protected header `kid = <APPLE_SIWA_KEY_ID>`
- `iss = <APPLE_TEAM_ID>`
- `sub = <APPLE_SIWA_CLIENT_ID>` (for native flows this is the bundle ID)
- `aud = "https://appleid.apple.com"` (literal)
- `exp <= iat + 6 months` (Apple's maximum; we use 180 days)

The JWT is minted ONCE per worker startup. It is NOT consumed by the iOS ID-token branch (`verifyIdToken` verifies the device-supplied JWT against Apple's JWKS directly, not the client secret) — it is required only for the web-redirect `validateAuthorizationCode` branch AND to satisfy Better Auth's typed `ProviderOptions` at config time. When the worker isolate restarts, a fresh secret is minted; the 180-day expiry means the worker never trips an expired-secret edge case in practice.

Source: [Apple — Creating the client secret](https://developer.apple.com/documentation/sign_in_with_apple/generate_and_validate_tokens).

---

## 9. Privacy / Apple-Disclosed Fields

### 9.1 First-sign-in name + email

Apple discloses the user's name + email ONLY on the very first authorization for a given (Team, bundle) tuple. On every subsequent sign-in, `ASAuthorizationAppleIDCredential.fullName` is `nil` and `.email` is `nil`. This is by design — Apple does not re-disclose PII the user has already consented to share.

iOS sends `idToken.user.{name, email}` only when `credential.fullName != nil || credential.email != nil`. On subsequent sign-ins the entire `user` object is OMITTED from the JSON (not set to `null`). Better Auth's `getUserInfo` (`apple.mjs:77-91`) falls back to the JWT's own claims for `email` (always present in the JWT) but does NOT re-populate `name` (the JWT lacks a name claim).

**Implication for the worker:** if `user.name` is empty in the DB for a SIWA user, that user signed in BEFORE iOS ever forwarded the structured name (i.e. they used a pre-Phase-15 build). No backfill is possible — Apple won't re-disclose. Support team should treat this as "user can edit their display name in app settings."

### 9.2 Private-relay email

Apple offers "Hide My Email" — the user's `email` claim then has the form `<random>@privaterelay.appleid.com`. This is a valid forwarder address: Apple forwards email sent to it to the user's real address.

Better Auth's `getUserInfo` at `apple.mjs:90` passes `profile.email` through unchanged including the private-relay form. The worker does NOT need to special-case it. The user's `user.email` column in the DB is the private-relay alias; sending mail to it via Resend works.

Implication: any future "log in with the email I have on file" UX must NOT assume the email looks like a normal personal address. Private-relay aliases match `*@privaterelay.appleid.com`.

---

## 10. Testing Contract

Both sides of the contract are pinned to JSON-shape regression tests.

### 10.1 Worker vitest fixtures

`workers/worker/src/auth.test.ts` (Plan 15-01) covers:

- Provider is configured at startup when all four env vars are present.
- Provider is OMITTED from `socialProviders` when any of the four is missing.
- `POST /api/auth/sign-in/social` with a synthetic Apple JWT happy-path round trip.
- Re-sign-in with the same JWT returns the same `user.id` (idempotency).

The fixtures use a stubbed `verifyIdToken` so vitest does not need network access to Apple's JWKS — the contract being asserted is the wire shape, not Apple's cryptography (Better Auth's source already asserts that).

### 10.2 iOS Swift Testing fixtures

`apps/apple/Packages/RishiAuth/Tests/RishiAuthTests/SiwaFlowTests.swift` (Plan 15-06) covers the iOS half:

| Test                                                | Asserts                                                                                                  |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `postsToSignInSocialPath`                           | The wire path is exactly `/api/auth/sign-in/social`.                                                     |
| `happyPathProducesSessionWithProviderApple`         | `Session.provider == .apple`, `Session.token == response.token`.                                         |
| `identityTokenSentAsRawJWTNotBase64`                | `idToken.token` starts with `eyJ` (JWT magic prefix), not base64-re-wrapped.                              |
| `nonceIsBoundToBothApplePromptAndBetterAuthBody`    | `appleIDRequest.nonce == idToken.nonce` (string-identical, both the SHA-256 hex).                         |
| `firstSignInForwardsUserNameAndEmail`               | `idToken.user.name.{firstName,lastName}` and `idToken.user.email` are populated when Apple discloses them.|
| `subsequentSignInOmitsUserBlock`                    | The outbound JSON has NO `"user"` key when Apple does not re-disclose.                                   |
| `privateRelayEmailPassesThroughUnchanged`           | `Session.email` preserves the `@privaterelay.appleid.com` form.                                          |
| `sessionUserIdCarriesAppleSubVerbatim`              | `Session.userId == response.user.id` as a string — no UUID conversion.                                   |
| `cancellationThrowsAndDoesNotHitWorker`             | User cancellation in the Apple sheet does NOT POST to the worker.                                        |

If a downstream platform (Android, future Electron re-add) wires this contract, port the equivalents of `postsToSignInSocialPath`, `identityTokenSentAsRawJWTNotBase64`, `nonceIsBoundToBothApplePromptAndBetterAuthBody`, and `subsequentSignInOmitsUserBlock` first — those four catch the most common contract drift.

---

## 11. Cross-Team Checklist

Tick before any platform's SIWA build ships to its respective store / channel.

### Worker team confirms:

- [ ] `POST /api/auth/sign-in/social` accepts the Section 2.2 body shape and returns the Section 2.4 envelope on success.
- [ ] `GET /api/auth/get-session` returns the literal `null` body (NOT 401, NOT `{}`) when unauthenticated.
- [ ] All four `APPLE_*` wrangler secrets from Section 7 are configured for the target environment (production, sandbox/staging if applicable).
- [ ] The minted client secret in Section 8 expires more than 7 days from now (re-mint on every worker deploy; isolate-restart cycle handles the rest).
- [ ] Worker logs forward `auth.signin.*` events to Sentry with `provider`, `user_id` (if known), and a redacted JWT prefix (first 12 chars only — never log the full token).
- [ ] vitest fixtures in Section 10.1 pass against the deployed build.
- [ ] Reviewed Pitfall 1 (nonce binding) and Pitfall 8 (first-sign-in user block) in `15-RESEARCH.md`.

### iOS team confirms:

- [ ] `SignInWithAppleCoordinator` POSTs to `/api/auth/sign-in/social` (NOT the legacy `/api/auth/apple`).
- [ ] `idToken.token` is the raw JWT string, not base64-re-wrapped.
- [ ] `idToken.nonce` is the SHA-256 hex digest of the raw nonce, with the SAME hex string bound to `ASAuthorizationAppleIDRequest.nonce`.
- [ ] First-sign-in flow sends `idToken.user.name.{firstName, lastName}` and `idToken.user.email`. Subsequent sign-ins OMIT the `user` key.
- [ ] `Session.userId` is `String` (not `UUID`).
- [ ] `GetSessionEndpoint.Response` is `ProfileResponse?` and decoding the literal JSON `null` produces `nil`.
- [ ] Swift Testing fixtures in Section 10.2 are green.

### Future-platform team confirms (Android, Electron, etc.):

- [ ] Read Section 2 + Section 3 + Section 6 verbatim before writing any code; do NOT reverse-engineer from Better Auth's docs (version drift).
- [ ] Port the equivalent of `SiwaFlowTests::postsToSignInSocialPath` to the new platform's test framework FIRST.
- [ ] Confirm `user.id` is handled as a string everywhere (database join column, in-memory session model, API typings).
- [ ] If the platform exposes a different OAuth provider's nonce contract (Google's, for instance), do NOT cargo-cult its semantics onto Apple — confirm against `apple.mjs` in the installed `@better-auth/core` version.

### Support team confirms:

- [ ] Runbook for "user signed in once but the app says signed out" includes: confirm `GET /api/auth/get-session` returns `null` for the user's bearer token (token was expired/invalidated -> expected behaviour, ask user to re-sign-in), versus returns a `ProfileResponse` (decoder bug -> escalate to iOS team).
- [ ] Runbook for "I see a `@privaterelay.appleid.com` email — is that real?" answers YES, it forwards to the user's real address; sending mail works.
- [ ] Runbook for "I can't log in" includes the four-secret check from Section 7 as the first triage step.

### DevOps team confirms:

- [ ] `wrangler secret list` shows all four `APPLE_*` secrets present on production.
- [ ] Sentry receives `auth.signin.failure` with the JWT prefix (12 chars only) for triage; sustained `INVALID_TOKEN` rate alerts the on-call.
- [ ] The `.p8` private key file is backed up OUT of `~/Downloads/` — Apple's console only allows ONE download per key, ever.

---

## 12. References

- `15-CONTEXT.md` — Phase 15 locked decisions (this doc's source of authority).
- `15-RESEARCH.md` Section Better Auth Apple Provider, Section Common Pitfalls — pre-implementation analysis.
- `15-01-SUMMARY.md` — worker-side provider wiring + vitest.
- `15-06-SUMMARY.md` — iOS coordinator rewrite + nonce binding + SiwaFlowTests.
- `15-07-SUMMARY.md` — `SignInSocialEndpoint` declaration in `RishiAPI`.
- `apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/AuthAPI.swift` — wire shape Codable definitions.
- `apps/apple/Packages/RishiAuth/Sources/RishiAuth/Coordinators/SignInWithAppleCoordinator.swift` — iOS coordinator.
- `apps/apple/Packages/RishiAuth/Sources/RishiAuth/Coordinators/Nonce.swift` — nonce generation.
- `workers/worker/src/auth.ts` — provider configuration.
- `workers/worker/src/auth-apple-secret.ts` — ES256 client-secret minting.
- `workers/worker/node_modules/@better-auth/core/dist/social-providers/apple.{mjs,d.mts}` — Better Auth's Apple provider source (verified contract).
- `workers/worker/node_modules/better-auth/dist/api/routes/sign-in.mjs` — sign-in route source.
- Apple — **Sign in with Apple REST API:** https://developer.apple.com/documentation/sign_in_with_apple
- Apple — **Creating the client secret:** https://developer.apple.com/documentation/sign_in_with_apple/generate_and_validate_tokens
- Better Auth — **Apple Social Provider docs:** https://www.better-auth.com/docs/authentication/apple (read against installed `@better-auth/core@1.6.10` source if there's any disagreement; this contract is the truth)

---

*Phase: 15-production-siwa-ship-blocker-cleanup / Plan: 10 / Owner: matovu90@gmail.com / Last reviewed: 2026-06-11*

# Native Google Sign-In Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native Google Sign-In for iOS and Mac Catalyst while preserving the existing Rishi access/refresh JWT contract used by Sign in with Apple.

**Architecture:** GoogleSignIn-iOS supplies a Google ID token on the Apple target. A focused Worker route verifies that token with Google JWKS, resolves a `provider_id="google"` / Google `sub` identity in the existing Drizzle `account` table, and issues the existing Rishi JWT pair. The Apple UI’s existing session persistence and post-sign-in side effects are shared with the new Google path.

**Tech Stack:** SwiftUI, Xcode Swift Package Manager, GoogleSignIn-iOS 9.x, Cloudflare Workers, Hono, Drizzle ORM, `jose`, Vitest, Bun.

---

## Files and responsibilities

- Create `workers/worker/src/routes/google.ts` — Google token verification, provider lookup/creation, UUID compatibility check, deletion fence, rate limit, and `/google` route response.
- Create `workers/worker/src/routes/google.test.ts` — focused Google route security and idempotency tests.
- Modify `workers/worker/src/index.ts` — mount the Google route under `/auth`.
- Create `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/Endpoints/GoogleAuthAPI.swift` — typed `/auth/google` endpoint contract.
- Create `apps/apple/rishi/rishi/Auth/GoogleSignInCoordinator.swift` — Google SDK presentation and ID-token extraction.
- Modify `apps/apple/rishi/rishi/Auth/SignedOutView.swift` — Google button, loading state, exchange, and shared session completion.
- Modify `apps/apple/rishi/rishi/rishiApp.swift` — forward Google callback URLs through `GIDSignIn`.
- Modify `apps/apple/rishi/rishi/Info.plist` — Google client-ID keys and callback URL scheme placeholder/configuration.
- Modify `apps/apple/rishi/rishi/rishi-mac.entitlements` — add the Catalyst keychain access group required by GoogleSignIn-iOS.
- Modify `apps/apple/rishi/rishi.xcodeproj/project.pbxproj` — add the official GoogleSignIn-iOS package and `GoogleSignIn` product to the app target.
- Modify `apps/apple/rishi/rishi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` — resolve and pin the package.
- Modify `apps/apple/rishi/rishiTests/SignedOutViewModelTests.swift` or add a focused exchange test beside it — test the client endpoint payload without requiring the SDK.
- Modify `apps/apple/rishi/rishi/AppDependencies+Billing.swift` — sign out of Google’s SDK when the app performs its existing local sign-out sequence.
- Modify `apps/apple/docs/features/auth.md` — document Google as the second native provider and the configuration/deployment requirements.

The Better Auth `account` table is reused conditionally: native-created rows use deterministic IDs and UUID-backed Rishi users, while any pre-existing row linked to a non-UUID Better Auth user fails closed until explicitly migrated. This avoids a schema migration in the current task while preventing the native app from receiving an incompatible identity. A production preflight must inspect existing Google rows before rollout.

### Task 1: Add red tests for Google verification and identity mapping

**Files:** Create `workers/worker/src/routes/google.test.ts`.

- [ ] **Step 1: Write the test fixtures and failing route expectations.** Generate an ES256 key pair with `jose`, stub the Google cert endpoint, and provide an in-memory D1 plus fake `RATE_LIMIT_KV`. Assert the route accepts only a token whose `iss`, `aud`, `exp`, and `sub` are valid. Add tests for wrong audience, wrong issuer, expired token, missing `sub`, repeat sign-in, deterministic account ID, incompatible pre-existing user ID, same-email/different-sub separation, deletion fencing, and IP throttling.

```ts
const request = (token: string) => new Request("https://api.fidexa.org/auth/google", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ identityToken: token }),
});

expect((await app.fetch(request(validToken), env)).status).toBe(200);
expect((await app.fetch(request(wrongAudienceToken), env)).status).toBe(401);
```

- [ ] **Step 2: Run the focused test and verify it fails because the route is not mounted.**

Run: `bun test src/routes/google.test.ts` from `workers/worker`.

Expected: FAIL with the missing `/auth/google` implementation or route response.

### Task 2: Implement the Worker Google route

**Files:** Create `workers/worker/src/routes/google.ts`; modify `workers/worker/src/index.ts` and `workers/worker/src/ops/rate-limit.ts`.

- [ ] **Step 1: Add Google verification using the existing `jose` dependency.** Create one module-level `createRemoteJWKSet(new URL("https://www.googleapis.com/oauth2/v3/certs"))` and verify with:

```ts
await jwtVerify(identityToken, googleJWKS, {
  issuer: ["https://accounts.google.com", "accounts.google.com"],
  audience: c.env.GOOGLE_CLIENT_ID,
  maxTokenAge: "1h",
});
```

Reject empty tokens, missing `payload.sub`, and invalid claims with a generic 401 response. Do not log the token or email.

- [ ] **Step 2: Resolve or create the provider identity with Drizzle.** Query `account.provider_id = "google"` and `account.account_id = payload.sub`. If found, query the referenced user and require `UUID(uuidString: user.id)` before issuing tokens; otherwise return a generic migration-required response. If not found, create a UUID `user` row using the verified Google name/email and insert an account row with `id = "google:<sub>"`, `providerId = "google"`, `accountId = payload.sub`, and explicit timestamps. Handle the deterministic primary-key conflict by deleting only the newly created orphan user and re-reading the canonical row.

- [ ] **Step 3: Return the Apple-compatible response shape.** Use the existing `signAccessToken` and `signRefreshToken` helpers and return `{ accessToken, refreshToken, userId, user: { id, email, name } }`. Do not create a Better Auth session or return the Google ID token as a bearer token.

- [ ] **Step 4: Add IP abuse limiting and mount the route.** Add a `googleSignInIp` limit to `RATE_LIMITS`, key it with `CF-Connecting-IP` (or `unknown`), return 429 before token verification when exhausted, and mount the router with `app.route("/auth", googleRoutes)` beside the existing auth route. Then run `bun test src/routes/google.test.ts`.

Expected: all focused Google tests pass, including repeat sign-in and no email auto-linking.

### Task 4: Add the native Google client dependency and callback configuration

**Files:** Modify `apps/apple/rishi/rishi.xcodeproj/project.pbxproj`, `Package.resolved`, and `Info.plist`.

- [ ] **Step 1: Add `https://github.com/google/GoogleSignIn-iOS` through Xcode SPM.** Pin the package to the current 9.x major line and add only the `GoogleSignIn` product to the `rishi` application target. The custom Rishi button means `GoogleSignInSwift` is unnecessary.

- [ ] **Step 2: Add runtime configuration keys without committing secrets.** Add `GIDClientID` and `GIDServerClientID` as build-setting substitutions. `GIDServerClientID` must equal the worker’s `GOOGLE_CLIENT_ID`; `GIDClientID` must be the public iOS OAuth client ID. Add the reversed iOS client-ID scheme to `CFBundleURLTypes`. If the project has no supplied iOS ID, use an explicit `GOOGLE_IOS_CLIENT_ID` placeholder and make the coordinator report a configuration error rather than silently attempting sign-in.

- [ ] **Step 3: Configure Catalyst Keychain access.** Add `$(AppIdentifierPrefix)$(CFBundleIdentifier)` to `rishi-mac.entitlements` as a keychain access group, preserving the existing application group. Do not add a client secret or a Google token to entitlements.

- [ ] **Step 4: Resolve package dependencies.** Run `xcodebuild -resolvePackageDependencies -project apps/apple/rishi/rishi.xcodeproj` and confirm `GoogleSignIn` appears in `Package.resolved`.

### Task 5: Add the iOS/Catalyst Google flow and share session completion

**Files:** Create `GoogleAuthAPI.swift` and `GoogleSignInCoordinator.swift`; modify `SignedOutView.swift` and `rishiApp.swift`.

- [ ] **Step 1: Add a typed endpoint with the existing response model.** Define `GoogleAuthEndpoint.Body(identityToken:)`, use `POST /auth/google`, and decode the same `accessToken`, `refreshToken`, `userId`, and `user` response fields as `JWTEndPoint`.

- [ ] **Step 2: Add a `@MainActor` SDK coordinator.** Configure `GIDSignIn.sharedInstance.configuration` from `GIDClientID` and `GIDServerClientID`, locate the active window’s presenting `UIViewController`, call `signIn(withPresenting:)`, and return the non-empty `user.idToken.tokenString`. Treat SDK cancellation as a non-error cancellation result. Keep SDK imports out of `RishiCore`.

- [ ] **Step 3: Forward callback URLs.** Add `application(_:open:options:)` to `RishiAppDelegate` and return `GIDSignIn.sharedInstance.handle(url)`. Preserve existing URL behavior by returning `false` when Google does not handle a URL.

- [ ] **Step 4: Add the Google button and exchange.** Add a custom SwiftUI button below Apple’s button. Prevent simultaneous Apple/Google requests, call the coordinator, send the ID token through `GoogleAuthEndpoint`, and reuse one session-completion function for Keychain writes, `deps.setUserId`, sync retry, current-user state, consent, and entitlement refresh. Clear partial Keychain state on persistence failure.

- [ ] **Step 5: Sign out of the Google SDK in the existing local sign-out path.** Call `GIDSignIn.sharedInstance.signOut()` before clearing Rishi state so the next Google login can select a different account.

- [ ] **Step 6: Build the Apple target.** Run the focused Xcode build and fix compile/API issues before moving to review.

### Task 6: Documentation and implementation review

**Files:** Modify `apps/apple/docs/features/auth.md` and add an adversarial review log to the plan or a sibling review document.

- [ ] **Step 1: Document the final flow and required Google Cloud configuration.** State that Google `sub` is the provider key, client IDs are public configuration, the worker client secret is deployed-only, and email does not auto-link accounts.

- [ ] **Step 2: Run an independent implementation review.** Review the complete diff for token-confusion bugs, audience/issuer omissions, account collisions, callback handling, Catalyst compatibility, credential leakage, migration omissions, and Apple regressions. Log every Critical/High/Medium finding.

- [ ] **Step 3: Fix and re-review until no Critical/High findings remain.** Re-run the affected tests/build after every fix and record the final verdict as PASS or PASS WITH NOTES.

### Task 7: Verify and deploy

- [ ] **Step 1: Run worker type-check and focused/all relevant tests.**

Run: `bun run type-check` and `bun test src/routes/google.test.ts src/auth.test.ts` from `workers/worker`.

Expected: exit code 0 and zero failing tests.

- [ ] **Step 2: Build the Apple app.**

Run: `xcodebuild build -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17'`.

Expected: exit code 0. A real Google sign-in smoke test remains dependent on configured OAuth IDs and a signed runtime.

- [ ] **Step 3: Verify worker secret names without printing values.** Run `bunx wrangler secret list` from `workers/worker` after fixing/authorizing Wrangler access if needed, and confirm `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` are present.

- [ ] **Step 4: Deploy the worker.** Run `bun run deploy` from `workers/worker`, capture the successful deployment output, then make one unauthenticated request to the deployed `/auth/google` endpoint with no token and confirm it returns the expected client error rather than a route-not-found response.

- [ ] **Step 5: Check the final diff and worktree.** Confirm only Google Sign-In artifacts are committed; leave the pre-existing Drizzle migration changes untouched.

## Adversarial review — plan round 2

### Findings and resolutions

1. **Critical — Better Auth user IDs are not guaranteed UUIDs, while the native app still requires UUID-backed user IDs.** Resolved by creating UUID-backed native users and failing closed for incompatible pre-existing Google account rows.
2. **High — no composite provider uniqueness exists in the Better Auth account table.** Resolved for the native route by deterministic account primary keys and conflict recovery; the deployment preflight must identify existing duplicate provider rows.
3. **High — the custom public auth route bypassed Better Auth’s configured rate limit.** Resolved by adding an IP-based `RATE_LIMIT_KV` check before verification.
4. **High — a user pending deletion could receive a fresh session.** Resolved by checking `deletion_state` before issuing tokens.
5. **High — reusing Better Auth’s Google rows could silently split or break web/mobile identities.** Resolved by fail-closed UUID compatibility checks and documenting that same-email identities do not auto-link.
6. **High — returning a Google ID token would fail current API middleware.** Resolved by issuing the established Rishi JWT pair through `signAccessToken` and `signRefreshToken`.
7. **Medium — `GoogleSignInSwift` adds a package product without being needed by the existing custom design system.** Resolved by using a custom Rishi button and only `GoogleSignIn`.
8. **Medium — Catalyst keychain storage requires the Google SDK’s keychain access group configuration.** Resolved by adding the application-identifier access group to the Mac Catalyst entitlements and verifying the package README requirement.
9. **Medium — deployment could be claimed without verifying the worker has credentials.** Resolved by making secret-name verification and an unauthenticated deployed-route smoke test explicit gates.

### Re-review verdict

PASS WITH NOTES: no open Critical or High findings remain. The production Google-row preflight, public iOS client ID, deployed Google credentials, Catalyst keychain group, and Wrangler credentials are explicit gates; the implementation must report those gaps rather than commit secret values or claim live sign-in success without a smoke test.

## Adversarial review — implementation round 1

### Findings and resolutions

1. **High — an absent `GOOGLE_CLIENT_ID` could disable audience validation.** Resolved by trimming the configured worker audience and returning a configuration error before `jwtVerify` when it is missing.
2. **High — SwiftUI scene URL delivery was not bridged.** Resolved by forwarding URLs through the app’s `.onOpenURL` handler while retaining the existing application-delegate callback bridge so Google OAuth can resume on iOS and Mac Catalyst without removing deep-link propagation.
3. **Medium — the implementation test mocked JWT verification.** Accepted as a test-scope note because the production route uses `jose` with fixed Google JWKS, RS256, issuer, audience, required subject/expiry, and max age; the deployed smoke test remains an external credential/device gate.
4. **Medium — Google client ID build settings are intentionally placeholders.** Accepted as a configuration gate: the app fails with a user-facing configuration error until the public iOS, server/web, and reversed client IDs are supplied through Xcode build settings.

### Re-review status

The two High findings were fixed and the focused Worker suite was rerun (12 tests passing). The narrow independent re-review passed both fixes and found no new Critical or High issues.

### Re-review verdict

PASS WITH NOTES: no open Critical or High findings remain. The remaining notes are external configuration and runtime gates: the public iOS client ID/build settings must be supplied, and a real signed iOS or Catalyst flow still requires a configured OAuth client and interactive device test.

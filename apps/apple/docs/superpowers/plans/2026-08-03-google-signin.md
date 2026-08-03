# Native Google Sign-In Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native Google Sign-In for iOS and Mac Catalyst while preserving the existing Rishi access/refresh JWT contract used by Sign in with Apple.

**Architecture:** GoogleSignIn-iOS supplies a Google ID token on the Apple target. A focused Worker route verifies that token with Google JWKS, resolves a `provider_id="google"` / Google `sub` identity in the existing Drizzle `account` table, and issues the existing Rishi JWT pair. The Apple UI’s existing session persistence and post-sign-in side effects are shared with the new Google path.

**Tech Stack:** SwiftUI, Xcode Swift Package Manager, GoogleSignIn-iOS 9.x, Cloudflare Workers, Hono, Drizzle ORM, `jose`, Vitest, Bun.

---

## Files and responsibilities

- Create `workers/worker/src/routes/google.ts` — Google token verification, provider-account lookup/creation, and `/google` route response.
- Create `workers/worker/src/routes/google.test.ts` — focused Google route security and idempotency tests.
- Modify `workers/worker/src/index.ts` — mount the Google route under `/auth`.
- Create `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/Endpoints/GoogleAuthAPI.swift` — typed `/auth/google` endpoint contract.
- Create `apps/apple/rishi/rishi/Auth/GoogleSignInCoordinator.swift` — Google SDK presentation and ID-token extraction.
- Modify `apps/apple/rishi/rishi/Auth/SignedOutView.swift` — Google button, loading state, exchange, and shared session completion.
- Modify `apps/apple/rishi/rishi/rishiApp.swift` — forward Google callback URLs through `GIDSignIn`.
- Modify `apps/apple/rishi/rishi/Info.plist` — Google client-ID keys and callback URL scheme placeholder/configuration.
- Modify `apps/apple/rishi/rishi.xcodeproj/project.pbxproj` — add the official GoogleSignIn-iOS package and `GoogleSignIn` product to the app target.
- Modify `apps/apple/rishi/rishi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` — resolve and pin the package.
- Modify `apps/apple/rishi/rishiTests/SignedOutViewModelTests.swift` or add a focused exchange test beside it — test the client endpoint payload without requiring the SDK.
- Modify `apps/apple/docs/features/auth.md` — document Google as the second native provider and the configuration/deployment requirements.

No Drizzle migration is planned: the existing `account` table is the provider-identity store, and deterministic account-row IDs (`google:<sub>`) use its existing primary key to make concurrent first sign-ins idempotent without changing schema.

### Task 1: Add red tests for Google verification and identity mapping

**Files:** Create `workers/worker/src/routes/google.test.ts`.

- [ ] **Step 1: Write the test fixtures and failing route expectations.** Generate an ES256 key pair with `jose`, stub the Google cert endpoint, and assert the route accepts only a token whose `iss`, `aud`, `exp`, and `sub` are valid. Add tests for wrong audience, wrong issuer, expired token, missing `sub`, repeat sign-in, and a Google token whose email matches an existing Apple user but must create a separate user.

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

**Files:** Create `workers/worker/src/routes/google.ts`; modify `workers/worker/src/index.ts`.

- [ ] **Step 1: Add Google verification using the existing `jose` dependency.** Create one module-level `createRemoteJWKSet(new URL("https://www.googleapis.com/oauth2/v3/certs"))` and verify with:

```ts
await jwtVerify(identityToken, googleJWKS, {
  issuer: ["https://accounts.google.com", "accounts.google.com"],
  audience: c.env.GOOGLE_CLIENT_ID,
  maxTokenAge: "1h",
});
```

Reject empty tokens, missing `payload.sub`, and invalid claims with a generic 401 response. Do not log the token or email.

- [ ] **Step 2: Resolve or create the provider identity with Drizzle.** Query `account` by `providerId = "google"` and `accountId = payload.sub`. If found, query the referenced `user` and issue Rishi tokens for that user. If not found, create a new UUID `user` row using the verified Google name/email and insert an `account` row with `id = "google:<sub>"`, `providerId = "google"`, `accountId = payload.sub`, and `userId`. If the deterministic account insert reports a primary-key conflict, delete only the newly created orphan user and re-read the existing account/user.

- [ ] **Step 3: Return the Apple-compatible response shape.** Use the existing `signAccessToken` and `signRefreshToken` helpers and return `{ accessToken, refreshToken, userId, user: { id, email, name } }`. Do not create a Better Auth session or return the Google ID token as a bearer token.

- [ ] **Step 4: Mount the route and run the focused tests.** Mount the router with `app.route("/auth", googleRoutes)` beside the existing auth route, then run `bun test src/routes/google.test.ts`.

Expected: all focused Google tests pass, including repeat sign-in and no email auto-linking.

### Task 3: Add the native Google client dependency and callback configuration

**Files:** Modify `apps/apple/rishi/rishi.xcodeproj/project.pbxproj`, `Package.resolved`, and `Info.plist`.

- [ ] **Step 1: Add `https://github.com/google/GoogleSignIn-iOS` through Xcode SPM.** Pin the package to the current 9.x major line and add only the `GoogleSignIn` product to the `rishi` application target. The custom Rishi button means `GoogleSignInSwift` is unnecessary.

- [ ] **Step 2: Add runtime configuration keys without committing secrets.** Add `GIDClientID` and `GIDServerClientID` as build-setting substitutions. `GIDServerClientID` must equal the worker’s `GOOGLE_CLIENT_ID`; `GIDClientID` must be the public iOS OAuth client ID. Add the reversed iOS client-ID scheme to `CFBundleURLTypes`. If the project has no supplied iOS ID, use an explicit `GOOGLE_IOS_CLIENT_ID` placeholder and make the coordinator report a configuration error rather than silently attempting sign-in.

- [ ] **Step 3: Resolve package dependencies.** Run `xcodebuild -resolvePackageDependencies -project apps/apple/rishi/rishi.xcodeproj` and confirm `GoogleSignIn` appears in `Package.resolved`.

### Task 4: Add the iOS/Catalyst Google flow and share session completion

**Files:** Create `GoogleAuthAPI.swift` and `GoogleSignInCoordinator.swift`; modify `SignedOutView.swift` and `rishiApp.swift`.

- [ ] **Step 1: Add a typed endpoint with the existing response model.** Define `GoogleAuthEndpoint.Body(identityToken:)`, use `POST /auth/google`, and decode the same `accessToken`, `refreshToken`, `userId`, and `user` response fields as `JWTEndPoint`.

- [ ] **Step 2: Add a `@MainActor` SDK coordinator.** Configure `GIDSignIn.sharedInstance.configuration` from `GIDClientID` and `GIDServerClientID`, locate the active window’s presenting `UIViewController`, call `signIn(withPresenting:)`, and return the non-empty `user.idToken.tokenString`. Treat SDK cancellation as a non-error cancellation result. Keep SDK imports out of `RishiCore`.

- [ ] **Step 3: Forward callback URLs.** Add `application(_:open:options:)` to `RishiAppDelegate` and return `GIDSignIn.sharedInstance.handle(url)`. Preserve existing URL behavior by returning `false` when Google does not handle a URL.

- [ ] **Step 4: Add the Google button and exchange.** Add a custom SwiftUI button below Apple’s button. Prevent simultaneous Apple/Google requests, call the coordinator, send the ID token through `GoogleAuthEndpoint`, and reuse one session-completion function for Keychain writes, `deps.setUserId`, sync retry, current-user state, consent, and entitlement refresh. Clear partial Keychain state on persistence failure.

- [ ] **Step 5: Build the Apple target.** Run the focused Xcode build and fix compile/API issues before moving to review.

### Task 5: Documentation and implementation review

**Files:** Modify `apps/apple/docs/features/auth.md` and add an adversarial review log to the plan or a sibling review document.

- [ ] **Step 1: Document the final flow and required Google Cloud configuration.** State that Google `sub` is the provider key, client IDs are public configuration, the worker client secret is deployed-only, and email does not auto-link accounts.

- [ ] **Step 2: Run an independent implementation review.** Review the complete diff for token-confusion bugs, audience/issuer omissions, account collisions, callback handling, Catalyst compatibility, credential leakage, migration omissions, and Apple regressions. Log every Critical/High/Medium finding.

- [ ] **Step 3: Fix and re-review until no Critical/High findings remain.** Re-run the affected tests/build after every fix and record the final verdict as PASS or PASS WITH NOTES.

### Task 6: Verify and deploy

- [ ] **Step 1: Run worker type-check and focused/all relevant tests.**

Run: `bun run type-check` and `bun test src/routes/google.test.ts src/auth.test.ts` from `workers/worker`.

Expected: exit code 0 and zero failing tests.

- [ ] **Step 2: Build the Apple app.**

Run: `xcodebuild build -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17'`.

Expected: exit code 0. A real Google sign-in smoke test remains dependent on configured OAuth IDs and a signed runtime.

- [ ] **Step 3: Verify worker secret names without printing values.** Run `bunx wrangler secret list` from `workers/worker` after fixing/authorizing Wrangler access if needed, and confirm `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` are present.

- [ ] **Step 4: Deploy the worker.** Run `bun run deploy` from `workers/worker`, capture the successful deployment output, then make one unauthenticated request to the deployed `/auth/google` endpoint with no token and confirm it returns the expected client error rather than a route-not-found response.

- [ ] **Step 5: Check the final diff and worktree.** Confirm only Google Sign-In artifacts are committed; leave the pre-existing Drizzle migration changes untouched.

## Adversarial review — plan round 1

### Findings and resolutions

1. **High — adding a second random account mapping could create duplicate Google users under concurrent sign-in.** Resolved by deterministic `account.id = "google:<sub>"`, conflict recovery, and a repeat-sign-in test.
2. **High — using email to find an existing user would silently merge independent provider identities.** Resolved by provider/sub lookup only and an explicit no-email-auto-link test.
3. **High — putting the Google SDK in RishiCore would contaminate the platform-neutral module.** Resolved by keeping Google SDK imports in the app target and placing only the typed endpoint in the existing core endpoint area.
4. **High — returning a Google ID token would fail current API middleware.** Resolved by issuing the established Rishi JWT pair through `signAccessToken` and `signRefreshToken`.
5. **Medium — `GoogleSignInSwift` adds a package product without being needed by the existing custom design system.** Resolved by using a custom Rishi button and only `GoogleSignIn`.
6. **Medium — deployment could be claimed without verifying the worker has credentials.** Resolved by making secret-name verification and an unauthenticated deployed-route smoke test explicit gates.

### Re-review verdict

PASS WITH NOTES: no open Critical or High findings remain. The public iOS client ID and deployed Wrangler credentials are external prerequisites; the implementation must report those gaps rather than commit secret values or claim live sign-in success without a smoke test.

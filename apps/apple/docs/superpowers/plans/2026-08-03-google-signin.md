# Native Google Sign-In Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native Google Sign-In for iOS and Mac Catalyst while preserving the existing Rishi access/refresh JWT contract used by Sign in with Apple.

**Architecture:** GoogleSignIn-iOS supplies a Google ID token on the Apple target. A focused Worker route verifies that token with Google JWKS, resolves a `provider_id="google"` / Google `sub` identity in the existing Drizzle `account` table, and issues the existing Rishi JWT pair. The Apple UI’s existing session persistence and post-sign-in side effects are shared with the new Google path.

**Tech Stack:** SwiftUI, Xcode Swift Package Manager, GoogleSignIn-iOS 9.x, Cloudflare Workers, Hono, Drizzle ORM, `jose`, Vitest, Bun.

---

## Files and responsibilities

- Create `workers/worker/src/routes/google.ts` — Google token verification, native-provider lookup/creation, deletion fence, rate limit, and `/google` route response.
- Create `workers/worker/src/routes/google.test.ts` — focused Google route security and idempotency tests.
- Modify `workers/worker/src/db/schema.ts` — add the UUID-backed `google_users` provider table and uniqueness constraint.
- Create generated `workers/worker/drizzle/migrations/<timestamp>_google_users/` artifacts — migration output from Drizzle only.
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

The Better Auth `account` table is intentionally not reused: Better Auth’s default user IDs are not UUIDs, while this native app still decodes the Rishi user ID as a UUID. The new `google_users` table is the native provider-identity store, with a unique Google subject and a foreign key to the UUID-backed Rishi user. Drizzle must generate the migration; no SQL is hand-authored.

### Task 1: Add red tests for Google verification and identity mapping

**Files:** Create `workers/worker/src/routes/google.test.ts`.

- [ ] **Step 1: Write the test fixtures and failing route expectations.** Generate an ES256 key pair with `jose`, stub the Google cert endpoint, and provide an in-memory D1 plus fake `RATE_LIMIT_KV`. Assert the route accepts only a token whose `iss`, `aud`, `exp`, and `sub` are valid. Add tests for wrong audience, wrong issuer, expired token, missing `sub`, repeat sign-in, same-email/different-sub separation, deletion fencing, and IP throttling.

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

### Task 2: Add the native Google identity schema and generated migration

**Files:** Modify `workers/worker/src/db/schema.ts`; create generated migration artifacts under `workers/worker/drizzle/migrations/`.

- [ ] **Step 1: Add `googleUsers` to the Drizzle schema.** Define `id` as the primary key, `googleUserId` as a unique Google subject, `userId` as a required foreign key to `user.id` with cascade deletion, nullable email, verified-email flag, and created/updated timestamps. Keep this table separate from Better Auth’s `account` table.

- [ ] **Step 2: Generate the migration with Bun.**

Run: `bunx drizzle-kit generate --config=drizzle.config.ts` from `workers/worker`.

Expected: a new timestamped migration and matching metadata; do not edit the generated SQL.

- [ ] **Step 3: Review the generated migration and schema diff.** Confirm it creates only `google_users`, its unique Google-sub index, and the foreign key; do not delete or rename any existing migration directory.

### Task 3: Implement the Worker Google route

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

- [ ] **Step 2: Resolve or create the native provider identity with Drizzle.** Query `google_users.google_user_id = payload.sub`. If found, query the referenced UUID-backed `user`, reject the request if a `deletion_state` row is `pending` or `purging`, and issue Rishi tokens for that user. If not found, create a UUID `user` row using the verified Google name/email and insert a `google_users` row. Handle a unique-sub conflict by deleting only the newly created orphan user and re-reading the canonical row.

- [ ] **Step 3: Return the Apple-compatible response shape.** Use the existing `signAccessToken` and `signRefreshToken` helpers and return `{ accessToken, refreshToken, userId, user: { id, email, name } }`. Do not create a Better Auth session or return the Google ID token as a bearer token.

- [ ] **Step 4: Add IP abuse limiting and mount the route.** Add a `googleSignInIp` limit to `RATE_LIMITS`, key it with `CF-Connecting-IP` (or `unknown`), return 429 before token verification when exhausted, and mount the router with `app.route("/auth", googleRoutes)` beside the existing auth route. Then run `bun test src/routes/google.test.ts`.

Expected: all focused Google tests pass, including repeat sign-in and no email auto-linking.

### Task 4: Add the native Google client dependency and callback configuration

**Files:** Modify `apps/apple/rishi/rishi.xcodeproj/project.pbxproj`, `Package.resolved`, and `Info.plist`.

- [ ] **Step 1: Add `https://github.com/google/GoogleSignIn-iOS` through Xcode SPM.** Pin the package to the current 9.x major line and add only the `GoogleSignIn` product to the `rishi` application target. The custom Rishi button means `GoogleSignInSwift` is unnecessary.

- [ ] **Step 2: Add runtime configuration keys without committing secrets.** Add `GIDClientID` and `GIDServerClientID` as build-setting substitutions. `GIDServerClientID` must equal the worker’s `GOOGLE_CLIENT_ID`; `GIDClientID` must be the public iOS OAuth client ID. Add the reversed iOS client-ID scheme to `CFBundleURLTypes`. If the project has no supplied iOS ID, use an explicit `GOOGLE_IOS_CLIENT_ID` placeholder and make the coordinator report a configuration error rather than silently attempting sign-in.

- [ ] **Step 3: Resolve package dependencies.** Run `xcodebuild -resolvePackageDependencies -project apps/apple/rishi/rishi.xcodeproj` and confirm `GoogleSignIn` appears in `Package.resolved`.

### Task 5: Add the iOS/Catalyst Google flow and share session completion

**Files:** Create `GoogleAuthAPI.swift` and `GoogleSignInCoordinator.swift`; modify `SignedOutView.swift` and `rishiApp.swift`.

- [ ] **Step 1: Add a typed endpoint with the existing response model.** Define `GoogleAuthEndpoint.Body(identityToken:)`, use `POST /auth/google`, and decode the same `accessToken`, `refreshToken`, `userId`, and `user` response fields as `JWTEndPoint`.

- [ ] **Step 2: Add a `@MainActor` SDK coordinator.** Configure `GIDSignIn.sharedInstance.configuration` from `GIDClientID` and `GIDServerClientID`, locate the active window’s presenting `UIViewController`, call `signIn(withPresenting:)`, and return the non-empty `user.idToken.tokenString`. Treat SDK cancellation as a non-error cancellation result. Keep SDK imports out of `RishiCore`.

- [ ] **Step 3: Forward callback URLs.** Add `application(_:open:options:)` to `RishiAppDelegate` and return `GIDSignIn.sharedInstance.handle(url)`. Preserve existing URL behavior by returning `false` when Google does not handle a URL.

- [ ] **Step 4: Add the Google button and exchange.** Add a custom SwiftUI button below Apple’s button. Prevent simultaneous Apple/Google requests, call the coordinator, send the ID token through `GoogleAuthEndpoint`, and reuse one session-completion function for Keychain writes, `deps.setUserId`, sync retry, current-user state, consent, and entitlement refresh. Clear partial Keychain state on persistence failure.

- [ ] **Step 5: Build the Apple target.** Run the focused Xcode build and fix compile/API issues before moving to review.

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

1. **Critical — Better Auth user IDs are not guaranteed UUIDs, while the native app still requires UUID-backed user IDs.** Resolved by isolating native Google identities in `google_users` and creating UUID-backed Rishi users; Better Auth’s `account` table is not reused.
2. **High — no composite provider uniqueness existed in the Better Auth account table.** Resolved by the dedicated table’s unique Google subject and generated Drizzle migration.
3. **High — the custom public auth route bypassed Better Auth’s configured rate limit.** Resolved by adding an IP-based `RATE_LIMIT_KV` check before verification.
4. **High — a user pending deletion could receive a fresh session.** Resolved by checking `deletion_state` before issuing tokens.
5. **High — reusing Better Auth’s Google rows could silently split or break web/mobile identities.** Resolved by making the native boundary explicit and documenting that same-email identities do not auto-link.
6. **High — returning a Google ID token would fail current API middleware.** Resolved by issuing the established Rishi JWT pair through `signAccessToken` and `signRefreshToken`.
7. **Medium — `GoogleSignInSwift` adds a package product without being needed by the existing custom design system.** Resolved by using a custom Rishi button and only `GoogleSignIn`.
8. **Medium — deployment could be claimed without verifying the worker has credentials.** Resolved by making secret-name verification and an unauthenticated deployed-route smoke test explicit gates.

### Re-review verdict

PASS WITH NOTES: no open Critical or High findings remain. The generated migration, public iOS client ID, deployed Google credentials, and Wrangler credentials are explicit gates; the implementation must report those gaps rather than commit secret values or claim live sign-in success without a smoke test.

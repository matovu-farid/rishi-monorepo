# Electron bearer authentication compatibility

> **Status:** Adversarial review loop in progress

## Goal

Allow an authenticated Electron user to call the current Worker API using the
same `Authorization: Bearer …` transport used by the Apple app, while keeping
the Apple app's legacy custom-JWT endpoints and behavior unchanged.

## Verified research

The two clients currently use different token issuers:

| Client | Sign-in/token source | Protected API transport |
|---|---|---|
| Apple | `/auth/apple` or `/auth/google` returns custom HS256 `accessToken` + `refreshToken` | `Authorization: Bearer <accessToken>`; refreshes `/auth/refresh` after `401` |
| Electron | `/desktop/start` + `/desktop/poll` returns Better Auth `session_token` | `Authorization: Bearer <session_token>` from the main-process encrypted session store |

The Worker currently has the pieces for both systems, but they are not wired
together:

- `workers/worker/src/middleware.ts` only verifies the custom HS256 access JWT.
- `workers/worker/src/auth.ts` configures Better Auth's `bearer()` plugin, but
  `workers/worker/src/index.ts` does not mount the `/api/auth/*` handler.
- Electron calls `/api/auth/get-session`, `/api/auth/sign-out`, and
  `/api/auth/delete-user` from
  `apps/rishi-electron/src/main/auth/auth-service.ts`.
- The production Electron renderer is served from a loopback HTTP origin, but
  the Worker CORS allow-list does not cover its fixed or fallback loopback
  ports.
- The Electron voice-input path can construct `Authorization: Bearer null`
  when no session token exists instead of following the app's existing
  authenticated/dev-bypass policy.

## Decision and alternatives

### Recommended: additive dual-auth Worker compatibility

1. Mount Better Auth's existing `/api/auth/*` handler.
2. Extend `makeRequireAuth` so it first preserves the current custom access-JWT
   verification and, only when that fails, asks Better Auth to resolve the
   bearer session from the same request headers.
3. Run the existing user-existence, pending-deletion, and username-repair
   checks after either verifier resolves a user id.
4. Permit only the known web/native origins plus Electron's loopback renderer
   origins in CORS.
5. Normalize the one Electron direct-fetch path that emits `Bearer null`.

This lets existing Electron installs keep their stored Better Auth session
token and lets Apple keep its custom access JWT without token conversion,
database migration, or changes to Apple refresh semantics.

### Not selected: mint custom Apple-style JWTs from `/desktop/poll`

This would require Electron to persist a second token family, add refresh
coalescing and expiry handling, and coordinate two credentials during sign-out.
It creates more race and migration surface than the requested compatibility
layer.

### Not selected: replace the custom middleware with Better Auth only

This would regress Apple and other clients that use the existing HS256 access
JWT contract. The current custom path must remain first-class.

## Files and responsibilities

| File | Planned change |
|---|---|
| `workers/worker/src/middleware.ts` | Add a Better Auth bearer fallback while preserving custom JWT verification and post-auth account checks. |
| `workers/worker/src/cors-origin.ts` (new) | Resolve preserved explicit origins and narrowly allow numeric-port Electron loopback origins. |
| `workers/worker/src/routes/auth-compat.ts` (new) | Own Electron's additive `POST /api/auth/delete-user` compatibility endpoint and delegate to the existing `deleteAccount` workflow. |
| `workers/worker/src/routes/better-auth.ts` (new) | Mount Better Auth's `/api/auth/*` handler without replacing the Worker's legacy `/auth/*` routes. |
| `workers/worker/src/index.ts` | Mount `authCompatRoutes` before Better Auth's wildcard, mount Better Auth `/api/auth/*` for non-delete auth calls, and replace the static CORS origin list with an explicit-origin plus loopback-origin predicate. Preserve all existing origins, headers, and methods. |
| `workers/worker/src/middleware.test.ts` | Add tests for custom-token precedence, Better Auth bearer fallback, invalid/missing auth rejection, and deletion-mode behavior. |
| `workers/worker/src/routes/auth-compat.test.ts` (new) | Verify `POST /api/auth/delete-user` runs the same full cleanup/revocation workflow as `DELETE /api/user` and is protected by the dual-auth middleware. |
| `workers/worker/src/index.auth.test.ts` (new) | Verify the mounted `/api/auth/*` route delegates to Better Auth for session and sign-out requests without disturbing legacy `/auth/*` routes or the exact delete-user compatibility route. If importing the full app is too coupled, extract a small route factory and test that factory. |
| `workers/worker/src/index.cors.test.ts` (new) | Verify existing Apple/web/native origins remain allowed, the Electron loopback origin is echoed, and unrelated origins are rejected. |
| `apps/rishi-electron/src/renderer/src/hooks/useVoiceInput.ts` | Avoid sending `Bearer null`; use the same token-or-dev-bypass/missing-auth behavior as the other Worker calls. |
| `apps/rishi-electron/src/renderer/src/hooks/useVoiceInput.test.ts` (new) | Assert an authenticated request sends the bearer and an unauthenticated request never sends `Bearer null`. |

No Apple source files, Apple endpoint paths, Apple token storage, Worker
database schema, or migrations are in scope.

## Implementation order

### 1. Add a testable dual-auth resolver

In `workers/worker/src/middleware.ts`, keep `verifyAccessToken` as the first
branch. For a bearer token that is not a valid custom access JWT, call
`createAuth(c.env).api.getSession({ headers: c.req.raw.headers })`. Accept the
request only when Better Auth returns a session and use `session.user.id` as
the Worker `userId`. Do not fall back to cookie-only authentication in this
middleware when the request has no bearer header; the goal is explicit bearer
compatibility and the existing middleware's missing-header behavior remains
401.

The resolver should have this shape so the two token contracts remain
deliberately ordered and testable:

```ts
const authHeader = c.req.header("Authorization");
if (!authHeader?.startsWith("Bearer ")) return unauthorized(c);

const token = authHeader.slice(7);
let userId: string | undefined;
const custom = await Effect.runPromiseExit(verifyAccessToken(c.env, token));
if (custom._tag === "Success") {
  userId = custom.value.userId;
} else {
  const auth = await createAuth(c.env);
  const session = await auth.api.getSession({ headers: c.req.raw.headers });
  userId = session?.user.id;
}
if (!userId) return unauthorized(c);
// Existing account/deletion/username checks follow once, using userId.
```

The implementation must keep exception behavior safe: Better Auth lookup
failures should become the existing JSON 401 for an invalid session rather than
leaking token-family details, while unexpected database/configuration errors
should continue to surface as Worker errors. Keep the helper's existing
`allowMissingUser` option unchanged.

After either branch resolves a user id, run the existing account-deletion,
user-existence, and `ensureUsername` checks exactly once. Preserve the
`allowMissingUser` option for deletion routes. Preserve the current custom JWT
failure response (`401 { error: "Unauthorized" }`) and do not expose which
token family was attempted.

Add focused tests with a mocked `createAuth` session resolver:

- a valid custom JWT still reaches the handler without calling Better Auth;
- a Better Auth bearer session reaches the handler and sets its user id;
- missing, invalid, and sessionless bearer requests remain 401;
- username allocation and deletion-state checks apply identically to both
  token families;
- `requireAuthForDeletion` still allows the existing deleted-account path only
  for a verified identity.

### 2. Add an explicit Electron deletion compatibility route

Create `workers/worker/src/routes/auth-compat.ts` with a typed Hono router.
Its `POST /delete-user` handler must use `requireAuthForDeletion`, call the
same `deleteAccount(db, env, userId)` function used by
`workers/worker/src/routes/user.ts`, and return the same `{ ok,
alreadyDeleted, revocationStatus }` response shape and error behavior. This
route exists because Better Auth's generic `delete-user` handler does not run
the Worker's cleanup, entitlement revocation, retention, and idempotency
workflow.

Mount it as `app.route("/api/auth", authCompatRoutes)` before the Better Auth
wildcard handler. Do not alter `DELETE /api/user`; Apple continues to use that
custom route.

Add tests that prove both custom Apple-style bearer and Better Auth bearer
session requests can reach the compatibility route, and that the route calls
the existing deletion workflow exactly once. Include an idempotent already
deleted case and a failed-revocation response case matching the existing
account-deletion integration contract.

### 3. Mount Better Auth without touching legacy auth routes

In `workers/worker/src/index.ts`, add the existing intended handler:

```ts
app.route("/api/auth", authCompatRoutes);

app.on(["GET", "POST"], "/api/auth/*", async (c) => {
  const auth = await createAuth(c.env);
  return auth.handler(c.req.raw);
});
```

Keep `app.route("/auth", googleRoutes)`, `app.route("/auth", authRoutes)`,
and every existing `/api/*` route in place. The mounted handler must support
Electron's current `/api/auth/get-session` and `/api/auth/sign-out` calls
through the configured Better Auth `bearer()` plugin. The exact
`/api/auth/delete-user` path must be handled by `authCompatRoutes`, not by
Better Auth's generic delete handler. Do not rename or remove `/auth/apple`,
`/auth/google`, or `/auth/refresh`.

Add a route-level test that uses a stubbed `createAuth`/handler boundary (or a
small extracted `betterAuthRoutes` factory) to prove the `/api/auth/*` mount
delegates the original request, the exact delete path is intercepted by the
compatibility route, and legacy `/auth/*` routing remains registered. Keep the
existing Better Auth unit tests separate from active Apple's `/auth/apple` and
`/auth/google` custom-token contract tests.

### 4. Make Electron's loopback renderer origin CORS-safe

Change the CORS `origin` option in `workers/worker/src/index.ts` to a narrow
predicate backed by the current explicit allow-list. It must:

- return the exact origin for the existing web, Tauri, mobile, and localhost
  development entries;
- return the exact origin for `http://127.0.0.1:<port>` and
  `http://localhost:<port>` only when the port is numeric and in the valid
  range;
- return `undefined` for arbitrary or non-HTTP origins;
- leave `allowHeaders` including `Authorization` and
  `X-Rishi-Data-Use-Consent`, `allowMethods`, and credential behavior intact.

Test preflight/normal responses for an Electron loopback origin, an existing
Apple/native origin, and an unrelated origin. Do not use `*`, and do not
broaden access to arbitrary loopback schemes or arbitrary origins.

### 5. Normalize the Electron voice-input header path

In `apps/rishi-electron/src/renderer/src/hooks/useVoiceInput.ts`, obtain the
token through the existing auth IPC wrapper. Send `Authorization: Bearer …`
only for a non-empty token; otherwise use the existing development bypass if
available and otherwise fail as unauthenticated before making the request.
Keep the Worker URL and `/api/audio/transcribe` endpoint unchanged.

Add request-header assertions for both authenticated and unauthenticated
paths. Do not refactor every direct Worker fetch in this change; the Worker
compatibility layer is the shared fix, and the voice-input correction is the
only confirmed malformed-header call site.

## Verification

Run from `workers/worker` with Bun:

```bash
bunx vitest run src/middleware.test.ts src/index.auth.test.ts src/index.cors.test.ts
```

Run the Electron focused tests from `apps/rishi-electron` with the package's
existing test command:

```bash
pnpm exec vitest run src/main/auth/auth-service.test.ts src/renderer/src/hooks/useVoiceInput.test.ts src/renderer/src/services/sync/service.test.ts
```

Then run these exact package gates:

```bash
cd workers/worker && bun run type-check
cd apps/rishi-electron && pnpm exec tsc --noEmit -p tsconfig.node.json --composite false
cd apps/rishi-electron && pnpm exec tsc --noEmit -p tsconfig.web.json --composite false
cd apps/rishi-electron && pnpm exec vitest run src/main/auth/auth-service.test.ts src/renderer/src/hooks/useVoiceInput.test.ts src/renderer/src/services/sync/service.test.ts
cd apps/rishi-electron && pnpm run build
```

Finally run the existing Apple-facing Worker contract tests that exercise
`/auth/apple`, `/auth/google`, `/auth/refresh`, and `DELETE /api/user`, plus the
full focused Worker suite:

```bash
cd workers/worker && bunx vitest run src/routes/google.test.ts src/routes/user.test.ts src/account-deletion.integration.test.ts
cd workers/worker && bunx vitest run
```

A successful verification must show zero test
failures, clean typechecks/builds for the touched packages, and unchanged
Apple-contract responses.

## Consumer / call-site audit

| Consumer | Credential expected | Compatibility requirement |
|---|---|---|
| Apple `WorkerClient` | custom HS256 access JWT | Must remain unchanged and continue to win the first verification branch. |
| Electron `AuthService` | Better Auth session token | `/api/auth/*` handler and middleware fallback must accept its bearer header. |
| Electron sync/upload/chat/voice/embed clients | bearer header from `getAuthToken()` | Existing endpoints must accept either token family; no endpoint removal. |
| Web Better Auth | cookie/session handler | `/api/auth/*` mount must preserve Better Auth behavior and trusted origins. |
| `/desktop/start`, `/desktop/poll`, `/desktop/cancel` | PKCE/state, intentionally unauthenticated | Must not be protected by the new middleware fallback. |
| Account deletion | Apple custom bearer at `DELETE /api/user`; Electron Better Auth bearer at `POST /api/auth/delete-user` | Preserve both routes; the Electron compatibility route must delegate to the same full cleanup workflow as `/api/user`. |

## Explicitly out of scope

- Changing Apple auth, token refresh, Keychain storage, or request headers.
- Replacing custom JWTs with Better Auth sessions or vice versa.
- Minting/rotating a second token family for Electron.
- Changing `/desktop/*` PKCE state semantics.
- Database schema/migrations, billing logic, or sharing-worker authentication.
- Broad Electron API-client refactors beyond the confirmed malformed voice-input
  header.

## Adversarial review loop

Each round follows: review → log findings → update this plan → re-review.

### Round 1 — Research review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Electron receives a Better Auth session token, while `requireAuth` verifies only the custom Apple JWT family. | Add a Better Auth bearer fallback after custom verification in `middleware.ts`, with tests for both families. |
| 2 | High | Electron's `/api/auth/*` calls are unreachable because the handler is commented out in `index.ts`. | Mount the existing Better Auth handler additively; preserve all `/auth/*` legacy routes. |
| 3 | High | Production Electron uses a loopback renderer origin not covered by the static CORS list. | Add a narrow numeric-port loopback predicate and preflight tests. |
| 4 | Medium | `useVoiceInput.ts` can send `Bearer null`, creating inconsistent unauthenticated behavior. | Normalize that call site and add header assertions. |
| 5 | High | Better Auth's generic delete-user handler would not run the Worker's full account-deletion cleanup and could diverge from Apple's `DELETE /api/user`. | Add an exact, pre-wildcard `POST /api/auth/delete-user` compatibility route that delegates to the existing `deleteAccount` workflow; preserve `DELETE /api/user`. |

**Round 1 result:** Re-review required. The generic Better Auth delete route
was explicitly rejected in favor of a compatibility route that reuses the
Worker's existing cleanup workflow.

### Round 2 — Plan re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The original plan could route Electron deletion through Better Auth's generic delete handler and skip Worker-specific cleanup. | Added `routes/auth-compat.ts`, mounted before the wildcard, and specified delegation/tests against `deleteAccount`. |
| 2 | High | The original plan conflated active Apple custom auth routes with unused Better Auth endpoint models. | Plan now treats `/auth/apple`, `/auth/google`, `/auth/refresh`, and `DELETE /api/user` as immutable Apple contracts and tests them separately. |
| 3 | Medium | A static list of exact loopback ports would miss Electron's fallback ephemeral port. | Use a narrow numeric-port predicate for `127.0.0.1`/`localhost`, with explicit rejection of unrelated origins. |
| 4 | Medium | The plan did not explicitly prove the polled Better Auth token can authenticate a protected Worker route. | Add a desktop/middleware contract test covering the token returned by `/desktop/poll` against `/api/sync/*` or `/api/user`. |

**Round 2 result:** Re-review required until the updated route ordering,
deletion delegation, token-family fallback, and executable verification
commands are independently confirmed.

### Round 3 — Re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Low | Better Auth token verification will log a failed custom-JWT attempt before the fallback. | Accepted as non-blocking diagnostic noise; do not change `jwt.ts` or Apple logging behavior in this scope. |
| 2 | Low | The Electron renderer can use a fixed or fallback numeric loopback port. | Explicit numeric-port predicate and rejection tests are specified; no broad wildcard CORS is allowed. |

**Round 3 result:** PASS — 0 open Critical/High issues. The plan now has an
explicit dual-token order, an exact deletion compatibility route before the
Better Auth wildcard, preserved Apple contracts, narrow CORS behavior, and
executable package verification commands.

> **Status:** Adversarial review loop complete — **PASS** (3 rounds, 0 open
> Critical/High issues)

## Implementation adversarial review loop

### Round 1 — Independent implementation review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | A Better Auth fallback must not accidentally authenticate an invalid bearer using a valid cookie on the same request. | `workers/worker/src/middleware.ts` now copies request headers, removes `Cookie`, and passes the explicit bearer header only to Better Auth. |
| 2 | Medium | The full Electron Vitest runner is unavailable because `apps/rishi-electron` has no installed local Vitest dependency. | The helper test remains in the change; Worker verification is run with Bun, and the Electron dependency limitation is reported rather than hidden. |

**Round 1 result:** Re-review required for the auth-boundary fix.

### Round 2 — Re-review

Independent reviewer verdict: **PASS** — 0 open Critical/High issues. The
review confirmed custom-JWT precedence, cookie stripping for Better Auth
fallback, exact delete-route ordering, narrow loopback CORS, preserved Apple
routes, and the Electron `Bearer null` fix. The focused Worker suite passed
45/45 tests.

# API Versioning and Apple Worker Development Policy

> **Status:** Accepted — one versioned public API Worker; Apple clients always use the production Worker

## Problem

The Apple client must use the canonical production API and sharing Workers so
development and release testing exercise the same deployed contracts. A local
Worker can be unavailable, can have different authentication/data, and can
make a client network failure look like an application bug.

The repository needs a durable policy that keeps already-installed clients
working, makes Apple development use the canonical deployed backend, and makes
the backend used by a test explicit and observable.

## Decisions

### 1. API contracts are immutable once released

- Existing unversioned `/api/...` routes are legacy contracts. They are frozen:
  their request shape, response shape, status meanings, and authentication
  behavior must not be changed for the benefit of a newer client.
- New API families begin under `/api/v1/...`.
- A new endpoint added to the current version does not require a version bump.
- The API version is bumped only when an existing endpoint contract changes in
  a breaking way. The previous version remains available for installed apps
  until its retirement is explicitly planned and communicated.
- Additive, backward-compatible fields may be introduced only when older
  clients safely ignore them. A field removal, rename, type change, changed
  requiredness, changed authentication requirement, or changed status/error
  semantics requires a new version.
- Shared reading is not yet a released Apple contract. Before release, its
  routes move from `/api/reading-sessions...` to `/api/v1/reading-sessions...`.
  No compatibility alias is required unless evidence shows that a deployed
  client already calls the unversioned route.
- Worker route modules, Apple endpoint definitions, tests, and documentation
  must use the same versioned path. A route is not considered released until
  its Worker deployment and client build are verified together.
- The existing sharing Worker `/v1` transport is also frozen. New sharing
  semantics must not be added to the legacy `SessionRoom` class, its `/v1`
  routes, or its stored state. They require a new versioned transport (the
  Apple implementation uses `/v2`) and a separate Durable Object class and
  binding. Add the new class through an append-only Wrangler migration; never
  repoint an existing Durable Object binding or reinterpret legacy state.
- The primary Worker must select the sharing transport version explicitly in
  its service client and WebSocket URL. A new client version must never rely on
  a legacy `/v1` fallback when the versioned transport is unavailable.
- The primary Worker's `SHARING_INTERNAL_SECRET` and sharing Worker's
  `WORKER_HMAC_SECRET` are the same shared trust secret. Rotate and set both
  production secrets together; rotating only one breaks signed primary-to-
  sharing requests.

### 2. Production has one canonical API Worker

- `rishi-worker` remains the production API Worker and `rishi-sharing-worker`
  remains its production service-bound sharing Worker. The sharing Worker is an
  internal transport service, not a second public API or a dev/prod API split.
- There is no permanent separate development API Worker. The same versioned
  Worker code and API contract are used in production and in development;
  development changes are exercised through Wrangler.
- Production deployments are the only place where production custom domains,
  production D1, production R2, production KV, and production Durable Objects
  may be selected.
- A local development process must never deploy, migrate, or mutate production
  resources as part of ordinary Apple testing.
- A Worker deployment must report its deployed API version and Worker version
  in logs/health output so a client failure can distinguish an old deployment
  from an application error.
- The health response body remains backward-compatible (`200` and the existing
  human-readable body); version metadata is added as response headers and
  structured logs rather than changing the body that existing probes may parse.

### 3. Apple development and testing use production

- Apple development and testing always use `https://api.fidexa.org` and
  `wss://sharing.fidexa.org`, including Debug builds and simulator tests.
- The Apple app must not read endpoint overrides from process environment
  variables. A missing or malformed compiled production endpoint is a visible
  setup failure, not a reason to fall back to localhost.
- Do not start the repository local Worker launcher as part of Apple testing.
  The local Worker configs may remain available for isolated Worker-only work,
  but they are not a valid Apple app backend.
- Before testing, verify the production API and sharing Worker health/version
  and record the selected endpoints. Never create duplicate Worker processes.
- Real accounts, books, D1/R2/KV data, and Durable Objects used by a manual
  Apple test are production resources and must be treated as user data.
- Worker-only route/protocol tests may use local simulated bindings, but they
  must not be described as Apple end-to-end tests and must not change the
  Apple endpoint configuration.

### 5. Apple endpoint selection is explicit and centralized

- The Apple app has one injected `RishiAPIEnvironment`/endpoint configuration
  used by `WorkerClient`, `SharedReadingAPI`, voice services, and any direct
  Worker endpoint helper.
- This audit includes every production fallback currently found in
  `ServiceGraphFactory.swift`, `WorkerEndpoint.swift`,
  `PurchaseService.swift`, `VoiceSessionPresenter.swift`, and
  `SharedReadingAPI.swift`. Tests may continue to inject arbitrary test URLs,
  but production application code must not construct an unconfigured client
  with its own production default.
- All builds use `https://api.fidexa.org` and `wss://sharing.fidexa.org` from
  the compiled centralized configuration. No build may inherit an endpoint
  from a process environment override or silently fall back to localhost.
- The app displays or logs the selected production environment and base URL in
  Debug so a test record proves which backend was used. Secrets and bearer
  tokens must not be logged.
- Shared reading receives the same base URL as the rest of the app. It must
  not retain a separate production default, because that can make a Debug app
  send sync traffic locally while sending session creation to production.
- Both simulators and physical devices use the public production endpoints;
  neither may be configured with a Mac loopback URL or a local Worker URL.

### 6. Startup and test procedure is part of the policy

Every Apple Worker-backed test follows this order:

1. Check for existing Apple app processes. Reuse a healthy app instance or stop
   it; do not create duplicate app instances.
2. Verify the production primary and sharing Worker health/version and record
   the selected URLs. Do not start local Worker processes for Apple testing.
3. Launch exactly the Apple targets required by the test, with the compiled
   production endpoint configuration.
4. Run the test and collect Worker/app logs on every failure.
5. Stop the app processes started by the test, unless the user explicitly asks
   to keep them open.

The launcher and Apple test harness must make a missing Worker a visible setup
failure. A network error must identify the base URL, API version, route,
HTTP status, Worker version when available, and a redacted request correlation
identifier.

## Proposed implementation surface

The implementation should be limited to these areas:

| Area | Proposed change |
|---|---|
| Worker route registration | Add a versioned `/api/v1` route group for shared reading and preserve existing legacy routes. |
| Worker configuration | Keep production API and sharing Worker bindings versioned and deployable without changing legacy contracts. |
| Worker scripts/docs | Document production health/version checks, duplicate-process detection, and Bun-only Worker commands. |
| Apple configuration | Use one compiled production endpoint configuration for Debug/Release containing the primary HTTP URL and sharing WebSocket URL; inject it through `ServiceGraphFactory`. |
| Apple networking | Remove hard-coded defaults and duplicated environment reads from `WorkerEndpoint`, billing, voice, and shared reading; make direct endpoint helpers use the same configuration. |
| Diagnostics | Add backward-compatible health headers and log environment, API version, route, status, and Worker correlation/version metadata without credentials or user content. |
| Tests | Add route compatibility tests, production endpoint-selection tests, and a two-account shared-reading smoke path. |
| Repository policy | Add this policy to the future-agent instructions and link the startup procedure from the Apple/Worker documentation. |

## Explicitly out of scope

- Creating or deploying a permanent development Worker service.
- Changing production routes or production data bindings.
- Automatically migrating or cleaning production D1/R2 data.
- Making a physical iPhone use loopback networking.
- Retiring legacy API versions without a separate compatibility/deprecation
  decision.
- Fixing unrelated existing Apple test-target compilation failures.

## Acceptance criteria

- A fresh Apple Debug run always calls `api.fidexa.org` and never localhost.
- A Release build always uses the same production endpoint.
- Shared reading and all other Worker-backed Apple features use the same chosen
  endpoint configuration.
- Apple test setup verifies the canonical production API Worker and its
  internal sharing service exactly once and does not launch local substitutes.
- The shared-reading API is versioned before release, while legacy routes remain
  unchanged and covered by compatibility tests.
- A failed request identifies enough information to tell apart a client bug,
  a stale deployment, an unreachable production Worker, an auth failure, and a Worker
  route/data failure.
- Worker-only seeded smoke tests may exercise the route/protocol without
  production resources, and a separate two-account Apple test can create,
  redeem/join, and start a shared reading session against the canonical
  production backend.

## Adversarial review loop

This artifact must receive an independent research/spec review before an
implementation plan is written. The reviewer must specifically try to disprove:

- that every Apple Worker call uses the centralized endpoint;
- that Apple builds cannot select local or unconfigured Worker endpoints;
- that the production primary-to-sharing service binding works with the
  versioned sharing transport;
- that versioning shared reading before release does not strand any deployed
  client; and
- that startup/cleanup cannot leave duplicate Workers or app instances.

### Round 1 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Endpoint selection is duplicated in `WorkerEndpoint.swift`, `PurchaseService.swift`, `VoiceSessionPresenter.swift`, and `SharedReadingAPI.swift`; changing only `ServiceGraphFactory` would leave production fallbacks. | The Apple networking decision now names every discovered production fallback and requires one injected configuration for all production call paths. |
| 2 | High | A local Worker with simulated bindings cannot authenticate the existing production accounts or see their books, so it cannot prove the requested two-account flow. | Apple tests now use the canonical production Workers, while local seeded protocol tests remain explicitly Worker-only. |
| 3 | High | An Apple build pointed at a local or stale Worker can turn a setup mismatch into a misleading app failure. | Apple endpoint selection is compiled to the canonical production URLs and process-environment overrides are removed. |
| 4 | Medium | Changing `/health` response JSON/text to include version data could break existing probes. | Version metadata is carried in headers and structured logs while preserving the current successful health body. |
| 5 | Medium | The HTTP API base URL does not determine the sharing WebSocket URL. | The Apple environment carries separate compiled production HTTP and WebSocket endpoints. |

**Round 1 result:** Re-review required until the updated draft is checked again against all call sites and the local binding topology.

### Round 2 — Re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The updated endpoint audit still needs an explicit rule for direct `WorkerEndpoint.send()` callers, which currently construct their own client from process environment. | The Apple networking rule explicitly includes direct endpoint helpers and requires production code to receive the centralized production configuration; implementation tests will fail if an app path still reads `RISHI_API_URL` directly. |
| 2 | Medium | A physical-device URL can be configured incorrectly as loopback and produce a misleading network failure. | The production endpoint is used for both simulators and physical devices, so no loopback configuration is permitted. |
| 3 | Low | Existing Worker READMEs use npm/pnpm examples despite the repository’s Bun-only Worker policy. | The implementation surface explicitly includes correcting both Worker README command sets. |

**Round 2 result:** PASS WITH NOTES — 0 open Critical/High issues. The Medium/Low items are concrete implementation requirements above; implementation planning may proceed after user review.

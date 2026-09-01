# API Versioning and Apple Worker Development Policy

> **Status:** Draft — awaiting user review before implementation

## Problem

The Apple client currently reaches the production API by default, while the
Worker source contains features that may not yet be deployed. That makes it
easy to test a local Apple build against an older production contract and to
mistake a deployment mismatch for an application bug. It also creates a risk
that a local Worker process inherits production D1, R2, KV, Durable Object, or
custom-domain configuration.

The repository needs a durable policy that keeps already-installed clients
working, gives Apple development a deterministic local backend, and makes the
backend used by a test explicit and observable.

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

### 2. Production has one canonical Worker

- `rishi-worker` remains the production API Worker and `rishi-sharing-worker`
  remains its production service-bound sharing Worker.
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

### 3. Local Wrangler is the default development backend

- Apple development starts the primary Worker and sharing Worker locally with
  Wrangler before launching the Apple app.
- The normal mode is local execution with local simulated bindings. This keeps
  D1, R2, KV, and Durable Object state isolated from production.
- The launcher owns both child processes, waits for both `/health` endpoints,
  records their URLs/PIDs, and stops both processes when the test session ends.
- The launcher must refuse to start a second copy when the managed ports are
  already occupied by a process it did not create. It should print the owning
  process and require an explicit cleanup/retry rather than silently choosing a
  different port, because the Apple endpoint must be unambiguous.
- The primary local Worker must use a local service binding to the local
  sharing Worker. Its development WebSocket URL must be the local sharing URL,
  not `wss://sharing.fidexa.org`.
- The local primary and sharing Workers must use separate, deterministic ports
  (for example, 8787 and 8788) and the launcher must pass the actual values to
  the Apple Debug configuration. The API base URL and sharing WebSocket URL are
  separate settings; one must not be inferred from the other.
- Local development configuration must contain no production custom-domain
  routes and no production resource IDs. In particular, the current remote
  `APPLE` R2 binding must be overridden by a local development binding.
- The checked-in worker README and scripts must use Bun, consistent with the
  repository policy. They must not instruct agents to use npm, pnpm, or yarn
  for Worker commands.

### 4. `--remote` is opt-in and must be safe

- `wrangler dev --remote` is allowed only when a checked-in or explicitly
  supplied development configuration selects non-production resources.
- `--remote` must never be run against the production config merely to make a
  local Apple test work. Remote Worker execution means the Worker code and its
  bindings execute on Cloudflare infrastructure; it is not equivalent to a
  local process.
- If non-production D1/R2/KV/DO resources do not exist, the launcher must fail
  with a clear explanation instead of falling back to production.
- The end-to-end two-account test must state whether it is using local
  simulated data or a non-production remote environment. A production account,
  database, bucket, or Durable Object is out of scope for an automatic local
  test.
- Local simulated bindings support protocol/route smoke tests with seeded test
  fixtures. They do not provide the existing production users, auth sessions,
  or books. The real two-account Apple test therefore requires a dedicated
  non-production environment with test accounts and test book data (or an
  explicit, manual user-directed setup); it must not silently use production
  accounts or production data.

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
- Debug builds use the managed local primary Worker URL. The default local
  simulator URL is `http://127.0.0.1:<primary-port>`; the port is defined once
  by the launcher and build configuration.
- Release/TestFlight/App Store builds use `https://api.fidexa.org` and cannot
  silently inherit a Debug URL or arbitrary process environment override.
- The app displays or logs the selected environment and base URL in Debug so
  a test record proves which backend was used. Secrets and bearer tokens must
  not be logged.
- The Debug override must be explicit and validated against the managed Worker
  URL. Release/TestFlight builds ignore development process-environment
  overrides and fail closed if their compiled production endpoint is malformed.
- Shared reading receives the same base URL as the rest of the app. It must
  not retain a separate production default, because that can make a Debug app
  send sync traffic locally while sending session creation to production.
- A physical iPhone cannot reach the Mac's loopback address. If physical-device
  testing is needed, the endpoint must be an explicitly configured LAN/tunnel
  URL and the local Worker must bind accordingly; this is separate from the
  simulator default.

### 6. Startup and test procedure is part of the policy

Every Apple Worker-backed test follows this order:

1. Check for existing managed Worker and Apple app processes. Reuse a healthy
   managed Worker or stop it; do not create duplicate app or Worker instances.
2. Start the primary and sharing Workers using the repository launcher.
3. Wait for health checks and record the selected URLs, Worker version, and
   binding mode.
4. Launch exactly the Apple targets required by the test, with Debug endpoint
   configuration pointing at the recorded primary URL.
5. Run the test and collect Worker/app logs on every failure.
6. Stop the managed Worker and app processes after testing, unless the user
   explicitly asks to keep them open.

The launcher and Apple test harness must make a missing Worker a visible setup
failure. A network error must identify the base URL, API version, route,
HTTP status, Worker version when available, and a redacted request correlation
identifier.

## Proposed implementation surface

The implementation should be limited to these areas:

| Area | Proposed change |
|---|---|
| Worker route registration | Add a versioned `/api/v1` route group for shared reading and preserve existing legacy routes. |
| Worker configuration | Add isolated local development config for both Workers; remove production remote bindings from the local path; configure local service binding and WebSocket URL. |
| Worker scripts/docs | Add one managed startup command for both Workers, health checks, duplicate-process detection, cleanup, and Bun-only instructions. |
| Apple configuration | Add a single Debug/Release endpoint configuration containing the primary HTTP URL and sharing WebSocket URL; inject it through `ServiceGraphFactory`. |
| Apple networking | Remove hard-coded defaults and duplicated environment reads from `WorkerEndpoint`, billing, voice, and shared reading; make direct endpoint helpers use the same configuration. |
| Diagnostics | Add backward-compatible health headers and log environment, API version, route, status, and Worker correlation/version metadata without credentials or user content. |
| Tests | Add route compatibility tests, local configuration safety checks, endpoint-selection tests, and a two-account shared-reading smoke path. |
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

- A fresh Apple Debug run cannot accidentally call `api.fidexa.org` when the
  managed local Worker is available.
- A Release build always uses the production endpoint.
- Shared reading and all other Worker-backed Apple features use the same chosen
  endpoint configuration.
- The local startup command starts both Workers exactly once, verifies health,
  isolates bindings, and cleans up its children.
- The shared-reading API is versioned before release, while legacy routes remain
  unchanged and covered by compatibility tests.
- A failed request identifies enough information to tell apart a client bug,
  a stale deployment, a missing local Worker, an auth failure, and a Worker
  route/data failure.
- A local seeded smoke test exercises the route/protocol without production
  resources, and a separate two-account simulator test can create, redeem/join,
  and start a shared reading session against an explicitly selected
  non-production backend.

## Adversarial review loop

This artifact must receive an independent research/spec review before an
implementation plan is written. The reviewer must specifically try to disprove:

- that every Apple Worker call uses the centralized endpoint;
- that local configuration cannot select production R2/D1/KV/DO resources;
- that the local primary-to-sharing service binding works with two Wrangler
  processes;
- that `--remote` has a safe, non-production configuration;
- that versioning shared reading before release does not strand any deployed
  client; and
- that startup/cleanup cannot leave duplicate Workers or app instances.

### Round 1 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Endpoint selection is duplicated in `WorkerEndpoint.swift`, `PurchaseService.swift`, `VoiceSessionPresenter.swift`, and `SharedReadingAPI.swift`; changing only `ServiceGraphFactory` would leave production fallbacks. | The Apple networking decision now names every discovered production fallback and requires one injected configuration for all production call paths. |
| 2 | High | A local Worker with simulated bindings cannot authenticate the existing production accounts or see their books, so it cannot by itself prove the requested two-account flow. | The acceptance criteria now require a local seeded protocol smoke lane and a separate non-production remote/manual-account lane for the real Apple flow. Production data is explicitly forbidden. |
| 3 | High | The existing primary Worker config includes a remote R2 binding and production routes; running it directly in development could leak into production storage. | Local development uses a separate isolated config with no production IDs/routes, and the policy requires a static safety check plus launcher refusal when resources are ambiguous. |
| 4 | Medium | Changing `/health` response JSON/text to include version data could break existing probes. | Version metadata is carried in headers and structured logs while preserving the current successful health body. |
| 5 | Medium | The HTTP API base URL does not determine the sharing WebSocket URL, especially for local two-Worker development. | The Apple environment and launcher now carry separate deterministic HTTP and WebSocket endpoints. |

**Round 1 result:** Re-review required until the updated draft is checked again against all call sites and the local binding topology.

### Round 2 — Re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The updated endpoint audit still needs an explicit rule for direct `WorkerEndpoint.send()` callers, which currently construct their own client from process environment. | The Apple networking rule explicitly includes direct endpoint helpers and requires production code to receive the composition-root configuration; implementation tests will fail if an app path still reads `RISHI_API_URL` directly. |
| 2 | Medium | A physical-device URL can be configured incorrectly as loopback and produce a misleading network failure. | The policy distinguishes simulator loopback from physical-device LAN/tunnel configuration and requires the launcher to print the reachable URL. |
| 3 | Low | Existing Worker READMEs use npm/pnpm examples despite the repository’s Bun-only Worker policy. | The implementation surface explicitly includes correcting both Worker README command sets. |

**Round 2 result:** PASS WITH NOTES — 0 open Critical/High issues. The Medium/Low items are concrete implementation requirements above; implementation planning may proceed after user review.

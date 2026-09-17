# API Versioning and Apple Worker Development Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Apple app use an explicit local or production Worker environment, version the unreleased shared-reading API without changing released contracts, and provide one safe command that starts the local Worker topology for testing.

**Architecture:** The single canonical API Worker keeps legacy `/api/...` routes frozen and mounts shared reading at `/api/v1/reading-sessions`. Its internal sharing Worker remains a transport service, not a separate public API or dev/prod contract. Checked-in Wrangler configurations start the required local topology on deterministic ports; `wrangler dev --remote` is an opt-in non-production execution mode. Apple resolves one injected environment containing HTTP and WebSocket endpoints at the composition root; Debug selects Wrangler and Release selects production.

**Tech Stack:** Hono, Cloudflare Workers/Wrangler, Bun, Swift/SwiftUI, Xcode project build settings, URLSession, Vitest, XCTest.

---

## Files and boundaries

- Worker API compatibility: `workers/worker/src/index.ts`, `workers/worker/src/api-version.ts`, and Worker route tests.
- Worker runtime metadata: `workers/worker/src/health.ts`, `workers/sharing-worker/src/index.ts`, and their tests.
- Local topology: `workers/worker/wrangler.dev.jsonc`, `workers/sharing-worker/wrangler.dev.jsonc`, `scripts/start-rishi-workers-dev.sh`, and Worker READMEs.
- Apple endpoint composition: `apps/apple/rishi/rishi/Networking/RishiAPIEnvironment.swift`, `apps/apple/rishi/rishi/ServiceGraphFactory.swift`, `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/RishiAPI/WorkerEndpoint.swift`, billing, voice, and shared-reading networking files.
- Apple build selection: `apps/apple/rishi/rishi/Info.plist` and the application target Debug/Release settings in `apps/apple/rishi/rishi.xcodeproj/project.pbxproj`.
- Verification: focused Worker tests, Apple networking tests, build checks, and the documented two-account smoke procedure.

## Task 1: Lock the API version contract with failing tests

**Files:**
- Create: `workers/worker/src/api-version.ts`
- Create: `workers/worker/src/api-version.test.ts`
- Modify: `workers/worker/src/index.ts`
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingAPI.swift`
- Modify: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingAPITests.swift`

- [ ] **Step 1: Add the shared-reading route contract test.** Assert that a request to `/api/v1/reading-sessions` reaches the existing session-share router in the Worker test harness and that the old unversioned route is not introduced as a second mutable implementation.

- [x] **Step 2: Add version constants and metadata tests.** Define `currentAPIRevision = "v1"`, `sharedReadingRoutePrefix = "/api/v1/reading-sessions"`, and response metadata names in one Worker module. Test that the metadata is deterministic and that a legacy route is not silently aliased by the new registration.

- [ ] **Step 3: Run the focused Worker test and confirm it fails.** Run from `workers/worker`:

  ```text
  bun vitest run src/api-version.test.ts
  ```

  Expected result: FAIL because the versioned route and constants do not yet exist.

- [x] **Step 4: Implement the minimal route registration.** Mount `sessionSharesRoutes` at `/api/v1/reading-sessions`, leave every existing `/api/...` registration unchanged, and use the constants from `api-version.ts` rather than duplicating the prefix.

- [x] **Step 5: Change Apple shared-reading paths to the same prefix.** Replace every `/api/reading-sessions` path in `SharedReadingAPI.swift`, including its 404 classification, with `/api/v1/reading-sessions`. Keep the base URL injected; do not add a new production default.

- [ ] **Step 6: Run the focused Worker and Apple API tests.** The Worker route test and the existing `SharedReadingAPITests` must pass, including assertions for the exact versioned request paths.

- [ ] **Step 7: Commit only the versioned route files.** Stage `workers/worker/src/api-version.ts`, its test, `workers/worker/src/index.ts`, `SharedReadingAPI.swift`, and its test; do not stage any pre-existing unrelated feature changes.

## Task 2: Add backward-compatible Worker version diagnostics

**Files:**
- Create: `workers/worker/src/health.ts`
- Create: `workers/worker/src/health.test.ts`
- Modify: `workers/worker/src/index.ts`
- Modify: `workers/sharing-worker/src/index.ts`
- Modify: `workers/sharing-worker/test/smoke.test.ts`

- [ ] **Step 1: Write health-header tests.** Test that `/health` remains HTTP 200 with its current body shape, and adds `X-Rishi-API-Version`, `X-Rishi-Worker-Name`, and `X-Rishi-Worker-Version` headers. Test the sharing Worker with the same API revision and a distinct worker name.

- [ ] **Step 2: Run the focused health tests and confirm failure.** Run:

  ```text
  (cd workers/worker && bun vitest run src/health.test.ts)
  (cd workers/sharing-worker && bun vitest run test/smoke.test.ts)
  ```

  Expected result: FAIL because the headers are absent.

- [x] **Step 3: Add the shared metadata helper.** Read `CF_VERSION_METADATA.id` when available, use `local` when absent, and add headers without changing the existing JSON/text response bodies. Do not include credentials, tokens, user IDs, or book content.

- [x] **Step 4: Run both focused health suites.** Confirm headers and body compatibility.

## Task 3: Create isolated local Worker configurations and the managed launcher

**Files:**
- Create: `workers/worker/wrangler.dev.jsonc`
- Create: `workers/sharing-worker/wrangler.dev.jsonc`
- Create: `scripts/start-rishi-workers-dev.sh`
- Modify: `workers/worker/package.json`
- Modify: `workers/sharing-worker/package.json`
- Modify: `workers/worker/README.md`
- Modify: `workers/sharing-worker/README.md`
- Create: `scripts/start-rishi-workers-dev.test.sh`

- [ ] **Step 1: Define local-only Wrangler configs.** The primary config uses no production IDs, routes, or `remote: true` bindings; it provides local D1/R2/KV/DO bindings needed by the Worker and points `SHARING_WORKER` at `rishi-sharing-worker-dev`. The sharing config has no production route and uses local Durable Object storage. Both configs set local development variables, including `SHARING_WORKER_WS_URL` to the local sharing URL and test-only auth only where the smoke test explicitly opts in.

- [ ] **Step 2: Add launcher safety tests.** The shell test checks that the launcher rejects occupied managed ports, does not contain production custom domains or production resource IDs in its selected config, waits for both `/health` endpoints, and terminates child Workers on exit.

- [x] **Step 3: Implement the launcher.** `scripts/start-rishi-workers-dev.sh` must:
  - accept `--remote` only with an explicit non-production config path;
  - default to `wrangler dev --config workers/sharing-worker/wrangler.dev.jsonc --port 8788` and `wrangler dev --config workers/worker/wrangler.dev.jsonc --port 8787`;
  - check ports before starting and print the owning PID on conflict;
  - record the two URLs and PIDs in its startup log;
  - poll `http://127.0.0.1:8788/health` and `http://127.0.0.1:8787/health` until both return 200;
  - trap `INT`, `TERM`, and `EXIT` to stop only its child processes; and
  - fail if the selected config contains production custom-domain or remote-binding settings.

- [x] **Step 4: Add Bun-only package commands and documentation.** Add a `dev:local` command in each Worker package that invokes Wrangler through Bun, and document the managed launcher. Remove npm/pnpm/yarn Worker commands from the two READMEs.

- [ ] **Step 5: Run the launcher safety test and a real local health smoke.** Confirm that one primary and one sharing Worker start, their health headers identify local versions, and cleanup removes both processes.

## Task 4: Centralize Apple HTTP and WebSocket endpoint selection

**Files:**
- Create: `apps/apple/rishi/rishi/Networking/RishiAPIEnvironment.swift`
- Create: `apps/apple/rishi/rishiTests/Networking/RishiAPIEnvironmentTests.swift`
- Modify: `apps/apple/rishi/rishi/ServiceGraphFactory.swift`
- Modify: `apps/apple/rishi/rishi/Info.plist`
- Modify: `apps/apple/rishi/rishi.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write environment-selection tests.** Test that an explicit injected environment preserves its HTTP and WebSocket URLs; Debug defaults to `http://127.0.0.1:8787` and `ws://127.0.0.1:8788`; Release defaults to `https://api.fidexa.org` and the production sharing URL; malformed URLs fail closed.

- [ ] **Step 2: Run the new tests and confirm failure.** Run the Apple environment test through the focused Swift test command used by this project. Expected result: FAIL because the environment type and build settings do not exist.

  ```text
  xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/RishiAPIEnvironmentTests
  ```

- [x] **Step 3: Implement `RishiAPIEnvironment`.** Give it `mode`, `httpBaseURL`, and `sharingWebSocketURL`, validate schemes/hosts, and resolve values from the compiled Info.plist keys. Permit a Debug-only explicit override for simulator/LAN testing; ignore that override in Release.

- [x] **Step 4: Wire Debug and Release build settings.** Add Info.plist substitutions for the local HTTP/WebSocket endpoints in Debug and production endpoints in Release. Ensure the Release configuration cannot inherit `RISHI_API_URL` from a developer process.

- [x] **Step 5: Inject the environment at `ServiceGraphFactory`.** Construct one environment, use its HTTP URL for `WorkerClient`, use the same HTTP URL for `SharedReadingAPI`, and pass the WebSocket URL to the shared-reading transport path that consumes the Worker response or fallback configuration.

- [ ] **Step 6: Run the environment tests and both generic Apple builds.** Build iOS and Mac Catalyst and verify the compiled Debug/Release Info.plist values.

## Task 5: Remove all production endpoint fallbacks from Apple application code

**Files:**
- Modify: `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/RishiAPI/WorkerEndpoint.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/PurchaseService.swift`
- Modify: `apps/apple/rishi/rishi/Voice/VoiceSessionPresenter.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingAPI.swift`
- Modify: affected Apple tests that construct these types directly

- [ ] **Step 1: Add a static audit test/script.** Search application sources (excluding tests, spikes, and comments) for direct reads of `RISHI_API_URL` and hard-coded `https://api.fidexa.org` defaults. Make the audit fail when any production application path remains.

- [x] **Step 2: Replace direct construction with injection.** Add `send(using:)` to `WorkerEndpoint` and update the application callers (`GroupIDEndpoint`, `VerifyEndPont`, and entitlement fire-and-forget) to use the bootstrapped `WorkerClient`; make the default billing entitlement client receive that same client; require `VoiceSessionPresenter`’s production construction to receive the configured base URL; and remove the SharedReading-specific default. Preserve test constructors by injecting explicit test URLs. No production caller may invoke a no-argument helper that constructs a new client from process environment.

- [ ] **Step 3: Run the audit and focused Apple tests.** Confirm no application fallback remains and that existing test-only URL injection still compiles.

## Task 6: Add diagnostics that identify the selected backend

**Files:**
- Modify: `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/RishiAPI/WorkerClient.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingAPI.swift`
- Modify: `apps/apple/rishi/rishi/Networking/RishiAPIEnvironment.swift`
- Modify: focused Apple networking tests

- [ ] **Step 1: Write request-diagnostic tests.** Test that request logs include mode, host, API version, route, status, and a generated correlation ID, while excluding authorization headers, tokens, and request bodies containing book/user data.

- [x] **Step 2: Add headers and redacted logs.** Send `X-Rishi-API-Version` and `X-Rishi-Request-ID`; parse Worker version headers; log structured failures through the existing `Log` surface. Apply the same request-ID/version behavior to `SharedReadingAPI` even though it has a specialized transport. Preserve user-facing production error policy: send errors to Sentry, but do not expose internal details in Release UI.

- [ ] **Step 3: Run focused networking tests and `git diff --check`.** Confirm diagnostics do not alter retry/auth behavior.

## Task 7: Verify the full development workflow and shared-reading feature

**Files:**
- Modify: `docs/superpowers/specs/2026-09-01-api-versioning-and-apple-worker-development-policy-design.md`
- Modify: `docs/superpowers/plans/2026-09-01-api-versioning-and-apple-worker-development.md`

- [ ] **Step 1: Run Worker type-check and focused tests.** From `workers/worker`, run `bun run type-check` and the route/health tests. From `workers/sharing-worker`, run `bun test` and the smoke tests. Record unrelated existing failures separately.

- [ ] **Step 2: Run Apple generic builds.** Build iOS and Mac Catalyst with the managed local endpoint configuration. Do not claim the full Xcode test target passes while its unrelated pre-existing compile errors remain.

- [ ] **Step 3: Run the local seeded shared-reading smoke.** Start the managed Workers once, verify both health endpoints and metadata, then exercise create/redeem/join/start against local fixtures. Capture the base URLs and Worker versions.

- [ ] **Step 4: Run the real two-account simulator test only with non-production resources.** Use iPhone 17 Pro and Catalyst only if the dedicated non-production accounts/data are available. Check app instances and memory before launch, close stale instances, and stop managed Workers after the test.

- [ ] **Step 5: Update the spec and plan with evidence.** Record exact passing commands, known unrelated failures, and whether the two-account flow completed. Mark the implementation review status only after a fresh adversarial pass over the final diff.

- [ ] **Step 6: Commit only the implementation files and link the commits/verification in the feature PR.** Preserve all unrelated dirty files and never deploy production from this local workflow.

## Adversarial review loop

Each round follows research → findings → artifact update → re-review.

### Round 1 — Research/spec review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Apple endpoint configuration is duplicated in multiple production paths. | Task 5 audits and removes all discovered fallbacks, not only `ServiceGraphFactory`. |
| 2 | High | Local simulated bindings cannot prove the existing two-account production-user flow. | Task 7 separates seeded local smoke from a non-production two-account test. |
| 3 | High | The current primary config includes a remote R2 binding and production routes. | Task 3 uses separate local configs and a launcher safety check. |
| 4 | Medium | Changing health response bodies could break existing probes. | Task 2 adds headers while preserving body/status compatibility. |
| 5 | Medium | The HTTP URL and sharing WebSocket URL are independent. | Task 4 models both explicitly. |

**Round 1 result:** Re-review required after implementation planning.

### Round 2 — Plan review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | A local service binding may not automatically connect two independently launched Wrangler processes. | Task 3 requires a real local service-binding health/session smoke before the plan is accepted as implemented; if Wrangler cannot bridge it, the launcher must use the documented local proxy/service-binding mechanism rather than silently testing the production sharing Worker. |
| 2 | High | Release safety cannot rely only on a process environment variable being absent. | Task 4 makes Release endpoint values compiled into the target and Task 5 audits all direct reads. |
| 3 | Medium | Auth and book data are unavailable in empty local D1. | Task 7 requires seeded fixtures for local smoke and dedicated non-production resources for the real two-account flow. |

**Round 2 result:** Re-review required until the implementation verifies the service-binding topology and Release endpoint isolation.

## Explicit out of scope

- Deploying or migrating production resources.
- Creating a permanent development Worker service.
- Retiring any released API version.
- Making physical iPhones reach Mac loopback without an explicit LAN/tunnel URL.
- Fixing unrelated pre-existing Apple test-target compile failures.

## Implementation verification notes

- `bun vitest run src/api-version.test.ts src/health.test.ts` passes in `workers/worker`.
- `bun vitest run test/smoke.test.ts` passes in `workers/sharing-worker`.
- `bun run type-check` still fails on the existing Worker type baseline: missing Apple/Upstash/R2 environment declarations, newer `Uint8Array`/`BufferSource` typings, existing Drizzle query typing errors, the generated-runtime `ExportedHandler` mismatch, and the pre-existing shared-schema declaration/test import issues. The current API-version and health changes add no new reported type error.
- `scripts/start-rishi-workers-dev.test.sh` and `scripts/check-apple-worker-endpoints.sh` pass.
- The managed launcher was started once. Primary `/health` returned HTTP 200 with the existing JSON body and `rishi-worker` metadata; sharing `/health` returned HTTP 200 with the existing `ok` body and `rishi-sharing-worker` metadata. The primary local service binding reported `[connected]`, and `/api/v1/reading-sessions` reached the Worker and returned its expected unauthenticated response.
- iPhone 17 Debug and Mac Catalyst Debug generic builds both pass with Xcode beta. The full Apple test target remains blocked by unrelated pre-existing test compilation failures; no full-test pass is claimed.
- A fresh independent review task was dispatched, but its result was not available before this verification pass. This document's review requirement remains open until that review is readable and any Critical/High findings are closed.

# Shared-Reading Isolated Live E2E Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Apple two-person shared-reading acceptance test run twice consecutively against an isolated Cloudflare E2E environment, prove synchronized progress, and leave no local or remote residue without enabling any production test path.

**Architecture:** Deploy explicit `e2e` Wrangler environments as distinct API and sharing Worker scripts with dedicated D1, R2, KV, and Durable Object state. Inject two exact E2E origins through the host, XCTest runner, and app launch boundaries; validate every returned WebSocket origin; and run a gated remote cleanup before canonical account deletion. Keep production endpoint selection and production test-auth policy unchanged.

**Tech Stack:** Swift 6, XCTest/XCUITest, TypeScript, Bun, Vitest, Cloudflare Workers, Wrangler 4, D1, R2, KV, Durable Objects, zsh.

**Approved design:** `apps/apple/docs/superpowers/specs/2026-09-19-shared-reading-e2e-environment-remediation-design.md`

---

## Scope and execution rules

- Execute tasks sequentially with a fresh implementation subagent for each task.
- After every implementation task, run a Luna specification review, fix and re-review until no Critical/High/Medium specification gap remains, then run a Terra code-quality review and close all Critical/High findings before advancing.
- Use Bun for every command executed from `workers/worker`.
- Preserve the five unrelated dirty files under `apps/apple/rishi-mcp/**` and `apps/apple/rishi/rishiUITests/MCPControlUITests.swift`; never stage them.
- Do not modify Electron, MCP, or GitHub workflow files.
- Never enable `ENABLE_TEST_AUTH`, `TEST_AUTH_SECRET`, or `TEST_AUTH_ALLOWED` on production.
- Never print, commit, or persist secret values in logs, evidence, manifests, or result bundles beyond the existing mode-`0600`, run-owned `.xctestrun` lifetime.
- Resource deletion and rollback are separate, destructive operations. Perform them only after exact-name/ID inspection and explicit authorization.

## File structure

### Create

- `workers/worker/scripts/verify-e2e-environment.ts` — parses both Wrangler JSONC files and proves the complete production/E2E isolation contract.
- `workers/worker/scripts/verify-e2e-environment.test.ts` — verifier behavior and production-leak regression coverage.

### Modify

- `workers/worker/src/r2-presign.ts`
- `workers/worker/src/r2-presign.test.ts`
- `workers/worker/src/routes/session-shares.ts`
- `workers/worker/src/routes/session-shares.test.ts`
- `workers/worker/src/routes/test-auth.ts`
- `workers/worker/src/routes/test-auth.test.ts`
- `workers/worker/src/account-deletion.integration.test.ts`
- `workers/worker/src/session-sharing-service.ts`
- `workers/worker/src/session-sharing-service.test.ts`
- `workers/worker/wrangler.jsonc`
- `workers/worker/package.json`
- `workers/worker/bun.lockb`
- `workers/sharing-worker/wrangler.jsonc`
- `apps/apple/rishi/rishi/Networking/RishiAPIEnvironment.swift`
- `apps/apple/rishi/rishiTests/Networking/RishiAPIEnvironmentTests.swift`
- `apps/apple/rishi/rishi/SharedReading/SharedReadingAPI.swift`
- `apps/apple/rishi/rishi/SharedReading/Transport/SharedReadingSignalingClient.swift`
- `apps/apple/rishi/rishi/ServiceGraphFactory.swift`
- `apps/apple/rishi/rishi/RootView.swift`
- `apps/apple/rishi/rishi/SharedReading/ActiveReadingSessionsView.swift`
- `apps/apple/rishi/rishiTests/SharedReading/SharedReadingAPITests.swift`
- `apps/apple/rishi/rishiTests/SharedReading/SharedReadingSignalingClientTests.swift`
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/TestAccountClient.swift`
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingHost.swift`
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingLiveRun.swift`
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingCLI.swift`
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingRecoveryJournal.swift`
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/TestAccountClientTests.swift`
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingHostTests.swift`
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingLiveRunTests.swift`
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingCLITests.swift`
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingRecoveryJournalTests.swift`
- `apps/apple/rishi/rishiUITests/SharedReadingTestSupport.swift`
- `apps/apple/rishi/rishiUITests/SharedReadingLaunchEnvironmentTests.swift`
- `apps/apple/scripts/validate-shared-reading.sh`
- `apps/apple/scripts/validate-shared-reading.test.sh`
- `apps/apple/rishi-e2e-host/README.md`

## Fixed external names

| Resource | Exact name |
| --- | --- |
| API Worker | `rishi-worker-e2e` |
| Sharing Worker | `rishi-sharing-worker-e2e` |
| API domain | `api-e2e.fidexa.org` |
| Sharing domain | `sharing-e2e.fidexa.org` |
| D1 | `rishi-e2e` |
| R2 | `apple-e2e`, `rishi-books-e2e`, `rishi-tts-cache-e2e`, `apple-dev-e2e` |
| KV | `RISHI_DESKTOP_STATE_E2E`, `RATE_LIMIT_KV_E2E` |

---

### Task 1: Make generated storage and share URLs environment-specific

**Files:**
- Modify: `workers/worker/src/r2-presign.ts`
- Modify: `workers/worker/src/r2-presign.test.ts`
- Modify: `workers/worker/src/routes/session-shares.ts`
- Modify: `workers/worker/src/routes/session-shares.test.ts`
- Modify: `workers/worker/wrangler.jsonc`

- [ ] **Step 1: Write failing production/E2E bucket tests**

Add tests that pass `BOOK_STORAGE_BUCKET_NAME: "rishi-books"` and `BOOK_STORAGE_BUCKET_NAME: "rishi-books-e2e"`, sign one PUT request for each, and assert the URL pathname begins with the corresponding bucket. Add a test proving an empty bucket name is rejected before signing.

- [ ] **Step 2: Write failing share-link origin tests**

Cover both a newly created invite and an idempotently returned invite. Assert production `PUBLIC_WEB_URL=https://rishi.fidexa.org` is preserved, E2E `PUBLIC_WEB_URL=https://api-e2e.fidexa.org` produces only that origin, and missing/malformed/non-HTTPS/user-info/alternate-port/path/query/fragment values fail before returning a share link.

- [ ] **Step 3: Run the red tests**

Run from `workers/worker`:

```sh
bun test src/r2-presign.test.ts src/routes/session-shares.test.ts
```

Expected: FAIL because the signer and share route still hard-code production names.

- [ ] **Step 4: Implement the minimal environment contracts**

Extend `R2SigningEnv` with `BOOK_STORAGE_BUCKET_NAME: string`. Validate a non-empty, R2-safe bucket name and construct the URL from that value. Build share links from a required validated `PUBLIC_WEB_URL` origin. Add top-level production var `BOOK_STORAGE_BUCKET_NAME: "rishi-books"` without changing production credentials, bindings, or `PUBLIC_WEB_URL`.

- [ ] **Step 5: Run focused and type checks**

```sh
bun test src/r2-presign.test.ts src/routes/session-shares.test.ts
bun run type-check
```

Expected: all signer tests pass and type-check exits `0`.

- [ ] **Step 6: Commit**

```sh
git add workers/worker/src/r2-presign.ts workers/worker/src/r2-presign.test.ts workers/worker/src/routes/session-shares.ts workers/worker/src/routes/session-shares.test.ts workers/worker/wrangler.jsonc
git commit -m "fix(worker): isolate generated e2e URLs"
```

---

### Task 2: Add fail-closed E2E remote cleanup and recovery deletion

**Files:**
- Modify: `workers/worker/src/routes/test-auth.ts`
- Modify: `workers/worker/src/routes/test-auth.test.ts`
- Modify: `workers/worker/src/session-sharing-service.ts`
- Modify: `workers/worker/src/session-sharing-service.test.ts`

- [ ] **Step 1: Add failing cleanup-route tests**

Cover these exact behaviors:

1. Gate failure returns indistinguishable `404`.
2. Any email outside the `rishi-e2e-` generated namespace is rejected before D1/service access.
3. For an active room, cleanup reads current controller ID/generation, requires that controller to be one of the two generated users, calls `endRoom` as that controller, verifies ended state, calls `purgeAppleRoom`, and verifies a later status lookup reports absence.
4. Ended and absent rooms are idempotent successes.
5. One stale-generation response triggers one status refresh and retry; a transferred controller among the generated users succeeds, while an unknown controller or second stale response fails closed.
6. A conflict, failed end verification, failed purge, or non-authoritative absence retains failure and does not delete either account.
7. Multiple rooms are attempted independently and all failures are reported without suppressing later cleanup attempts.

- [ ] **Step 2: Add failing gated deletion tests**

Replace expectations for the current best-effort raw-table route. Assert `DELETE /test/users/:email` delegates to the canonical `deleteAccount` workflow, returns success only after its R2/account verification, returns non-2xx on R2 failure, and returns exact JSON `{ "error": "user not found" }` with `404` only when absence is authoritative.

- [ ] **Step 3: Run red tests**

```sh
bun test src/routes/test-auth.test.ts src/session-sharing-service.test.ts
```

Expected: FAIL because remote cleanup does not exist and the fallback route still swallows R2 failures.

- [ ] **Step 4: Implement the cleanup service contract**

Add a typed service operation that treats only the sharing Worker’s exact not-found response as absence. The route request contains the two generated emails; it resolves the corresponding users and owned session rows, then executes the status/current-controller/end/verify/purge/verify sequence from the design. The current controller must resolve to one of those generated users. Permit one status-refresh retry for `STALE_CONTROLLER_GENERATION`; fail closed after that. It never accepts arbitrary user IDs or session IDs from the caller.

- [ ] **Step 5: Delegate gated account recovery to canonical deletion**

Remove the raw SQL/R2 best-effort deletion body. Call the same `deleteAccount` implementation used by `/api/user`, preserving the existing second-delete exact-404 verification contract.

- [ ] **Step 6: Run Worker tests**

```sh
bun test src/routes/test-auth.test.ts src/session-sharing-service.test.ts src/account-deletion.integration.test.ts
bun run type-check
```

Expected: all focused tests pass; type-check exits `0`.

- [ ] **Step 7: Commit**

```sh
git add workers/worker/src/routes/test-auth.ts workers/worker/src/routes/test-auth.test.ts workers/worker/src/session-sharing-service.ts workers/worker/src/session-sharing-service.test.ts workers/worker/src/account-deletion.integration.test.ts
git commit -m "fix(worker): verify shared reading e2e cleanup"
```

---

### Task 3: Add the Cloudflare E2E isolation verifier

**Files:**
- Create: `workers/worker/scripts/verify-e2e-environment.ts`
- Create: `workers/worker/scripts/verify-e2e-environment.test.ts`
- Modify: `workers/worker/package.json`
- Modify: `workers/worker/bun.lockb`

- [ ] **Step 1: Add JSONC parser dependency with Bun**

```sh
bun add --dev jsonc-parser
```

Expected: `package.json` and `bun.lockb` record the direct development dependency.

- [ ] **Step 2: Write failing verifier tests**

Use temporary JSONC fixtures with one mutation per invariant. Prove rejection of production D1 ID/name, any production R2 bucket, either production KV ID, production service target, production custom domain, missing E2E DO bindings/migrations, E2E cron, missing gates, a gate present in production, duplicate KV IDs, a missing/wrong `CLOUDFLARE_ACCOUNT_ID`, a missing/production/malformed `PUBLIC_API_URL`, `PUBLIC_WEB_URL`, `SHARING_WORKER_WS_URL`, or sharing `AUTH_BASE_URL`, `BOOK_STORAGE_BUCKET_NAME` missing or unequal to the same environment's `BOOK_STORAGE.bucket_name`, any E2E sharing service binding, missing API `CF_VERSION_METADATA`, missing SQL text rule, missing or changed compatibility date/flags in either Worker, missing sharing observability, and missing required secret names. Include one complete isolated fixture that passes and prove the production bucket variable equals production `BOOK_STORAGE.bucket_name` while the E2E variable equals `rishi-books-e2e`.

- [ ] **Step 3: Run the red verifier test**

```sh
bun test scripts/verify-e2e-environment.test.ts
```

Expected: FAIL because the verifier module does not exist.

- [ ] **Step 4: Implement parsing and assertions**

The script accepts optional config paths for tests and defaults to the repository API/sharing Wrangler files. It parses JSONC structurally, compares default production against the complete explicit `env.e2e` blocks, validates every required non-inherited setting listed in Step 2, prints only names/IDs (never secrets), and exits non-zero with one precise message per violated invariant. Task 4 dry-run artifacts independently confirm Wrangler resolves those explicit settings to E2E-only deployment targets.

- [ ] **Step 5: Add package command and run tests**

Add:

```json
"verify:e2e-environment": "bun run scripts/verify-e2e-environment.ts"
```

Then run:

```sh
bun test scripts/verify-e2e-environment.test.ts
```

Expected: all fixture tests pass. The command against current repository configs is expected to fail until Task 4 adds `env.e2e`.

- [ ] **Step 6: Commit**

```sh
git add workers/worker/scripts/verify-e2e-environment.ts workers/worker/scripts/verify-e2e-environment.test.ts workers/worker/package.json workers/worker/bun.lockb
git commit -m "test(worker): verify e2e environment isolation"
```

---

### Task 4: Provision isolated Cloudflare resources and add explicit E2E configs

**Files:**
- Modify: `workers/worker/wrangler.jsonc`
- Modify: `workers/sharing-worker/wrangler.jsonc`

- [ ] **Step 1: Confirm authentication and exact pre-state**

Run from `workers/worker`:

```sh
bunx wrangler whoami
bunx wrangler d1 list --json
bunx wrangler r2 bucket list
bunx wrangler kv namespace list
```

Expected: authenticated account `b700cf80e995aacbfa27aaa8d2084d18`; none of the fixed E2E resource names already exists. If a name exists, inspect and adopt it only after proving it is dedicated and empty; never create a duplicate or delete it speculatively.

- [ ] **Step 2: Create exact isolated resources**

```sh
bunx wrangler d1 create rishi-e2e
bunx wrangler r2 bucket create apple-e2e
bunx wrangler r2 bucket create rishi-books-e2e
bunx wrangler r2 bucket create rishi-tts-cache-e2e
bunx wrangler r2 bucket create apple-dev-e2e
bunx wrangler kv namespace create RISHI_DESKTOP_STATE_E2E
bunx wrangler kv namespace create RATE_LIMIT_KV_E2E
```

Expected: each command creates exactly one named resource and prints its Cloudflare ID when applicable. Record the emitted D1 and KV IDs in the task report; these outputs, not invented literals, are authoritative.

- [ ] **Step 3: Add complete `env.e2e` blocks**

Use `apply_patch` to insert the exact emitted D1/KV IDs. The API block must redeclare the script name, custom domain, vars including exact `CLOUDFLARE_ACCOUNT_ID=b700cf80e995aacbfa27aaa8d2084d18`, `PUBLIC_WEB_URL=https://api-e2e.fidexa.org`, and `BOOK_STORAGE_BUCKET_NAME=rishi-books-e2e`, service binding, four R2 bindings, two KV bindings, D1 migration configuration, `UserUsageLedger` DO/migration, SQL text rule, version metadata, compatibility settings, minimum required-secret names, and no cron. The sharing block must redeclare its script name/domain, `AUTH_BASE_URL`, `TEST_AUTH_ALLOWED: "1"`, both DO bindings/migrations, compatibility, observability, and required `WORKER_HMAC_SECRET` only; it must have no service binding, and TURN remains omitted initially.

- [ ] **Step 4: Prove config isolation before deployment**

```sh
bun run verify:e2e-environment
bunx wrangler deploy --env e2e --dry-run --outdir /private/tmp/rishi-worker-e2e-dry-run
```

From `workers/sharing-worker`:

```sh
pnpm exec wrangler deploy --env e2e --dry-run --outdir /private/tmp/rishi-sharing-worker-e2e-dry-run
```

Expected: verifier passes; both dry runs resolve only E2E names/resources and expose no secret value.

- [ ] **Step 5: Commit configuration**

```sh
git add workers/worker/wrangler.jsonc workers/sharing-worker/wrangler.jsonc
git commit -m "chore(worker): configure isolated shared reading e2e"
```

Rollback at this stage means removing only the un-deployed `env.e2e` blocks from a new commit. Do not delete created resources until exact IDs are re-listed and the user authorizes destructive cleanup.

---

### Task 5: Establish secrets, deploy E2E Workers, migrate, and smoke-test

**Files:** No repository source files unless a deployment-discovered bug requires a reviewed fix.

- [ ] **Step 1: Create the bucket-scoped R2 credential checkpoint**

Using the signed-in Cloudflare browser, create one R2 Object Read & Write token scoped only to `rishi-books-e2e`. Cloudflare includes read, write, and list-object capability in this permission; accept listing only inside this isolated bucket, with no bucket administration, account-wide access, or access to another bucket. Capture its Access Key ID and Secret Access Key once into a mode-`0600` temporary credential file outside the repository. Do not paste either value into chat, command arguments, source, or logs. If browser authentication or this exact scope cannot be completed, stop this task as `BLOCKED` without weakening scope.

- [ ] **Step 2: Generate and install E2E-only secrets**

Generate independent high-entropy values for `TEST_AUTH_SECRET`, `BETTER_AUTH_SECRET`, `ACCESS_TOKEN_SECRET`, `REFRESH_TOKEN_SECRET`, and `VOICE_SESSION_NONCE_SECRET`. Generate one additional value and install it as API `SHARING_INTERNAL_SECRET` and sharing `WORKER_HMAC_SECRET`. Install the R2 credential pair only on `rishi-worker-e2e`. Use interactive Wrangler secret input or mode-`0600` files; never print values. Confirm only secret names with:

```sh
bunx wrangler secret list --env e2e
```

and from `workers/sharing-worker`:

```sh
pnpm exec wrangler secret list --env e2e
```

Expected: the exact minimum name sets from the design; no external-provider or production-only secret names.

- [ ] **Step 3: Deploy sharing E2E first**

From `workers/sharing-worker`:

```sh
pnpm test
pnpm exec wrangler deploy --env e2e --minify
```

Expected: tests pass; deployment reports `rishi-sharing-worker-e2e` and `sharing-e2e.fidexa.org` with E2E-owned DO migrations.

- [ ] **Step 4: Apply D1 migrations to the exact E2E database**

From `workers/worker`:

```sh
bun run verify:migrations
bunx wrangler d1 migrations list rishi-e2e --remote
bunx wrangler d1 migrations apply rishi-e2e --remote
```

Expected: migration target is printed as `rishi-e2e`; production database `rishi` is never named by the apply command; a second list shows no pending E2E migration.

- [ ] **Step 5: Deploy API E2E**

```sh
bun test
bun run type-check
bun run verify:e2e-environment
bunx wrangler deploy --env e2e --minify
```

Expected: deployment reports `rishi-worker-e2e`, `api-e2e.fidexa.org`, the E2E service binding, and only E2E resource names.

- [ ] **Step 6: Run non-secret smoke and production-negative gates**

Require exact health contracts. API: status `200`, JSON content type, `status="healthy"`, `service="openai-tts-proxy"`, parseable ISO timestamp, `X-Rishi-API-Version: v1`, `X-Rishi-Worker-Name: rishi-worker`, and a non-empty deployed `X-Rishi-Worker-Version`. Sharing: status `200`, `text/plain` content type, and exact body `ok`. Probe E2E test auth with the secret and an incomplete body: exact `400`. Probe E2E without a secret: `404`. Probe production without any E2E secret: `404`. Send a synthetic test bearer to the production sharing endpoint and require rejection without creating a room.

Create two generated E2E smoke accounts. As owner, obtain a presigned PUT, upload a small non-sensitive fixture, then perform the authenticated metadata sync/push used by `FixtureBookProvisioner` and verify the resulting book row through the normal API before session creation. Obtain a presigned GET and verify the bytes came from `rishi-books-e2e`. Create a real shared-reading session, require share-link origin `https://api-e2e.fidexa.org`, redeem it as the participant, and prove the room exists through the API-to-service-binding path. Call remote cleanup with both generated addresses, verify authoritative room absence, delete both accounts independently, and require exact absence of both accounts and both generated-account object prefixes.

Expected: all E2E checks pass; production rejects both test paths; both smoke accounts, their objects, and the room are absent.

- [ ] **Step 7: Record deployment evidence**

Record only script versions, resource names/IDs, HTTP statuses, and redacted cleanup evidence in the task report. Remove temporary secret files after confirming deployed secret names. Rollback, if required, starts by disabling only E2E routes/gates and rolling back E2E script versions; resource deletion remains separately authorized.

---

### Task 6: Add gated Apple E2E endpoint selection

**Files:**
- Modify: `apps/apple/rishi/rishi/Networking/RishiAPIEnvironment.swift`
- Modify: `apps/apple/rishi/rishiTests/Networking/RishiAPIEnvironmentTests.swift`

- [ ] **Step 1: Write failing endpoint-mode tests**

Add `.liveE2E`. Prove the exact pair `https://api-e2e.fidexa.org` and `wss://sharing-e2e.fidexa.org` is selected only in Debug when both `RISHI_UITEST=1` and `RISHI_E2E_REAL_AUTH=1` are present. In a gated launch, missing/malformed/mixed/production/user-info/path/query/fragment/alternate-port values must return `nil`; they must never fall back to production. Non-gated launches must ignore E2E variables and retain bundle production settings.

- [ ] **Step 2: Run the red test**

```sh
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/RishiAPIEnvironmentTests
```

Expected: new tests fail because only production mode exists.

- [ ] **Step 3: Implement all-or-nothing selection**

Add an injectable environment dictionary to `load`. Keep the exact E2E allowlist private to this boundary. Compile E2E selection only under `#if DEBUG`; release and ordinary debug code paths remain unchanged.

- [ ] **Step 4: Run focused tests and commit**

Run the command from Step 2; expect PASS. Then run the same focused suite with `-configuration Release` while supplying E2E variables through the test environment and require production endpoint selection, proving release code cannot enter E2E mode. Then:

```sh
git add apps/apple/rishi/rishi/Networking/RishiAPIEnvironment.swift apps/apple/rishi/rishiTests/Networking/RishiAPIEnvironmentTests.swift
git commit -m "test(apple): isolate live e2e endpoints"
```

---

### Task 7: Validate every server-returned sharing WebSocket origin

**Files:**
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingAPI.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/Transport/SharedReadingSignalingClient.swift`
- Modify: `apps/apple/rishi/rishi/ServiceGraphFactory.swift`
- Modify: `apps/apple/rishi/rishi/RootView.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/ActiveReadingSessionsView.swift`
- Modify: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingAPITests.swift`
- Create: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingSignalingClientTests.swift`

- [ ] **Step 1: Write failing response-origin tests**

For both mark-book-ready and rejoin responses, prove matching `wss` scheme/host/effective-port with a session path succeeds. At the transport boundary, inject a recording WebSocket-task factory and prove different host, production host, `ws`, user info, query, fragment, and alternate port fail without creating a task. Exercise the initial connection and every reconnect/refresh path that can consume a new admission.

- [ ] **Step 2: Run the red tests**

```sh
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/SharedReadingAPITests -only-testing:rishiTests/SharedReadingSignalingClientTests
```

Expected: mismatched origins are currently accepted.

- [ ] **Step 3: Implement validation at both admission and socket boundaries**

Pass the active environment's expected sharing origin from `ServiceGraphFactory` into `SharedReadingAPI` and every `SharedReadingSignalingClient` construction in `RootView` and `ActiveReadingSessionsView`. Validate decoded admissions at the API boundary, then independently revalidate immediately before each `URLSessionWebSocketTask` creation, including reconnect/refresh admissions. Use the existing typed retryable service failure and create no socket task on mismatch.

- [ ] **Step 4: Run focused tests and commit**

Run Step 2; expect PASS. Then:

```sh
git add apps/apple/rishi/rishi/SharedReading/SharedReadingAPI.swift apps/apple/rishi/rishi/SharedReading/Transport/SharedReadingSignalingClient.swift apps/apple/rishi/rishi/ServiceGraphFactory.swift apps/apple/rishi/rishi/RootView.swift apps/apple/rishi/rishi/SharedReading/ActiveReadingSessionsView.swift apps/apple/rishi/rishiTests/SharedReading/SharedReadingAPITests.swift apps/apple/rishi/rishiTests/SharedReading/SharedReadingSignalingClientTests.swift
git commit -m "fix(apple): validate shared reading websocket origin"
```

---

### Task 8: Wire host injection, remote cleanup, and recovery

**Files:**
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/TestAccountClient.swift`
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingHost.swift`
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingLiveRun.swift`
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingCLI.swift`
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingRecoveryJournal.swift`
- Modify the corresponding host tests listed in the file structure.
- Modify: `apps/apple/rishi/rishiUITests/SharedReadingTestSupport.swift`
- Create: `apps/apple/rishi/rishiUITests/SharedReadingLaunchEnvironmentTests.swift`

- [ ] **Step 1: Write failing host configuration tests**

`SharedReadingLiveRunTests` must prove exact E2E HTTPS/WSS values are required before any network, relay, lock, build, account, or simulator callback. `SharedReadingCLITests` must prove recovery accepts only the E2E API and does not require WSS. Production origins must fail.

- [ ] **Step 2: Write failing `.xctestrun` and app-handoff tests**

For owner and participant, assert both endpoint keys occur in `EnvironmentVariables`, `TestingEnvironmentVariables`, and `UITargetAppEnvironmentVariables`. Retain existing registration nonce separation. Add executable UI-support tests proving owner initial launch, participant initial launch, and participant restart each copy both values and that `app.launch()` is not reached when either value is absent. During a gated run, the owner must accept only a share link at exact origin `https://api-e2e.fidexa.org`, reject `rishi.fidexa.org` or any other origin, and relay only the extracted raw token.

- [ ] **Step 3: Write failing remote-cleanup orchestration tests**

Extend `TestAccountManaging` with an idempotent remote shared-reading cleanup method. Prove `SharedReadingHost.cleanup` stops both peers, calls remote cleanup once with both generated accounts, and only after verified success deletes accounts independently. In `SharedReadingRecoveryJournal`, update the actual per-account `deleteProvisionedAccount` recovery path (or its callback contract) so one batched remote room cleanup for the journaled addresses completes before the first account deletion. `SharedReadingRecoveryJournalTests` must prove ordering, exactly-once room cleanup, no account deletion on cleanup failure, and retained journal/manifest/lock state.

- [ ] **Step 4: Run red host tests**

```sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 --filter SharedReadingLiveRunTests
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 --filter SharedReadingHostTests
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 --filter SharedReadingCLITests
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 --filter TestAccountClientTests
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 --filter SharedReadingRecoveryJournalTests
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiUITests/SharedReadingLaunchEnvironmentTests
```

Expected: new contracts fail.

- [ ] **Step 5: Implement exact endpoint injection**

Rename `rendezvousEnvironment` to `launchEnvironment` and include both endpoint keys. Inject all three dictionaries for both destinations; keep app registration nonces in target-app scope only. `SharedReadingTestSupport.launch` requires and forwards both keys for initial launch and participant restart.

- [ ] **Step 6: Implement remote cleanup and recovery order**

Add the gated API client request with only generated addresses and secret header. Call it through the existing `preAccountCleanup` stage after exact local process/simulator cleanup and before account deletion. Wire the same batched call into `SharedReadingRecoveryJournal` before its real `deleteProvisionedAccount` loop; do not rely on a nonexistent `recoverProvisionedAccounts` boundary. Persist no room ID or response secret.

- [ ] **Step 7: Run host and app tests**

```sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/RishiAPIEnvironmentTests -only-testing:rishiTests/SharedReadingAPITests
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiUITests/SharedReadingLaunchEnvironmentTests
```

Expected: host suite passes with only intentional live skips; focused app tests pass.

- [ ] **Step 8: Commit**

Stage only the explicit host/app paths changed by this task, verify the five unrelated dirty files remain unstaged, and commit:

```sh
git commit -m "test(apple): route shared reading e2e safely"
```

---

### Task 9: Update validator/docs and run deterministic regression

**Files:**
- Modify: `apps/apple/scripts/validate-shared-reading.sh`
- Modify: `apps/apple/scripts/validate-shared-reading.test.sh`
- Modify: `apps/apple/rishi-e2e-host/README.md`

- [ ] **Step 1: Write failing wrapper cases**

Require exact E2E API and WSS origins, reject production/malformed/missing values before Swift runs, preserve deterministic/live phase status, and keep recovery API-only. Ensure fake Swift cannot fall through to real Swift.

- [ ] **Step 2: Run red wrapper suite**

```sh
zsh apps/apple/scripts/validate-shared-reading.test.sh
```

Expected: new endpoint cases fail.

- [ ] **Step 3: Implement wrapper and documentation changes**

Document E2E domains, explicit acknowledgements, fixture validation, preflight, recovery, two-run acceptance, redacted evidence, production-negative gate, and the rule that Cloudflare E2E deployment must be healthy first.

- [ ] **Step 4: Run complete deterministic verification**

```sh
zsh apps/apple/scripts/validate-shared-reading.test.sh
env -u RISHI_E2E_RUN_LIVE -u RISHI_E2E_ALLOW_NETWORK -u RISHI_E2E_ALLOW_SIMULATOR_RESET swift test --package-path apps/apple/rishi-e2e-host --jobs 1
cd workers/worker && bun test && bun run type-check && bun run verify:e2e-environment
cd ../sharing-worker && pnpm test
git diff --check
```

Expected: all suites and verifier pass; live XCTest skips only because live mode is unset; diff check is clean.

- [ ] **Step 5: Commit**

```sh
git add apps/apple/scripts/validate-shared-reading.sh apps/apple/scripts/validate-shared-reading.test.sh apps/apple/rishi-e2e-host/README.md
git commit -m "docs(apple): validate isolated shared reading e2e"
```

---

### Task 10: Run two consecutive live validations and residue audits

**Files:** No committed evidence file may contain secrets or account credentials.

- [ ] **Step 1: Confirm exact preconditions without launching apps**

Require healthy E2E API/sharing endpoints, successful gated preflight, validated `alice.epub`, exact existing iPhone 17 Pro template UDID, no unresolved recovery artifact, and no held build lock. Keep all unrelated simulator/app instances closed.

- [ ] **Step 2: Run live validation once**

Set the exact E2E origins, explicit network/reset acknowledgements, E2E test secret/domain, template UDID, absolute project path, validated fixture path, and a new mode-`0600` evidence path. Run `apps/apple/scripts/validate-shared-reading.sh`.

Expected: unique run ID, participant sequence `>= 2`, exactly two deleted accounts, successful peer exits, and exit `0`.

- [ ] **Step 3: Audit first-run residue**

Prove no local journal/manifest/staged fixture/secret `.xctestrun`/owned process/build lock/disposable simulator remains. Use the gated cleanup/absence API and E2E resource inspection to prove both accounts, all owned rooms, and both generated-account R2 prefixes are absent. Retain the mode-`0600`, redacted evidence record outside the repository until Task 11 compares both runs; it must contain no credential, bearer, raw invite token, or secret path.

- [ ] **Step 4: Run the same validation a second time**

Use the same configuration and a new evidence path. Expected: a different run ID and the same complete success criteria.

- [ ] **Step 5: Audit second-run residue and production isolation**

Repeat Step 3. Re-run the config verifier and the non-mutating production negative gates. Any residue, skipped live test, disabled E2E route, or production acceptance is failure.

---

### Task 11: Final branch review and completion

- [ ] **Step 1: Luna specification review**

Review commits from `89dc464c2` through HEAD against the approved remediation design and every completion gate. Include deployment/live evidence. Fix and re-review until 0 open Critical/High/Medium findings.

- [ ] **Step 2: Terra code-quality/security review**

Review exact process ownership, secret handling, production isolation, Cloudflare bindings, cleanup idempotency, tests, and uncommitted-file preservation. Fix all Critical/High findings and re-review.

- [ ] **Step 3: Final evidence audit**

Run `git status --short`, `git diff --check`, all deterministic suites, config verifier, deployment smoke, production negatives, and compare both mode-`0600` redacted live evidence records retained outside the repository. Confirm the only remaining uncommitted files are the five pre-existing unrelated MCP/UI-test edits, then securely remove the two temporary evidence records.

- [ ] **Step 4: Prepare integration**

Use the finishing-development-branch workflow. Do not merge until the two live runs and both final reviews pass.

## Adversarial review record

### Self-review round 1

- Added an explicit R2 signer task after discovering that the binding alone does not control presigned bucket URLs.
- Split local code, external resource provisioning, secret provisioning, deployment, and live evidence into separate gates so a config-only pass cannot claim a working feature.
- Added an E2E remote room cleanup before account deletion after review proved normal room end is asynchronous.
- Required canonical fail-closed deletion for bearer-independent recovery because the legacy gated route swallowed R2 failures.
- Required exact production-negative checks and a resolved-config isolation verifier.

**Self-review result:** ready for independent plan review; no known Critical/High/Medium gap.

### Independent plan review round 1

- Corrected the R2 token constraint to match Cloudflare's bucket-scoped Object Read & Write capability, which necessarily includes listing objects in that one isolated bucket.
- Added the previously missed hard-coded production share-link origin and required environment-specific route, harness, verifier, smoke, and regression coverage.
- Made the exact Cloudflare account ID mandatory in E2E config and added a real signed PUT/GET smoke check.
- Retained both redacted live evidence records through final comparison instead of deleting them during each residue audit.
- Required smoke to create and authoritatively purge a real room, not merely call cleanup on an empty account.
- Bound `BOOK_STORAGE_BUCKET_NAME` to the same environment's actual R2 binding and prohibited service bindings on the sharing Worker.
- Mapped recovery to `SharedReadingRecoveryJournal`'s real per-account deletion path and added ordering/failure-retention tests.
- Added signaling-client validation immediately before task creation, including reconnect/refresh paths, with a recording factory that proves no task is created on rejection.
- Replaced source-level launch coverage with executable owner/participant/restart tests, added a Release-build gate, and corrected the canonical account-deletion test filename.
- Required smoke to register book metadata before session creation and to exercise both generated accounts through redemption, cleanup, and independent deletion.
- Corrected remote cleanup to use the room's current generated controller with one bounded stale-generation refresh/retry.
- Expanded verifier fixtures across every required non-inherited setting and replaced ambiguous health language with exact status/content/header/body assertions.

**Round 1 result:** **PASS** after two bounded re-review passes — Luna and Terra confirmed 0 open Critical, High, or Medium issues.

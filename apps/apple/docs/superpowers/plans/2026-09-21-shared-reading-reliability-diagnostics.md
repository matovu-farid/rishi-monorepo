# Shared Reading Reliability and Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Apple shared reading recover safely across failures and identity transitions while exposing privacy-safe development diagnostics and actionable Worker errors.

**Architecture:** Separate authority dimensions with typed generation values; have one reconnect state machine and one account-scoped session registry; require a fresh server snapshot before rejoin UI becomes usable. Reuse the DEBUG local Apple dump sink, correlate it with the Worker’s structured error envelope, and merge explicit Catalyst/iPhone artifacts on the host.

**Tech Stack:** Swift 6, SwiftUI, XCTest/Swift Testing, TypeScript, Cloudflare Workers/Durable Objects, Drizzle, Bun.

---

## Guardrails

- Do not make live two-account E2E a gate for this work. Use focused deterministic tests and build/type checks.
- Keep diagnostics DEBUG-only, local, and non-fatal. Never log credentials, invite tokens/URLs, emails, raw user IDs, book metadata/content/hash/position, SDP/ICE, or raw error bodies.
- Do not author, edit, delete, or rename migration SQL manually. Inspect production D1 read-only first; generate any approved reconciliation through `bunx drizzle-kit generate` from `workers/worker`.
- Preserve unrelated dirty worktree changes. Stage only task-owned paths.
- Catalyst is not a simulator: its DEBUG log location must be explicitly created and retrieved independently of `simctl`.

## Consumer and call-site audit

| Behavior | Consumers that must change together |
| --- | --- |
| Authority fence | `SharedReadingModels`, signaling DTOs, coordinator, API tests, coordinator tests |
| Reconnect | signaling transport, `SharedReadingErrors`, coordinator connection callers, deterministic transport tests |
| Rejoin | API, active-session view/store, session view, reader destination, API/recovery tests |
| Session lifecycle | RootView, ServiceGraphFactory, rishiApp, auth, deletion, invite/progress stores, both shared-reading entry points |
| Backend errors | main Worker route/service, sharing Worker room boundary, Apple error decoding/API, Worker tests |
| Diagnostics | `Log`, SimulatorDumpSink, Apple shared-reading boundaries, Worker JSON logging, host collector and tests |

### Task 1: Select the safe migration reconciliation path

**Files:**
- Inspect: `workers/worker/src/db/schema.ts`, `workers/worker/drizzle/**`, `workers/worker/drizzle.config.ts`
- Inspect: `apps/apple/docs/superpowers/specs/2026-09-15-shared-reading-recovery-design.md`
- Create/modify only after audit: Drizzle schema and generated migration artifacts
- Test: `workers/worker/src/db/session-sharing-migration.test.ts`

- [ ] **Step 1: Record a read-only production audit.** Query the D1 migration journal and session-invite schema/row shape using the repository’s approved read-only Wrangler workflow. Record the exact predecessor state, row counts by nullability, and schema evidence in a review artifact; do not apply a migration.
- [ ] **Step 2: Write the failing migration-state test and decision record.** Add cases for fresh canonical, a journaled-applied predecessor, and a populated database where the historical `NOT NULL` migration failed before being journaled. The review record must select an operationally safe reconciliation for the exact journal state; an appended generated migration is not a remedy for an earlier unapplied failure.
- [ ] **Step 3: Run the red test.** From `workers/worker`, run the focused Bun test and confirm it fails because the selected schema transition is absent.
- [ ] **Step 4: Execute only the selected remediation.** For a journaled predecessor, model the next schema change in Drizzle and generate artifacts. For an unapplied failed historical migration, stop and use the separately approved production recovery procedure from the audit; do not hand-edit history or pretend an appended migration can run first.
- [ ] **Step 5: Run the focused test and schema generation check.** Confirm the test passes and `git diff --check` is empty. Commit only schema, generated artifacts, test, and audit record.

### Task 2: Make the shared-reading protocol authoritative and reconnect-safe

**Files:**
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingModels.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingSessionCoordinator.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/Transport/SharedReadingSignalingClient.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingErrors.swift`
- Create: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingGenerationTests.swift`
- Create: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingCoordinatorFenceTests.swift`
- Create: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingReconnectTests.swift`

- [ ] **Step 1: Write red authority-fence tests.** Independently send stale room, roster, controller, connection, and reader sequence values; include a newer room epoch with one stale subordinate value. Assert state remains unchanged for stale values and a newer epoch clears every subordinate fence before accepting a complete authoritative tuple.
- [ ] **Step 2: Verify red.** Run only these tests on iPhone Simulator through `scripts/test-integrity/run-verified.ts`; ensure the known raw-`Int`/roster-versus-room implementation fails assertions.
- [ ] **Step 3: Introduce typed generations.** Define `SharedReadingRoomEpoch`, `SharedReadingRosterGeneration`, `SharedReadingControllerGeneration`, and `SharedReadingConnectionGeneration` as distinct Codable/Comparable/Sendable raw-value types. Use them in all DTOs, fences, snapshots, and coordinator state; retain `rosterGeneration` explicitly.
- [ ] **Step 4: Implement atomic fence application.** Add one coordinator method that validates session ID, accepts a strictly newer room epoch by clearing roster/controller/connection/reader/progress state, then validates each same-epoch subordinate generation independently. Never compare values from different dimensions.
- [ ] **Step 5: Write red reconnect tests.** With an injected clock/backoff and scripted socket outcomes, assert exactly one reconnect task, no retry reset on socket open/arbitrary frame, reset only on validated `session.state`, bearer-only refresh, admission-only refresh, terminal stop, and explicit-disconnect cancellation.
- [ ] **Step 6: Implement classified reconnect decisions.** Add `retry(after:)`, `refreshBearer`, `refreshAdmission`, and `stop(code)` decisions. A reconnect operation selects one decision, performs only the required refresh, and remains cancellable.
- [ ] **Step 7: Verify green and commit.** Run the three focused suites and an Apple compile check. Commit only the protocol/reconnect files and tests.

### Task 3: Require authoritative rejoin and drain account-scoped sessions

**Files:**
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingAPI.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/ActiveReadingSessionStore.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/ActiveReadingSessionsView.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingSessionView.swift`
- Create: `apps/apple/rishi/rishi/SharedReading/SharedReadingSessionRegistry.swift`
- Modify: `apps/apple/rishi/rishi/{ServiceGraphFactory.swift,RootView.swift,rishiApp.swift,AppDependencies.swift,AppDependencies+Billing.swift}`
- Modify: `apps/apple/rishi/rishi/Auth/SignedOutViewModel.swift`
- Modify: `apps/apple/rishi/rishi/Account/AccountDeletionCoordinator.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/{PendingSessionInviteStore.swift,SharedSessionProgressStore.swift}`
- Create: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingActiveRecoveryTests.swift`
- Create: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingSessionRegistryTests.swift`

- [ ] **Step 1: Write red active-recovery tests.** Assert `/api/v1/reading-sessions/active` then `/rejoin`, local content-hash validation, fresh admission replacement, terminal removed/ended behavior, and that the view remains reconnecting until fresh matching state and roster arrive. Cover both an authoritative stored progress snapshot with a newer sequence and a server-confirmed no-progress state.
- [ ] **Step 2: Implement recovered-session readiness.** Introduce `SharedReadingRecoveredSession` containing the active summary, fresh admission, and verified local content hash. Make the rejoin flow construct it only after `/active` and local verification; gate session/book controls on authoritative state+roster and an explicit progress-present or progress-absent result.
- [ ] **Step 3: Write red lifecycle tests.** Cover owner/participant leave, sign-out, account switch, account deletion, remote end, timeout, and a delayed account-A callback after account B becomes active.
- [ ] **Step 4: Implement one registry.** Create a main-actor registry which registers session handles by account and has `drain(accountID:deadline:)`. Drain must locally cancel transport/peer/media/tasks and clear invitation/progress state immediately, then make best-effort leave. Use identity generation guards for asynchronous callbacks.
- [ ] **Step 5: Inject and invoke the registry at every boundary.** Make it a `BootstrappedServices` dependency. `AppDependencies.beginAccountChange`, `replaceUserId`, and `performSignOut` must drain before publishing new identity; inject the same registry into both shared-reading creation/rejoin flows and the account-deletion coordinator factory/callers. Do not allow views to become the only owner of a live session.
- [ ] **Step 6: Verify green and commit.** Run focused recovery/registry/auth tests on iPhone Simulator and a clean Apple build. Commit task-owned Apple files only.

### Task 4: Return actionable, correlated backend errors and complete deletion revocation

**Files:**
- Modify: `workers/worker/src/session-sharing-service.ts`
- Modify: `workers/worker/src/account-deletion.ts`
- Modify: `workers/worker/src/routes/session-shares.ts`
- Modify as contract requires: `workers/sharing-worker/src/{index.ts,AppleSessionRoom.ts}`
- Modify: `apps/apple/rishi/rishi/SharedReading/{SharedReadingErrors.swift,SharedReadingAPI.swift}`
- Modify tests: `workers/worker/src/{session-sharing-service.test.ts,account-deletion.integration.test.ts}` and `workers/sharing-worker/test/**`

- [ ] **Step 1: Write red error-contract tests.** For validation, auth, retryable upstream, terminal session, and deletion errors, assert `{ code, retryable, action, correlationId }`, one safe display message, and no secrets/identifiers in the response.
- [ ] **Step 2: Implement a single allowlisted error encoder and client decoder.** Generate/propagate an opaque request correlation ID from the route through `SessionSharingService` to the sharing Worker; map internal failures to the safe envelope and log only category, ID, outcome, and timing. Add `correlationId` to the client-safe `SharedReadingError` decode path and assert it reaches Apple diagnostics.
- [ ] **Step 3: Write red deletion tests.** Cover owner deletion ending/purging its room, participant deletion revoking membership, idempotent retry/lost response, and rejected re-admission by a deleted identity.
- [ ] **Step 4: Complete revocation before D1 finalization.** Finish the existing narrow deletion changes using Drizzle application queries and an acknowledged Durable Object operation; keep it idempotent and preserve unrelated dirty Worker files.
- [ ] **Step 5: Verify green and commit.** Run Worker/sharing focused Bun tests and typechecks using Bun commands. Commit only reviewed Worker/deletion files.

### Task 5: Add privacy-safe DEBUG diagnostics and host collection

**Files:**
- Modify: `apps/apple/rishi/rishi/Modules/RishiLogging/RishiLogging/Sinks/SimulatorDumpSink.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiLogging/RishiLogging/Log.swift`
- Modify: `apps/apple/rishi/rishi/RootView.swift`
- Modify: Apple shared-reading API, coordinator, signaling client, rejoin, and registry files from Tasks 2–3
- Create: `apps/apple/rishi/scripts/collect-shared-reading-diagnostics.sh`
- Test: `apps/apple/rishi/rishiTests/RishiLogging/SimulatorDumpSinkTests.swift`
- Create test: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingDiagnosticLoggingTests.swift`

- [ ] **Step 1: Write red logging tests.** Assert `sharing.*` events route to a shared-reading/network NDJSON stream, all schema fields are allowlisted, forbidden fields are omitted/redacted, malformed logging data cannot crash an actor, and correlation IDs are stable within one attempted operation.
- [ ] **Step 2: Add target-specific DEBUG storage and a typed sharing logger.** Keep non-blocking writing. The simulator adapter uses the existing dump directory; a Catalyst DEBUG adapter writes to an explicit app-support dump location. Add a structured sharing-event helper that accepts only typed safe fields. Do not introduce production uploads or an unbounded second sink.
- [ ] **Step 3: Migrate existing unsafe sharing logs, then instrument boundaries.** Replace RootView/API raw IDs and `Log.error` sharing payloads with the typed helper; ensure generic errors do not serialize raw sharing errors into the dump or Sentry. Emit safe events at API request/result, local-book validation, admission, socket open/close/reconnect decision, event accept/reject, recovery readiness, registry registration/drain, leave/end, and error mapping. Use the decoded backend correlation ID when supplied.
- [ ] **Step 4: Write red collector tests.** The collector must require an iPhone UDID, an explicit Catalyst dump path, and output path; label each parsed event, produce a manifest, reject path traversal/unknown target/missing dump, and never parse credentials.
- [ ] **Step 5: Implement separate acquisition adapters.** Use `simctl get_app_container` only for the explicit iPhone UDID; read the explicit Catalyst dump directory independently. Copy only diagnostic NDJSON files, emit merged NDJSON and manifest to the caller-selected directory, and make every failure precise and non-destructive.
- [ ] **Step 6: Verify green and commit.** Run logger/collector tests and a DEBUG build for both targets. Commit only logging, collector, and focused test files.

### Task 6: Final non-E2E verification and reviews

- [ ] **Step 1: Run focused Apple suites.** Run authority, reconnect, recovery, registry, and logging suites serially with the integrity wrapper; retain normalized artifacts.
- [ ] **Step 2: Run Worker focused suites.** Run the error-contract, deletion, migration, and sharing-room tests plus package typechecks with Bun; retain outputs.
- [ ] **Step 3: Run DEBUG builds.** Build iPhone Simulator and Catalyst serially under the project resource preflight; no live session is required.
- [ ] **Step 4: Verify scope and safety.** Confirm no Electron changes, no handwritten migration SQL, no E2E requirement added, and search source/tests for prohibited diagnostic values.
- [ ] **Step 5: Independent code review and re-review.** Resolve every Critical/High finding, repeat the review on the changed revision, and record evidence in the review artifact before merge.

## Adversarial review loop

### Round 1 — Review

| # | Sev | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | High | A client file cannot be a shared filesystem across app sandboxes and Workers. | Keep per-app DEBUG NDJSON; add explicit host collection and correlation with Worker Logs. |
| 2 | High | A generic reconnect retry can refresh valid credentials/admission and hide terminal failures. | Use exclusive typed reconnect decisions and deterministic state-machine tests. |
| 3 | High | Account-scoped views cannot guarantee teardown before identity change. | One composition-root registry performs immediate local drain plus best-effort network leave. |
| 4 | High | Historical migration safety cannot be inferred from source control. | Require a read-only production D1 audit and Drizzle-generated transition only. |

**Round 1 result:** Re-review required after independent plan review.

### Round 2 — Re-review after corrections

| # | Sev | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | Critical | Catalyst was incorrectly treated as a Simulator source. | Added a dedicated Catalyst DEBUG storage adapter and explicit collector path; `simctl` is iPhone-only. |
| 2 | Critical | An appended Drizzle migration cannot repair an earlier unapplied historical migration. | Added journal-state decision tree and explicit stop/approved recovery procedure. |
| 3 | Critical | Registry wiring omitted the actual `AppDependencies` account identity fence. | Added `AppDependencies`, billing sign-out, BootstrappedServices, and deletion factory/caller integration. |
| 4 | Medium | Existing generic sharing logs could bypass allowlisted redaction. | Migrate raw RootView/API/error paths to typed safe events and test record-level privacy. |
| 5 | Medium | Apple did not decode backend correlation IDs. | Extend the error model/decoder and assert propagation to diagnostics. |
| 6 | Medium | A valid active session may have no progress frame. | Define readiness as fresh state+roster plus explicit progress-present or progress-absent state. |

**Round 2 result:** **PASS** — independent re-review found 0 open Critical/High findings.

## Relay replacement amendment

The manual collector in Task 5 is replaced by a local chronological relay. The
relay owns the output path and one manual-run lifecycle; the apps do not write
to arbitrary host paths.

### Task 5R: Stream typed diagnostics to one chronological local file

**Files:**
- Modify: `apps/apple/rishi/rishi/Modules/RishiLogging/RishiLogging/Log.swift`
- Modify: `apps/apple/rishi/rishi/rishiApp.swift` and the shared-reading launch configuration boundary
- Create: `apps/apple/rishi/scripts/shared-reading-diagnostics-relay.ts`
- Replace: `apps/apple/rishi/scripts/collect-shared-reading-diagnostics.sh`

- [ ] **Step 1: Define the run contract.** A launch command creates a fresh output directory, random loopback port and opaque 256-bit run key; it passes only relay URL, key, actor, and run ID into each DEBUG app target. The relay, not either app, chooses `shared-reading.ndjson` and rejects reused output roots.
- [ ] **Step 2: Add typed nonblocking relay delivery.** `Log.sharedReading` retains its allowlisted local outbox. When relay configuration is present, enqueue a bounded HTTP POST containing only the typed event, actor, run ID, and monotonic actor sequence. Delivery failure never blocks app work; records remain in the privacy-safe local outbox for later flush/import.
- [ ] **Step 3: Finalize deterministic chronology.** The relay authenticates the opaque key using constant-time comparison and validates schema/actor/run ID. It retains event time plus arrival timestamp/sequence, then atomically emits `shared-reading.ndjson` at orderly shutdown sorted by `(eventTimestamp, actor, actorSequence)`. The manifest records relay clock metadata and any late/unflushed count; it never rewrites event time.
- [ ] **Step 4: Start, drain, and stop with the manual run.** The launch command starts the relay before either target, waits for explicit readiness, launches only the configured owner/participant targets, requests bounded app outbox flush at shutdown, then automatically performs a one-shot import of remaining typed fallback records before finalizing the relay output. It emits a single output location and any unflushed count. No filesystem watch loop or generic app-log ingestion is allowed.
- [ ] **Step 5: Privacy/source review.** Confirm only typed events cross loopback; the key, tokens, invite links, book/user values, raw errors, and generic logs cannot be written to the relay file.

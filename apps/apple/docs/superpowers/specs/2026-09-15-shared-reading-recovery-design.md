# Shared Reading Recovery and MCP Acceptance Design

> **Status:** Independent design review PASS (0 open Critical/High); pending
> user review

## Goal

Make Apple shared reading work between one Mac Catalyst user and one iPhone 17
Pro Simulator user, and prove that a real Codex client can drive the complete
flow through the local Rishi MCP server without creating duplicate app
instances or bypassing production behavior.

The accepted live-test authentication strategy uses two designated production
accounts whose signed-in app state already exists on the two targets. The test
does not enable a production test-auth route, inject bearer sessions, or create
a second API environment.

## Required outcome

Completion means all of the following are demonstrated together:

1. Catalyst selects a specific book, creates an invitation, starts the session,
   and opens the reader.
2. The iPhone redeems the canonical invitation and joins as a different user.
3. Both clients agree on the session, book, controller, position, and playback
   state.
4. Position and pause/resume changes propagate in both observable UI state and
   the versioned room protocol.
5. The iPhone can restart, recover the session through `/active`, rejoin, and
   receive a freshly observed authoritative reader position.
6. Leaving, ending, sign-out, and account deletion cannot retain unauthorized
   sockets, reconnect work, tokens, or room authority.
7. Codex performs the scenario through the actual registered MCP server and
   semantic app actions. Fake drivers, direct state injection, skipped tests,
   and host-only XCTest orchestration do not satisfy this requirement.
8. The test starts at most one Catalyst and one iPhone Rishi instance, monitors
   memory before each heavyweight phase, and removes every disposable process
   and artifact it owns. The only retained artifacts are the redacted evidence
   set defined below, stored under the run UUID with an explicit retention owner
   and expiry policy.

## Compatibility boundaries

The released unversioned `/api` routes and sharing Worker `/v1` transport are
frozen. Apple shared-reading behavior remains isolated as follows:

```text
Apple app
  -> production https://api.fidexa.org/api/v1/reading-sessions
  -> primary Worker membership/invite authority
  -> signed service binding /v2/internal/rooms/:sessionId
  -> AppleSessionRoom Durable Object
  -> production wss://sharing.fidexa.org/v2/sessions/:sessionId/wss
  -> Apple signaling, coordinator, peer mesh, and reader
```

- The primary Worker owns public authentication, invitations, D1 membership,
  idempotency, and account-scoped discovery.
- `AppleSessionRoom` owns Apple-only realtime room state, controller authority,
  admission leases, capacity, sockets, sync snapshots, and room lifetime.
- The Apple app never calls internal sharing endpoints.
- `SessionRoom`, `/v1`, and historical Electron message shapes remain intact.
- The sharing Worker validates the app bearer against the canonical Better Auth
  authority at `https://api.fidexa.org/api/auth/get-session`. Configuration or
  code that targets `rishi.fidexa.org` is invalid because the web app does not
  host or proxy Better Auth. A startup/configuration test and a live WebSocket
  admission smoke test verify this boundary.
- `/api/realtime/client_secrets` remains retired because restoring it would
  bypass the ledger-backed voice-session admission flow. Its retirement is not
  a shared-reading regression.

## Repair design

### 1. Creation and invitation consistency

`createRoom` carries `sessionId` inside the signed command as well as the URL.
The sharing Worker rejects a path/payload mismatch. Identical retries are
idempotent; conflicting retries fail explicitly.

Invitation creation uses a recoverable state transition rather than an
uncoordinated Durable Object call followed by two independent D1 inserts. D1
records the deterministic invitation/session identity and a provisioning state
before the room call. A retry reconciles that same identity against room status
and either completes or compensates it. A transient status failure returns a
retryable upstream error and never marks an invitation ended.

Static routes such as `/active` are registered before `/:id` routes. `/active`
returns only sessions belonging to the authenticated owner or participant and
supplies enough identity for `/rejoin` without reusing a one-time invite.

### 2. Admission and room lifetime

The API returns a bare signed admission ticket. The WebSocket client adds the
single `admission.` subprotocol prefix; the sharing Worker strips it once before
verification. Tickets are bound to room, user, epoch, and connection generation
and are single-use.

Issuing a ticket creates a pending-admission lease with the exact ticket expiry.
The lease counts toward capacity only while valid. Reissuing replaces the prior
lease for that user, and alarms remove expired unconsumed leases without
removing a newer connection generation.

Waiting rooms use an explicit invitation/startup expiry. The short empty-room
timer begins only after the room has had occupancy and later becomes empty.
This prevents a large book import from expiring a new room while still ensuring
abandoned rooms end.

### 3. Authoritative synchronization and reconnect

`AppleSessionRoom` persists the latest bounded controller sync frame after
validating room epoch, controller generation, connection generation, sequence,
book identity, and payload bounds. A newly admitted or reconnecting socket
receives state, roster, then exactly one current valid sync snapshot. Ending the
room or changing the authority fence clears stale snapshots.

The Apple signaling client retains one bounded reconnect loop for retryable
transport, bearer-refresh, and admission-refresh failures. Backoff resets only
after an authoritative server event. Ended, removed, forbidden,
incompatible-book, and explicit cancellation states terminate retries.

Room epoch, roster generation, controller generation, connection generation,
and reader sequence remain separate typed concepts. Events from another room,
an older authority fence, or an older sequence cannot overwrite current state.

### 4. Account and application lifecycle

The app composition root owns a shared-reading session registry. Sign-out and
account switching perform a best-effort leave, cancel signaling and peer media,
release microphone/TTS state, clear pending presentations and invitation
tokens, and erase account-scoped active/progress state. Cleanup does not block
sign-out, but delayed work from account A cannot present or reconnect under
account B.

Server-side account deletion uses an idempotent
`revokeAccountReferences(accountUserId, deletionOperationId)` command exposed
only on the HMAC-authenticated `/v2/internal` surface. It has no `actingUserId`
or caller-supplied controller generation and is never exposed on a public route.

- If the account owns the room, the command ends the room, closes every socket,
  invalidates all tickets/leases, and returns the terminal room identity.
- If the account is a participant, the command closes that participant's
  sockets, invalidates their tickets/leases, and removes their membership.
- If that participant currently controls the room, the room deterministically
  transfers control to the oldest connected eligible participant. If no
  eligible participant exists, it ends the room.
- Repeating the same or a later deletion operation returns the resulting state
  without reapplying generation changes.

Cleanup progress is persisted before destructive D1 cascades and processed in
bounded batches so retries advance without exceeding Worker invocation-chain
limits. Integration tests cover owner, ordinary participant, participant-as-
controller, no replacement, already-ended room, concurrent disconnect, and a
lost successful command response.

The purge API returns `{ "ok": true }` on success and preserves `409 CONFLICT`
for active rooms. Generic response decoding cannot turn a success sentinel into
`null`.

### 5. Migration safety

The two checked-in session-invite migrations have an unproven metadata chain,
are absent from Drizzle's journal, and the second adds a required
`idempotency_key` without a default. Before any deployment, a read-only
production D1 inspection records:

- applied `d1_migrations` entries;
- whether `session_invites` exists and its SQL definition;
- column nullability and row count;
- existing indexes, including the owner/idempotency unique index;
- UTC observation time, production database identifier, inspected repository
  SHA, and SHA-256 hashes of every candidate migration artifact.

Local staged-migration tests cover a fresh database, an empty intermediate
table, and a populated intermediate table. Historical migration files are
never deleted, renamed, or hand-edited. The observed production state selects
exactly one generated path:

1. If neither migration was applied and the table is absent, retain the old
   artifacts as quarantined history, remove them from the deployment allowlist,
   and generate one canonical migration from the `origin/main` schema snapshot
   to the complete target schema with Drizzle Kit.
2. If the first migration was applied and the second was not, clone the observed
   production schema into a local D1 database and run
   `bunx drizzle-kit pull --init` only against that clone, using an isolated
   reconciliation config and output directory. The generated baseline SQL,
   schema, snapshot, production schema digest, and D1 migration record form the
   predecessor evidence and are not applied to production. Against that
   generated baseline, first change the canonical
   `workers/worker/src/db/schema.ts` declaration to nullable and run
   `bunx drizzle-kit generate` to create the first executable delta. That
   nullable declaration remains the source of truth for the entire transitional
   deployment. Deploy a Worker version compatible with the nullable column,
   apply that generated delta through the repository's Wrangler/D1 workflow,
   and run a disabled-by-default bounded Drizzle backfill keyed by a durable
   cursor. After verifying zero nulls and duplicate owner/key pairs, change the
   same canonical schema declaration to non-null/unique and run
   `bunx drizzle-kit generate` against the same generated chain for the final
   delta. Apply it before enabling session creation. The unsafe historical
   second artifact remains quarantined and is never executed.
3. If the second migration is recorded, verify the physical column, nullability,
   row values, and index before generating any reconciliation. A recorded row
   alone is not accepted as proof.

Every generated SQL and metadata artifact is accepted without hand editing and
is tested from the exact observed predecessor state. The inspection expires if
the production schema, inspected repository SHA, or migration hashes change.
Deployment remains blocked until a fresh matching evidence record exists.

### 6. MCP and app-control ownership

The Swift MCP remains a separate local stdio process. It owns the XCTest bridge
and exactly one session per explicit destination. For live acceptance it stops
an existing designated target only when necessary, relaunches exactly one copy
while preserving the app container and signed-in account, and refuses to act on
unowned or duplicate instances.

All MCP/E2E-owned process creation passes through one audited process supervisor;
static checks reject direct production `Process`/spawn calls outside it. Before
each launch the supervisor acquires a destination-scoped exclusive lock, records
the requested executable, parent PID, child PID, process start time, and target,
and rejects an occupied lock or a pre-existing duplicate. It keeps the lock until
the complete descendant tree exits. The evidence verifier reconciles every owned
PID and process-start record to one accepted launch event, so a short-lived owned
duplicate cannot disappear between periodic inventories.

Books receive stable semantic accessibility identifiers derived from book
identity, not list position or title alone. Public MCP operations use semantic
identifiers and supported UI controls; raw coordinates and arbitrary shell
execution remain unavailable. Catalyst-specific activation may use XCTest's
coordinate click internally when required by Catalyst accessibility behavior,
but this is not exposed as a general MCP coordinate tool.

The MCP must support the observable sequence:

```text
list_app_instances -> memory_snapshot -> start_app(catalyst)
-> start_app(iphone) -> inspect_app_state -> select_book
-> create_reading_session -> join_reading_session
-> wait_for_participant -> start/open -> reader progress
-> pause/resume -> restart participant -> active/rejoin
-> leave/end -> final memory_snapshot -> stop owned instances
```

The standalone E2E host may prepare builds, validate resources, and coordinate
evidence, but it cannot own parallel app sessions during MCP acceptance. There
is one process owner per destination.

## Failure and error contract

Every cross-component failure is classified as either retryable or terminal.
Stable error codes distinguish invalid input, authentication, room capacity,
expired/used admission, ended/removed membership, incompatible content,
conflict, upstream unavailability, and cleanup failure. Logs include a redacted
correlation ID, API/Worker version, route, phase, and destination; they never
include bearer tokens, invitation tokens, signed URLs, passwords, or book
content.

The test coordinator preserves the primary scenario failure and cleanup outcome
separately. Cleanup failure cannot replace the original failure, and success is
not reported while account, process, lock, socket, or artifact cleanup is
unconfirmed.

Injected failure tests cover every retryable and terminal classification. A
redaction test scans structured logs and retained evidence for bearer tokens,
invitation tokens, passwords, signed URLs, and fixture paths. Coordinator tests
assert that primary and cleanup failures remain separately observable.

## Verification model

Each implementation task follows strict red-green-refactor:

1. Add one focused regression and run it against the current behavior.
2. Record the expected failing assertion.
3. Apply the smallest production change.
4. Run the focused test and relevant neighboring suite.
5. Run an independent specification-compliance review.
6. Resolve every Critical/High finding and re-review.
7. Run an independent code-quality review.
8. Resolve every Critical/High finding and re-review.
9. Commit only the task's owned files.

No test may convert failure or zero discovered tests into success. Live
acceptance may not use `XCTSkip`, a fake MCP driver, injected sessions,
localhost Workers, synthesized success events, or stale reader values.

Every test command records discovered, passed, skipped, and failed counts.
Acceptance requires `discovered > 0`, `failed = 0`, `skipped = 0`, and process
exit status zero. CI contains a deliberately failing verifier proving that a
failing suite and a zero-test suite both make the job fail.

### Same-run live evidence ledger

One immutable redacted ledger binds the final live run to a run UUID, UTC
timestamps, repository SHA, `origin/main` SHA, MCP executable SHA-256, registered
MCP configuration identity, production endpoint/Worker versions, and the PIDs
and destinations of MCP, E2E host, XCTest, Xcode, and Rishi processes. For each
live target it also records bundle identifier/version, Mach-O UUID and SHA-256,
build repository SHA, installation and launch timestamps, target UDID, device
model, and OS version. The launched identities must match both the just-produced
build products and the corresponding result bundle; a stale installed binary
invalidates the run.

For each heavyweight phase it records host memory, explicit minimum thresholds,
owned process descendants, destination ownership lock, and app-instance count.
The run aborts before launching the next phase when a threshold is not met.

Memory samples come directly from host process APIs and are bound to PID plus
process start time. Before package resolution, each serialized Xcode build, and
each live peer/MCP phase, `hostAvailableBytes` must be at least 8 GiB and free
disk at least 20 GiB. During a heavyweight phase the coordinator samples every
five seconds, records current and peak RSS for each owned MCP, E2E host, Xcode,
XCTest, Catalyst, and Simulator app process, and aborts when host available
memory remains below 2 GiB for two samples or combined owned RSS exceeds 6 GiB.
No sample may be older than ten seconds when a phase gate is evaluated.

The ordered MCP transcript records tool name, semantic target identifier,
redacted result identity, and timestamp. UI checkpoints record stable book,
session, controller, reader locator/sequence, and playback state. Protocol
checkpoints record the causal `/v2` frame identity and matching authority fields.
Distinct accounts are represented by non-reversible per-run fingerprints.

The ledger is append-only hash-chained JSON Lines. The coordinator creates an
ephemeral Ed25519 key at run start, signs the final chain digest, and deletes the
private key after finalization. The public key, signature, and digest are copied
into both result-bundle attachments and the Codex MCP transcript. A separate
verifier recomputes the chain, verifies the signature, and requires every
checkpoint and bundle to reference the same run UUID and digest before the run
can pass.

The coordinator is an aggregator, not the authority for facts it reports. The
MCP server emits its own invocation log, the XCTest bridge/app emits UI and
target-build observations into result-bundle attachments, a separate OS sampler
records process/memory observations, and production HTTP/WebSocket observations
are cross-checked against independently retrieved Worker event identities and
membership state. Each producer owns a separate ephemeral signing key whose
public key, PID, executable hash, and first record are registered before the
scenario starts. The verifier requires a causal cross-source match and rejects a
checkpoint supported only by a coordinator-authored record; no source may attest
both the action and its claimed external effect.

Result bundles, the redacted evidence ledger, and redacted failure logs are
retained as completion evidence. Credentials, cloned `.xctestrun` files, bridge
sockets, manifests, screenshots containing account data, derived data, and
other success artifacts are disposable and removed after verification.

## Completion evidence

| Requirement | Authoritative evidence |
| --- | --- |
| Legacy compatibility | An inventory tied to the recorded `origin/main` SHA lists every released route, request/response contract, authentication flow, D1/binding contract, `/v1` message family, and Durable Object protocol, including unchanged contracts transitively touched by changed schemas, middleware, configuration, or bindings. Each entry records unchanged-and-verified or an explicit compatible delta. Captured Electron-style ICE passes unchanged; negative isolation tests prove Apple commands/state remain unavailable on `/v1`. |
| Create and join | Primary Worker route tests cross the real serializer/internal-route boundary and prove identical retries yield one invitation/room, conflicting retries fail, interruption after each D1/DO step resumes, a transient status failure returns retryable without false `ended`, and all compensation paths leave no duplicate or orphan. The same-run MCP transcript and UI checkpoints prove Catalyst selected the stable book ID, created the canonical invite, started the session, and opened the reader; distinct account fingerprints and server membership evidence prove iPhone performed the one-time redemption. |
| Durable room behavior | Controlled-clock tests prove ticket expiry, capacity recovery, startup/empty expiry, hibernation, sync replay, and stale-fence rejection. Admission tests also prove one-time replay rejection, wrong room/user/epoch/generation rejection, doubled-prefix rejection, reissued-ticket supersession, and expired-lease cleanup that cannot remove a newer generation. |
| API recovery | Mounted `/active` tests cover owner, participant, removed member, ended room, other account, and temporary sharing-service failure. The live ledger proves a real iPhone process restart, production `/active` response, rejoin, a greater post-restart reader sequence/authority marker, and exactly one current snapshot rather than cached state. |
| Client reconnect | Swift tests prove increasing bounded backoff, transient refresh recovery, terminal stop, and authoritative handshake reset. |
| Account safety | A teardown matrix separately proves leave, end, sign-out, account switch, owner deletion, participant deletion, and participant-controller deletion. Cleanup has a 30-second deadline, explicit local registry/transport drain signals, authoritative room/membership status, and three post-cleanup probes one second apart. Timeout, contradictory state, or an inconclusive probe fails the test. The probes confirm no unauthorized socket, reconnect task, token, lease, membership, or room authority. A focused decoder test proves purge success remains `{ok:true}` and conflict remains 409. |
| Migration safety | Fresh, empty-intermediate, and populated-intermediate migration tests plus fresh timestamped production schema evidence bound to database ID, repository SHA, and migration hashes. The selected remediation consists only of Drizzle-generated SQL/metadata and verified Drizzle backfill code. |
| MCP correctness | Swift package tests cover protocol, semantic workflows, ownership races, lock failure, bridge timeout/EOF, descendant cleanup, and memory floors. |
| Apple builds | Fresh serialized Catalyst and iPhone 17 Pro Simulator builds pass using distinct derived-data paths. Their repository SHA, bundle metadata, Mach-O UUIDs/hashes, target UDIDs/OS versions, installation times, and launched-process identities match the same-run result bundles and evidence ledger. |
| Real feature | Two result bundles report one discovered and passing peer test each with zero skips. A checkpoint matrix maps causal `/v2` frame IDs to before/after UI observations and proves matching session, book, controller, sequence, exact locator, and playback state for progress, pause, resume, restart, and rejoin. |
| Codex integration | The ledger identifies the registered stdio server PID, executable hash, and configuration, and contains the immutable ordered Codex MCP transcript. Machine checks prove fake mode, session injection, `XCTSkip`, localhost Workers, public coordinate tools, and host-owned parallel app orchestration were absent. |
| Resource cleanup | The exclusive launch-gate audit reconciles every owned process start to one destination lock and proves no transient owned duplicate; timestamped inventories record memory before every heavyweight phase. Final descendant checks cover MCP/E2E host/Rishi/Xcode/XCTest; locks, sockets, manifests, credentials, cloned test specs, and disposable artifacts are removed. Only the redacted run-UUID evidence set remains under its recorded retention owner and expiry policy. |
| Failure diagnostics | Injected tests prove retryable/terminal classification, structured-log redaction, and separate preservation of primary and cleanup failures. Raw summaries prove nonzero test discovery and zero skips/failures. |
| Deployment readiness | Fresh `origin/main` compatibility comparison, verified migration state, `/v2`-first rollout order, both Worker health/version checks, and zero open Critical/High findings. Each Worker computes a truncated HMAC fingerprint over the same deployment-specific random challenge on an internal-only verification path; CI compares the fingerprints without logging either secret, then sends a signed primary-to-sharing smoke command that must verify successfully. |

## Implementation decomposition

The implementation plan will split work into these sequentially integrated
lanes, with only non-overlapping research or tests parallelized:

1. Freeze the change inventory and restore trustworthy CI/test discovery.
2. Preserve `/v1` compatibility and record migration state.
3. Repair creation identity, `/active`, idempotency, and transient failures.
4. Repair admission, leases, room expiry, sync replay, and sharing errors.
5. Repair Apple reconnect, generation ordering, and account transitions.
6. Repair bounded account deletion and migration upgrade behavior.
7. Repair stable book actions, Catalyst activation, MCP ownership, and resource
   enforcement.
8. Build the real MCP-owned two-account acceptance path.
9. Run the full compatibility, Worker, Apple, MCP, live, cleanup, and rollout
   gates; then perform a final independent branch review.

## Dirty-work disposition

- Preserve and rework useful Apple accessibility, Swift MCP, E2E host, and
  `/v2` purge building blocks only through their assigned tasks.
- Keep the production test-auth route disabled and exclude its current dirty
  implementation from the accepted live path.
- Keep `/api/realtime/client_secrets` retired and retain explicit retirement
  tests; do not restore its unmetered credential flow.
- Exclude Electron build-asset deletions, root screenshots, marketing capture
  changes, unrelated dependency churn, and any test change that merely blesses
  a broken contract.
- Delete the Node MCP implementation only in the same verified commit that
  proves the Swift replacement's protocol parity and real bridge operation.

## Rollout

No production deployment occurs during ordinary implementation. After all
local and live gates pass, deployment order is:

1. Re-run the production compatibility audit against current `origin/main`.
2. Record production D1 migration state and select the matching generated
   migration path. If the nullable/backfill path is required, deploy the
   nullable-compatible primary Worker with session creation disabled, apply the
   generated nullable delta, run and verify the bounded Drizzle backfill, then
   apply the generated non-null/unique delta.
3. Deploy the sharing Worker `/v2` support and separate Apple Durable Object
   binding while retaining `/v1`.
4. Verify sharing Worker health/version, canonical Better Auth authority, and the
   signed internal and authenticated WebSocket smoke paths.
5. Deploy the final primary Worker `/api/v1` routes with session creation still
   disabled, verify schema compatibility, then enable creation.
6. Verify both Workers and run the real two-account MCP acceptance.
7. Roll back by disabling new session creation while allowing existing rooms to
   end; never remove `/v1`, `/v2`, or historical migrations as rollback.

## Adversarial review requirement

The written implementation plan and every completed lane receive independent
review. A lane cannot advance with an open Critical/High finding. The final
review must attempt to disprove compatibility, authorization, retry safety,
state convergence, cleanup, resource ownership, and the claim that Codex drove
the real feature.

### Design review round 1

The independent architecture and testability reviews returned
**RE-REVIEW REQUIRED**. High findings covered the wrong production auth
authority, underspecified privileged account revocation, unexecutable migration
remediation, indirect live evidence, incomplete lifecycle postconditions,
stale migration evidence, and ambiguous artifact retention. The revisions above
define the missing contracts and strengthen completion evidence. A fresh
independent re-review is required before implementation planning.

### Design review round 2

The independent reviewers returned **RE-REVIEW REQUIRED**. The remaining High
findings required an exact canonical-schema migration transition, explicit
admission and creation failure proofs, stronger lifecycle and secret-verification
gates, precise memory limits, an integrity-protected evidence ledger, complete
compatibility inventory, transient-process detection, independent evidence
producers, and live target/binary identity binding. The design was revised to
make each item an executable completion condition.

### Design review round 3

The Terra architecture/migration reviewer and Luna testability/evidence reviewer
both returned **PASS** with no open Critical or High findings. Terra confirmed
that the nullable canonical Drizzle schema, generated delta, bounded backfill,
and final constraint migration are ordered safely. Luna confirmed that retained
evidence boundaries, exclusive audited launches, cross-source evidence, and
fresh binary/target identity binding close the live-acceptance proof gaps.

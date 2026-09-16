# Shared Reading Worker and Protocol Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the production `/api/v1` shared-reading API and isolated sharing `/v2` Durable Object correct, retry-safe, migration-safe, and backward compatible with released `/api` and `/v1` clients.

**Architecture:** D1 is invitation/membership/idempotency authority; `AppleSessionRoom` is realtime authority. The primary Worker writes a recoverable provisioning record before sending HMAC-authenticated `/v2/internal` commands. Admission uses one bare, single-use ticket with an expiring capacity lease; the room persists one fenced sync snapshot for rejoin.

**Tech Stack:** TypeScript, Hono, Cloudflare Workers/Durable Objects/D1, Drizzle ORM/Kit, Zod, Vitest, Bun, Wrangler.

---

## File ownership map

- Migration owner only: `workers/worker/src/db/schema.ts`, `workers/worker/drizzle/**`, `workers/worker/scripts/verify-migration-pattern.ts`, `workers/worker/src/test-utils/d1.ts`, and the canonical primary `workers/worker/wrangler.jsonc` migration pattern.
- Sharing owner only: `packages/sharing-protocol/src/{schemas,sync}.ts`, `workers/sharing-worker/src/{AppleSessionRoom,index,tokens,wsCreds,appleTopology,auth,health,hmac}.ts`, matching tests.
- Primary API owner: W3 exclusively owns `workers/worker/src/routes/session-shares.ts`, `workers/worker/src/session-sharing-service.ts`, `workers/worker/src/{index,api-version}.ts`, and matching tests until its commit/review completes.
- Deletion owner: after the serialized W3→W4 handoff, W4 owns `workers/worker/src/account-deletion.ts`, its exact integration tests, deletion-marker fences in session-share membership writes, the `revokeAccountReferences` and `purgeAppleRoom` client/decoder methods and tests, stable pending/conflict mapping in `workers/worker/src/routes/{user,auth-compat}.ts` and tests, the Apple room's permanent deleted-account tombstone, and the sharing gateway's exact purge/revoke result-to-status mapping and tests. W4 must not modify schema or migration artifacts; pre-existing Drizzle-history drift is tracked separately. Every other primary/sharing section remains W2/W3-owned.
- Integration owner only: after W4 is committed and independently accepted, W5 receives a symbol-level handoff for trust-keyring verification in `workers/worker/src/session-sharing-service.ts`, `workers/sharing-worker/src/{index,hmac}.ts`, their exact tests, both Workers' configuration/type files, health tests, and compatibility evidence. W5 may not alter room/session behavior outside those trust symbols.

No owner may stage unrelated dirty files or edit another lane's files.

The deprecated Electron app, its tests, and its packaging are outside this
plan. `routes/auth-compat.ts` is touched only because it is a still-deployed
backend account-deletion entry point: preserve its existing success contract,
add only the same truthful 503/409 deferred mappings as the canonical route,
and do not modify or execute Electron code/tests.

## Mandatory command/result wrapper

No raw test/typecheck/build command below is itself accepted as a gate. Execute
each through `scripts/test-integrity/run-verified.ts`. For Vitest, the wrapper
adds a task-labelled reporter path inside the supplied private run root, parses that
artifact, and records the individual exit. For typecheck/build use format
`command`. Every green run requires discovered `> 0`, skipped/failed `0`, and
exit `0`; every red run requires discovered/failed `> 0` and nonzero exit. An
absent/unparseable artifact fails. The task's literal command is passed after
`--`; artifact names use the exact task label (`W1`, `W2`, `W3`, `W4`, or `W5`).

## Adversarial review loop and stopping rule

Every work package uses an independent loop: implement → verify the predefined
gates → review → log findings → repair → re-run the same gates → re-review.
Critical and High findings block the package. The loop exits only when all of
the following are true:

- every completion gate already defined for that package passes with valid
  result-integrity evidence;
- the latest independent review reports zero open Critical or High findings;
- any remaining Medium or Low notes are recorded and explicitly accepted as
  non-blocking follow-up work; and
- the package's cached diff contains only its reviewed ownership set.

Once those conditions are met, commit the package and advance to the next one.
Do not reopen a proven decision or broaden the package merely because another
review pass can suggest additional work. Reopen it only when new evidence
contradicts an accepted proof, a named completion gate regresses, or the user
changes the requirements. New suggestions that do not affect a named invariant
or completion gate belong in follow-up work rather than extending the active
loop indefinitely.

Only one reviewer may be active for a work package and revision at a time.
Never launch duplicate cold reviews of the same unchanged plan or diff. Before
dispatch, check existing review tasks and reuse the active one. A re-review
starts only after fixes change the reviewed artifact. Parallel review is allowed
only for explicitly disjoint scopes with separate files and acceptance criteria.
If duplicate same-scope reviews are started accidentally, stop the less advanced
one immediately and keep the review with the most completed evidence.

## Task W0: Capture compatibility and production migration evidence

**Files:**

- Create: `apps/apple/docs/superpowers/reviews/shared-reading-worker-baseline.md`
- Inspect: `origin/main`, Worker route/config/schema/protocol files

- [ ] **Step 1: Inventory every released contract**

Record each unversioned `/api` route, every `/v1` request/message family, auth
flow, D1 table/index, binding, Durable Object class, and migration present at
`origin/main`. Include unchanged contracts transitively touched by middleware,
schema, config, or binding edits.

Run:

```bash
git rev-parse origin/main
git diff --name-status origin/main...HEAD -- workers packages/sharing-protocol
rg -n 'app\.(get|post|put|patch|delete)|routes\.(get|post|put|patch|delete)' workers/worker/src workers/sharing-worker/src
rg -n 'durable_objects|migrations_pattern|bindings|class_name|new_classes|renamed_classes' workers/worker/wrangler.jsonc workers/sharing-worker/wrangler.jsonc
```

Expected: the baseline contains one disposition per released contract:
`UNCHANGED_VERIFIED` or `COMPATIBLE_DELTA`; no `/v1` Apple state/command appears.

- [ ] **Step 2: Run the read-only production D1 inspection**

Run from `workers/worker` after read-only network authorization:

```bash
date -u '+%Y-%m-%dT%H:%M:%SZ'
git rev-parse HEAD
git rev-parse origin/main
git status --porcelain=v2
shasum -a 256 drizzle/migrations/20260820112725_session_invites_from_prod_session_only/migration.sql drizzle/migrations/20260820112725_session_invites_from_prod_session_only/snapshot.json drizzle/migrations/20260820121338_session_invites_idempotency/migration.sql drizzle/migrations/20260820121338_session_invites_idempotency/snapshot.json
bunx wrangler d1 migrations list rishi --remote
bunx wrangler d1 execute rishi --remote --command "SELECT * FROM d1_migrations ORDER BY 1"
bunx wrangler d1 execute rishi --remote --command "SELECT name, sql FROM sqlite_master WHERE type='table' AND name='session_invites'"
bunx wrangler d1 execute rishi --remote --command "PRAGMA table_info('session_invites')"
bunx wrangler d1 execute rishi --remote --command "SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name='session_invites' ORDER BY name"
bunx wrangler d1 execute rishi --remote --command "SELECT COUNT(*) AS row_count, SUM(idempotency_key IS NULL) AS null_keys, COUNT(*) - COUNT(DISTINCT owner_user_id || char(0) || idempotency_key) AS duplicate_pairs FROM session_invites"
```

Expected: evidence includes UTC time, database ID
`970159b7-ca91-49c1-bae8-feb43b24a7e6`, both SHAs, artifact hashes, migration
records, physical DDL, columns, indexes, row/null/duplicate counts. All commands
are read-only; do not run `migrate:remote`.

- [ ] **Step 3: Select exactly one migration path**

Write one machine-readable decision using the values copied verbatim from Step 2:

```ts
type MigrationDecision = {
  databaseId: "970159b7-ca91-49c1-bae8-feb43b24a7e6";
  observedAt: string;
  head: string;
  originMain: string;
  path: "fresh-canonical" | "nullable-backfill" | "physical-reconciliation";
  deploymentAllowed: false;
};
```

Expected: the path follows the approved design; missing or contradictory evidence
keeps `deploymentAllowed` false.

- [ ] **Step 4: Commit the read-only evidence**

```bash
git add apps/apple/docs/superpowers/reviews/shared-reading-worker-baseline.md
git commit -m "docs: record shared reading worker baseline"
```

## Task W1: Repair the migration chain without hand-authored SQL

**Files:**

- Modify: `workers/worker/src/db/schema.ts`
- Modify: `workers/worker/src/test-utils/d1.ts`
- Modify: `workers/worker/scripts/verify-migration-pattern.ts`
- Create when selected: `workers/worker/drizzle.reconciliation.config.ts`
- Create when selected: `workers/worker/scripts/backfill-session-invite-idempotency.ts`
- Create: `workers/worker/src/db/session-sharing-migration.test.ts`
- Generate: `workers/worker/drizzle/migrations/**`
- Modify: `workers/worker/wrangler.jsonc`

- [ ] **Step 1: Write staged-predecessor tests**

Add staged-predecessor cases with these exact expectations:

```ts
it("migrates a fresh database to the final schema", async () => { /* ... */ });
it("migrates an empty first-stage predecessor", async () => { /* ... */ });
it("blocks a populated first-stage predecessor without data loss", async () => {
  // The immutable second migration adds a NOT NULL column without a default.
  // It must fail before mutating the three predecessor rows.
});
```

Run:

```bash
cd workers/worker
RISHI_W1_RED_ROOT=$(mktemp -d /private/tmp/rishi-W1-red.XXXXXX)
bun ../../scripts/test-integrity/run-verified.ts --format vitest-json --expect fail --require-failure-id "blocks a populated intermediate predecessor without data loss" --owned-output-root "$RISHI_W1_RED_ROOT" --artifact "$RISHI_W1_RED_ROOT/migration.json" --cwd . -- bun run test -- src/db/session-sharing-migration.test.ts
```

Expected red: the repository initially lacks explicit evidence that fresh and
empty predecessors succeed while a populated half-migrated predecessor fails
closed without mutating its rows.

- [ ] **Step 2: Make the selected canonical schema state explicit**

For `nullable-backfill`, the transitional canonical declaration is:

```ts
idempotencyKey: text("idempotency_key"),
```

After verified backfill it becomes:

```ts
idempotencyKey: text("idempotency_key").notNull(),
```

with the existing owner/key unique index retained. For the fresh path, generate
directly from the full non-null target. Never create a hidden temporary schema
that disagrees with the live canonical file.

- [ ] **Step 3: Execute only the selected migration branch**

For `fresh-canonical`, retain both historical directories in
`migrations_pattern` as immutable append-only history and generate from the
`origin/main` snapshot to the complete non-null schema:

```bash
cd workers/worker
bunx drizzle-kit generate --config=drizzle.config.ts --name=session_invites_canonical
```

For `nullable-backfill`, first export schema-only production state to an isolated
local clone, then introspect only that clone:

```bash
cd workers/worker
RISHI_W1_RECONCILIATION_ROOT=$(mktemp -d /private/tmp/rishi-W1-reconciliation.XXXXXX)
bunx wrangler d1 export rishi --remote --no-data --output="$RISHI_W1_RECONCILIATION_ROOT/schema.sql"
sqlite3 "$RISHI_W1_RECONCILIATION_ROOT/reconciliation.sqlite" ".read $RISHI_W1_RECONCILIATION_ROOT/schema.sql"
RISHI_RECONCILIATION_DB_URL="$RISHI_W1_RECONCILIATION_ROOT/reconciliation.sqlite" bunx drizzle-kit pull --init --config=drizzle.reconciliation.config.ts
```

`drizzle.reconciliation.config.ts` reads only the task-specific
`RISHI_RECONCILIATION_DB_URL`, rejects a missing value, and writes only to
`drizzle/reconciliation/session-invites/`; a test rejects the production database
ID, remote URL, or normal migration output directory. The pulled SQL, schema,
snapshot, production digest, and D1 migration record are predecessor evidence
and are never applied to production. The reconciliation output is used only to
select/verify the branch and is recorded as hashed non-deployable evidence; it
is never named by Wrangler. Change canonical `schema.ts` to nullable, then
generate the deployable nullable delta into the canonical migration directory:

```bash
bunx drizzle-kit generate --config=drizzle.config.ts --name=session_invites_nullable_idempotency
```

Implement `backfill-session-invite-idempotency.ts` with Drizzle selects/updates,
a durable cursor, bounded page size, deterministic keys for existing rows, and
idempotent resume. Prove locally that interruption after every page resumes and
finishes with zero nulls/duplicates. Only after that proof, change canonical
`schema.ts` to non-null/unique and generate:

```bash
bunx drizzle-kit generate --config=drizzle.config.ts --name=session_invites_idempotency_constraint
```

For `physical-reconciliation`, the read-only W0 inspection is the physical
baseline. If its column/nullability/index/row evidence matches the final target,
retain both already-applied historical migrations in the canonical chain and
hash-lock their generated SQL and snapshots. D1 production skips them by their
exact recorded names; fresh and local databases must replay them in order. Run
this canonical no-change proof:

```bash
cd workers/worker
RISHI_W1_PHYSICAL_ROOT=$(mktemp -d /private/tmp/rishi-W1-physical.XXXXXX)
bun ../../scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W1_PHYSICAL_ROOT" --artifact "$RISHI_W1_PHYSICAL_ROOT/snapshot-command.json" --cwd . -- bun run scripts/verify-migration-pattern.ts --snapshot-before "$RISHI_W1_PHYSICAL_ROOT/before.json"
bunx drizzle-kit generate --config=drizzle.config.ts --name=session_invites_physical_noop # may report that the old snapshot format cannot generate an artifact
bun ../../scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W1_PHYSICAL_ROOT" --artifact "$RISHI_W1_PHYSICAL_ROOT/noop.json" --cwd . -- bun run scripts/verify-migration-pattern.ts --assert-noop --before "$RISHI_W1_PHYSICAL_ROOT/before.json" --generated-name session_invites_physical_noop --expect-executable-statements 0
```

If Drizzle Kit reports that the historical snapshot format is outdated and
emits no artifact, record that output and use the unchanged before/after
snapshot as the no-change proof. The verifier requires either no new canonical
artifacts or a generated artifact
whose parsed executable-statement count is exactly zero; it rejects DDL/DML,
journal mutation, missing/malformed before-state, and reconciliation-directory
output. If any
physical property differs, select `nullable-backfill` instead—never force-mark a
migration applied and never hand-edit SQL or snapshots.

For generated deltas, verify the generated SQL/snapshot/metadata are under
the canonical `drizzle/` directory, the canonical `wrangler.jsonc` migration
pattern includes those exact files in order, and no
`drizzle/reconciliation/session-invites/**` path matches either deployment
pattern. Record reconciliation hashes and canonical generated paths separately
in the reviewed migration-files evidence.

All fixture setup and assertions use Drizzle. The test migrator and deployment
pattern retain the exact generated historical chain. The verifier hash-locks
already-applied SQL and snapshots so they cannot drift after production has
recorded their names.

- [ ] **Step 4: Verify generated files and migration allowlists**

```bash
RISHI_W1_VERIFY_ROOT=$(mktemp -d /private/tmp/rishi-W1-verify.XXXXXX)
bun ../../scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W1_VERIFY_ROOT" --artifact "$RISHI_W1_VERIFY_ROOT/migrations.json" --cwd . -- bun run verify:migrations
git status --porcelain=v2 -- workers/worker/drizzle workers/worker/src/db/schema.ts workers/worker/wrangler.jsonc
git diff --name-only -- workers/worker/drizzle
```

Expected: any generated SQL and snapshot appear together; the canonical
Wrangler pattern names the append-only deployable chain. Create
`apps/apple/docs/superpowers/reviews/shared-reading-generated-migration-files.txt`
with `apply_patch`, listing each generated SQL/snapshot/metadata path verbatim
from this output, one repository-relative path per line. Review that file before
staging. For physical reconciliation with no generated artifact, it records
that fact and separately lists the retained, hash-locked historical evidence.

- [ ] **Step 5: Prove all local predecessor states**

```bash
RISHI_W1_GREEN_ROOT=$(mktemp -d /private/tmp/rishi-W1-green.XXXXXX)
bun ../../scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_W1_GREEN_ROOT" --artifact "$RISHI_W1_GREEN_ROOT/migration.json" --cwd . -- bun run test -- src/db/session-sharing-schema.test.ts src/db/session-sharing-migration.test.ts
bun ../../scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W1_GREEN_ROOT" --artifact "$RISHI_W1_GREEN_ROOT/migrate-local.json" --cwd . -- bun run migrate:local
```

Expected green: fresh and empty-intermediate migrations succeed; the populated
intermediate test proves the immutable unsafe alteration fails closed and all
predecessor rows remain; discovered `> 0`, skipped/failed `0`, exits `0`.

- [ ] **Step 6: Commit only migration-owned files**

```bash
git diff --name-only -- workers/worker/src/db/schema.ts workers/worker/src/test-utils/d1.ts workers/worker/src/db/session-sharing-migration.test.ts workers/worker/src/db/session-sharing-schema.test.ts workers/worker/scripts/verify-migration-pattern.ts workers/worker/drizzle.reconciliation.config.ts workers/worker/scripts/backfill-session-invite-idempotency.ts workers/worker/wrangler.jsonc
git add workers/worker/src/db/schema.ts workers/worker/src/test-utils/d1.ts workers/worker/src/db/session-sharing-migration.test.ts workers/worker/src/db/session-sharing-schema.test.ts workers/worker/scripts/verify-migration-pattern.ts workers/worker/wrangler.jsonc
git add workers/worker/drizzle.reconciliation.config.ts workers/worker/scripts/backfill-session-invite-idempotency.ts
git add --pathspec-from-file=apps/apple/docs/superpowers/reviews/shared-reading-generated-migration-files.txt
git add -f apps/apple/docs/superpowers/reviews/shared-reading-generated-migration-files.txt
git diff --cached --name-status
git commit -m "fix(worker): make session invite migration safe"
```

The optional-file `git add` line is executed only when the selected path creates
those files. The reviewed generated-file manifest always records whether a
deployable artifact was generated before the cached-diff check and commit.

Expected: cached paths exactly match the reviewed owner list and generated-file
manifest; no whole migration/source directory is staged.

## Task W2: Repair the isolated sharing `/v2` room contract

**Files:**

- Modify: `packages/sharing-protocol/src/schemas.ts`
- Modify: `packages/sharing-protocol/src/schemas.test.ts`
- Modify: `workers/sharing-worker/src/AppleSessionRoom.ts`
- Modify: `workers/sharing-worker/src/index.ts`
- Modify: `workers/sharing-worker/src/tokens.ts`
- Modify: `workers/sharing-worker/src/wsCreds.ts`
- Modify: `workers/sharing-worker/src/appleTopology.ts`
- Modify: `workers/sharing-worker/src/auth.ts`
- Modify: `workers/sharing-worker/worker-configuration.d.ts`
- Create: `workers/sharing-worker/test/AppleSessionRoom.recovery.test.ts`
- Modify: `workers/sharing-worker/test/versioned-apple-route.test.ts`

- [ ] **Step 1: Write failing signed-command and ticket tests**

Use the exact command and response boundaries:

```ts
expect(createCommand).toEqual({
  command: "createRoom",
  sessionId,
  initialSharerUserId,
  bookContext,
  maxParticipants: 5,
});
expect(response.admissionTicket.startsWith("admission.")).toBe(false);
await expect(openSocket(`admission.${response.admissionTicket}`, { sessionId: otherRoom }))
  .rejects.toMatchObject({ status: 401 });
await expect(openSocket(`admission.admission.${response.admissionTicket}`))
  .rejects.toMatchObject({ status: 401 });
```

Add replay, wrong user/room/epoch/generation, reissue supersession, and expired
lease cases. Run the focused suite and record the current failures.

```bash
RISHI_W2_RED_ROOT=$(mktemp -d /private/tmp/rishi-W2-red.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect fail --require-failure-id "createRoom binds canonical sessionId" --require-failure-id "admission ticket has exactly one prefix" --require-failure-id "unconsumed admission lease expires and restores capacity" --owned-output-root "$RISHI_W2_RED_ROOT" --artifact "$RISHI_W2_RED_ROOT/evidence.json" --cwd workers/sharing-worker -- bun run test -- test/versioned-apple-route.test.ts test/SessionRoom.appleTopology.test.ts test/tokens.test.ts test/wsCreds.test.ts test/AppleSessionRoom.recovery.test.ts
```

Expected: all three named new tests are discovered and failing, skipped `0`,
and the underlying exit is nonzero; unrelated failures cannot satisfy the gate.

- [ ] **Step 2: Implement one-prefix, one-use admission leases**

Use these stored concepts, not participant presence as an implicit lease:

```ts
type PendingAdmissionLease = {
  ticketId: string;
  userId: string;
  inviteId: string;
  connectionGeneration: number;
  expiresAt: number;
};

type AppleStoredState = ExistingAppleStoredState & {
  pendingAdmissionLeases: Record<string, PendingAdmissionLease>;
  latestSyncSnapshot?: AuthoritativeSyncSnapshot;
  startupExpiresAt: number;
  hasEverBeenOccupied: boolean;
};
```

The API returns `ticket.token` without `admission.`. `wsCreds` strips one wire
prefix; `verifyAdmissionTicket` receives the bare token. Consume by ticket ID in
the same storage transaction that admits the matching generation.

- [ ] **Step 3: Separate startup and post-occupancy expiry**

Implement the alarm invariant:

```ts
if (!state.hasEverBeenOccupied && now >= state.startupExpiresAt) {
  await this.endAppleRoom(state, "room_expired");
} else if (state.hasEverBeenOccupied && this.connectedCount() === 0 && state.lastEmptyAt && now - state.lastEmptyAt >= EMPTY_ROOM_TTL_MS) {
  await this.endAppleRoom(state, "room_expired");
}
```

Expired lease cleanup must compare `ticketId` and `connectionGeneration` before
deleting, so an old alarm cannot erase a newer lease.

- [ ] **Step 4: Persist and replay one authoritative snapshot**

Validate before storing:

```ts
type AuthoritativeSyncSnapshot = {
  sessionId: string;
  roomEpoch: number;
  controllerGeneration: number;
  connectionGeneration: number;
  controllerUserId: string;
  sequence: number;
  frame: SyncFrame;
};
```

On admission send `session.state`, then roster, then exactly one snapshot when
all fences still match. Clear it on room end or authority-fence change. Reject
older sequence or generation without broadcasting.

- [ ] **Step 5: Add HMAC-only account revocation**

Expose only this internal command shape:

```ts
type RevokeAccountReferencesCommand = {
  command: "revokeAccountReferences";
  accountUserId: string;
  deletionOperationId: string;
};
```

Owner revocation ends the room. Participant revocation closes their sockets and
removes membership. Participant-controller revocation deterministically picks
the oldest eligible connected participant, or ends when none exists. Repeating
the operation returns the stored result without another generation change.

- [ ] **Step 6: Add a member-authorized observation command**

Persist a bounded ring of non-sensitive immutable event identities and expose it
only through the HMAC-authenticated internal command:

```ts
type SessionObservation = {
  observationId: string;
  eventId: string;
  eventType: "membership" | "authority" | "sync" | "playback" | "terminal";
  roomEpoch: number;
  controllerGeneration: number;
  connectionGeneration: number;
  readerSequence?: number;
  frameDigest?: string;
  occurredAt: number;
};

type GetMemberObservationsCommand = {
  command: "getMemberObservations";
  sessionId: string;
  requestingUserId: string;
  afterObservationId?: string;
};
```

The room verifies `requestingUserId` is the owner or current participant and
returns only session ID, role/status, current authority fields, and bounded event
identities/digests. It never returns profiles, bearer/admission/invite tokens,
book contents, signed URLs, ICE/SDP, or another account's raw identity. Tests
prove unauthorized, removed, ended-retention-expired, and cross-room requests
fail closed.

- [ ] **Step 7: Preserve `/v1` and canonicalize auth**

Set production sharing auth base to:

```json
"AUTH_BASE_URL": "https://api.fidexa.org"
```

Retain legacy ICE candidate fields—including `usernameFragment`—and prove Apple
commands/state remain unavailable under `/v1`. Run:

```bash
cd workers/sharing-worker
RISHI_W2_TYPEGEN_ROOT=$(mktemp -d /private/tmp/rishi-W2-typegen.XXXXXX)
bun ../../scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W2_TYPEGEN_ROOT" --artifact "$RISHI_W2_TYPEGEN_ROOT/cf-typegen.json" --cwd . -- bun run cf-typegen
```

Commit the regenerated `worker-configuration.d.ts`. Add a production-config test
that resolves the full session URL to
`https://api.fidexa.org/api/auth/get-session`, plus a negative assertion that
`https://rishi.fidexa.org/api/auth/get-session` is never requested. Exercise the
same authority through authenticated `/v2` WebSocket admission.

- [ ] **Step 8: Run focused and complete sharing checks**

```bash
cd workers/sharing-worker
RISHI_W2_GREEN_ROOT=$(mktemp -d /private/tmp/rishi-W2-green.XXXXXX)
bun ../../scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_W2_GREEN_ROOT" --artifact "$RISHI_W2_GREEN_ROOT/focused.json" --cwd . -- bun run test -- test/versioned-apple-route.test.ts test/SessionRoom.appleTopology.test.ts test/tokens.test.ts test/wsCreds.test.ts test/AppleSessionRoom.recovery.test.ts
bun ../../scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W2_GREEN_ROOT" --artifact "$RISHI_W2_GREEN_ROOT/typecheck.json" --cwd . -- bunx tsc --noEmit
bun ../../scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_W2_GREEN_ROOT" --artifact "$RISHI_W2_GREEN_ROOT/full.json" --cwd . -- bun run test
```

Expected: nonzero discovery, skipped/failed `0`, exits `0`; controlled-clock
tests prove leases, capacity recovery, expiry, hibernation, replay, and fencing.

- [ ] **Step 9: Commit sharing-owned files**

```bash
git diff --name-only -- packages/sharing-protocol/src/schemas.ts packages/sharing-protocol/src/schemas.test.ts packages/sharing-protocol/src/sync.ts packages/sharing-protocol/src/sync.test.ts workers/sharing-worker/src/AppleSessionRoom.ts workers/sharing-worker/src/index.ts workers/sharing-worker/src/tokens.ts workers/sharing-worker/src/wsCreds.ts workers/sharing-worker/src/appleTopology.ts workers/sharing-worker/src/auth.ts workers/sharing-worker/src/health.ts workers/sharing-worker/src/hmac.ts workers/sharing-worker/test/versioned-apple-route.test.ts workers/sharing-worker/test/SessionRoom.appleTopology.test.ts workers/sharing-worker/test/tokens.test.ts workers/sharing-worker/test/wsCreds.test.ts workers/sharing-worker/test/AppleSessionRoom.recovery.test.ts workers/sharing-worker/wrangler.jsonc workers/sharing-worker/worker-configuration.d.ts
git add packages/sharing-protocol/src/schemas.ts packages/sharing-protocol/src/schemas.test.ts packages/sharing-protocol/src/sync.ts packages/sharing-protocol/src/sync.test.ts workers/sharing-worker/src/AppleSessionRoom.ts workers/sharing-worker/src/index.ts workers/sharing-worker/src/tokens.ts workers/sharing-worker/src/wsCreds.ts workers/sharing-worker/src/appleTopology.ts workers/sharing-worker/src/auth.ts workers/sharing-worker/src/health.ts workers/sharing-worker/src/hmac.ts workers/sharing-worker/test/versioned-apple-route.test.ts workers/sharing-worker/test/SessionRoom.appleTopology.test.ts workers/sharing-worker/test/tokens.test.ts workers/sharing-worker/test/wsCreds.test.ts workers/sharing-worker/test/AppleSessionRoom.recovery.test.ts workers/sharing-worker/wrangler.jsonc workers/sharing-worker/worker-configuration.d.ts
git diff --cached --name-status
git commit -m "fix(sharing): recover Apple session rooms"
```

## Task W3: Make `/api/v1` creation, `/active`, and `/rejoin` recoverable

**Files:**

- Modify: `workers/worker/src/routes/session-shares.ts`
- Modify: `workers/worker/src/session-sharing-service.ts`
- Modify: `workers/worker/src/session-sharing-service.test.ts`
- Modify: `workers/worker/src/routes/user.ts`
- Modify: `workers/worker/src/routes/auth-compat.ts`
- Modify: matching route tests
- Modify: `workers/sharing-worker/src/index.ts`
- Modify: `workers/sharing-worker/test/versioned-apple-route.test.ts`
- Modify: `workers/worker/src/index.ts`
- Modify: `workers/worker/src/api-version.ts`
- Modify: `workers/worker/src/env.d.ts`
- Modify: `workers/worker/worker-configuration.d.ts`
- Modify: `workers/worker/wrangler.jsonc`
- Create: `workers/worker/src/routes/session-observations.ts`
- Create: `workers/worker/src/routes/session-shares.test.ts`
- Create: `workers/worker/src/routes/session-observations.test.ts`
- Modify: `workers/worker/src/session-sharing-service.test.ts`

- [ ] **Step 1: Write failing route-boundary tests**

The creation test must cross the mounted Hono route and real serializer:

```ts
expect(internalCommands[0]).toMatchObject({ command: "createRoom", sessionId });
expect(await countInvites(ownerUserId, key)).toBe(1);
expect(await countRooms(sessionId)).toBe(1);
```

Repeat the same key after injected failures immediately after D1 provisioning,
room creation, redemption insert, and status fetch. A conflicting payload with
the same owner/key must return `409 IDEMPOTENCY_CONFLICT`.

Also pin the rollout gate:

```ts
expect(await createSession({ APPLE_SHARED_READING_CREATION_ENABLED: "false" }))
  .toMatchObject({ status: 503, body: { code: "SHARED_READING_MAINTENANCE", retryable: false } });
expect(await getActiveSessions({ APPLE_SHARED_READING_CREATION_ENABLED: "false" }))
  .toMatchObject({ status: 200 });
```

Test that status, `/active`, `/rejoin`, leave, and end remain available while
new creation is disabled. Legacy routes and `/v1` behavior remain unchanged.

Run before implementation:

```bash
RISHI_W3_RED_ROOT=$(mktemp -d /private/tmp/rishi-W3-red.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect fail --require-failure-id "createRoom receives canonical sessionId after durable provisioning" --require-failure-id "creation disabled fails before mutations while active remains available" --owned-output-root "$RISHI_W3_RED_ROOT" --artifact "$RISHI_W3_RED_ROOT/evidence.json" --cwd workers/worker -- bun run test -- src/routes/session-shares.test.ts src/routes/session-observations.test.ts src/session-sharing-service.test.ts
```

Expected: wrapper exits `0` only when tests are discovered, at least one named
new assertion fails, no test is skipped, and the underlying Vitest exit is
nonzero. Otherwise do not proceed.

- [ ] **Step 2: Persist a recoverable provisioning state before the room call**

Use explicit states:

```ts
type SessionInviteProvisioningState = "provisioning" | "ready" | "compensating" | "failed";
```

Within one D1 batch/transaction, claim deterministic `inviteId`, `sessionId`,
owner/key, request fingerprint, token hash, and `provisioning`. Retry reads the
same row, validates the fingerprint, reconciles room status, and completes or
compensates. A transport/status failure remains retryable and never writes
`ended` without authoritative room evidence.

- [ ] **Step 3: Implement the default-disabled creation gate**

Add this binding to canonical env/generated types:

```ts
APPLE_SHARED_READING_CREATION_ENABLED: "true" | "false";
```

The canonical production Wrangler config defaults to `"false"`; local tests
inject the binding without creating a separate development Worker config. At the
first line of the create handler, before any D1/DO mutation:

```ts
if (c.env.APPLE_SHARED_READING_CREATION_ENABLED !== "true") {
  return c.json(
    { code: "SHARED_READING_MAINTENANCE", error: "New reading sessions are temporarily unavailable.", retryable: false },
    503,
  );
}
```

Existing read/rejoin/control routes do not consult the gate. Run
`bun generate-types` and commit the regenerated `worker-configuration.d.ts`.

- [ ] **Step 4: Include `sessionId` in the signed create payload**

Implement the client call exactly as:

```ts
async createRoom(input: SessionSharingCreateRoomRequest) {
  return this.request(input.sessionId, "createRoom", input);
}
```

The sharing Worker already rejects path/payload mismatch from W2.

- [ ] **Step 5: Mount `/active` before `/:id`**

The route order must be:

```ts
routes.get("/active", activeSessionsHandler);
routes.get("/:id", sessionStatusHandler);
routes.post("/:id/rejoin", rejoinHandler);
```

Return only authenticated owner/participant sessions. Test owner, participant,
removed member, ended room, unrelated account, and temporary sharing failure.
`/rejoin` mints a fresh one-use ticket and never consumes/reuses the invite URL.

- [ ] **Step 6: Mount the member-authorized observation route**

Add this route after `/active` and before `/:id`:

```ts
routes.get("/:id/observations", sessionObservationsHandler);
```

The handler authenticates the caller, proves D1 owner/current-participant
membership, then sends W2's signed `getMemberObservations` command with the
authenticated user ID. It accepts an optional opaque `after` cursor and returns:

```ts
type SessionObservationResponse = {
  sessionId: string;
  membership: "owner" | "participant";
  status: "waiting" | "active" | "ended";
  roomEpoch: number;
  controllerGeneration: number;
  observations: SessionObservation[];
};
```

Tests cover owner, participant, removed user, unrelated user, wrong session,
expired retention, pagination/cursor, and upstream failure. They also scan the
response/logs to prove no raw user IDs, profiles, tokens, URLs, SDP/ICE, or book
contents escape.

- [ ] **Step 7: Return stable retry semantics**

Map service errors by stable code:

```ts
if (error instanceof SessionSharingServiceError) {
  return c.json({ code: error.code, error: error.message, retryable: error.retryable }, error.status);
}
```

Ensure upstream timeout/unavailable is retryable; ended/removed/forbidden/
conflict is terminal. Never leak bearer, invite token, HMAC, or signed URL.

- [ ] **Step 8: Run focused and complete primary checks**

```bash
cd workers/worker
RISHI_W3_GREEN_ROOT=$(mktemp -d /private/tmp/rishi-W3-green.XXXXXX)
bun ../../scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_W3_GREEN_ROOT" --artifact "$RISHI_W3_GREEN_ROOT/focused.json" --cwd . -- bun run test -- src/routes/session-shares.test.ts src/routes/session-observations.test.ts src/session-sharing-service.test.ts src/api-version.test.ts
bun ../../scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W3_GREEN_ROOT" --artifact "$RISHI_W3_GREEN_ROOT/typecheck.json" --cwd . -- bun run type-check
bun ../../scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_W3_GREEN_ROOT" --artifact "$RISHI_W3_GREEN_ROOT/full.json" --cwd . -- bun run test
```

Expected: creation interruption cases converge to one invite/room; `/active`
tests all pass; discovered `> 0`, skipped/failed `0`, exits `0`.

- [ ] **Step 9: Commit API-owned files**

```bash
git diff --name-only -- workers/worker/src/routes/session-shares.ts workers/worker/src/routes/session-shares.test.ts workers/worker/src/routes/session-observations.ts workers/worker/src/routes/session-observations.test.ts workers/worker/src/session-sharing-service.ts workers/worker/src/session-sharing-service.test.ts workers/worker/src/index.ts workers/worker/src/api-version.ts workers/worker/src/api-version.test.ts workers/worker/src/env.d.ts workers/worker/worker-configuration.d.ts workers/worker/wrangler.jsonc
git add workers/worker/src/routes/session-shares.ts workers/worker/src/routes/session-shares.test.ts workers/worker/src/routes/session-observations.ts workers/worker/src/routes/session-observations.test.ts workers/worker/src/session-sharing-service.ts workers/worker/src/session-sharing-service.test.ts workers/worker/src/index.ts workers/worker/src/api-version.ts workers/worker/src/api-version.test.ts workers/worker/src/env.d.ts workers/worker/worker-configuration.d.ts workers/worker/wrangler.jsonc
git diff --cached --name-status
git commit -m "fix(worker): recover shared reading sessions"
```

## Task W4: Make account deletion bounded and authoritative

**Files:**

- Modify: `workers/worker/src/account-deletion.ts`
- Modify: `workers/worker/src/account-deletion.integration.test.ts`
- Modify: `workers/worker/src/session-sharing-service.ts`
- Modify: `workers/worker/src/session-sharing-service.test.ts`
- Modify: `workers/worker/src/routes/session-shares.ts`
- Modify: `workers/worker/src/routes/session-shares.test.ts`
- Modify: `workers/worker/src/routes/user.ts`
- Modify: `workers/worker/src/routes/user.test.ts`
- Modify: `workers/worker/src/routes/auth-compat.ts`
- Modify: `workers/worker/src/routes/auth-compat.test.ts`
- Modify: `workers/sharing-worker/src/AppleSessionRoom.ts`
- Modify: `workers/sharing-worker/src/index.ts`
- Modify: `workers/sharing-worker/test/AppleSessionRoom.recovery.test.ts`
- Modify: `workers/sharing-worker/test/versioned-apple-route.test.ts`
- Create: `apps/apple/docs/superpowers/reviews/shared-reading-w4-required-tests.txt`
- Create: `scripts/test-integrity/verify-required-tests.ts`
- Create: `scripts/test-integrity/verify-required-tests.test.ts`

- [ ] **Step 0: Preserve one stable deletion operation and acquire a bounded lease**

Use the existing `deletion_state` row as the account-level fence. Insert the
marker with `onConflictDoNothing`, reload it, and always reuse its original
`deletion_id`; repeated HTTP requests and scheduled retries must never overwrite
the marker or mint a second operation identity. Use the existing `status` and
`retry_at` columns as the monotonic workflow state and bounded work lease:

```ts
type DeletionRun = {
  userId: string;
  deletionOperationId: string;
  status: "pending" | "purging";
  retryAt: number;
};
```

Acquire either state with a conditional Drizzle update matching `user_id`,
`deletion_id`, the current `status`, and a due `retry_at`, then move `retry_at`
to a unique short future lease deadline retained by that runner. A newly
inserted marker starts due immediately so the creating request can acquire this
same lease; it must not be delayed by the retry interval. A loser reloads the
marker and returns the stable pending result. The only state transition before
the existing cascade is conditional `pending → purging`, and it occurs only
after a fresh unresolved-session query is empty; its `WHERE` also matches the
runner's exact leased `retry_at`, so an expired/stale runner cannot cross the
handoff. `purging` is a durable resume point with the same due-lease claim:
retries skip room enumeration and continue only the existing idempotent external
cleanup using the stored `deletion_id`. Immediately before any final D1 removal,
execute the complete D1 deletion set as one Drizzle `db.batch`; every statement
that is not already protected by an account FK must include the same guard
subquery matching `user_id`, `deletion_id`, `status='purging'`, and the runner's
exact leased `retry_at`, and the guarded user-row delete runs last. A zero-row
guarded delete means reload and return pending; it must not be treated as this
runner's success. A crash before the batch leaves durable D1 state for a retry,
and a stale runner may repeat only idempotent external cleanup—not reset the
marker, regress status, or delete account rows after losing its lease.

This package intentionally adds no columns or migrations. Run
`verify:migrations` as a regression guard; do not repair the repository's
pre-existing Drizzle snapshot/history drift in this feature branch.

- [ ] **Step 1: Write the deletion matrix red tests**

Cover owner, participant, participant-controller, no replacement, already-ended,
concurrent disconnect, repeated operation, and lost successful response. Assert
the client sends no `actingUserId` or caller-selected controller generation.
Add named tests proving: a command mutates a room then its response is lost;
retry reuses the same operation ID and receives W2's stored result; concurrent
callers retain the original operation ID; a lease loser reloads instead of
regressing progress; a mid-run conflict/transient failure retains the account
and unresolved membership status; success/not-found acknowledges work; a newly
inserted lower-sorting session is discovered on the next scan; and only an empty
fresh scan unlocks the D1 cascade. Add tests that every owner/member reopening
write rejects an account with a deletion marker and conditions its final update
on marker absence. Add room tests proving deleted-account tombstones survive
restart, block rejoin/re-admission, and are distinct from restorable removals.
The scheduled `retryPendingDeletions` test selects and carries the existing
`deletion_id`, then proves a stale scheduled invocation cannot generate a new
identity or enter the final cascade after another runner wins. Add named cases
for an already-ended owner room being purged then removed from the D1 queue, a
crash after `pending → purging`, a due `purging` runner resuming the cascade, and
an expired pending runner losing the exact-`retry_at` handoff CAS. Prove that a
purging runner whose lease expires before the final D1 batch changes zero rows,
reloads, and cannot report success after another runner renews the lease.

Prefix every required test with a stable ID `[W4-01]` through `[W4-N]` and list
every exact full test name in
`apps/apple/docs/superpowers/reviews/shared-reading-w4-required-tests.txt`.
`verify-required-tests.ts` reads one or more Vitest JSON artifacts, rejects
duplicate IDs, missing manifest entries, skipped/non-passing required tests, and
unmanifested `[W4-*]` tests. Its own tests cover each rejection path. The
manifest must include both route families' 503 and 409 false-success guards,
every lease/crash/retry case above, owner and participant cleanup, and the room
tombstone/restart cases.

Run before implementation:

```bash
RISHI_W4_RED_ROOT=$(mktemp -d /private/tmp/rishi-W4-red.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect fail --require-failure-id "revokeAccountReferences never accepts actingUserId" --owned-output-root "$RISHI_W4_RED_ROOT" --artifact "$RISHI_W4_RED_ROOT/evidence.json" --cwd workers/worker -- bun run test -- src/account-deletion.integration.test.ts src/session-sharing-service.test.ts
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect fail --require-failure-id "deletion marker closes the membership write race" --owned-output-root "$RISHI_W4_RED_ROOT" --artifact "$RISHI_W4_RED_ROOT/route-evidence.json" --cwd workers/worker -- bun run test -- src/routes/session-shares.test.ts
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect fail --require-failure-id "deleted-account tombstone survives restart and blocks rejoin" --owned-output-root "$RISHI_W4_RED_ROOT" --artifact "$RISHI_W4_RED_ROOT/room-evidence.json" --cwd workers/sharing-worker -- bun run test -- test/AppleSessionRoom.recovery.test.ts test/versioned-apple-route.test.ts
```

Expected: each wrapper exits `0` only when its new matrix is discovered, the
named assertion fails, skips are zero, and Vitest exits nonzero. Otherwise do
not proceed.

- [ ] **Step 2: Use membership status as the durable cleanup queue**

Before destructive D1 cascades, repeatedly query unresolved work from the
existing sharing tables. The owner predicate is `session_invites.owner_user_id
= accountUserId AND status IN ('open','ended')`. The participant predicate is
`session_invite_redemptions.user_id = accountUserId AND membership_status IN
('pending','admitted','left')`. Use Drizzle `selectDistinct`, order by
`session_id ASC`, apply a fixed limit, and process serially. Requery from the
beginning on every invocation; acknowledged status transitions are the durable
progress record, so a session created with a lower ID between runs cannot be
skipped.

For each session call the HMAC-only internal command
`revokeAccountReferences(sessionId, accountUserId, deletionOperationId)`. It
must not accept an `actingUserId` or controller generation. The room records a
permanent deleted-account tombstone, clears that account's sockets, leases,
reservations and profile references, and returns the stored result on an
identical retry. `SESSION_NOT_FOUND` acknowledges the item. If the owner is
deleted, always end and purge the owned room: its invite, source book, and
redemptions are account-owned D1 rows that will cascade. Controller replacement
does not make that metadata survive account deletion. A room that is already
ended is also purged so no personal identifiers remain in Durable Object
storage.

Only after revoke/purge is acknowledged may the primary Worker apply a
conditional monotonic queue transition. For an owner room, delete the invite
row conditioned on `owner_user_id` and the observed `status`; its existing FKs
cascade the now-ended session's invite items and redemptions, and row absence is
the durable acknowledgement for both formerly-open and already-ended rooms.
For participant-only work, move the redemption's unresolved membership state to
`removed`. Inspect the affected-row count; zero means reload/requery rather than
assuming progress. On conflict, network failure, or 5xx, stop immediately,
retain the account and unresolved row, move the account lease to bounded retry
scheduling, and return. When a fresh query is empty, conditionally move the
marker `pending → purging` using the runner's exact lease value and run the
existing idempotent account cascade. Do not impersonate a controller through
public room methods.

Every operation that can reopen participation—including invite restoration,
admission, book-ready, leave, and rejoin—must reject a present deletion marker,
and its final D1 update must be conditional on marker absence to close the
check/write race.

`deleteAccount` never resolves successfully while cleanup is incomplete. It
returns only after the account is deleted; otherwise it throws one of two stable
typed outcomes which both route families map explicitly:

```ts
type AccountDeletionDeferred = {
  code: "ACCOUNT_DELETION_PENDING";
  status: 503;
  retryable: true;
  retryAt: number;
};
type AccountDeletionConflict = {
  code: "ACCOUNT_DELETION_CONFLICT";
  status: 409;
  retryable: true;
};
```

Neither `/api/auth/delete-user` nor `DELETE /api/user/` may return `{ok:true}`
unless the terminal cascade has completed. The existing success response remains
unchanged; tests pin 503/409 bodies for partial/conflict outcomes.

- [ ] **Step 3: Preserve purge decoding**

Decode success and conflict distinctly:

```ts
type PurgeResult = { ok: true } | { ok: false; code: "CONFLICT"; error: string };
```

`{ok:true}` must not decode to `null`; active-room conflict remains HTTP 409.
Expand W4 ownership to the sharing gateway and exact tests: map room `CONFLICT`
to HTTP 409, preserve the typed `PurgeResult` in the primary client instead of
the generic void-sentinel normalization, and test success/conflict at both
boundaries. Distinguish `SESSION_NOT_FOUND` from transport/5xx failure. If room
state exists but the account is absent, revocation must still clear provisional
leases/reservations before returning the stored not-found acknowledgement.

- [ ] **Step 4: Run deletion and full Worker checks**

```bash
cd workers/worker
RISHI_W4_GREEN_ROOT=$(mktemp -d /private/tmp/rishi-W4-green.XXXXXX)
bun ../../scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_W4_GREEN_ROOT" --artifact "$RISHI_W4_GREEN_ROOT/focused.json" --cwd . -- bun run test -- src/account-deletion.integration.test.ts src/session-sharing-service.test.ts
bun ../../scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_W4_GREEN_ROOT" --artifact "$RISHI_W4_GREEN_ROOT/routes.json" --cwd . -- bun run test -- src/routes/session-shares.test.ts src/routes/user.test.ts src/routes/auth-compat.test.ts
bun ../../scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W4_GREEN_ROOT" --artifact "$RISHI_W4_GREEN_ROOT/migrations.json" --cwd . -- bun run verify:migrations
bun ../../scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W4_GREEN_ROOT" --artifact "$RISHI_W4_GREEN_ROOT/typecheck.json" --cwd . -- bun run type-check
bun ../../scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_W4_GREEN_ROOT" --artifact "$RISHI_W4_GREEN_ROOT/full.json" --cwd . -- bun run test
SHARING_W4_GREEN_ROOT=$(mktemp -d /private/tmp/rishi-sharing-W4-green.XXXXXX)
bun ../../scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$SHARING_W4_GREEN_ROOT" --artifact "$SHARING_W4_GREEN_ROOT/focused.json" --cwd ../sharing-worker -- bun run test -- test/AppleSessionRoom.recovery.test.ts test/versioned-apple-route.test.ts
bun ../../scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$SHARING_W4_GREEN_ROOT" --artifact "$SHARING_W4_GREEN_ROOT/typecheck.json" --cwd ../sharing-worker -- bunx tsc --noEmit
bun ../../scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W4_GREEN_ROOT" --artifact "$RISHI_W4_GREEN_ROOT/required-tests-unit.json" --cwd ../.. -- bun test scripts/test-integrity/verify-required-tests.test.ts
bun ../../scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W4_GREEN_ROOT" --artifact "$RISHI_W4_GREEN_ROOT/required-tests.json" --cwd ../.. -- bun scripts/test-integrity/verify-required-tests.ts --manifest apps/apple/docs/superpowers/reviews/shared-reading-w4-required-tests.txt --artifact "$RISHI_W4_GREEN_ROOT/focused.json" --artifact "$RISHI_W4_GREEN_ROOT/routes.json" --artifact "$SHARING_W4_GREEN_ROOT/focused.json"
```

Expected: all matrix cases pass, invocation-chain work is bounded/retriable,
duplicate owner/member visibility cannot process a room twice per scan, newly
inserted lower IDs are discovered, lease losers cannot enter the cascade,
deleted accounts cannot reopen membership or rejoin a room, discovered `> 0`,
skipped/failed `0`, exits `0`.

- [ ] **Step 5: Commit deletion-owned files**

```bash
git add workers/worker/src/account-deletion.ts workers/worker/src/account-deletion.integration.test.ts workers/worker/src/session-sharing-service.ts workers/worker/src/session-sharing-service.test.ts workers/worker/src/routes/session-shares.ts workers/worker/src/routes/session-shares.test.ts workers/worker/src/routes/user.ts workers/worker/src/routes/user.test.ts workers/worker/src/routes/auth-compat.ts workers/worker/src/routes/auth-compat.test.ts workers/sharing-worker/src/AppleSessionRoom.ts workers/sharing-worker/src/index.ts workers/sharing-worker/test/AppleSessionRoom.recovery.test.ts workers/sharing-worker/test/versioned-apple-route.test.ts scripts/test-integrity/verify-required-tests.ts scripts/test-integrity/verify-required-tests.test.ts apps/apple/docs/superpowers/reviews/shared-reading-w4-required-tests.txt
git commit -m "fix(worker): revoke shared sessions on deletion"
```

Rollback disables/reverts application behavior without changing migration
history. W4 does not add or alter database schema.

## Task W4R: Reconcile late post-deletion R2 uploads

**Files:**

- Modify: `workers/worker/src/account-r2-reconciliation.ts`
- Modify: `workers/worker/src/account-r2-reconciliation.test.ts`
- Modify: `workers/worker/src/index.scheduled.test.ts`
- Modify: `workers/worker/src/index.ts`
- Modify: `workers/worker/wrangler.jsonc`
- Modify: `workers/worker/src/shares/shareReferences.ts`
- Modify: `workers/worker/src/shares/shareStorage.test.ts`

Direct presigned PUTs have no documented maximum completion time after a
request starts. A fixed wait after URL expiry therefore cannot prove that no
upload will materialize after the user row and FK-backed deletion marker are
gone. W4R supplies the durable recovery path without retaining a per-account
tombstone or changing D1 schema.

- [x] **Step 1: Complete the reconciliation and schedule matrix**

Add stable `[W4R-*]` tests for: a completed upload appearing after account
deletion and an earlier sweep; an object arriving behind the current cursor;
repeated overwrite of the same orphan key; a live owner with no book row;
surviving `books`, `share_package_items`, and `session_invite_items` references;
100-object pagination; restart from persisted cursor; invalid checkpoint;
partial/batch delete failure; conditional-write contention; cycle wraparound;
49-key reference-query chunks; at most 100 bound D1 parameters per statement;
and the modeled two-prefix subrequest budget. A later reference-chunk failure
must delete nothing and leave the checkpoint unchanged.

`index.scheduled.test.ts` proves the distinct schedules remain declared, the
`* * * * *` branch attempts one bounded `books/` page and one bounded `covers/`
page, a `books/` failure does not suppress `covers/`, the invocation reports the
first failure for monitoring, and minute reconciliation does not run any daily
maintenance helper. The existing `17 2 * * *` path remains the sole dispatcher
for pending-deletion retries, expired-share cleanup, share-link creation,
retention cleanup, and notification-log redaction. No test sleeps or skips.

- [x] **Step 2: Implement one bounded reconciliation page**

Create this exact public contract:

```ts
export type AccountR2Prefix = "books/" | "covers/";

export interface AccountR2SweepResult {
  prefix: AccountR2Prefix;
  scanned: number;
  deleted: number;
  cycleCompleted: boolean;
  checkpoint: "advanced" | "contended";
}

export type AccountR2SweepError = Error & {
  code: "ACCOUNT_R2_SWEEP_FAILED";
  phase: "checkpoint" | "list" | "owners" | "references" | "delete";
  retryable: true;
};
```

`reconcileAccountR2Page(db, bucket, prefix, nowMs)` lists at most 100 objects,
extracts owner IDs only from literal `books/<owner>/...` or
`covers/<owner>/...` keys, and uses Drizzle to delete only when that owner is
absent. Existing users—including deletion-fenced users—are never reconciler
targets. Before deletion, preserve references from active library books,
`share_package_items`, and `session_invite_items`; extend the existing
`referencedR2Keys` helper without changing its callers.

Store no account identity in maintenance state. Persist one versioned checkpoint
per prefix in R2:

```text
_maintenance/account-r2-reconciliation/v1/books.json
_maintenance/account-r2-reconciliation/v1/covers.json
```

Each checkpoint contains version, opaque revision, nullable listing cursor,
cycle-start time, and last-completed-cycle time. Advance with an R2 conditional
write against the observed ETag; initial creation requires absence. A stale
writer reports `contended` and cannot overwrite newer progress. Missing state
starts a traversal; malformed state fails closed and is conditionally reset,
never interpreted as completion. At listing completion, reset the cursor for a
new cycle so arrivals behind the old cursor are discovered later.

D1/read/reference failure deletes nothing and leaves the checkpoint. Split
candidate reference lookups into chunks of at most 49 keys so every generated
D1 statement binds at most 100 parameters. After all reference chunks succeed,
delete all removable objects for that prefix with one `bucket.delete(keys)`
batch. A reference-chunk, batch-delete, or checkpoint failure does not advance
the checkpoint; replay is safe because missing objects are idempotent.

The 100-object worst-case operation model per prefix is exact: checkpoint GET
(1), R2 list (1), set-based owner lookup (1), nine set-based reference lookups
for three reference sources across `49 + 49 + 2` key chunks (9), one R2 batch
delete (1), and checkpoint PUT (1), totaling 14 operations per prefix and 28 for
`books/` plus `covers/`. `[W4R-BUDGET]` enforces 50 as this feature's
conservative design budget, leaving 22 modeled operations of headroom. It is not
a statement of the current Cloudflare platform limit; internal Cloudflare
service requests have a separate, higher allowance.

- [x] **Step 3: Keep daily and reconciliation schedules distinct**

Keep both entries in `workers/worker/wrangler.jsonc`:

```json
"crons": ["17 2 * * *", "* * * * *"]
```

The scheduled handler branches on `controller.cron`. Only `* * * * *` runs one
bounded page for each reconciliation prefix, isolates prefix failures, reports
failure after both prefixes were attempted, and returns before daily work. The
existing `17 2 * * *` path remains unchanged and runs the five existing daily
maintenance helpers once on its own schedule.

The single-trigger R2 daily-gate proposal is rejected and must not be
implemented. Daily maintenance includes unbounded share-link precreation, so it
must not compete with two reconciliation pages under the minute-trigger budget.
Several daily helpers also catch item-level failures and return aggregate counts
instead of durably exposing every incomplete item; a Cron-level completion
pointer could therefore mark a partially successful daily run complete. No R2
daily state/lease keys, bootstrap pointer, legacy-trigger bridge, or replacement
of `17 2 * * *` is part of W4R.

- [x] **Step 4: Complete local gates and independent review**

```bash
cd workers/worker
RISHI_W4R_ROOT=$(mktemp -d /private/tmp/rishi-W4R.XXXXXX)
bun ../../scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_W4R_ROOT" --artifact "$RISHI_W4R_ROOT/focused.json" --cwd . -- bun run test -- src/account-r2-reconciliation.test.ts src/index.scheduled.test.ts src/shares/shareStorage.test.ts
bun ../../scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W4R_ROOT" --artifact "$RISHI_W4R_ROOT/migrations.json" --cwd . -- bun run verify:migrations
bun ../../scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W4R_ROOT" --artifact "$RISHI_W4R_ROOT/typecheck.json" --cwd . -- bun run type-check
bun ../../scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_W4R_ROOT" --artifact "$RISHI_W4R_ROOT/full.json" --cwd . -- bun run test
```

Expected: all `[W4R-*]` cases are present and passing, full-cycle progress is
observable, reference chunks never exceed 49 keys or 100 D1 parameters, deletion
is one R2 batch per prefix, and the named `[W4R-BUDGET]` test proves the modeled
budget is exactly 14 operations per prefix and 28 for both prefixes, within the
project-enforced conservative budget of 50. Discovered tests must be nonzero
with zero skips/failures, and every command must exit `0` without leaked
children. No migration, generated schema artifact, binding, dependency, or file
outside the W4R list may change. `git diff --check` must exit `0`.

Commit `411eb7220` (`fix(worker): bound reconciliation operations`) contains the
batch-delete and parameter-safety correction plus its regression tests. A fresh
independent Terra review returned **PASS**, zero open Critical/High findings, for
the committed W4R implementation and the 28-operation two-prefix model.

- [ ] **Step 5: Obtain capacity authorization, deploy, and verify production**

Production evidence establishes that the Cloudflare Free account is already at
its five-account-wide-schedule limit:

| Worker | Existing schedules | Count |
|---|---|---:|
| `rishi-worker` | `17 2 * * *` | 1 |
| `kak-credit` | `30 0 * * *`; `30 1 1 * *`; `30 2 * * *` | 3 |
| `tanstack-start-app` | `0 * * * *` | 1 |
| **Total** |  | **5/5** |

The first deployment attempt partially succeeded: Worker code version
`f26670a8e` became live, Cloudflare's schedules PUT returned HTTP 400, and the
dashboard confirmed that `rishi-worker` still has only `17 2 * * *`. The old
daily maintenance trigger remains active and unchanged; `* * * * *` was never
created, so the deployed reconciler is dormant. Do not describe code deployment
success as W4R production completion.

Rollout is blocked until the user explicitly authorizes either a specific Cron
slot to be freed or paid Cloudflare capacity. Do not remove or alter a schedule
on `kak-credit`, `tanstack-start-app`, or any other Worker, and do not upgrade the
account, without that authorization. Re-run the read-only account-wide inventory
immediately before any authorized mutation and stop if it differs from the table
above.

After capacity is explicitly authorized, deploy the latest clean commit that
contains `411eb7220`; never deploy the dirty working tree. Require the schedules
PUT to succeed and, after propagation, verify in the dashboard/API that
`rishi-worker` has both the unchanged `17 2 * * *` daily trigger and the new
`* * * * *` reconciler trigger. Reconfirm every unrelated Worker schedule against
the authorized inventory and ensure the account count matches the selected
capacity path. Immediately before trigger cutover, capture both complete R2
checkpoint objects—including body and ETag—for
`_maintenance/account-r2-reconciliation/v1/books.json` and
`_maintenance/account-r2-reconciliation/v1/covers.json`; record an explicit
missing-object result if either checkpoint does not yet exist.

Wait for at least three successful minute Cron Events. Cron Events establish
only invocation-level outcome; they do not prove which prefix ran or expose the
14/28 operation model. Capture both checkpoint objects again after the third or
later successful event and compare them with the pre-cutover snapshots. For each
prefix with a pre-existing checkpoint, require a changed `revision` and progress
appropriate to its page: an advanced non-null `cursor`, or a reset to `null`
with a newer `cycleCompletedAt`. If the pre-cutover checkpoint was absent,
require a newly created schema-valid checkpoint with a nonempty revision and
page/cycle fields consistent with the observed successful events. After a
completed cycle, a later minute must start the next cycle with a newer
`cycleStartedAt` and the cursor returned for that page. Keep observing until
both prefixes complete a full cycle, reset, and advance through the first page
of the next cycle. Use Cron Events/metrics only for invocation success/failure
and absence of `exceededCpu`; use checkpoint snapshots for per-prefix progress.
Production logs are not acceptance evidence for prefix attempts, prefix
outcomes, or operation counts. The 14/28 count is proven only by the named local
`[W4R-BUDGET]` test.

No safe production fault injection is currently defined: corrupting or replacing
a live checkpoint would alter real scan position. Forced failure/retry remains a
local or staging gate. Production requires natural failure handling only and
does not require a failure to occur. During the observation window, retain the
checkpoint snapshots surrounding each observed minute. If a natural failed Cron
Event occurs, acceptance evidence is the failed Cron Event plus both checkpoints
immediately before and after it and after the next successful minute. The failed
event does not identify a prefix: a sibling checkpoint may validly advance.
Require every changed checkpoint to remain schema-valid and monotonic, every
unchanged checkpoint to preserve its prior body/ETag, and the next successful
minute to resume valid revision/cursor/cycle-time progress for both prefixes.
Do not infer retry behavior or prefix failure identity from nonexistent
structured prefix logs.

Any missing minute trigger, daily-trigger change, checkpoint that does not
advance and wrap, unrecovered natural failure, `exceededCpu`, or unrelated
schedule change fails rollout. Keep the fixed drain until the later W4
deployment; keeping it longer remains a valid conservative choice.

## Task W5: Independent Worker review and deployment-readiness evidence

**Files:**

- Modify: `apps/apple/docs/superpowers/reviews/shared-reading-worker-baseline.md`
- Create: `workers/worker/scripts/verify-sharing-trust.ts`
- Create: `workers/worker/scripts/verify-sharing-trust.test.ts`
- Modify: `workers/worker/src/session-sharing-service.ts`
- Modify: `workers/worker/src/session-sharing-service.test.ts`
- Modify: `workers/worker/worker-configuration.d.ts`
- Modify: `workers/worker/wrangler.jsonc`
- Modify: `workers/sharing-worker/src/index.ts`
- Modify: `workers/sharing-worker/src/hmac.ts`
- Modify: `workers/sharing-worker/test/versioned-apple-route.test.ts`
- Modify: `workers/sharing-worker/worker-configuration.d.ts`
- Modify: `workers/sharing-worker/wrangler.jsonc`
- Modify findings only in the owning lane's files

- [ ] **Step 1: Specification review**

Fresh reviewer checks every Worker/protocol row in the approved design against
source and fresh output. Fix and re-review all Critical/High findings.

- [ ] **Step 2: Security/compatibility review**

Separate reviewer attempts ticket replay, cross-room/user binding, double-prefix,
stale generation, HMAC bypass, `/v1` Apple command access, idempotency poisoning,
and migration-history misuse. Fix and re-review all Critical/High findings.

- [ ] **Step 3: Pre-trust regression baseline**

```bash
set -euo pipefail
RISHI_W5_ROOT=$(mktemp -d /private/tmp/rishi-W5.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_W5_ROOT" --artifact "$RISHI_W5_ROOT/sharing-tests.json" --cwd workers/sharing-worker -- bun run test
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W5_ROOT" --artifact "$RISHI_W5_ROOT/sharing-typecheck.json" --cwd workers/sharing-worker -- bunx tsc --noEmit
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W5_ROOT" --artifact "$RISHI_W5_ROOT/worker-migrations.json" --cwd workers/worker -- bun run verify:migrations
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W5_ROOT" --artifact "$RISHI_W5_ROOT/worker-typecheck.json" --cwd workers/worker -- bun run type-check
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_W5_ROOT" --artifact "$RISHI_W5_ROOT/worker-tests.json" --cwd workers/worker -- bun run test
git diff --check origin/main...HEAD -- workers packages/sharing-protocol
```

Expected: all exits `0`, no skips/failures. This is a baseline only; it is not
the final W5 gate because Step 4 still changes trust code.

- [ ] **Step 4: Implement and test internal trust equality verification**

The sharing Worker's HMAC-authenticated `/v2/internal/verify-trust` command accepts
a 32-byte random challenge and returns only:

```ts
type TrustFingerprint = {
  algorithm: "HMAC-SHA-256";
  fingerprint: string;
};
```

The sharing verifier accepts a two-key rollout ring using the existing
`WORKER_HMAC_SECRET` as current and optional `WORKER_HMAC_SECRET_NEXT`; the
primary signer uses `SHARING_INTERNAL_SECRET_NEXT` when present and otherwise
the existing `SHARING_INTERNAL_SECRET`. The request carries a non-secret key
generation (`current` or `next`), and sharing verifies only the named key. It
computes `HMAC(selected secret, challenge)`, truncates to 16 bytes, and
base64url-encodes the result. The primary client computes the same value with
its selected secret, constant-time compares, and then sends a separately signed
no-op room smoke command. Neither secret, challenge signature, full HMAC, nor
bearer value is logged or returned publicly. The route is absent from `/v1` and
all public `/api/v1` routers. Tests prove current-only operation, dual-acceptance,
next-key preference, unknown generation rejection, and rollback from next to
current.

`verify-sharing-trust.ts` generates the challenge in-process, invokes the
internal client, compares fingerprints, sends the signed smoke, and exits `0`
only when both pass. Tests inject fixture secrets and prove equal, unequal,
tampered response, replayed challenge, `/v1` access, and log-redaction cases.

```bash
cd workers/worker
RISHI_W5_TRUST_ROOT=$(mktemp -d /private/tmp/rishi-W5-trust.XXXXXX)
bun ../../scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_W5_TRUST_ROOT" --artifact "$RISHI_W5_TRUST_ROOT/evidence.json" --cwd . -- bun run test -- scripts/verify-sharing-trust.test.ts src/session-sharing-service.test.ts
```

- [ ] **Step 5: Re-run the complete final local gate after trust changes**

Repeat every Step 3 command into a new private `RISHI_W5_FINAL_ROOT`, then run
the focused trust suite once more into that same root. Run the W4 required-test
verifier against the new `worker-tests.json` and `sharing-tests.json`; W5 may
not rely on W4's earlier artifacts after modifying shared service tests.

```bash
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W5_FINAL_ROOT" --artifact "$RISHI_W5_FINAL_ROOT/required-tests.json" --cwd . -- bun scripts/test-integrity/verify-required-tests.ts --manifest apps/apple/docs/superpowers/reviews/shared-reading-w4-required-tests.txt --artifact "$RISHI_W5_FINAL_ROOT/worker-tests.json" --artifact "$RISHI_W5_FINAL_ROOT/sharing-tests.json"
```

Expected: complete
sharing and primary suites, both typechecks, migration verification, trust
tests, and diff check all exit `0`; discovered tests are nonzero with zero
skips/failures; the latest independent review has zero open Critical/High
findings. No rollout may begin from the earlier baseline artifacts.

- [ ] **Step 6: Record the exact later rollout order and keep mutation disabled**

After separate user authorization, rotate through the tested two-key ring so a
failure between secret writes cannot break existing signed traffic. Preserve
the current keys. Generate the next value once, install it on sharing first,
deploy sharing's dual verifier, and prove current-key traffic still works before
the primary Worker is allowed to select `next`. Provisioning, both deployments,
verification, rollback if needed, and unset must run in this one guarded shell
session; do not split the sequence across terminals or tool calls:

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
set -euo pipefail
RISHI_SHARING_TRUST_SECRET=$(openssl rand -hex 32)
trap 'unset RISHI_SHARING_TRUST_SECRET' EXIT
SHARING_INTERNAL_VERIFY_URL='https://sharing.fidexa.org/v2/internal/verify-trust'
printf '%s' "$RISHI_SHARING_TRUST_SECRET" | bunx wrangler secret put WORKER_HMAC_SECRET_NEXT --config workers/sharing-worker/wrangler.jsonc
# Deploy sharing dual-verification code, then run current-key health/trust/smoke.
printf '%s' "$RISHI_SHARING_TRUST_SECRET" | bunx wrangler secret put SHARING_INTERNAL_SECRET_NEXT --config workers/worker/wrangler.jsonc
# Deploy primary with creation still disabled, then run next-key trust/smoke.
# Keep the value only for the fail-closed verification command below; unset it immediately afterward.
```

Record only operator identity, UTC time, Cloudflare secret-version identifiers
or command success, never the value. If the sharing write/deploy fails, old
traffic remains on `current`. If the primary write/deploy or next-key smoke
fails, roll the primary back to current-key selection while sharing continues to
accept both; do not remove either current key. The evidence records this exact
order: fresh
compatibility/D1 audit; verify that the canonical migration list has no
unexpected pending migration; sharing-next provisioning; deploy sharing `/v2`
plus the separate Apple DO binding with dual verification; verify current-key
health/auth/trust/signed smoke; primary-next provisioning; deploy primary
`/api/v1` with creation disabled; verify next-key trust/smoke plus read/rejoin
and deletion; unset the in-memory next secret; enable creation; real MCP
acceptance. Promotion/removal of current/next keys is a later separately tested
rotation and is not required to enable this release.

W4 adds no schema dependency and does not authorize remote migration mutation.
Before rollout, record the read-only migration state:

```bash
cd workers/worker
bun run verify:migrations
shasum -a 256 drizzle/migrations/20260820112725_session_invites_from_prod_session_only/migration.sql drizzle/migrations/20260820112725_session_invites_from_prod_session_only/snapshot.json drizzle/migrations/20260820121338_session_invites_idempotency/migration.sql drizzle/migrations/20260820121338_session_invites_idempotency/snapshot.json
bunx wrangler d1 migrations list rishi --remote
bunx wrangler d1 execute rishi --remote --command "SELECT name, applied_at FROM d1_migrations ORDER BY id"
bunx wrangler d1 execute rishi --remote --command "PRAGMA table_info('deletion_state')"
bunx wrangler d1 execute rishi --remote --command "PRAGMA foreign_key_list('deletion_state')"
```

If the audit shows a pending migration required by the already-approved W1
chain, stop and review that exact artifact before separately authorizing
`migrate:remote`. Compare the pending names and four artifact hashes byte-for-
byte with the W0 approved evidence; any additional/missing name or changed hash
blocks migration and deployment. After any separately authorized W1 migration,
repeat the remote list, migration table, physical-column, and FK commands before
deploying code. Fail closed unless the physical table includes non-null
`user_id`, `deletion_id`, `ledger_name`, `status`, `retry_at`, `created_at`, and
`updated_at`, with `user_id` as the primary key and its foreign key targeting
`user.id` with `ON DELETE CASCADE`. Copy the command output and the explicit
pass/fail comparison into the deployment evidence. The pre-existing Drizzle
metadata/history drift is documented as independent follow-up work and is not
repaired opportunistically here. Never force-mark a migration applied. If any
verification fails, do not deploy the primary Worker.

After both Workers are deployed with creation still disabled, continue in that
same guarded shell and run the
production equality and signed-smoke command while the generated next secret is
still only in process memory:

```bash
RISHI_W5_PROD_ROOT=$(mktemp -d /private/tmp/rishi-W5-prod.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W5_PROD_ROOT" --artifact "$RISHI_W5_PROD_ROOT/trust.json" --cwd workers/worker -- bun run scripts/verify-sharing-trust.ts --endpoint "$SHARING_INTERNAL_VERIFY_URL" --generation next
unset RISHI_SHARING_TRUST_SECRET
```

The script reads `RISHI_SHARING_TRUST_SECRET` from the inherited environment;
it must reject a missing value, never print it, and verify the deployed response
and signed no-op rather than local fixtures. A nonzero exit rolls the primary
back to current-key selection and blocks creation enablement.

Creation enablement is an audited config change only after final constraint,
compatibility, health, auth, trust, and signed-smoke checks pass:

```json
"APPLE_SHARED_READING_CREATION_ENABLED": "true"
```

Regenerate primary binding types, run W3's complete tests, review the exact
config/type diff, then perform the separately authorized final primary deploy.
The deployment record contains config SHA, Worker version, operator, UTC time,
and successful post-deploy create/read/rejoin probes.

Do not run deploy, remote migration application, secret rotation, or enable
session creation during implementation.

- [ ] **Step 7: Commit trust-verification files by exact path**

```bash
git diff --name-only -- workers/worker/scripts/verify-sharing-trust.ts workers/worker/scripts/verify-sharing-trust.test.ts workers/worker/src/session-sharing-service.ts workers/worker/src/session-sharing-service.test.ts workers/worker/worker-configuration.d.ts workers/worker/wrangler.jsonc workers/sharing-worker/src/index.ts workers/sharing-worker/src/hmac.ts workers/sharing-worker/test/versioned-apple-route.test.ts workers/sharing-worker/worker-configuration.d.ts workers/sharing-worker/wrangler.jsonc apps/apple/docs/superpowers/reviews/shared-reading-worker-baseline.md
git add workers/worker/scripts/verify-sharing-trust.ts workers/worker/scripts/verify-sharing-trust.test.ts workers/worker/src/session-sharing-service.ts workers/worker/src/session-sharing-service.test.ts workers/worker/worker-configuration.d.ts workers/worker/wrangler.jsonc workers/sharing-worker/src/index.ts workers/sharing-worker/src/hmac.ts workers/sharing-worker/test/versioned-apple-route.test.ts workers/sharing-worker/worker-configuration.d.ts workers/sharing-worker/wrangler.jsonc
git add -f apps/apple/docs/superpowers/reviews/shared-reading-worker-baseline.md
git diff --cached --name-status
git commit -m "test(worker): verify sharing trust boundary"
```

## Adversarial plan review

### Round 1 — Terra

**Verdict:** RE-REVIEW REQUIRED. High findings identified generic migration
branches, missing generated auth types/startup assertions, missing trust-secret
verification, broad staging, absent member-authorized production observation,
and rollout-order ambiguity. W1 now defines three mutually exclusive migration
branches and generated-file staging; W2 adds auth type generation, positive/
negative authority tests, redacted internal observations; W3 exposes only a
member-authorized `/api/v1` observation route; W5 defines trust fingerprints,
signed smoke, exact files, and rollout order. Re-review is required.

Round 2 found that accepted Worker test/typecheck/type-generation gates still
bypassed the mandatory integrity wrapper. Every such gate now records a unique
normalized artifact; only read-only production inspection and migration
artifact-generation commands remain raw. Fresh independent PASS is required.

### W4/W5 recovery review

Terra rejected the first no-migration revision because `purging` could strand a
crashed run, ended owner rooms lacked a durable processed transition, and stale
lease holders could enter the final cascade. W4 now leases both states, deletes
owner invite rows only after acknowledged purge, and guards the final D1 batch
with the exact purging lease.

Luna rejected the first rollout revision because the final gate preceded trust
changes and two single-secret writes could create a production mismatch. W5 now
repeats the complete gate after trust changes and uses a reversible current/next
keyring rollout. Its High testability/scope findings are addressed by the
required-test manifest, deployed trust command, explicit ownership handoff,
exact migration/hash comparison, and Electron boundary.

Final Terra and Luna re-review verdict: **PASS**, zero open Critical/High
findings. Terra confirmed the exact-lease final D1 batch closes the stale
purging-runner race. Luna confirmed the post-trust full gate, current/next
keyring rollout, one-shell production verification, ownership handoff, required-
test manifest, migration/hash checks, and Electron boundary.

### W4R Cron capacity and operation-budget recovery review

Production evidence invalidated the single-trigger R2 daily-gate proposal. The
existing daily chain contains unbounded share-link precreation, and several
helpers absorb item-level failures into counts/logs rather than a durable
all-items-complete result. Running that chain behind a minute-trigger completion
pointer could exceed the invocation budget or durably mark partial maintenance
as complete. The proposal—including its daily state/lease objects, bootstrap
seed, catch-up rules, and removal of `17 2 * * *`—is rejected. W4R preserves the
daily trigger unchanged and keeps `* * * * *` as a distinct, bounded reconciler
branch.

The first production deploy then established a separate capacity blocker: the
Worker code version became live, but the schedules PUT returned HTTP 400 and the
dashboard retained only `17 2 * * *`, leaving reconciliation dormant. The
read-only inventory accounts for all five Free-plan slots: one Rishi daily
schedule, three `kak-credit` schedules, and one `tanstack-start-app` schedule.
No other Worker schedule or account plan may be changed without explicit user
authorization, so production rollout remains blocked rather than borrowing a
slot implicitly.

Terra's implementation review also rejected the original per-object delete and
unbounded reference-query shape because it violated W4R's conservative operation
budget and D1 parameter safety. Commit `411eb7220` batches each prefix's
removable keys into one R2 delete and chunks reference lookups to 49 keys, with
at most 100 D1 parameters per statement. The named local `[W4R-BUDGET]` test
models 14 operations per prefix and 28 for both prefixes against the
project-enforced budget of 50; 50 is not represented as Cloudflare's current
internal service-request platform limit. Tests also prove a later
reference-chunk failure deletes nothing or advances no checkpoint and preserve
safe replay after batch-delete failure.

The latest plan review rejected production assertions that Cron Events or Worker
logs expose per-prefix attempts, prefix outcomes, or 14/28 operation counts. The
rollout now captures both R2 checkpoint bodies and ETags before cutover and after
at least three successful minute Cron Events, then proves each prefix's progress
from revision, cursor, `cycleStartedAt`, and `cycleCompletedAt` transitions.
Cron Events and metrics are limited to invocation outcome and CPU evidence; the
operation model remains local-test evidence.

The same review rejected deliberate corruption of a live production checkpoint
as a supposedly non-destructive retry probe. No safe production fault injection
is currently defined, so forced failure/retry remains a local or staging gate.
Production accepts natural failures only: if one occurs, retain the observable
failed Cron Event and both checkpoint snapshots before, after, and after the next
successful minute. No production failure is required when none occurs naturally.

**Recovery review verdict:** independent Terra **PASS**, zero open
Critical/High findings for the committed code and operation model. Production
deployment remains **BLOCKED ON EXPLICIT CAPACITY AUTHORIZATION**. After a slot
or paid capacity is authorized, deploy the latest clean commit containing
`411eb7220` and require the minute trigger plus before/after checkpoint evidence
for both prefixes through full wrap. Require failure/retry recovery evidence only
in local/staging or when a natural production failure is actually observed.

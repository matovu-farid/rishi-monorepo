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
- Deletion owner: after the serialized W3→W4 handoff, W4 may modify only the `revokeAccountReferences` client/decoder methods in `workers/worker/src/session-sharing-service.ts` and their exact tests, plus `workers/worker/src/account-deletion.ts` and `workers/worker/src/account-deletion.integration.test.ts`; every other primary API section remains W3-owned.
- Integration owner only: both Workers' configuration/type files, health tests, compatibility evidence.

No owner may stage unrelated dirty files or edit another lane's files.

## Mandatory command/result wrapper

No raw test/typecheck/build command below is itself accepted as a gate. Execute
each through `scripts/test-integrity/run-verified.ts`. For Vitest, the wrapper
adds a task-labelled reporter path inside the supplied private run root, parses that
artifact, and records the individual exit. For typecheck/build use format
`command`. Every green run requires discovered `> 0`, skipped/failed `0`, and
exit `0`; every red run requires discovered/failed `> 0` and nonzero exit. An
absent/unparseable artifact fails. The task's literal command is passed after
`--`; artifact names use the exact task label (`W1`, `W2`, `W3`, `W4`, or `W5`).

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
- Modify only if W3 did not include it: `workers/worker/src/session-sharing-service.ts`

- [ ] **Step 1: Write the deletion matrix red tests**

Cover owner, participant, participant-controller, no replacement, already-ended,
concurrent disconnect, repeated operation, and lost successful response. Assert
the client sends no `actingUserId` or caller-selected controller generation.

Run before implementation:

```bash
RISHI_W4_RED_ROOT=$(mktemp -d /private/tmp/rishi-W4-red.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect fail --require-failure-id "revokeAccountReferences never accepts actingUserId" --owned-output-root "$RISHI_W4_RED_ROOT" --artifact "$RISHI_W4_RED_ROOT/evidence.json" --cwd workers/worker -- bun run test -- src/account-deletion.integration.test.ts src/session-sharing-service.test.ts
```

Expected: wrapper exits `0` only when the new matrix is discovered, at least one
named assertion fails, skips are zero, and Vitest exits nonzero. Otherwise do not
proceed.

- [ ] **Step 2: Persist bounded cleanup progress**

Use an operation record/cursor through Drizzle:

```ts
type SessionRevocationProgress = {
  deletionOperationId: string;
  accountUserId: string;
  cursor: string | null;
  completed: boolean;
};
```

Write progress before destructive D1 cascades. Process a bounded page, call the
HMAC-only W2 command, persist the next cursor/result, and retry until complete.
Do not impersonate a controller through public room-control methods.

- [ ] **Step 3: Preserve purge decoding**

Decode success and conflict distinctly:

```ts
type PurgeResult = { ok: true } | { ok: false; code: "CONFLICT"; error: string };
```

`{ok:true}` must not decode to `null`; active-room conflict remains HTTP 409.

- [ ] **Step 4: Run deletion and full Worker checks**

```bash
cd workers/worker
RISHI_W4_GREEN_ROOT=$(mktemp -d /private/tmp/rishi-W4-green.XXXXXX)
bun ../../scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_W4_GREEN_ROOT" --artifact "$RISHI_W4_GREEN_ROOT/focused.json" --cwd . -- bun run test -- src/account-deletion.integration.test.ts src/session-sharing-service.test.ts
bun ../../scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W4_GREEN_ROOT" --artifact "$RISHI_W4_GREEN_ROOT/migrations.json" --cwd . -- bun run verify:migrations
bun ../../scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_W4_GREEN_ROOT" --artifact "$RISHI_W4_GREEN_ROOT/typecheck.json" --cwd . -- bun run type-check
bun ../../scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_W4_GREEN_ROOT" --artifact "$RISHI_W4_GREEN_ROOT/full.json" --cwd . -- bun run test
```

Expected: all matrix cases pass, invocation-chain work is bounded/retriable,
discovered `> 0`, skipped/failed `0`, exits `0`.

- [ ] **Step 5: Commit deletion-owned files**

```bash
git add workers/worker/src/account-deletion.ts workers/worker/src/account-deletion.integration.test.ts workers/worker/src/session-sharing-service.ts workers/worker/src/session-sharing-service.test.ts
git commit -m "fix(worker): revoke shared sessions on deletion"
```

## Task W5: Independent Worker review and deployment-readiness evidence

**Files:**

- Modify: `apps/apple/docs/superpowers/reviews/shared-reading-worker-baseline.md`
- Create: `workers/worker/scripts/verify-sharing-trust.ts`
- Create: `workers/worker/scripts/verify-sharing-trust.test.ts`
- Modify: `workers/worker/src/session-sharing-service.ts`
- Modify: `workers/worker/src/session-sharing-service.test.ts`
- Modify: `workers/sharing-worker/src/index.ts`
- Modify: `workers/sharing-worker/src/hmac.ts`
- Modify: `workers/sharing-worker/test/versioned-apple-route.test.ts`
- Modify findings only in the owning lane's files

- [ ] **Step 1: Specification review**

Fresh reviewer checks every Worker/protocol row in the approved design against
source and fresh output. Fix and re-review all Critical/High findings.

- [ ] **Step 2: Security/compatibility review**

Separate reviewer attempts ticket replay, cross-room/user binding, double-prefix,
stale generation, HMAC bypass, `/v1` Apple command access, idempotency poisoning,
and migration-history misuse. Fix and re-review all Critical/High findings.

- [ ] **Step 3: Final local gate**

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

Expected: all exits `0`, no skips/failures, zero open Critical/High findings.

- [ ] **Step 4: Implement and test internal trust equality verification**

The sharing Worker's HMAC-authenticated `/v2/internal/verify-trust` command accepts
a 32-byte random challenge and returns only:

```ts
type TrustFingerprint = {
  algorithm: "HMAC-SHA-256";
  fingerprint: string;
};
```

It computes `HMAC(WORKER_HMAC_SECRET, challenge)`, truncates to 16 bytes, and
base64url-encodes the result. The primary client computes the same value with
`SHARING_INTERNAL_SECRET`, constant-time compares, and then sends a separately
signed no-op room smoke command. Neither secret, challenge signature, full HMAC,
nor bearer value is logged or returned publicly. The route is absent from `/v1`
and all public `/api/v1` routers.

`verify-sharing-trust.ts` generates the challenge in-process, invokes the
internal client, compares fingerprints, sends the signed smoke, and exits `0`
only when both pass. Tests inject fixture secrets and prove equal, unequal,
tampered response, replayed challenge, `/v1` access, and log-redaction cases.

```bash
cd workers/worker
RISHI_W5_TRUST_ROOT=$(mktemp -d /private/tmp/rishi-W5-trust.XXXXXX)
bun ../../scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_W5_TRUST_ROOT" --artifact "$RISHI_W5_TRUST_ROOT/evidence.json" --cwd . -- bun run test -- scripts/verify-sharing-trust.test.ts src/session-sharing-service.test.ts
```

- [ ] **Step 5: Record the exact later rollout order and keep mutation disabled**

After separate user authorization, generate one value once and provision both
production secret names from it before either dependent deployment:

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
set -euo pipefail
RISHI_SHARING_TRUST_SECRET=$(openssl rand -hex 32)
printf '%s' "$RISHI_SHARING_TRUST_SECRET" | bunx wrangler secret put SHARING_INTERNAL_SECRET --config workers/worker/wrangler.jsonc
printf '%s' "$RISHI_SHARING_TRUST_SECRET" | bunx wrangler secret put WORKER_HMAC_SECRET --config workers/sharing-worker/wrangler.jsonc
unset RISHI_SHARING_TRUST_SECRET
```

Record only operator identity, UTC time, Cloudflare secret-version identifiers
or command success, never the value. If either command fails, stop; do not deploy
or rotate only one side. The evidence then records this order: fresh
compatibility/D1 audit; synchronized secret provisioning; primary nullable-
compatible deployment with creation disabled; generated nullable delta/backfill/
final constraint when selected; sharing `/v2` plus separate Apple DO binding;
health/auth/trust/signed smoke; final primary `/api/v1` with creation disabled;
verification; creation enablement; real MCP acceptance.

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

- [ ] **Step 6: Commit trust-verification files by exact path**

```bash
git diff --name-only -- workers/worker/scripts/verify-sharing-trust.ts workers/worker/scripts/verify-sharing-trust.test.ts workers/worker/src/session-sharing-service.ts workers/worker/src/session-sharing-service.test.ts workers/sharing-worker/src/index.ts workers/sharing-worker/src/hmac.ts workers/sharing-worker/test/versioned-apple-route.test.ts apps/apple/docs/superpowers/reviews/shared-reading-worker-baseline.md
git add workers/worker/scripts/verify-sharing-trust.ts workers/worker/scripts/verify-sharing-trust.test.ts workers/worker/src/session-sharing-service.ts workers/worker/src/session-sharing-service.test.ts workers/sharing-worker/src/index.ts workers/sharing-worker/src/hmac.ts workers/sharing-worker/test/versioned-apple-route.test.ts
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

Final Terra and Luna verdict: **PASS**, zero open Critical/High findings.

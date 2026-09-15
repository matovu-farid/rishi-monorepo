# Shared Reading Recovery Master Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver and prove a production-backed two-person shared-reading session between Rishi on Mac Catalyst and iPhone 17 Pro Simulator, driven end-to-end by Codex through the Swift MCP server.

**Architecture:** First restore the Worker typecheck baseline in an independent prerequisite commit that can land on `origin/main`. Then repair the frozen-boundary Worker path (`/api/v1` to an isolated sharing `/v2` Durable Object), repair Apple recovery and account lifecycle, and make the Swift MCP the sole process owner for live acceptance. The four detailed plans are integrated serially at contract boundaries and independently reviewed after every lane.

**Tech Stack:** Cloudflare Workers, Hono, Durable Objects, D1, Drizzle, TypeScript, Bun, Swift 6, SwiftUI, XCTest, Swift Testing, Xcode, Model Context Protocol over stdio, and production `api.fidexa.org`/`sharing.fidexa.org` endpoints.

---

## Source documents

- Approved design: `apps/apple/docs/superpowers/specs/2026-09-15-shared-reading-recovery-design.md`
- Worker/protocol plan: `apps/apple/docs/superpowers/plans/2026-09-15-shared-reading-worker-protocol.md`
- Worker typecheck prerequisite: `apps/apple/docs/superpowers/plans/2026-09-15-worker-typecheck-repair.md`
- Apple client plan: `apps/apple/docs/superpowers/plans/2026-09-15-shared-reading-apple-client.md`
- MCP/live plan: `apps/apple/docs/superpowers/plans/2026-09-15-shared-reading-mcp-live-acceptance.md`
- Production compatibility policy: `docs/superpowers/specs/2026-09-01-api-versioning-and-apple-worker-development-policy-design.md`

## Non-negotiable scope boundary

Every worker receives this exclusion list:

```text
Do not stage, revert, delete, or rewrite:
- root rishi-*.png screenshots
- apps/rishi-electron/build/**
- apps/apple/marketing/iphone-preview/capture_simulator.sh
- unrelated voice, billing, sync, watch, web, or package-lock churn
- another worker's files
```

The Electron application is not part of this project: no file under
`apps/rishi-electron/**` may be reviewed, restored, staged, tested, or modified.
The only retained Electron-related instruction is the user's separate CI-only
request that its GitHub Actions test job remain disabled.

The Node-to-Swift MCP replacement is accepted only when protocol parity and a
real Codex connection are proved in the same commit. The production test-auth
route stays disabled. `/api/realtime/client_secrets` stays retired.

## Agent ownership and dependency graph

```text
I0 fail-closed result-integrity prerequisite
  -> T0 Worker TypeScript project boundary
  -> T1 Web API byte boundaries
  -> T2 persisted allowance plan types
  -> T3 Drizzle/cursor/Sentry types
  -> T4 independent review + prerequisite upstream boundary
  -> W0 read-only evidence + dirty inventory
  -> W1 migration decision
  -> W2 sharing /v2 room contract
  -> W3 primary /api/v1 contract
  -> W4 account revocation
  -> A0 typed generation contracts
  -> A1 reconnect + authority fences
  -> A2 /active + rejoin
  -> A3 composition-root cleanup
  -> A4 native gestures + semantic controls
  -> M0 Swift MCP parity
  -> M1 process ownership
  -> M2 independent evidence producers
  -> M3 semantic XCTest bridge
  -> M4 preparation-only E2E host
  -> M5 real Codex registration
  -> M6 two-account acceptance
  -> M7 MCP/live adversarial review
  -> G final compatibility/review/rollout gate
```

Only these activities may overlap:

- W2 protocol tests and A0 test scaffolding after W1 is decided, provided A0
  consumes a frozen fixture contract and does not edit Worker files.
- M1 package unit tests and A3 account-lifecycle tests, provided neither starts
  Xcode, Simulator, or Rishi.
- Independent reviewers may inspect any lane but never edit it.

One agent owns all Wrangler configuration and migration metadata at a time. One
agent owns `AppleSessionRoom.ts` at a time. One agent owns app composition-root
files at a time. One agent owns MCP/E2E process creation at a time.
`MCPControlUITests.swift` is owned only by M3; A4 publishes stable accessibility
identifiers and M2 publishes evidence interfaces that M3 consumes afterward.

## Task 1: Land the independent result-integrity prerequisite (I0)

**Files:**

- Create: `scripts/test-integrity/run-verified.ts`
- Create: `scripts/test-integrity/run-verified.test.ts`
- Create: `scripts/test-integrity/resource-preflight.ts`
- Create: `scripts/test-integrity/resource-preflight.test.ts`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Prove CI discovers failures**

Implement one fail-closed runner used by every later red/green gate:

```ts
type ResultFormat = "vitest-json" | "node-test" | "swift-output" | "xcresult" | "codex-jsonl" | "command";
type ExpectedOutcome = "pass" | "fail";
type VerifiedCounts = { discovered: number; passed: number; skipped: number; failed: number };
```

`run-verified.ts` executes the command after `--`, records command/args/cwd/start/
finish/exit status without environment values, parses the named format, and
rejects missing/unparseable artifacts, `discovered === 0`, any skip, a pass with
failures/nonzero exit, or an expected red with zero exit/no failed assertion.
The canonical CLI is `--format FORMAT --expect pass|fail --artifact PATH
--cwd PATH -- COMMAND`; the positional format remains only as a bootstrap/self-test
compatibility form. Normalized artifacts are files distinct from reporter output
directories such as `.xcresult` bundles.
For red tests, repeatable `--require-failure-id EXACT_TEST_ID` requires every
named test to be present and failing; an unrelated failure cannot satisfy it.
The Vitest parser uses full test names, the SwiftPM parser uses suite-qualified
test names, and the xcresult parser uses XCTest/Swift Testing identifiers from
the result bundle. I0 self-tests exact-ID matching for all three formats.
Every expected-red test must compile and execute its named assertion; build or
link failure is never accepted as red. Where a production symbol does not yet
exist, the red test uses a test-only adapter or static source contract first,
then keeps that assertion while adding compiled behavior coverage after the
minimal production API exists.
For `xcresult`, it invokes `xcrun xcresulttool get test-results summary --path`;
for Vitest it injects a JSON reporter into the command after `--`, captures that
reporter to a runner-owned temporary file, and embeds its parsed counts in the
normalized `--artifact`; for `node-test` it requires Node's TAP reporter and
parses its test/pass/fail/skipped summary; for SwiftPM it parses the complete captured summary and
fails if no supported summary is present. `command` records
each build/typecheck command separately and requires exit `0` without claiming
test counts.

`codex-jsonl` preserves stdout byte-for-byte at a distinct required
`--raw-output` path, parses every JSONL event, and writes a separate normalized
artifact. Against the pinned Codex CLI schema it requires exactly one
`thread.started` identifier, one ordered turn whose `turn.completed` is terminal,
matched `item.started`/`item.completed` records for `mcp_tool_call` items,
schema-valid optional `item.updated` and non-capability `todo_list` updates, immutable
server/tool/arguments, only the
allowed MCP server, successful results for the named tools, and any exact
`error.message` rejection correlated to its required tool. Malformed/truncated JSONL, unmatched calls, unexpected
tool errors, non-approved servers, or non-MCP command/file/web/computer-use
capability items fail. Raw MCP initialize/tools-list frames are transport
internals and are not expected in `codex exec --json` output.

`resource-preflight.ts` records UTC sample time, available memory, free disk,
target locks/process inventory, and a digest in a normalized artifact. Its tests
cover thresholds, stale samples, duplicate target processes, lock conflicts, and
malformed platform output. `run-verified.ts --resource-artifact PATH` rejects a
sample older than ten seconds or below the requested thresholds. Immediately
before an Xcode command, while holding the destination lane lock, the runner
re-samples resources and process/lock identities and revalidates the thresholds;
this closes the preflight-to-exec race. It records its own child PID/start-time
plus descendant PID/start-time/executable identities and any
`--owned-output-root` for build cleanup reconciliation, and rejects success if
any recorded descendant remains alive.

The owned output root must already exist, be owned by the current user, have
exact mode `0700`, and be an exclusive runner namespace protected by its own
nonblocking lock: no other process may
rename the root or its descendants during a verified write. The writer stages
bytes directly in the pinned root, rejects symlink/path replacement, atomically
renames into the validated parent, and detects and cleans up deterministic swaps.
POSIX directory descriptors cannot prevent another process from renaming an
already-open root inode; callers enforce exclusivity with the preflight/lock
protocol. Xcode invocations require an explicit unique `--owned-output-root`,
keep the normalized artifact and `.xcresult` inside it, and hold nonblocking
exclusive root and Catalyst/iPhone lane locks through command completion and
artifact commit. Captured stdout/stderr and streamed xcresult hashing have
explicit fail-closed byte/entry limits. The resource digest is an accidental-corruption checksum, not an
authentication MAC; trust comes from the exclusive local root, atomic contained
write, freshness window, and caller-supplied threshold validation.

Run:

```bash
set -euo pipefail
bun test scripts/test-integrity/run-verified.test.ts scripts/test-integrity/resource-preflight.test.ts
bun scripts/test-integrity/run-verified.ts self-test
```

These are the only raw test commands: they bootstrap and self-test the verifier
before it exists. Every test/build/typecheck command after I0 must use the
reviewed runner and a unique normalized artifact.

The self-test feeds passing, failing, skipped, zero-test, truncated, malformed,
missing/wrong required-failure IDs, and command-exit mismatch fixtures for every
test format.

Add a `test-result-integrity` CI step that runs both commands above. Keep the
previously requested Electron test and Mobile lint jobs disabled explicitly;
do not disable Worker, sharing-protocol, Swift MCP, or shared-reading result
verification jobs. The self-test itself is green only when its intentionally
failing/zero/skip fixtures are rejected.

Expected: a failing test and zero-discovered suite both produce nonzero exits;
the normal verifier reports discovered, passed, skipped, and failed counts.

- [ ] **Step 2: Independently review and commit only I0**

```bash
git diff --name-only -- scripts/test-integrity/run-verified.ts scripts/test-integrity/run-verified.test.ts scripts/test-integrity/resource-preflight.ts scripts/test-integrity/resource-preflight.test.ts .github/workflows/ci.yml
git add scripts/test-integrity/run-verified.ts scripts/test-integrity/run-verified.test.ts scripts/test-integrity/resource-preflight.ts scripts/test-integrity/resource-preflight.test.ts
git add .github/workflows/ci.yml
git diff --cached --name-status
git commit -m "test: enforce result integrity"
git rev-parse HEAD > /private/tmp/shared-reading-I0.sha
```

Expected: exactly the four test-integrity scripts and CI workflow are committed;
Electron tests and Mobile lint remain explicitly disabled while Worker,
sharing-protocol, Swift MCP, and result-integrity checks remain enabled. An
independent reviewer must return PASS with zero open Critical/High.

- [ ] **Step 3: Stop at the remote-mutation gate**

I0 must be present on `origin/main` before T0 can depend on it. End at the
reviewed local commit and request separate, contemporaneous user authorization
to upstream it through the approved main workflow. After authorization, verify
local/remote SHAs, perform the non-force upstream operation, fetch
`origin/main`, and prove the exact I0 commit is an ancestor. Do not begin T0
until that proof passes.

Using the clean main worktree recorded during the read-only preflight, run
exactly after that authorization:

```bash
set -euo pipefail
test -n "$RISHI_MAIN_WORKTREE"
test -z "$(git -C "$RISHI_MAIN_WORKTREE" status --porcelain)"
I0_SHA=$(cat /private/tmp/shared-reading-I0.sha)
test "$(git show -s --format=%s "$I0_SHA")" = "test: enforce result integrity"
MAIN_BEFORE=$(git ls-remote origin refs/heads/main | awk '{print $1}')
git -C "$RISHI_MAIN_WORKTREE" fetch origin main
test "$(git -C "$RISHI_MAIN_WORKTREE" rev-parse HEAD)" = "$MAIN_BEFORE"
git -C "$RISHI_MAIN_WORKTREE" cherry-pick "$I0_SHA"
git -C "$RISHI_MAIN_WORKTREE" push origin HEAD:main
git fetch origin main
MAIN_AFTER=$(git rev-parse origin/main)
git merge-base --is-ancestor "$I0_SHA" "$MAIN_AFTER"
RISHI_LANDING_ROOT=$(mktemp -d /private/tmp/rishi-I0-landing.XXXXXX)
printf '{"i0":"%s","mainBefore":"%s","mainAfter":"%s","force":false}\n' "$I0_SHA" "$MAIN_BEFORE" "$MAIN_AFTER" > "$RISHI_LANDING_ROOT/landing.json"
```

Any dirty main worktree, protected-branch rejection, conflict, SHA mismatch, or
ancestry failure stops the operation; no bypass or force retry is allowed.

## Task 2: Restore the Worker typecheck prerequisite

**Files:** See `2026-09-15-worker-typecheck-repair.md`.

- [ ] **Step 1: Run T0-T3 in order**

Narrow only the Worker's explicit TypeScript project include, then repair Web
API byte boundaries, distinguish historical `combined` allowances from current
StoreKit products, and resolve the Drizzle/cursor/Sentry errors without
suppression. Every imported shared module remains transitively typechecked.

- [ ] **Step 2: Run T4 and preserve the PR boundary**

Require an independent PASS with zero open Critical/High findings and a clean
full Worker test/typecheck run. Commit only the exact prerequisite files, then
stop and request separate, contemporaneous authorization for the remote-main
operation. After authorization, verify SHAs/status, upstream without force,
fetch `origin/main`, prove the prerequisite commit is its ancestor, and update
the feature branch from that exact baseline before W0 begins.

Use a clean main worktree recorded by Task 1; substitute only its reviewed
absolute path and the captured prerequisite SHA:

```bash
set -euo pipefail
I0_SHA=$(cat /private/tmp/shared-reading-I0.sha)
TYPECHECK_SHA=$(cat /private/tmp/shared-reading-typecheck.sha)
test "$(git show -s --format=%s "$I0_SHA")" = "test: enforce result integrity"
test "$(git show -s --format=%s "$TYPECHECK_SHA")" = "fix(worker): restore strict typecheck"
MAIN_BEFORE=$(git ls-remote origin refs/heads/main | awk '{print $1}')
git -C "$RISHI_MAIN_WORKTREE" fetch origin main
test "$(git -C "$RISHI_MAIN_WORKTREE" rev-parse HEAD)" = "$MAIN_BEFORE"
git -C "$RISHI_MAIN_WORKTREE" merge-base --is-ancestor "$I0_SHA" "$MAIN_BEFORE"
git -C "$RISHI_MAIN_WORKTREE" cherry-pick "$TYPECHECK_SHA"
git -C "$RISHI_MAIN_WORKTREE" push origin HEAD:main
git fetch origin main
MAIN_AFTER=$(git rev-parse origin/main)
git merge-base --is-ancestor "$I0_SHA" "$MAIN_AFTER"
git merge-base --is-ancestor "$TYPECHECK_SHA" "$MAIN_AFTER"
git merge --no-edit origin/main
```

`RISHI_MAIN_WORKTREE` must be a clean worktree whose HEAD exactly equals the
captured remote main SHA. Any protected-branch rejection, ancestry mismatch,
dirty worktree, conflict, or feature-manifest mismatch stops the operation; do
not force, retry through a bypass, or broaden the manifest.

## Task 3: Freeze the exact feature implementation baseline

**Files:**

- Create: `apps/apple/docs/superpowers/reviews/shared-reading-change-inventory.md`
- Create: `apps/apple/docs/superpowers/reviews/shared-reading-feature-paths.txt`
- Inspect only: current worktree and refreshed `origin/main`

- [ ] **Step 1: Record immutable identities and classify every dirty path**

```bash
git rev-parse HEAD
git rev-parse origin/main
git merge-base HEAD origin/main
git status --porcelain=v2
git diff --name-status
git diff --name-status origin/main...HEAD
```

Record every dirty path exactly once as `ADOPT_AND_REPAIR`, `EXCLUDE`,
`REPLACE_ON_PARITY`, or `QUARANTINE`; do not classify by guesswork.
Write the sorted repository-relative paths allowed in the final feature diff to
`shared-reading-feature-paths.txt`; the W/A/M owners may update it only through
reviewed exact-path commits.

- [ ] **Step 2: Commit only the ignored inventory file**

```bash
git add -f apps/apple/docs/superpowers/reviews/shared-reading-change-inventory.md
git add -f apps/apple/docs/superpowers/reviews/shared-reading-feature-paths.txt
git diff --cached --name-status
git commit -m "docs: inventory shared reading recovery changes"
RISHI_INVENTORY_ROOT=$(mktemp -d /private/tmp/rishi-shared-reading-inventory.XXXXXX)
git diff --name-only origin/main...HEAD | sort > "$RISHI_INVENTORY_ROOT/feature-actual.txt"
diff -u apps/apple/docs/superpowers/reviews/shared-reading-feature-paths.txt "$RISHI_INVENTORY_ROOT/feature-actual.txt"
```

Expected: both review manifests are based on the refreshed main SHA and are the
only staged paths.

## Task 4: Execute the Worker/protocol plan

**Files:** See `2026-09-15-shared-reading-worker-protocol.md`.

- [ ] **Step 1: Run W0-W1**

Perform read-only production D1 inspection, select the one matching migration
path, and prove it against fresh/empty/populated predecessor states. Do not run
`migrate:remote` or `deploy`.

- [ ] **Step 2: Run W2-W4 in order**

Implement `/v2` room semantics, then `/api/v1` creation/active/rejoin, then
account revocation. Each lane uses a fresh implementation agent, a specification
reviewer, and a code-quality reviewer.

- [ ] **Step 3: Satisfy the Worker gate**

```bash
set -euo pipefail
RISHI_GATE_ROOT=$(mktemp -d /private/tmp/rishi-master-worker-gate.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_GATE_ROOT" --artifact "$RISHI_GATE_ROOT/W2-sharing.json" --cwd workers/sharing-worker -- bun run test
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_GATE_ROOT" --artifact "$RISHI_GATE_ROOT/W2-sharing-typecheck.json" --cwd workers/sharing-worker -- bunx tsc --noEmit
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_GATE_ROOT" --artifact "$RISHI_GATE_ROOT/W3-migrations.json" --cwd workers/worker -- bun run verify:migrations
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_GATE_ROOT" --artifact "$RISHI_GATE_ROOT/W3-typecheck.json" --cwd workers/worker -- bun run type-check
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_GATE_ROOT" --artifact "$RISHI_GATE_ROOT/W3-worker.json" --cwd workers/worker -- bun run test
```

Expected: nonzero tests discovered, zero skipped/failed, both typechecks exit
`0`, and the migration verifier accepts only the selected generated chain.

## Task 5: Execute the Apple client plan

**Files:** See `2026-09-15-shared-reading-apple-client.md`.

- [ ] **Step 1: Repair typed recovery and generation ordering**

Implement a single retry loop, authoritative handshake reset, separate room/
roster/controller/connection/reader generations, and `/active` rejoin.

- [ ] **Step 2: Repair app/account lifecycle**

Install one composition-root session registry and drain it on sign-out, account
switch, and deletion without allowing delayed account-A work under account B.

- [ ] **Step 3: Satisfy the Apple unit/build gate**

Run the exact focused and serialized build commands in the Apple plan only after
the host has at least 8 GiB available memory and 20 GiB free disk.

Expected: every suite discovers tests and has zero skips/failures; fresh Catalyst
and iPhone products identify the current repository SHA.

## Task 6: Execute the MCP/live acceptance plan

**Files:** See `2026-09-15-shared-reading-mcp-live-acceptance.md`.

- [ ] **Step 1: Establish sole ownership**

MCP, not the standalone E2E host, acquires target locks and owns all XCTest/Rishi
processes. The host becomes a fixture/evidence helper only.

- [ ] **Step 2: Connect the registered server to Codex**

Use the actual registered stdio executable and prove the Codex thread/turn
lifecycle plus correlated MCP item start/completion records for read-only
instance/memory calls, then semantic app actions. Optional schema-valid
`item.updated` records may appear but are not required.

- [ ] **Step 3: Run the complete two-account scenario**

Use only the two designated already-signed-in accounts. Execute create, redeem,
start/open, progress, pause/resume, iPhone restart, `/active` rejoin, leave/end,
and cleanup through MCP semantic actions.

- [ ] **Step 4: Satisfy the evidence gate**

Expected: one signed hash-chained run ledger, independent producer records,
matching result bundles, fresh binary identities, causal `/v2`/UI checkpoints,
zero skips, and no owned descendants or disposable artifacts after cleanup.

## Task 7: Final adversarial review and integration gate

**Files:**

- Create: `apps/apple/docs/superpowers/reviews/shared-reading-final-review.md`
- Modify only if findings require fixes: files owned by the failed lane

- [ ] **Step 1: Run a specification-compliance reviewer**

The reviewer maps every row of the approved design's completion-evidence table
to current test output, source, live artifacts, and SHAs. Missing or indirect
evidence is a finding, not a pass.

- [ ] **Step 2: Run a separate code-quality/security reviewer**

The reviewer attempts to disprove authorization, idempotency, stale-generation
rejection, migration safety, `/v1` compatibility, cleanup, redaction, and MCP
ownership.

- [ ] **Step 3: Resolve and re-review**

Repeat implementation review until both reviewers return `PASS` with zero open
Critical/High findings. `PASS WITH NOTES` requires explicit user acceptance.

- [ ] **Step 4: Run the final command matrix**

```bash
set -euo pipefail
RISHI_FINAL_ROOT=$(mktemp -d /private/tmp/rishi-shared-reading-final.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_FINAL_ROOT" --artifact "$RISHI_FINAL_ROOT/sharing.json" --cwd workers/sharing-worker -- bun run test
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_FINAL_ROOT" --artifact "$RISHI_FINAL_ROOT/sharing-typecheck.json" --cwd workers/sharing-worker -- bunx tsc --noEmit
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_FINAL_ROOT" --artifact "$RISHI_FINAL_ROOT/migrations.json" --cwd workers/worker -- bun run verify:migrations
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_FINAL_ROOT" --artifact "$RISHI_FINAL_ROOT/worker-typecheck.json" --cwd workers/worker -- bun run type-check
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_FINAL_ROOT" --artifact "$RISHI_FINAL_ROOT/worker.json" --cwd workers/worker -- bun run test
bun scripts/test-integrity/run-verified.ts --format swift-output --expect pass --owned-output-root "$RISHI_FINAL_ROOT" --artifact "$RISHI_FINAL_ROOT/mcp.log" --cwd . -- swift test --package-path apps/apple/rishi-mcp
bun scripts/test-integrity/run-verified.ts --format swift-output --expect pass --owned-output-root "$RISHI_FINAL_ROOT" --artifact "$RISHI_FINAL_ROOT/e2e-host.log" --cwd . -- swift test --package-path apps/apple/rishi-e2e-host
git diff --name-only origin/main...HEAD | sort > "$RISHI_FINAL_ROOT/feature-final.txt"
diff -u apps/apple/docs/superpowers/reviews/shared-reading-feature-paths.txt "$RISHI_FINAL_ROOT/feature-final.txt"
```

Then run the serialized Xcode and live MCP commands in the detailed plans.

Expected: all exits `0`, discovered tests `> 0`, skipped/failed `0`, and the live
run ledger verifier exits `0`.

- [ ] **Step 5: Audit the final diff**

```bash
git diff --check origin/main...HEAD
git diff --name-status origin/main...HEAD
git status --porcelain=v2
```

Expected: only approved feature/recovery files and explicitly retained evidence
or plans are included. Excluded dirty files remain unstaged and unchanged.

## Completion matrix

| Requirement | Required authoritative proof |
| --- | --- |
| Working two-person feature | Same-run Catalyst+iPhone UI and `/v2` causal checkpoints for create/join/start/progress/pause/resume/restart/rejoin/end |
| Real Codex control | Registered MCP executable hash/config plus ordered Codex tool transcript |
| Production behavior | Canonical HTTP/WebSocket endpoint identities and Worker versions; no localhost/test auth/session injection |
| Migration safety | Fresh production read-only evidence plus selected generated chain passing three predecessor-state tests |
| Compatibility | Full `origin/main` route/auth/schema/binding/DO inventory with `/v1` ICE and negative isolation tests |
| Account safety | Bounded server revocation plus app registry drain; three post-cleanup probes |
| Resource safety | Exclusive target locks, every PID/start event reconciled, memory/disk thresholds, zero owned descendants |
| Test integrity | Discovered `> 0`, exit `0`, skipped/failed `0`; negative verifier proves failures cannot be hidden |
| Review quality | Independent specification and quality/security PASS, zero open Critical/High |

## Rollout boundary

Implementation and local/live verification do not authorize production mutation.
No agent may run `wrangler deploy`, `bun run deploy`, `migrate:remote`, secret
rotation, GitHub merge, or PR merge unless the user separately requests it after
all gates pass. Once separately authorized, rollout order is exactly:

1. refresh the `origin/main` compatibility audit and production D1 evidence;
2. generate one deployment-specific trust secret once, set both production
   `SHARING_INTERNAL_SECRET` and `WORKER_HMAC_SECRET` from that same value, and
   record only operator, UTC time, secret-version identifiers, and command
   success; a one-sided rotation is forbidden;
3. deploy the primary Worker compatible with the selected schema transition,
   with shared-session creation disabled;
4. apply the generated nullable delta when required, run/verify the bounded
   backfill, and apply the generated non-null/unique delta;
5. deploy sharing Worker `/v2` plus the separate Apple Durable Object binding,
   retaining `/v1`;
6. verify health, canonical auth, trust-secret fingerprints, and signed smoke;
7. deploy final primary `/api/v1` routes with creation still disabled, verify,
   then enable creation;
8. run the real two-account MCP acceptance.

## Adversarial plan review

### Round 1 — Terra architecture/planning review

**Verdict:** RE-REVIEW REQUIRED.

High findings covered rollout order, incomplete migration branches, generated
auth types and trust verification, omitted DAG nodes and overlapping ownership,
broad staging, invalid epoch/subordinate-fence ordering, missing independent
Worker observation, and missing review records. All are resolved in the revised
master and detailed plans. A fresh Terra and Luna re-review is required before
Task 1 implementation begins.

### Round 2 — Terra and Luna executable-proof review

**Verdict:** RE-REVIEW REQUIRED.

High findings were: I0 was not independently landable before T0; upstream-main
authority and ancestry commands were ambiguous; accepted test gates bypassed
the integrity runner; expected-failing typecheck allowed arbitrary diagnostics;
T2/T3 test ownership was incomplete; the Sentry proposal used a double cast;
Codex acceptance retained workspace-write capability; M5 lacked pre-build
resource ownership; and M6 could accept stale peer bundles. Revisions now split
I0 into its own reviewed/upstream-gated prerequisite, stop at explicit remote
authorization gates, define exact ancestry/feature-manifest assertions, wrap
every post-I0 test/build/typecheck/registration gate, compare exact typecheck
diagnostics, enumerate all prerequisite tests, use a typed Sentry adapter with
one tested request-boundary cast, run Codex read-only with transcript capability
rejection, supervise the M5 build after preflight, and bind two exact fresh
`MCPControlUITests/testServer` bundles to the live run. Fresh Terra and Luna
PASS verdicts with zero open Critical/High remain required.

### Final round — Terra and Luna

**Verdict:** PASS. Both independent reviewers reported zero open
Critical/High findings on the current five-plan set. Task 1 may begin.

## Planning self-review

- **Spec coverage:** Compatibility/migrations map to W0-W1; creation and `/active`
  map to W3; admission, lifetime, sync, and revocation map to W2/W4; reconnect and
  account lifecycle map to A0-A3; semantic UI maps to A4; process ownership,
  evidence, Codex integration, and the real two-account flow map to M0-M7; final
  review and rollout boundaries map to master Task 7. The pre-existing Worker
  typecheck failure maps to T0-T4 and lands before feature work. No approved requirement is
  unmapped.
- **Placeholder scan:** The four new plans contain no deferred-work markers or
  unspecified implementation steps. Runtime-generated SHAs, timestamps, PIDs,
  hashes, and UDIDs are explicitly captured by commands rather than invented in
  the plan.
- **Type consistency:** Public MCP `start_reading_session` and `open_shared_book`
  map to the bridge's `startSession` and `openReader`; reader actions are limited
  to page/playback actions. Worker ticket, revocation, generation, and evidence
  types use the same names across producer, consumer, and tests.

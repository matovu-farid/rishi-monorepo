# Worker Typecheck Baseline Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `workers/worker` typecheck cleanly without hiding Worker source errors or forcing unrelated optional shared-package applications into the Worker compilation.

**Architecture:** Narrow the Worker TypeScript project to Worker files plus shared modules actually reached through imports, then correct each remaining Worker-owned type mismatch at its semantic boundary. Keep this prerequisite commit independent from shared-reading behavior so it can be landed on `origin/main` before feature-only commits.

**Tech Stack:** TypeScript, Bun, Cloudflare Worker types, Hono, Sentry, Drizzle, Web Crypto, Vitest.

**Prerequisite:** Master task I0 has been independently reviewed, committed,
and proved present on `origin/main`; therefore every command below can rely on
`scripts/test-integrity/run-verified.ts` without importing a feature-only tool.

---

## Evidence baseline

With TypeScript 5.9.3 pinned, the narrowed Worker project currently reports 52
diagnostics. The original five-category baseline was incomplete. First repair
the unresolvable App Store library gitlink, missing generated binding types,
stale shared-schema import/export, explicit `.ts` test import, and floating
compiler. Only then capture the exact remaining semantic baseline, whose known
categories are:

1. `workers/worker/tsconfig.json` explicitly includes all
   `packages/shared/src/**/*.ts`, pulling shared tests and optional `xstate`/
   `epubjs` modules whose dependencies are not Worker dependencies.
2. Buffer/typed-array values are not accepted by the current DOM/Cloudflare
   `BodyInit` and Web Crypto `BufferSource` definitions.
3. persisted allowance rows permit `"combined"`, while new-product `ApplePlan`
   correctly permits only `"reader" | "voice"`.
4. Drizzle insert-select expressions in `routes/sync.ts` lack explicit aliases.
5. Sentry's inferred `ExportedHandler<unknown>` and a stale cursor test disagree
   with Worker handler/tuple types.

No task may newly add or broaden `skipLibCheck`, `any`, `@ts-ignore`, test
exclusion, or dependency installation to hide a Worker-owned error. The
pre-existing `skipLibCheck` setting does not excuse Worker source diagnostics;
all Worker source and tests remain in the project.

## Task T0: Repair the TypeScript project boundary

**Files:**

- Modify: `workers/worker/tsconfig.json`
- Create: `workers/worker/src/typecheck-boundary.test.ts`
- Create: `workers/worker/scripts/verify-typecheck-baseline.ts`
- Create: `workers/worker/scripts/verify-typecheck-baseline.test.ts`

- [x] **Step 1: Pin the intended boundary with a red test**

The test loads `tsconfig.json` and asserts Worker source/scripts/config are
included, while the explicit all-shared-source glob is absent:

```ts
expect(config.include).toEqual([
  "src/**/*.ts",
  "src/**/*.tsx",
  "scripts/**/*.ts",
  "drizzle.config.ts",
  "drizzle-do.config.ts",
]);
expect(config.include).not.toContain("../../packages/shared/src/**/*.ts");
```

Run:

```bash
RISHI_T0_RED_ROOT=$(mktemp -d /private/tmp/rishi-T0-red.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect fail --require-failure-id "excludes the all-shared-source glob" --owned-output-root "$RISHI_T0_RED_ROOT" --artifact "$RISHI_T0_RED_ROOT/evidence.json" --cwd workers/worker -- bunx vitest run src/typecheck-boundary.test.ts
```

Expected: discovered/failed `> 0`, skipped `0`, underlying exit nonzero.

- [x] **Step 2: Narrow only the explicit include**

Use the exact include array above. Keep path aliases to shared source so every
module actually imported by Worker code is still typechecked transitively. Do
not add shared test/module excludes or copy declarations.

- [x] **Step 3: Run boundary and typecheck**

```bash
RISHI_T0_GREEN_ROOT=$(mktemp -d /private/tmp/rishi-T0-green.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_T0_GREEN_ROOT" --artifact "$RISHI_T0_GREEN_ROOT/tests.json" --cwd workers/worker -- bunx vitest run src/typecheck-boundary.test.ts
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_T0_GREEN_ROOT" --artifact "$RISHI_T0_GREEN_ROOT/typecheck-baseline.json" --cwd workers/worker -- bun run scripts/verify-typecheck-baseline.ts --stage T0
```

`verify-typecheck-baseline.ts --stage T0|T1|T2` runs
`bunx tsc --noEmit --pretty false`, requires a nonzero underlying exit, parses
every diagnostic, rejects any path outside `workers/worker`, and compares the
exact sorted file/code multiset against stage-specific checked-in allowlists.
T0 is: app-store `TS2769` x1; allowance rollover `TS2322` x2;
APNs `TS2769` x1; entitlement sync `TS2322` x2; JWS `TS2769` x4; nonce `TS2345`
x2; index `TS2345` x3, `TS2769` x1, `TS2722` x1; sync route `TS2769` x2; cursor
test `TS2353` x1. T1 removes the app-store/APNs/JWS/nonce and index-body
diagnostics, leaving allowance `TS2322` x2, entitlement `TS2322` x2, index
`TS2345` x2 plus `TS2722` x1, sync route `TS2769` x2, and cursor `TS2353` x1.
T2 leaves only index `TS2345` x2 plus `TS2722` x1, sync route `TS2769` x2, and
cursor `TS2353` x1. Its tests reject an added diagnostic, missing diagnostic,
changed code, shared-package path, malformed output, and zero exit. Expected:
boundary and verifier tests pass; the baseline verifier passes only with that
exact remaining Worker-owned diagnostic set.

## Task T0A: Make the baseline reproducible and config-derived

**Files:**

- Create: `.gitmodules`
- Modify: `workers/worker/package.json`
- Modify: `workers/worker/bun.lockb`
- Modify: `workers/worker/wrangler.jsonc`
- Regenerate: `workers/worker/worker-configuration.d.ts`
- Create: `workers/worker/src/env.d.ts`
- Create: `workers/worker/src/env-contract.test.ts`
- Modify: `workers/worker/src/routes/test-auth.ts`
- Modify: `packages/shared/package.json`
- Delete: `packages/shared/src/schema.js`
- Modify: `workers/worker/src/usage/api-usage-routes.test.ts`
- Create: `workers/worker/src/apple-connect/functions.test.ts`
- Modify: `workers/worker/vitest.config.ts`
- Create: `workers/worker/src/test-utils/cloudflare-workers.ts`

- [x] **Step 1: Pin tools and restore the exact dependency**

Pin `typescript` to `5.9.3` in Worker dev dependencies and update only the Bun
lockfile. Register the App Store library gitlink in `.gitmodules` at the
dedicated fork. The parent gitlink is `c969a0d`, whose custom ancestors are
`20ebd85` and `6c09edb`. Do not upgrade or replace the crypto library.
Authorization was received on 2026-09-16; a non-force push advanced the public
fork's `main` from `bc5cf76` to `c969a0d`. A fresh bare repository then fetched
`main`, resolved its head to
`c969a0de6c5c8aa550c09c4feadfbbe48810c310`, and proved `20ebd85` and `6c09edb`
are ancestors. The dependency is now reproducible from `.gitmodules`.

- [x] **Step 2: Make binding types config-derived**

Use the read-only production `wrangler secret list` names plus current source
usage to define `secrets.required` in `wrangler.jsonc`. Never put secret values
in the repository. Keep `ENABLE_TEST_AUTH`, `TEST_AUTH_SECRET`,
`ENABLE_OPS_ADMIN`, `OPS_ADMIN_SECRET`, and optional `SENTRY_DSN` out of the
production-required list; declare genuinely optional/non-production bindings in
`src/env.d.ts`. Regenerate
`worker-configuration.d.ts` with Wrangler; never hand-edit it. The contract test
must verify required-vs-optional classification and that generated types are
current.

- [x] **Step 3: Remove stale module-resolution defects**

Import Drizzle tables in `routes/test-auth.ts` from `../db/schema`, remove the
dead `@rishi/shared/schema` export and stale `schema.js` only after repository
usage proves there are no supported consumers, and remove the lone `.ts` suffix
from the dynamic test import. Add App Store import/constructor tests against the
exact pinned submodule API. Configure Vitest with a minimal test-only
`cloudflare:workers` Durable Object shim and raw-SQL text loader so tests that
import the real Worker graph execute rather than failing during module loading.
Update `api-usage-routes.test.ts` to stop calling the intentionally removed
legacy `/api/realtime/client_secrets` route, send the required current AI data
consent header for TTS, and use the ledger/stream response harness already
covered by the dedicated passing voice-session and TTS route tests. Never
restore a removed production route merely to satisfy a stale test.

- [x] **Step 4: Verify and recapture the exact baseline**

```bash
cd workers/worker
bun install --frozen-lockfile --ignore-scripts
bunx tsc --version                         # exactly 5.9.3
bunx wrangler types --check
bunx vitest run src/typecheck-boundary.test.ts src/env-contract.test.ts \
  src/apple-connect/functions.test.ts src/routes/test-auth.test.ts \
  src/usage/api-usage-routes.test.ts
bunx tsc --noEmit --pretty false
```

Expected: no missing dependency, binding, shared-schema, or import-extension
diagnostic. Update the T0/T1/T2 exact diagnostic multisets only from this pinned,
clean-clone-equivalent state, and have an independent reviewer confirm that
every remaining diagnostic belongs to T1-T3.

## Task T1: Normalize binary values at Web API boundaries

**Files:**

- Create: `workers/worker/src/utils/web-bytes.ts`
- Create: `workers/worker/src/utils/web-bytes.test.ts`
- Modify: `workers/worker/src/app-store-server-library-node/index.ts`
- Modify: `workers/worker/src/app-store-server-library-node/index.js`
- Create: `workers/worker/src/app-store-server-library-node/request-body.test.ts`
- Modify: `workers/worker/src/billing/apns.ts`
- Modify: `workers/worker/src/billing/apns.test.ts`
- Modify: `workers/worker/src/billing/jws-verify.ts`
- Modify: `workers/worker/src/billing/jws-verify.test.ts`
- Modify: `workers/worker/src/durable-objects/voice-session/nonce.ts`
- Create: `workers/worker/src/durable-objects/voice-session/nonce.test.ts`
- Modify: `workers/worker/src/index.ts`
- Create: `workers/worker/src/index.web-bytes.test.ts`

`workers/worker/src/app-store-server-library-node` is a submodule. Changes under
that path must be reviewed and committed inside the submodule, then represented
in the monorepo by the gitlink update. The submodule commit and its ancestors
must be fetchable from the `.gitmodules` remote before the parent commit can be
considered reproducible. Publishing those commits is a separate remote mutation
and requires contemporaneous user authorization.

- [x] **Step 1: Write exact-copy red tests**

```ts
it("copies ArrayBufferLike bytes into an ArrayBuffer-backed view", () => {
  const input = Uint8Array.from([1, 2, 3]);
  const output = webBytes(input);
  expect(output).toEqual(input);
  expect(output.buffer).toBeInstanceOf(ArrayBuffer);
  expect(output).not.toBe(input);
});
```

Run the focused test through the integrity runner and require a discovered,
non-skipped failure before implementation:

```bash
RISHI_T1_RED_ROOT=$(mktemp -d /private/tmp/rishi-T1-red.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect fail --require-failure-id "copies ArrayBufferLike bytes into an ArrayBuffer-backed view" --require-failure-id "normalizes every Web API binary boundary" --owned-output-root "$RISHI_T1_RED_ROOT" --artifact "$RISHI_T1_RED_ROOT/evidence.json" --cwd workers/worker -- bunx vitest run src/utils/web-bytes.test.ts src/app-store-server-library-node/request-body.test.ts src/billing/apns.test.ts src/billing/jws-verify.test.ts src/durable-objects/voice-session/nonce.test.ts src/index.web-bytes.test.ts
```

- [x] **Step 2: Implement one safe helper**

```ts
export function webBytes(input: ArrayBuffer | ArrayBufferView): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(
    input instanceof ArrayBuffer
      ? new Uint8Array(input)
      : new Uint8Array(input.buffer, input.byteOffset, input.byteLength),
  );
}
```

Use `webBytes(value)` for Web Crypto inputs. Use `webBytes(value).buffer` for
`Response`/`fetch` bodies. Preserve `string | undefined` request bodies without
conversion. The pinned submodule must remain standalone, so it performs the
equivalent inline copy with `Uint8Array.from(body).buffer` rather than importing
the parent Worker's helper. The submodule intentionally tracks generated
JavaScript; apply the same body-copy behavior to `index.js` and prove the
extensionless runtime import exercises it.

- [x] **Step 3: Run focused behavior tests and typecheck**

```bash
RISHI_T1_GREEN_ROOT=$(mktemp -d /private/tmp/rishi-T1-green.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_T1_GREEN_ROOT" --artifact "$RISHI_T1_GREEN_ROOT/tests.json" --cwd workers/worker -- bunx vitest run src/utils/web-bytes.test.ts src/app-store-server-library-node/request-body.test.ts src/billing/apns.test.ts src/billing/jws-verify.test.ts src/durable-objects/voice-session/nonce.test.ts src/index.web-bytes.test.ts
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_T1_GREEN_ROOT" --artifact "$RISHI_T1_GREEN_ROOT/typecheck-stage.json" --cwd workers/worker -- bun run scripts/verify-typecheck-baseline.ts --stage T1
```

Expected: discovered `> 0`, skipped/failed `0`; the stage verifier proves every
`BodyInit`/`BufferSource` diagnostic is gone and the exact remaining T2/T3
diagnostic multiset is unchanged.

## Task T2: Separate new Apple products from persisted combined allowances

**Files:**

- Modify: `workers/worker/src/billing/apple-product-plans.ts`
- Modify: `workers/worker/src/billing/allowance-period-rollover.ts`
- Modify: `workers/worker/src/billing/entitlement-sync.ts`
- Modify: `workers/worker/src/billing/apple-product-plans.test.ts`
- Create: `workers/worker/src/billing/allowance-period-rollover.test.ts`
- Create: `workers/worker/src/billing/subscription-transitions.test.ts`
- Modify: `workers/worker/src/audio-speech-cache.test.ts`

- [x] **Step 1: Write persisted-plan compatibility tests**

Assert `APPLE_PRODUCT_PLAN_MAP` never emits `combined`, while historical
allowance rows with `combined` still roll over and synchronize both reader and
voice allowances.

```bash
RISHI_T2_RED_ROOT=$(mktemp -d /private/tmp/rishi-T2-red.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect fail --require-failure-id "combined history rolls over both allowance dimensions" --require-failure-id "combined history remains valid during subscription transitions" --owned-output-root "$RISHI_T2_RED_ROOT" --artifact "$RISHI_T2_RED_ROOT/evidence.json" --cwd workers/worker -- bunx vitest run src/billing/apple-product-plans.test.ts src/billing/allowance-period-rollover.test.ts src/billing/subscription-transitions.test.ts
```

Expected: discovered/failed `> 0`, skipped `0`, and failures are the new
combined-history/product-separation assertions.

- [x] **Step 2: Define distinct types**

```ts
export type ApplePlan = "reader" | "voice";
export type PersistedAllowancePlan = ApplePlan | "combined";
```

Keep product mappings/transition APIs on `ApplePlan`. Use
`PersistedAllowancePlan` only when reading/writing existing D1/ledger period
rows. A persisted `combined` period ranks as Voice (the highest included tier)
when classifying a later StoreKit Reader/Voice transaction, but remains
`combined` in storage. On monthly rollover, preserve that historical row's exact
narration and voice totals in its `combined` successor and reset usage; do not
index `PLAN_ALLOWANCES` with `combined` or invent a new StoreKit product. A
concurrent insert winner may also be `combined`, and the DO synchronization type
must accept and preserve it.

- [x] **Step 3: Run billing tests and typecheck**

```bash
RISHI_T2_GREEN_ROOT=$(mktemp -d /private/tmp/rishi-T2-green.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_T2_GREEN_ROOT" --artifact "$RISHI_T2_GREEN_ROOT/tests.json" --cwd workers/worker -- bunx vitest run src/billing/apple-product-plans.test.ts src/billing/allowance-period-rollover.test.ts src/billing/subscription-transitions.test.ts src/audio-speech-cache.test.ts
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_T2_GREEN_ROOT" --artifact "$RISHI_T2_GREEN_ROOT/typecheck-stage.json" --cwd workers/worker -- bun run scripts/verify-typecheck-baseline.ts --stage T2
```

Expected: all combined-history tests pass, no product map accepts combined, all
four ApplePlan assignment diagnostics disappear, and the exact remaining T3
diagnostic multiset is unchanged.

## Task T3: Repair Drizzle alias, cursor, and Sentry handler types

**Files:**

- Modify: `workers/worker/src/routes/sync.ts`
- Modify: `workers/worker/src/sync/change-cursor.test.ts`
- Modify: `workers/worker/src/index.ts`
- Modify: `workers/worker/src/routes/sync-push.test.ts`
- Modify: `workers/worker/src/sync/change-cursor.test.ts`
- Create: `workers/worker/src/index.sentry-adapter.test.ts`

- [x] **Step 1: Add sync insert-select behavior tests**

Prove a chapter-index parent/children batch inserts accepted newer data, rejects
older data, and deletes/replaces children only when the accepted parent exists.
The test asserts behavior, not generated SQL text.

- [x] **Step 2: Alias every Drizzle selected expression**

Use explicit aliases matching insert columns:

```ts
id: sql<string>`${parent.id}`.as("id"),
userId: sql<string>`${userId}`.as("user_id"),
bookId: sql<string>`${bookId}`.as("book_id"),
```

Apply the same typed alias pattern to every parent/child selected field. Keep all
database access in Drizzle.

- [x] **Step 3: Correct the cursor test tuple**

`compareSyncCursorTuple` intentionally compares only `updatedAtMs`, `kind`, and
`id`. Remove `highWaterMs` from only the direct tuple-comparison object at the
failing assertion; keep high-water validation tests on `SyncCursor` decoding.

- [x] **Step 4: Type the Sentry boundary once**

Construct a real `ExportedHandler<Env>` adapter object and pass that object to
Sentry, rather than casting the Hono application to an unrelated handler type:

```ts
const honoHandler: ExportedHandler<Env> = {
  fetch(request, env, ctx) {
    return app.fetch(request as Parameters<typeof app.fetch>[0], env, ctx);
  },
};
const sentryHandler = Sentry.withSentry<Env>(
  sentryOptions,
  honoHandler,
);

const fetchHandler = sentryHandler.fetch;
if (!fetchHandler) throw new Error("Sentry fetch handler unavailable");
```

The one library-boundary request cast is permitted only at this adapter and is
covered by compile/runtime tests for `(request, env, ctx)`, returned response,
thrown error propagation, and absent optional `fetch`. No `unknown` or handler
double-cast is permitted. Do not spread casts across routes.

- [x] **Step 5: Run complete Worker verification**

```bash
set -euo pipefail
RISHI_T3_ROOT=$(mktemp -d /private/tmp/rishi-T3.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_T3_ROOT" --artifact "$RISHI_T3_ROOT/worker.json" --cwd workers/worker -- bunx vitest run
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_T3_ROOT" --artifact "$RISHI_T3_ROOT/typecheck.json" --cwd workers/worker -- bun run type-check
```

Expected: nonzero test discovery, skipped/failed `0`, both exits `0`; no
suppression or unrelated dependency addition.

Latest post-rebase evidence (2026-09-16): the branch is based directly on
`origin/main` at `779acae1b`, the integrity runner discovered and passed all 550
Worker tests with zero failures/skips, strict `bun run type-check` exited 0,
Wrangler dry-run exited 0, and `git diff --check` passed. The branch diff has no
Electron paths. The standalone submodule request-body test also passed (1/1)
after commit `c969a0d`.

GitHub CI initially failed to resolve the now-explicit submodule because the
Worker typecheck checkout did not initialize the dependency. The Worker
deployment job had the same latent checkout defect. A broad recursive checkout
is unsafe because the repository also contains an unrelated unmapped gitlink at
`apps/apple/wokerUrl`; therefore both Worker-specific jobs now initialize only
`workers/worker/src/app-store-server-library-node`. Unrelated jobs and gitlinks
remain unchanged. Completion requires a fresh-clone proof of that targeted
command and a green rerun of PR CI. This workflow correction does not authorize
or perform a Worker deployment.

Fresh-clone proof passed: the targeted command initialized only the Worker
submodule and checked out the exact pinned SHA. Luna first rejected the broad
recursive approach because of the unmapped gitlink, then independently
re-reviewed the targeted correction and returned **PASS** with zero findings at
80% confidence. Green PR CI remains the external completion gate.

PR #267 merged as `b3be709d7`. Its authorized production run `35059026051`
passed checkout, targeted submodule initialization, installs, and strict
typecheck, then stopped before Worker deployment because the workflow replayed
historical migration `0004_chapter_index.sql` through a D1 import endpoint that
the GitHub token cannot use. Read-only production queries proved both migration
tables and all four indexes already exist, with zero writes. The recovery patch
removes only that already-applied migration replay; schema and generated
migration artifacts remain unchanged, and deployment still requires a green
typecheck followed by `wrangler deploy --minify` and route smoke tests.
The workflow now includes its own path in the push filter so this workflow-only
recovery commit triggers the authorized deployment. Future schema changes must
use the repository's migration command before deploying dependent code; this
patch does not establish migration replay as part of every Worker deployment.
Terra independently re-reviewed the final recovery workflow and returned
**PASS**, with zero findings at 80% confidence and no additional migration
required for this schema-neutral deployment.

## Task T4: Review, commit, and upstream before feature-only work

**Files:** Exact T0-T3 files only

The exact scope is the current prerequisite worktree diff, including
`.gitmodules`, the plan/evidence file, Worker package/config/generated binding
files, the stale shared-schema removal, all T0-T3 implementation/tests, and the
submodule gitlink. Electron files and shared-reading feature behavior are not
part of this branch.

- [x] **Step 1: Independent regression review**

Reviewer checks that Worker typecheck still reaches every imported shared module,
binary copies preserve bytes, combined remains legacy-compatible but not a new
product, Drizzle behavior is unchanged, and the Sentry adapter is the only cast.
Fix/re-review every Critical/High finding.

- [x] **Step 2: Stage exact files and inspect**

```bash
git status --short
git diff --stat
git diff --check
git add -A
git diff --cached --name-status
git diff --cached --submodule=log
git commit -m "fix(worker): restore strict typecheck"
git rev-parse HEAD > /private/tmp/shared-reading-typecheck.sha
```

- [ ] **Step 3: Preserve the feature review boundary**

Before shared-reading implementation, move this prerequisite commit to
`origin/main` only after stopping for separate, contemporaneous user
authorization. Then verify fresh local/remote SHAs and status, use the approved
non-force upstream-main workflow, fetch and prove the commit is an ancestor of
`origin/main`, and update the feature branch so the PR shows only feature
commits. Never force-push or infer remote-mutation authority from plan approval.

## Production compatibility matrix

| Contract surface | Diff from `origin/main` | Compatibility verdict |
| --- | --- | --- |
| Public routes | No route added, removed, or renamed by this prerequisite; stale tests no longer call an already-removed legacy realtime route. | Compatible; frozen unversioned `/api` surface unchanged. |
| Request/response payloads | Binary values are copied into standards-compatible `ArrayBuffer` bodies without changing bytes; test harnesses are corrected to current payloads. | Compatible. |
| Authentication/authorization | No production auth flow change; generated bindings classify required and optional names without storing values. | Compatible. |
| Worker bindings/config | Existing bindings are represented in generated types; no binding is removed or renamed. | Compatible, subject to post-rebase dry-run. |
| D1 schema/migrations | No schema or migration artifact changes. | Compatible. |
| Durable Object bindings/state/protocol | No binding, migration, class, storage schema, `/v1`, or `/v2` protocol change. | Compatible. |

This prerequisite is not authorization to deploy. Re-run this matrix against
the final rebased diff and obtain explicit deployment authorization before any
production mutation.

## Adversarial plan review

Terra and Luna must review this prerequisite with the other recovery plans. Zero
open Critical/High findings are required before T0 implementation.

Round 2 identified four High risks in this lane: feature-only runner dependency,
arbitrary expected-failure diagnostics, omitted test paths, and a Sentry double
cast. The plan now requires upstream I0 first, an exact diagnostic multiset
verifier, enumerated T2/T3 tests and staging, and a real typed handler adapter
with one tested request-boundary cast. Re-review remains required.

Final Terra and Luna verdict: **PASS**, zero open Critical/High findings.

Implementation review after rebasing: Terra found one **High** reproducibility
blocker and no other finding at 80% confidence: `c969a0d` and its custom
ancestors were not fetchable from the `.gitmodules` fork. The compatibility
matrix passed for public routes, payloads, auth, bindings, D1, Durable Objects,
and sharing transports. The authorized publication and fresh-fetch proof above
resolve the underlying condition; an independent closure re-review remains the
final review gate.

Luna closure re-review: **PASS WITH NOTES**, zero findings at 80% confidence.
The reviewer independently verified the fork head/ancestry, 550/550 Worker
tests, strict typecheck, Wrangler types/dry-run, diff hygiene, absence of
Electron paths, and every row of the compatibility matrix. The only
non-blocking note was one default-parallel timeout in
`index.sentry-adapter.test.ts`; that test passed in isolation and the complete
suite passed under constrained concurrency, consistent with runner resource
sensitivity rather than a product defect.

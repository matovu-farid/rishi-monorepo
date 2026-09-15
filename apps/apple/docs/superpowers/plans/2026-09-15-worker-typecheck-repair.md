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

`bunx tsc --noEmit --pretty false` currently fails in five categories:

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

No task may use `skipLibCheck`, `any`, `@ts-ignore`, test exclusion, or broad
dependency installation to hide a Worker-owned error.

## Task T0: Repair the TypeScript project boundary

**Files:**

- Modify: `workers/worker/tsconfig.json`
- Create: `workers/worker/src/typecheck-boundary.test.ts`
- Create: `workers/worker/scripts/verify-typecheck-baseline.ts`
- Create: `workers/worker/scripts/verify-typecheck-baseline.test.ts`

- [ ] **Step 1: Pin the intended boundary with a red test**

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
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect fail --require-failure-id "Worker typecheck boundary excludes the all-shared-source glob" --owned-output-root "$RISHI_T0_RED_ROOT" --artifact "$RISHI_T0_RED_ROOT/evidence.json" --cwd workers/worker -- bun run test -- src/typecheck-boundary.test.ts
```

Expected: discovered/failed `> 0`, skipped `0`, underlying exit nonzero.

- [ ] **Step 2: Narrow only the explicit include**

Use the exact include array above. Keep path aliases to shared source so every
module actually imported by Worker code is still typechecked transitively. Do
not add shared test/module excludes or copy declarations.

- [ ] **Step 3: Run boundary and typecheck**

```bash
RISHI_T0_GREEN_ROOT=$(mktemp -d /private/tmp/rishi-T0-green.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_T0_GREEN_ROOT" --artifact "$RISHI_T0_GREEN_ROOT/tests.json" --cwd workers/worker -- bun run test -- src/typecheck-boundary.test.ts
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_T0_GREEN_ROOT" --artifact "$RISHI_T0_GREEN_ROOT/typecheck-baseline.json" --cwd workers/worker -- bun run scripts/verify-typecheck-baseline.ts --stage T0
```

`verify-typecheck-baseline.ts --stage T0|T1|T2` runs
`bunx tsc --noEmit --pretty false`, requires a nonzero underlying exit, parses
every diagnostic, rejects any path outside `workers/worker`, and compares the
exact sorted file/code multiset against stage-specific checked-in allowlists.
T0 is: app-store `TS2769` x1; allowance rollover `TS2322` x2;
APNs `TS2769` x1; entitlement sync `TS2322` x2; JWS `TS2769` x3; nonce `TS2345`
x2; index `TS2345` x3, `TS2769` x1, `TS2722` x1; sync route `TS2769` x2; cursor
test `TS2353` x1. T1 removes the app-store/APNs/JWS/nonce and index-body
diagnostics, leaving allowance `TS2322` x2, entitlement `TS2322` x2, index
`TS2345` x2 plus `TS2722` x1, sync route `TS2769` x2, and cursor `TS2353` x1.
T2 leaves only index `TS2345` x2 plus `TS2722` x1, sync route `TS2769` x2, and
cursor `TS2353` x1. Its tests reject an added diagnostic, missing diagnostic,
changed code, shared-package path, malformed output, and zero exit. Expected:
boundary and verifier tests pass; the baseline verifier passes only with that
exact remaining Worker-owned diagnostic set.

## Task T1: Normalize binary values at Web API boundaries

**Files:**

- Create: `workers/worker/src/utils/web-bytes.ts`
- Create: `workers/worker/src/utils/web-bytes.test.ts`
- Modify: `workers/worker/src/app-store-server-library-node/index.ts`
- Create: `workers/worker/src/app-store-server-library-node/request-body.test.ts`
- Modify: `workers/worker/src/billing/apns.ts`
- Modify: `workers/worker/src/billing/apns.test.ts`
- Modify: `workers/worker/src/billing/jws-verify.ts`
- Modify: `workers/worker/src/billing/jws-verify.test.ts`
- Modify: `workers/worker/src/durable-objects/voice-session/nonce.ts`
- Create: `workers/worker/src/durable-objects/voice-session/nonce.test.ts`
- Modify: `workers/worker/src/index.ts`
- Create: `workers/worker/src/index.web-bytes.test.ts`

- [ ] **Step 1: Write exact-copy red tests**

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
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect fail --require-failure-id "copies ArrayBufferLike bytes into an ArrayBuffer-backed view" --require-failure-id "normalizes every Web API binary boundary" --owned-output-root "$RISHI_T1_RED_ROOT" --artifact "$RISHI_T1_RED_ROOT/evidence.json" --cwd workers/worker -- bun run test -- src/utils/web-bytes.test.ts src/app-store-server-library-node/request-body.test.ts src/billing/apns.test.ts src/billing/jws-verify.test.ts src/durable-objects/voice-session/nonce.test.ts src/index.web-bytes.test.ts
```

- [ ] **Step 2: Implement one safe helper**

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
conversion.

- [ ] **Step 3: Run focused behavior tests and typecheck**

```bash
RISHI_T1_GREEN_ROOT=$(mktemp -d /private/tmp/rishi-T1-green.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_T1_GREEN_ROOT" --artifact "$RISHI_T1_GREEN_ROOT/tests.json" --cwd workers/worker -- bun run test -- src/utils/web-bytes.test.ts src/app-store-server-library-node/request-body.test.ts src/billing/apns.test.ts src/billing/jws-verify.test.ts src/durable-objects/voice-session/nonce.test.ts src/index.web-bytes.test.ts
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
- Create: `workers/worker/src/billing/entitlement-sync.test.ts`

- [ ] **Step 1: Write persisted-plan compatibility tests**

Assert `APPLE_PRODUCT_PLAN_MAP` never emits `combined`, while historical
allowance rows with `combined` still roll over and synchronize both reader and
voice allowances.

```bash
RISHI_T2_RED_ROOT=$(mktemp -d /private/tmp/rishi-T2-red.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect fail --require-failure-id "combined history rolls over both allowance dimensions" --require-failure-id "combined history synchronizes without becoming an Apple product" --owned-output-root "$RISHI_T2_RED_ROOT" --artifact "$RISHI_T2_RED_ROOT/evidence.json" --cwd workers/worker -- bun run test -- src/billing/apple-product-plans.test.ts src/billing/allowance-period-rollover.test.ts src/billing/entitlement-sync.test.ts
```

Expected: discovered/failed `> 0`, skipped `0`, and failures are the new
combined-history/product-separation assertions.

- [ ] **Step 2: Define distinct types**

```ts
export type ApplePlan = "reader" | "voice";
export type PersistedAllowancePlan = ApplePlan | "combined";
```

Keep product mappings/transition APIs on `ApplePlan`. Use
`PersistedAllowancePlan` only when reading/writing existing D1/ledger period
rows. Add an exhaustive normalizer that maps a persisted combined row to its two
allowance dimensions without inventing a new StoreKit product.

- [ ] **Step 3: Run billing tests and typecheck**

```bash
RISHI_T2_GREEN_ROOT=$(mktemp -d /private/tmp/rishi-T2-green.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_T2_GREEN_ROOT" --artifact "$RISHI_T2_GREEN_ROOT/tests.json" --cwd workers/worker -- bun run test -- src/billing/apple-product-plans.test.ts src/billing/allowance-period-rollover.test.ts src/billing/entitlement-sync.test.ts
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

- [ ] **Step 1: Add sync insert-select behavior tests**

Prove a chapter-index parent/children batch inserts accepted newer data, rejects
older data, and deletes/replaces children only when the accepted parent exists.
The test asserts behavior, not generated SQL text.

- [ ] **Step 2: Alias every Drizzle selected expression**

Use explicit aliases matching insert columns:

```ts
id: sql<string>`${parent.id}`.as("id"),
userId: sql<string>`${userId}`.as("user_id"),
bookId: sql<string>`${bookId}`.as("book_id"),
```

Apply the same typed alias pattern to every parent/child selected field. Keep all
database access in Drizzle.

- [ ] **Step 3: Correct the cursor test tuple**

`compareSyncCursorTuple` intentionally compares only `updatedAtMs`, `kind`, and
`id`. Remove `highWaterMs` from only the direct tuple-comparison object at the
failing assertion; keep high-water validation tests on `SyncCursor` decoding.

- [ ] **Step 4: Type the Sentry boundary once**

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

- [ ] **Step 5: Run complete Worker verification**

```bash
set -euo pipefail
RISHI_T3_ROOT=$(mktemp -d /private/tmp/rishi-T3.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format vitest-json --expect pass --owned-output-root "$RISHI_T3_ROOT" --artifact "$RISHI_T3_ROOT/worker.json" --cwd workers/worker -- bun run test
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_T3_ROOT" --artifact "$RISHI_T3_ROOT/typecheck.json" --cwd workers/worker -- bun run type-check
```

Expected: nonzero test discovery, skipped/failed `0`, both exits `0`; no
suppression or unrelated dependency addition.

## Task T4: Review, commit, and upstream before feature-only work

**Files:** Exact T0-T3 files only

- [ ] **Step 1: Independent regression review**

Reviewer checks that Worker typecheck still reaches every imported shared module,
binary copies preserve bytes, combined remains legacy-compatible but not a new
product, Drizzle behavior is unchanged, and the Sentry adapter is the only cast.
Fix/re-review every Critical/High finding.

- [ ] **Step 2: Stage exact files and inspect**

```bash
git diff --name-only -- workers/worker/tsconfig.json workers/worker/src/typecheck-boundary.test.ts workers/worker/scripts/verify-typecheck-baseline.ts workers/worker/scripts/verify-typecheck-baseline.test.ts workers/worker/src/utils/web-bytes.ts workers/worker/src/utils/web-bytes.test.ts workers/worker/src/app-store-server-library-node/index.ts workers/worker/src/app-store-server-library-node/request-body.test.ts workers/worker/src/billing/apns.ts workers/worker/src/billing/apns.test.ts workers/worker/src/billing/jws-verify.ts workers/worker/src/billing/jws-verify.test.ts workers/worker/src/durable-objects/voice-session/nonce.ts workers/worker/src/durable-objects/voice-session/nonce.test.ts workers/worker/src/index.ts workers/worker/src/index.web-bytes.test.ts workers/worker/src/index.sentry-adapter.test.ts workers/worker/src/billing/apple-product-plans.ts workers/worker/src/billing/apple-product-plans.test.ts workers/worker/src/billing/allowance-period-rollover.ts workers/worker/src/billing/allowance-period-rollover.test.ts workers/worker/src/billing/entitlement-sync.ts workers/worker/src/billing/entitlement-sync.test.ts workers/worker/src/routes/sync.ts workers/worker/src/routes/sync-push.test.ts workers/worker/src/sync/change-cursor.test.ts
git add workers/worker/tsconfig.json workers/worker/src/typecheck-boundary.test.ts workers/worker/scripts/verify-typecheck-baseline.ts workers/worker/scripts/verify-typecheck-baseline.test.ts workers/worker/src/utils/web-bytes.ts workers/worker/src/utils/web-bytes.test.ts workers/worker/src/app-store-server-library-node/index.ts workers/worker/src/app-store-server-library-node/request-body.test.ts workers/worker/src/billing/apns.ts workers/worker/src/billing/apns.test.ts workers/worker/src/billing/jws-verify.ts workers/worker/src/billing/jws-verify.test.ts workers/worker/src/durable-objects/voice-session/nonce.ts workers/worker/src/durable-objects/voice-session/nonce.test.ts workers/worker/src/index.ts workers/worker/src/index.web-bytes.test.ts workers/worker/src/index.sentry-adapter.test.ts workers/worker/src/billing/apple-product-plans.ts workers/worker/src/billing/apple-product-plans.test.ts workers/worker/src/billing/allowance-period-rollover.ts workers/worker/src/billing/allowance-period-rollover.test.ts workers/worker/src/billing/entitlement-sync.ts workers/worker/src/billing/entitlement-sync.test.ts workers/worker/src/routes/sync.ts workers/worker/src/routes/sync-push.test.ts workers/worker/src/sync/change-cursor.test.ts
git diff --cached --name-status
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

## Adversarial plan review

Terra and Luna must review this prerequisite with the other recovery plans. Zero
open Critical/High findings are required before T0 implementation.

Round 2 identified four High risks in this lane: feature-only runner dependency,
arbitrary expected-failure diagnostics, omitted test paths, and a Sentry double
cast. The plan now requires upstream I0 first, an exact diagnostic multiset
verifier, enumerated T2/T3 tests and staging, and a real typed handler adapter
with one tested request-boundary cast. Re-review remains required.

Final Terra and Luna verdict: **PASS**, zero open Critical/High findings.

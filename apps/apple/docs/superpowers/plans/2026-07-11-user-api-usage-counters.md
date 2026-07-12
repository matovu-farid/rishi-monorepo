# Authenticated Voice and TTS Request Counters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Count authenticated voice-chat and TTS synthesis requests per user in D1 without requiring an active subscription for those feature routes.

**Architecture:** Add a one-row-per-user aggregate table to the shared Drizzle schema. A small worker helper performs atomic D1 upserts and is scheduled with Hono's `executionCtx.waitUntil()` after `requireAuth`; route handlers count voice session-secret requests and both TTS synthesis routes independently of existing billing metering.

**Tech Stack:** Cloudflare Workers, Hono, D1, Drizzle ORM, TypeScript, Vitest, Drizzle SQL migrations.

---

## Files and responsibilities

- Modify `packages/shared/src/schema.ts`: define the `userApiUsage` table and its typed counters.
- Create `workers/worker/src/usage/api-usage.ts`: expose an atomic `incrementApiUsage` helper for voice and TTS counters.
- Modify `workers/worker/src/index.ts`: count authenticated voice/TTS requests and remove the unused subscription middleware from the voice route.
- Create `workers/worker/drizzle/migrations/0011_user_api_usage.sql`: create the D1 table with the user foreign key and defaults.
- Create `workers/worker/src/test-utils/d1.ts`: provide a file-backed SQLite implementation of the small D1 binding surface used by the integration test, initialized from existing migration artifacts.
- Create `workers/worker/src/usage/api-usage-routes.test.ts`: exercise the real Hono routes and real counter persistence, mocking only external provider network calls.

### Task 1: Add red tests for the usage boundary

**Files:**

- Test helper: `workers/worker/src/test-utils/d1.ts`
- Test: `workers/worker/src/usage/api-usage-routes.test.ts`

- [ ] **Step 1: Add a real in-memory D1 adapter for tests.**

Use Node's built-in `node:sqlite` `DatabaseSync` to implement the D1 binding methods Drizzle calls. Initialize one file-backed database per suite by applying the repository's existing baseline migration and the new `0011_user_api_usage.sql` migration artifacts. Do not hand-write schema SQL, mock `incrementApiUsage`, or mock the database.

- [ ] **Step 2: Add end-to-end route flow assertions.**

Invoke the real Hono `app.fetch` handlers for authenticated voice, OpenAI TTS, and ElevenLabs TTS requests. Capture and await the real `waitUntil` promises, then query `user_api_usage` from the in-memory database. Assert repeated requests accumulate, voice and TTS counters stay separate, two users get independent rows, and an authenticated request works without a subscription row.

- [ ] **Step 3: Assert authentication and endpoint scope.**

Run a request without credentials and assert `401` with no usage row. Call the options endpoint and assert it does not create or increment a usage row. Mock only OpenAI/ElevenLabs network responses so the test remains deterministic and offline.

- [ ] **Step 4: Run the focused tests and verify they fail for the missing helper/hooks.**

Run from `workers/worker`:

```bash
yarn vitest run --config vitest.config.ts src/usage/api-usage-routes.test.ts
```

Expected: FAIL because the usage helper/module and route hooks do not yet exist.

### Task 2: Add the shared schema and D1 migration

**Files:**

- Modify: `packages/shared/src/schema.ts`
- Create: `workers/worker/drizzle/migrations/0011_user_api_usage.sql`

- [ ] **Step 1: Define the table in the shared schema.**

Add this shape beside the other user-owned tables:

```ts
export const userApiUsage = sqliteTable("user_api_usage", {
  userId: text("user_id")
    .primaryKey()
    .references(() => user.id, { onDelete: "cascade" }),
  voiceChatRequests: integer("voice_chat_requests").notNull().default(0),
  ttsRequests: integer("tts_requests").notNull().default(0),
  createdAt: integer("created_at").notNull(),
  updatedAt: integer("updated_at").notNull(),
});
```

Use the existing schema's timestamp convention and keep the table aggregate-only; do not add per-request event rows.

- [ ] **Step 2: Add the explicit SQLite migration.**

Create `0011_user_api_usage.sql` with:

```sql
CREATE TABLE `user_api_usage` (
  `user_id` text PRIMARY KEY NOT NULL,
  `voice_chat_requests` integer DEFAULT 0 NOT NULL,
  `tts_requests` integer DEFAULT 0 NOT NULL,
  `created_at` integer NOT NULL,
  `updated_at` integer NOT NULL,
  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
```

Do not edit the existing migration journal or the unrelated untracked `0002` files; preserve the repository's current migration history.

- [ ] **Step 3: Run schema/type validation.**

Run the shared package's existing type/build command and verify the new table exports without TypeScript errors before adding worker code.

### Task 3: Implement the atomic worker counter helper

**Files:**

- Create: `workers/worker/src/usage/api-usage.ts`
- Test: `workers/worker/src/usage/api-usage-routes.test.ts`

- [ ] **Step 1: Implement the narrow counter API.**

Export:

```ts
export type ApiUsageMetric = "voiceChat" | "tts";

export function incrementApiUsage(
  env: Env,
  userId: string,
  metric: ApiUsageMetric,
): Promise<void>;
```

Create the Drizzle database with `createDb(env.DB)`, map `voiceChat` to `userApiUsage.voiceChatRequests` and `tts` to `userApiUsage.ttsRequests`, and use one SQLite/D1 upsert whose conflict update increments only the selected column while preserving the other counter. Set both timestamps from one `Date.now()` value. Reject invalid metric values through the TypeScript union and a runtime `switch` default error.

- [ ] **Step 2: Make the upsert atomic and user-scoped.**

Use `onConflictDoUpdate` on `userApiUsage.userId`; the update expression must be `column + 1`, not a value read into JavaScript first. This prevents concurrent requests for the same user from losing increments.

- [ ] **Step 3: Run the real route-flow tests green.**

Run:

```bash
yarn vitest run --config vitest.config.ts src/usage/api-usage-routes.test.ts
```

Expected: PASS with persisted insert/update rows and independent metric behavior asserted.

### Task 4: Hook the routes and make preview access explicit

**Files:**

- Modify: `workers/worker/src/index.ts`
- Test: `workers/worker/src/usage/api-usage-routes.test.ts`

- [ ] **Step 1: Import the counter helper.**

Add `import { incrementApiUsage } from "./usage/api-usage";` to the worker entrypoint.

- [ ] **Step 2: Count voice session-start requests after authentication.**

Change the route declaration from:

```ts
app.post("/api/realtime/client_secrets", requireAuth, requireActiveSubscription, async (c) => {
```

to an authentication-only route and schedule:

```ts
c.executionCtx.waitUntil(
  incrementApiUsage(c.env, c.get("userId"), "voiceChat"),
);
```

Place the scheduling immediately inside the authenticated handler before the OpenAI request so authorized attempts are counted even if the upstream call fails.

- [ ] **Step 3: Count OpenAI and ElevenLabs TTS requests.**

Add the same `waitUntil` call with `"tts"` immediately inside each authenticated TTS handler, before body validation/cache lookup. This counts authorized requests and cache hits while leaving existing cost metering unchanged.

- [ ] **Step 4: Run the focused route-flow test green.**

Run `yarn vitest run --config vitest.config.ts src/usage/api-usage-routes.test.ts`. Expected: all pass, including authentication rejection, route counting, separate metric values, migration-backed persistence, and voice access without a subscription rejection.

### Task 5: Verify the complete change

**Files:**

- Review all modified files and migration SQL; no new source files are expected beyond those listed above.

- [ ] **Step 1: Run the worker test suite.**

Run:

```bash
yarn vitest run --config vitest.config.ts
```

Expected: the new route-flow test remains green; unrelated existing tests may continue to expose the repository's stale JavaScript-entrypoint/auth-fixture failures.

- [ ] **Step 2: Run worker TypeScript validation.**

Run:

```bash
yarn type-check
```

Expected: generated worker bindings and TypeScript compilation complete successfully.

- [ ] **Step 3: Validate migration formatting and diff hygiene.**

Run:

```bash
git diff --check
git status --short
```

Confirm only the approved design/plan docs and implementation files are changed; do not stage or modify the unrelated existing migration artifacts.

- [ ] **Step 4: Review the final diff against the approved design.**

Confirm authentication is still required, active-subscription checks were removed only from the voice/TTS feature scope, `/api/audio/speech/options` is not counted, and counters use atomic D1 updates.

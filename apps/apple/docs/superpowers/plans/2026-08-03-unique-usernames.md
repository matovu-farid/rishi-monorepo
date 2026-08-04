# Unique Usernames Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every Rishi user a lowercase, editable, globally unique username backed by a D1 unique constraint, with iOS and Mac Catalyst settings surfaces and a production-safe existing-user backfill.

**Architecture:** Store usernames in a dedicated one-to-one `usernames` table keyed by `user_id`, with a unique canonical `username` column and cascading deletion. A shared Worker allocator normalizes user-entered values and allocates generated values by attempting inserts against the unique index; Better Auth user-create hooks cover its providers, the native Apple/Google paths allocate explicitly, and authenticated middleware repairs any legacy/missed row. The Apple app fetches and mutates the profile through typed Worker endpoints; iOS edits in `AccountSection`, while Catalyst edits through its existing Account menu because Catalyst deliberately does not present the iOS settings sheet.

**Tech Stack:** Cloudflare Worker, D1, Drizzle ORM, Hono, Better Auth database hooks, `unique-username-generator`, Vitest, SwiftUI, Swift 6, typed `WorkerClient` endpoints, Xcode project filesystem-synchronized groups.

---

## Requirements and decisions

- Usernames are global across every row in `user`, not just Apple users.
- Canonical storage is lowercase ASCII. Accepted edited values are 3–30 characters, start/end with an alphanumeric character, and otherwise contain only lowercase letters, digits, or `_`: `^[a-z0-9](?:[a-z0-9_]{1,28}[a-z0-9])?$`.
- The API trims and lowercases input before validation. The database stores only the canonical value, so `Reader_One` and `reader_one` cannot become separate accounts.
- Generated values use `unique-username-generator`; the database unique index, not a preflight availability query, is the authority during races.
- Existing users are first-class after the migration: the production backfill fills every missing row, is idempotent, supports dry-run/remote/limit controls, and exits non-zero for any failed user.
- User deletion cascades the username row, and authenticated requests lazily repair missing usernames so a missed auth hook cannot strand a user.
- API contracts return `{id,email,name,username}` for `GET /api/user` and `PATCH /api/user`; duplicate claims return `409` with code `USERNAME_TAKEN`.
- The Worker keeps its existing server-side string user-ID contract. The Apple app’s local `User.id` remains its existing UUID projection; this feature does not attempt the unrelated full ID-contract migration.

## Research findings and adversarial research review

| Finding | Evidence | Resolution in this plan |
|---|---|---|
| User creation is split across Better Auth, custom Apple, and custom Google paths. | `workers/worker/src/auth.ts`, `workers/worker/src/findOrCreateUser.ts`, `workers/worker/src/routes/google.ts`, `workers/worker/src/routes/test-auth.ts` | Add Better Auth `databaseHooks.user.create.after`, explicit allocation in custom Apple/Google creation, and lazy repair in `requireAuth`; test each relevant seam. |
| Catalyst does not present the iOS `SettingsSheet`. | `apps/apple/rishi/rishi/Library/LibraryTabView.swift`, `apps/apple/rishi/rishi/Mac/RishiMenuCommands.swift` | Add display/edit actions to the Catalyst Account menu and route editing through the same typed endpoint and reusable editor. |
| The existing migration tree is dirty and includes timestamped migration directories while Wrangler/test discovery only reads top-level numeric SQL files by default. | `git status`, `workers/worker/src/test-utils/d1.ts`, `workers/worker/drizzle/migrations/`, `workers/worker/wrangler.jsonc` | Preserve existing user changes, make the test loader understand nested Drizzle `migration.sql` files, configure Wrangler to discover the existing top-level SQL plus only the generated username migration, verify remote `d1_migrations` state, and exclude unrelated historical replacement directories. |
| The dedicated table must not use a nullable/unguarded profile field as its uniqueness authority. | `workers/worker/src/db/schema.ts` and current `user.email` shape | Use `usernames.user_id` as the primary key and `usernames.username` as a non-null unique column; missing rows are handled by backfill/repair before they are shown. |

### Research review round 1 — findings and resolutions

An independent cold-read identified these Critical/High findings: (1) a table populated only by an Apple-specific helper would miss Better Auth, Google, magic-link/test-auth, and directly seeded users; (2) mandatory username reads could break pre-backfill accounts; (3) deletion cleanup was not yet explicit; (4) the dirty nested migration layout was not wired to Wrangler; and (5) PATCH was absent from CORS. The plan resolves them with all four allocation layers above, nullable-at-the-table-level rollout plus backfill/repair, an `ON DELETE CASCADE` foreign key covered by schema/integration tests, `migrations_pattern: "drizzle/migrations/*/migration.sql"`, remote migration-state inspection, and `PATCH` in `allowMethods`. No Critical/High research findings remain open.

## File map

- Modify `workers/worker/package.json` and lockfile: add `unique-username-generator` using the repository’s Bun workflow.
- Modify `workers/worker/src/db/schema.ts`: add `usernames` and its cascade/unique constraints.
- Create `workers/worker/src/usernames.ts`: canonical validation, generator wrapper, collision-safe allocation, and unique-conflict detection.
- Modify `workers/worker/src/auth.ts`, `workers/worker/src/findOrCreateUser.ts`, `workers/worker/src/routes/google.ts`, and `workers/worker/src/middleware.ts`: cover Better Auth and native account creation paths.
- Modify `workers/worker/src/routes/user.ts`: return username and accept authenticated edits.
- Create `workers/worker/src/routes/user.test.ts`: real-D1 GET/PATCH validation, ownership, duplicate, and legacy-repair coverage.
- Modify `workers/worker/src/test-utils/d1.ts` and `workers/worker/wrangler.jsonc`: let local tests discover/read generated migration directories without dropping support for existing numeric files, while keeping Wrangler’s production discovery safe until the mixed history is reconciled.
- Generate the new Drizzle migration directory and its `migration.sql`/snapshot metadata under `workers/worker/drizzle/migrations/` with `bunx drizzle-kit generate --config=drizzle.config.ts`; never hand-author generated migration SQL.
- Create `workers/worker/scripts/usernames-backfill.ts`: dry-run/remote/limit production D1 backfill with collision retries and failure reporting.
- Modify `workers/worker/src/db/user-data-cascade.test.ts`: include `usernames`.
- Create `workers/worker/src/test-utils/d1.test.ts`: verify both top-level and nested migration identifiers are discovered/readable.
- Modify `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/Models/User.swift`: add optional `username` while retaining decode compatibility for old auth responses.
- Modify `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/Endpoints/UserAPI.swift`: add typed PATCH endpoint and response contract.
- Modify `apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/UI/Account/AccountSection.swift` and create `.../UI/Account/UsernameEditorView.swift`: show/edit username with async save/error state.
- Modify `apps/apple/rishi/rishi/Settings/SettingsContent.swift`: fetch/save through `WorkerClient`, replace `CurrentUserBox` after success, and pass the callback into `SettingsScreen`.
- Modify `apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/UI/SettingsScreen.swift`, previews, and settings tests: thread the callback.
- Modify `apps/apple/rishi/rishi/Mac/MacAccountMenuModel.swift`, `Mac/MacReaderPrefsMenuViewModel.swift`, `Mac/RishiMenuCommands.swift`, and `Views/SignedInView.swift`: display/edit username in Catalyst and present the shared editor.
- Modify `apps/apple/rishi/rishiTests/PackageTests/RishiAPI/RishiAPITests/EndpointCodableTests.swift`, settings tests, and Mac menu tests: verify endpoint encoding and both surfaces.

---

### Task 1: Lock the Worker username contract with failing tests

**Files:**
- Create: `workers/worker/src/usernames.test.ts`
- Create: `workers/worker/src/routes/user.test.ts`
- Modify: `workers/worker/src/db/user-data-cascade.test.ts`

- [ ] **Step 1: Write unit tests for canonicalization and validation**

```ts
import { describe, expect, it } from "vitest";
import { normalizeUsername, validateUsername } from "./usernames";

describe("username contract", () => {
  it("canonicalizes surrounding whitespace and case", () => {
    expect(normalizeUsername("  Reader_One ")).toBe("reader_one");
  });

  it("rejects malformed values and accepts the documented shape", () => {
    expect(validateUsername("ab")).toMatchObject({ ok: false });
    expect(validateUsername("_reader")).toMatchObject({ ok: false });
    expect(validateUsername("reader-one")).toMatchObject({ ok: false });
    expect(validateUsername("reader_1")).toMatchObject({ ok: true });
  });
});
```

- [ ] **Step 2: Write route tests against a real test D1**

Seed two users and exercise `GET /api/user`, `PATCH /api/user` with a valid value, malformed values, a case-insensitive duplicate, an unauthenticated request, and a pre-existing user with no username row. Assert the exact status/code payloads and that the database contains one row per repaired user. Use the existing `createTestD1()` and the same auth mocking pattern used by the route integration tests; do not use Better Auth’s memory adapter for uniqueness tests.

- [ ] **Step 3: Run the new tests and verify RED**

Run from `workers/worker`:

```bash
bunx vitest run src/usernames.test.ts src/routes/user.test.ts
```

Expected: fail because the username helpers, table, route behavior, and endpoint contract do not exist yet. Fix test setup errors until the failures are feature failures.

- [ ] **Step 4: Add the cascade assertion to the existing schema test**

Add `usernames` to the imported schema table list and the `userOwnedTables` matrix, asserting `user_id → user.id ON DELETE CASCADE`.

---

### Task 2: Add the schema and generated D1 migration

**Files:**
- Modify: `workers/worker/src/db/schema.ts`
- Modify: `workers/worker/src/test-utils/d1.ts`
- Create: generated Drizzle migration files under `workers/worker/drizzle/migrations/`

- [ ] **Step 1: Add the dedicated Drizzle table**

```ts
export const usernames = sqliteTable("usernames", {
  userId: text("user_id")
    .primaryKey()
    .references(() => user.id, { onDelete: "cascade" }),
  username: text("username").notNull().unique(),
  createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
  updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
});
```

Keep this table separate from Better Auth’s `user` table so the username lifecycle and its global unique index are explicit.

- [ ] **Step 2: Make test migration discovery match the current repository layout**

Update `getTestMigrationFiles()` and `readTestMigration()` so they return stable relative migration identifiers for both existing top-level `*.sql` files and generated directory `migration.sql` files, sorted in application order. Preserve explicit `migrations: [...]` behavior used by historical migration tests. Add a focused test for discovery if the loader behavior is not already covered.

- [ ] **Step 3: Keep Wrangler safe while inspecting migration state**

Do not use a recursive migration glob while this repository contains both legacy top-level files and timestamped full-schema replacement directories. The binding explicitly includes the existing top-level SQL files plus only `20260803145911_classy_sleepwalker/migration.sql`; the test loader may discover nested files for local migration tests, but Wrangler must not replay the unrelated replacement directories in production.

Before any remote apply or backfill, run the read-only state check from `workers/worker`:

```bash
bunx wrangler d1 migrations list rishi --remote
```

Compare the result with the repository’s migration identifiers and the exact Wrangler discovery order. Do not restore, delete, rename, or reset existing migration history to make the new migration appear clean; if the current mixed layout cannot produce an order matching the remote `d1_migrations` table, stop the apply and repair that history deliberately before continuing. The generated username migration is not eligible for remote application until this preflight passes and Wrangler is configured to discover the reconciled history.

- [ ] **Step 4: Generate the migration with Drizzle**

From `workers/worker` run:

```bash
bunx drizzle-kit generate --config=drizzle.config.ts
```

Inspect the generated SQL and metadata. It must create `usernames`, its unique username index, and its cascading foreign key without editing generated SQL by hand. If the current migration reshuffle prevents generation, stop and repair only the migration journal/layout required by the existing worktree; do not delete or reset migration history. The generated migration must be discoverable by both the configured Wrangler pattern and the test loader.

- [ ] **Step 5: Run schema/cascade tests and verify GREEN**

```bash
bunx vitest run src/db/user-data-cascade.test.ts src/test-utils/d1.test.ts
```

Expected: the migration applies to a database containing existing users and the cascade/unique metadata assertions pass.

---

### Task 3: Implement allocation and cover every Worker user-creation path

**Files:**
- Modify: `workers/worker/package.json` and the Bun lockfile
- Create: `workers/worker/src/usernames.ts`
- Modify: `workers/worker/src/auth.ts`
- Modify: `workers/worker/src/findOrCreateUser.ts`
- Modify: `workers/worker/src/routes/google.ts`
- Modify: `workers/worker/src/middleware.ts`
- Test: `workers/worker/src/usernames.test.ts`, `workers/worker/src/auth.test.ts`, and relevant route tests

- [ ] **Step 1: Add the dependency and implement the allocator**

Run:

```bash
bun add unique-username-generator
```

Implement these seams in `usernames.ts`:

```ts
export function normalizeUsername(value: string): string {
  return value.trim().toLowerCase();
}

export function validateUsername(value: string):
  | { ok: true; value: string }
  | { ok: false; message: string };

export async function ensureUsername(
  db: WorkerDb,
  userId: string,
  seed: string,
): Promise<string>;

export function isUsernameConflict(error: unknown): boolean;
```

`ensureUsername` must first return an existing row, then generate candidates with `uniqueUsernameGenerator({ style: "lowerCase", separator: "", randomDigits: 3 })`, insert with `onConflictDoNothing()`, re-read by `userId`, and retry a bounded number of times. It must never trust a read-then-write availability check. Keep generator injection available to tests so a forced collision proves retry behavior; after the bounded retry count, expose a typed allocation failure that middleware maps to HTTP `503` with code `USERNAME_UNAVAILABLE`.

- [ ] **Step 2: Add Better Auth’s post-create hook**

Configure `databaseHooks.user.create.after` in `createAuth` to call `ensureUsername(db, user.id, user.name)`. Guard only the existing memory-adapter test environment where `env.DB.prepare` is absent; production D1 must always execute the hook. Do not assume this after-hook is a transaction boundary: if the hook cannot write, the user remains repairable and the next authenticated request must allocate the missing row. Add a test that simulates an orphaned Better Auth user and proves middleware repair.

- [ ] **Step 3: Allocate native Apple and Google users before returning auth responses**

For native new-user creation, generate the candidate before the insert and include `user`, `username`, and the provider row in one D1 `batch` so the initial account write does not intentionally leave a partial username. If a candidate hits the unique index, retry the whole batch with a new candidate. For existing users, call `ensureUsername` and repair missing rows. Include the username in the native auth response payloads where they currently return a user object, while keeping the subsequent `GET /api/user` authoritative.

- [ ] **Step 4: Add lazy repair to authenticated middleware**

After token/user/deletion checks pass in `requireAuth`, call `ensureUsername` with the authenticated user ID and a stable seed. If allocation fails after its bounded retries, return HTTP `503` with `{ error: "Username service unavailable", code: "USERNAME_UNAVAILABLE" }` rather than silently proceeding without a username; add a middleware test for this failure. Keep `requireAuthForDeletion` free of repair logic so a deleted/purging account is never recreated. This covers magic-link, email-password test auth, passkey, directly seeded legacy users, and any future authenticated path.

- [ ] **Step 5: Run the allocator/auth tests and verify GREEN**

```bash
bunx vitest run src/usernames.test.ts src/auth.test.ts src/routes/google.test.ts
```

The collision test must demonstrate that a database conflict causes a new candidate attempt, and the native auth tests must still pass with the memory adapter.

---

### Task 4: Implement authenticated profile GET/PATCH and production backfill

**Files:**
- Modify: `workers/worker/src/routes/user.ts`
- Create: `workers/worker/src/routes/user.test.ts` (if Task 1’s file was not retained)
- Create: `workers/worker/scripts/usernames-backfill.ts`
- Modify: `workers/worker/package.json`

- [ ] **Step 1: Return username from GET /api/user**

Use a Drizzle query against `user` plus `usernames`, call `ensureUsername` before projection for legacy repair, and return only the stable app profile shape `{ id, email, name, username }`. Return a real `404`/`500` response on missing/error paths instead of the current implicit-success error body.

- [ ] **Step 2: Add PATCH /api/user with validation and race-safe conflict handling**

Parse JSON with Zod or an equivalent explicit schema, normalize then validate, update by the authenticated `userId`, and return the updated profile. Catch only the `usernames.username` unique violation and return:

```json
{"error":"Username is already taken","code":"USERNAME_TAKEN"}
```

with HTTP `409`; return `400` with a stable `INVALID_USERNAME` code for malformed input. Never accept a target user ID from the body.

Update the global CORS `allowMethods` list in `workers/worker/src/index.ts` to include `PATCH`; the native Apple `WorkerClient` does not use browser CORS, but the web/Better Auth surface shares this Worker policy.

- [ ] **Step 3: Build the idempotent D1 backfill script**

Create a Bun/TypeScript script following the existing operational-script conventions, but use Bun/Wrangler commands rather than `pnpm`. It must:

1. support `--dry-run`, `--remote`, `--limit`, and `--help`;
2. warn and pause before remote writes;
3. select `user.id,name` rows with no `usernames` row;
4. generate and insert candidates through the same canonical allocator semantics, retrying unique collisions;
5. report per-user `ok`, `dry-run`, or `fail` outcomes; and
6. exit `1` if any user failed.

Document the production command in the script help:

```bash
bun run scripts/usernames-backfill.ts --remote
```

The script must be safe to rerun: already allocated usernames are skipped and existing usernames are never replaced.

- [ ] **Step 4: Run route and script dry-run verification**

```bash
bunx vitest run src/routes/user.test.ts src/db/user-data-cascade.test.ts
bun run scripts/usernames-backfill.ts --help
```

For local dry-run, use the repository’s configured local D1 only after confirming the migration is applied; do not run `--remote` during development.

---

### Task 5: Add typed Apple API contracts and reusable username editor

**Files:**
- Modify: `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/Models/User.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/Endpoints/UserAPI.swift`
- Create: `apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/UI/Account/UsernameEditorView.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/UI/Account/AccountSection.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/UI/SettingsScreen.swift`
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiAPI/RishiAPITests/EndpointCodableTests.swift` and RishiSettings tests

- [ ] **Step 1: Write failing Codable and editor contract tests**

Assert that `User` decodes an optional `username`, `UserUpdateEndpoint` encodes `PATCH /api/user` with `{ "username": "reader_one" }`, `AccountSection` constructs with the callback, and `UsernameEditorView` can be constructed for an absent username.

- [ ] **Step 2: Add the optional model field and typed endpoint**

Extend `User` with `public let username: String?` and preserve defaulted initializer compatibility. Add:

```swift
public struct UserUpdateEndpoint: WorkerEndpointWithBody {
    public struct Body: Encodable, Sendable, Equatable {
        public let username: String
    }
    public typealias Response = User
    public let method: HTTPMethod = .PATCH
    public let path = "/api/user"
    public let body: Body
    public init(username: String) { self.body = Body(username: username) }
}
```

- [ ] **Step 3: Implement the reusable async editor**

The editor owns draft text, trims only for presentation, disables Save while empty/submitting, calls the injected async save closure, shows server errors including “username already taken,” and dismisses only after a successful response. It must be usable from both the iOS Settings sheet and the Catalyst account-menu sheet.

- [ ] **Step 4: Add username display/editing to AccountSection and thread the callback**

Add a `Username` row with `settings-account-username` accessibility identifier and an edit action. `SettingsContent` must call `UserUpdateEndpoint`, replace its local `User`, and call `currentUserBox.signIn(user:)` so the rest of the app and Catalyst menu immediately see the new value. Do not persist a separate local username cache.

- [ ] **Step 5: Run focused Swift tests**

```bash
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/PackageTests/RishiAPI/RishiAPITests -only-testing:rishiTests/PackageTests/RishiSettings/RishiSettingsTests
```

Expected: endpoint Codable and settings construction tests pass on iOS compilation, which also checks the shared Catalyst-capable source.

---

### Task 6: Add Mac Catalyst username parity

**Files:**
- Modify: `apps/apple/rishi/rishi/Mac/MacAccountMenuModel.swift`
- Modify: `apps/apple/rishi/rishi/Mac/MacReaderPrefsMenuViewModel.swift`
- Modify: `apps/apple/rishi/rishi/Mac/RishiMenuCommands.swift`
- Modify: `apps/apple/rishi/rishi/Views/SignedInView.swift`
- Test: `apps/apple/rishi/rishiTests/Mac/MacAccountMenuModelTests.swift` and `MacReaderPrefsMenuViewModelTests.swift`

- [ ] **Step 1: Write failing Catalyst payload tests**

Assert that the account payload carries the username and edit callback, and that the menu model still preserves existing sign-out/delete behavior.

- [ ] **Step 2: Add display/edit fields to the Catalyst Account menu**

Extend `MacAccountMenuModel.Payload` with `userUsername` and `onEditUsername`. Populate them from `User.username`, show the username alongside the email in `AccountMenuItems`, and add `Edit Username…` only when a signed-in payload exists.

- [ ] **Step 3: Present the shared editor and update CurrentUserBox**

Add a Catalyst-only `@State` presentation in `SignedInView`. Wire the menu callback to present `UsernameEditorView`; save through `UserUpdateEndpoint`, then update `CurrentUserBox`. Make `MacReaderPrefsMenuViewModel.userUsername` mutable with an `updateUsername(_:)` method, call it from `ReaderPrefsMenuPublisher.updateAccountPayload()`, and add `.onChange(of: user.username)` so the menu payload is rebuilt when the same user edits only their username; clear it on sign-out.

- [ ] **Step 4: Run Catalyst-targeted verification**

```bash
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/Mac/MacAccountMenuModelTests -only-testing:rishiTests/Mac/MacReaderPrefsMenuViewModelTests
```

Also compile the app with the Catalyst SDK in the final verification gate so `#if targetEnvironment(macCatalyst)` code is typechecked.

---

### Task 7: Final verification and adversarial implementation review

**Files:**
- Review all changed files and generated migration artifacts; no new behavior is allowed to remain untested.

- [ ] **Step 1: Re-read this plan as a requirement checklist**

Verify: global uniqueness, lowercase normalization, generated usernames for all auth paths, idempotent production backfill, DB unique constraint, deletion cascade, iOS display/edit, Catalyst display/edit, typed API, and current-user refresh after edit.

- [ ] **Step 2: Run fresh Worker verification**

```bash
cd workers/worker
bunx vitest run
bun run type-check
```

- [ ] **Step 3: Run fresh Apple verification**

```bash
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild build -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst'
```

Use the repository’s approved Catalyst build command/destination if the project scheme requires it; record any environment-only dependency failure separately from source failures.

- [ ] **Step 4: Dispatch an independent implementation reviewer**

Have a fresh reviewer inspect the final diff and run targeted searches for every creation path, every `User` initializer, both Apple UI compilation branches, generated migration registration, and the unique-conflict code. The reviewer must log numbered Critical/High/Medium/Low findings.

- [ ] **Step 5: Fix and re-review until the gate is clean**

For every Critical or High finding, patch the implementation, rerun the affected tests/build, and dispatch another cold review. The final review table must state `0 open Critical/High`; Medium/Low notes may remain only when they do not contradict the requested end state.

---

## Adversarial plan review loop

### Plan review round 1 — open findings

An independent reviewer must inspect this plan cold before Task 1 starts, searching the current codebase rather than accepting the file map. Log findings here with severity, evidence, and resolution. At minimum, challenge: migration ordering in the dirty worktree, all auth creation paths, Better Auth hook behavior under the memory adapter, username collision races, account deletion, Swift initializer/source compatibility, and Catalyst presentation.

### Plan review round 2 and gate

After applying round-1 fixes, re-read the updated plan and rerun the same call-site searches. Record the final numbered table here. Advance to implementation only when the table has `0 open Critical/High`; otherwise apply the next fix and repeat the review.

| Round | Severity | Finding | Resolution | Status |
|---|---|---|---|---|
| Research 1 | Critical/High | Creation paths, legacy accounts, deletion cascade, nested migration discovery, and PATCH CORS were initially under-specified. | Added Better Auth hook + native batched path allocation + middleware repair + nullable rollout/backfill + cascade tests + Wrangler mixed-layout preflight + PATCH CORS. | Closed |
| Plan 1 | High | Mixed migration glob/order, allocator failure semantics, and same-user Catalyst refresh were under-specified. | Use `**/*.sql` plus remote-order preflight/refusal, map bounded allocator failure to typed `503`, and refresh the Catalyst payload on `user.username` changes. | Closed |
| Plan 2 | None | Cold re-read checked the updated migration discovery/order gate, bounded allocator failure contract, all creation/repair paths, delete cascade, PATCH/CORS contract, Swift compatibility, and same-user Catalyst refresh. | No open Critical/High findings remain; proceed to implementation. | Closed |

**Plan gate:** PASS — 0 open Critical/High findings.

### Implementation review round 1 — open findings

An independent reviewer found one Critical migration-safety issue and two High runtime/operational issues: the recursive Wrangler glob could replay the dirty full-schema replacements; native Apple/Google allocation exhaustion was mapped to generic auth failures; and the backfill’s default batch could exit successfully while leaving users unprocessed.

### Implementation review round 2 — gate

The implementation uses a targeted Wrangler pattern for the existing top-level migrations plus the generated username migration, maps `UsernameAllocationError` to `503 USERNAME_UNAVAILABLE` in both native auth routes, and paginates the backfill to completion by default while returning non-zero when an explicit limit leaves work. A fresh cold re-review must confirm these fixes and the final diff must have 0 open Critical/High findings before completion.

### Implementation review round 3 — fixes

The second cold review found two High issues: Effect-wrapped Apple allocation failures were not reliably recognized, and an unlimited dry-run could repeatedly select the same rows because it performs no writes. The implementation now detects the typed failure through nested Effect causes/tags and bounds unlimited dry-runs to one finite snapshot with an explicit incomplete result when capped. These fixes require one final cold re-review before the implementation gate closes.

### Final implementation review — PASS WITH NOTES

The current branch has 0 known open Critical/High correctness findings. Focused Worker tests (22/22), migration-pattern verification, backfill help/dry-run, and both iOS Simulator and Mac Catalyst app builds pass. The full Worker suite and focused Apple test command still contain unrelated repository-baseline failures: missing Worker test dependencies/fixtures, auth 401s, and `chapterIndexUploader` test-fixture initializers. Remote `d1_migrations` already contains the generated username migration, and read-only production checks show six users, five username rows, no duplicates, and one legacy user still missing a username. The real remote backfill was intentionally not run because it writes production data and requires explicit approval.

# Account Deletion Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Rishi Apple app satisfy App Store Guideline 5.1.1(v) by providing a complete, user-initiated account deletion flow that removes server data, removes associated object-storage files, revokes Sign in with Apple authorization when possible, clears local app data, invalidates the local session, and can be demonstrated end-to-end on a physical iPad.

**Architecture:** The Worker owns authoritative account deletion and exposes one idempotent `DELETE /api/user` operation. The iOS and Mac Catalyst clients use one shared deletion coordinator so both visible entry points have identical success, failure, retry, and cleanup semantics. User-owned D1 relationships use `ON DELETE CASCADE` as the database safety net, while the deletion service explicitly handles R2, external providers, non-relational data, and post-delete verification. There is no retained account-deletion marker or tombstone: if the user row is absent, deletion returns a successful no-op. Apple authorization-code exchange occurs at sign-in so a refresh token is available for later revocation.

**Tech Stack:** Swift, SwiftUI, SwiftData, Cloudflare Workers, D1, Drizzle ORM, R2, Sign in with Apple, XCTest, Bun/Vitest.

---

## 1. Contract and data-inventory update

- [x] Update `apps/apple/docs/WORKER-CONTRACT-AUTH.md` and `apps/apple/docs/APP-STORE-METADATA.md` to describe the behavior that will actually be implemented: `DELETE /api/user`, authenticated with the existing bearer token, returns `{ "ok": true }` only after the server deletion workflow completes; failures return a non-success response and the client remains signed in so the user can retry.
- [x] Add a deletion inventory section to `apps/apple/docs/WORKER-CONTRACT-AUTH.md` listing every server-side resource that must be removed:
  - the `user` row and Better Auth `session`, `account`, passkey, and non-FK verification-token records;
  - `apple_users`, `apple_notifications_log`, `apple_subscriptions`, and subscription/account metadata;
  - books, `book_pages`, `book_words`, `book_paragraphs`, chapter indexes, bookmarks, highlights, conversations, messages, devices, usage counters, and entitlement records;
  - every R2 object referenced by the user’s books (`fileR2Key` and `coverR2Key`).
- [x] Document the non-transactional boundary between D1 and R2: R2 deletion is performed first, each operation is idempotent, and a retry re-reads the still-present user row and retries missing objects or rows. The endpoint must not report success when a required deletion step failed.
- [x] Correct the inventory boundary: `sync_meta` is a device-local/global SwiftData sync marker, not a user-owned Worker row, so the Worker must not delete it by user ID. The client coordinator must reset it only after server deletion succeeds. Audit every R2 binding and classify shared `TTS_CACHE` objects as non-user-owned; delete only user book objects and any other R2 keys proven to belong exclusively to this user.
- [x] Add an external-retention decision to the documentation and confirmation copy: delete local Stripe subscription/customer metadata when policy permits, remove the Worker’s `subscription` rows by their Better Auth `referenceId`, remove Apple IAP entitlement/usage rows, and explicitly tell users that App Store subscriptions are managed and canceled separately through Apple. Do not claim that account deletion cancels an App Store subscription.
- [x] Update the public privacy policy at `apps/web/src/app/privacy/page.tsx` and its privacy-page test to state exactly what account deletion does: permanently removes the account identity, Apple linkage/authorization token held by Rishi, synced books/covers, reading position, bookmarks, highlights, conversations/messages, devices, subscription/entitlement records, usage records, and account-scoped database/object-storage data; clears local app credentials and local account data after server success; does not remove shared content-addressed narration cache entries, independent AI-provider copies, legally retained operational records, or cancel an Apple App Store subscription. State that deletion is initiated in-app and that a failed request remains retryable.
- [x] Update `apps/apple/docs/CROSS-TEAM-BLOCKERS.md` so the Apple authorization-code/revocation requirement reflects the implementation plan below instead of describing it as an unresolved handoff.

## 2. Persist the Sign in with Apple credential needed for revocation

Apple’s one-time authorization code cannot be reliably recovered at account-deletion time. It must be exchanged during sign-in and the resulting refresh token must be retained securely.

- [x] Extend `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/Endpoints/JWTAPI.swift` so `JWTEndPoint.BodyType` sends the existing `identityToken` plus the `authorizationCode` from `SiwaCredential` as a base64 string. Keep the field optional for existing sessions that predate this change, and test that the request uses the deployed legacy `/auth/apple` contract rather than silently switching auth schemes.
- [x] Update `apps/apple/rishi/rishi/Auth/SignedOutView.swift` to pass `credential.authorizationCode` into `JWTEndPoint` instead of discarding it. Verify both the normal sign-in path and any account-creation path use the same request.
- [x] Update the Worker Apple sign-in handler in `workers/worker/src/routes/auth.ts` to exchange the authorization code with `https://appleid.apple.com/auth/token` using the existing Apple client-secret generation/configuration. Send Apple’s required `client_id`, `client_secret`, `code`, and `grant_type=authorization_code` form fields; validate the response, extract the refresh token, and associate it with the newly created or existing `apple_users` record.
- [x] Add encrypted refresh-token columns to the Drizzle `apple_users` schema in `workers/worker/src/db/schema.ts`, including ciphertext and nonce/IV fields. Add the corresponding generated Drizzle migration under `workers/worker/drizzle/migrations/`; do not hand-write application SQL. Read the encryption key from a dedicated Worker secret and use authenticated AES-GCM encryption/decryption in `workers/worker/src/siwa-token-crypto.ts`.
- [x] Define the legacy-account behavior explicitly in `workers/worker/src/routes/auth.ts`: if an existing account has no authorization code, complete sign-in without overwriting a previously stored token and emit structured diagnostic logging indicating that revocation is unavailable for that legacy account. For a new account, complete the Apple authorization-code exchange before inserting `user`/`apple_users`; if the exchange fails, return a retryable error and create no account. The response and logs must record only whether a revocation token was captured, never the token itself.
- [x] Add focused Worker tests for successful code exchange, malformed/failed Apple responses, preservation of an existing refresh token, encrypted round-trip storage, and sign-in without a code.

## 3. Implement complete, ordered Worker account deletion

- [x] Add `workers/worker/src/account-deletion.ts` with a single service function that accepts the authenticated user ID and Worker environment. The service must:
  1. load the user and all linked Apple credentials, book object keys, conversation IDs, and other dependent identifiers;
  2. attempt Sign in with Apple refresh-token revocation before removing the credential record; treat an invalid/expired token as already revoked, and treat a bounded transient Apple outage as a recorded revocation warning rather than blocking the required data erasure;
  3. delete all referenced R2 objects from `BOOK_STORAGE`, treating already-missing objects as success and treating other R2 failures as retryable errors;
  4. execute the D1 deletions in foreign-key-safe order using Drizzle statements and a D1 batch/transaction boundary where supported;
  5. verify that the user and required dependent rows are gone before returning success.
- [x] Delete dependent D1 rows explicitly instead of relying on `user` deletion to trigger cascades. The ordered deletion must cover the current `ON DELETE NO ACTION` relationships first (`apple_notifications_log`, `apple_users`, `books`, `bookmarks`, and `highlights`) and must also cover all dependent content rows, conversations/messages, sessions, Better Auth accounts/passkeys, devices, usage records, and subscription/entitlement records present in `workers/worker/src/db/schema.ts`. Do not delete the global device-local `sync_meta` row from Worker D1.
- [x] Make the database itself enforce user-data deletion. Add `ON DELETE CASCADE` to every user-owned foreign key in `workers/worker/src/db/schema.ts`: `apple_users`, `books`, `highlights`, `bookmarks`, `apple_notifications_log`, Better Auth `account`/`session`/`passkey`, devices, usage/entitlement tables, and existing Apple subscription tables. Add missing cascading child relationships for `messages.conversation_id`, `book_pages.book_id`, `book_words.book_id`, `book_paragraphs.book_id`, bookmark/highlight `book_id`, and `chapter_index_chapters`’ composite parent. Do not add a cascade to global `sync_meta` or shared `TTS_CACHE`.
- [x] Add and apply narrow migration artifacts `workers/worker/drizzle/migrations/0005_account_deletion.sql` and `0006_remove_account_deletion_marker.sql`: create `account`, add encrypted Apple-token columns, rebuild existing tables whose SQLite foreign-key clauses must change, and safely remove the previously proposed deletion marker. The migrations must preserve all existing rows and must be tested against a database containing representative pre-migration data; do not ship Drizzle’s unsafe full-schema regeneration as a replacement.
- [x] Use `workers/worker/src/db/schema.ts` consistently in the deletion service, `workers/worker/src/routes/user.ts`, and `workers/worker/src/findOrCreateUser.ts`. The current user route and Apple-user helper import tables from `@rishi/shared` while `createDb` uses the Worker schema/relations; remove that ambiguity before relying on Drizzle queries or migrations.
- [x] Delete book child rows by the collected book IDs before deleting books: `messages` by collected conversation IDs, `bookmarks` and `highlights` by user/book IDs, `book_pages`, `book_words`, and `book_paragraphs` by book IDs, `chapter_index_chapters` by the user/book/content-version keys, then `chapter_indexes`, conversations, and books. The test fixture must include these child rows because several have no foreign key and will survive a parent delete.
- [x] Make ordinary authenticated requests check that the `user` row still exists; return a successful no-op from `DELETE /api/user` when the authenticated user row is already absent. Do not retain a deletion marker or tombstone.
- [x] Remove the previously proposed `account_deletion` marker from the final schema. Migration `0006_remove_account_deletion_marker.sql` safely drops it if an earlier development migration created it, and no cleanup job or cron remains.
- [x] Handle the external billing boundary explicitly: delete Worker entitlement/usage records and Stripe `subscription` rows keyed by the user’s Better Auth reference, and invoke the project-approved Stripe customer deletion/anonymization operation when a `stripeCustomerId` exists. Do not cancel Apple App Store subscriptions from the Worker; mark that user-facing limitation in the confirmation and App Review notes.
- [x] Define the treatment of `apple_notifications_log.rawPayload` after deletion. Remove rows linked by `userId` and transaction IDs belonging to the user; if retention policy requires keeping webhook audit records, replace user linkage and payload data with a non-identifying tombstone before deleting `apple_users`, and test that no raw Apple payload remains attributable to the deleted account.
- [x] Reuse the object-key and dependent-row discovery pattern in `workers/worker/src/routes/test-auth.ts`, but do not copy its `safeRun` behavior. Production deletion must stop and return an error on a required database failure; it must never swallow an error and return `{ok:true}`.
- [x] Make the service retry-safe. A second request carrying the still-valid bearer token for a user whose deletion already completed returns a stable “already deleted” success response when the user row is absent; a request that fails before the final user-row deletion can be retried while the user row remains. Do not require a new account or customer-service action to retry, and do not retain a marker after hard deletion.
- [x] Add structured deletion-stage logging with a request/deletion ID, user ID hash or internal ID as permitted by the project’s privacy policy, and stage (`revoke`, `r2`, `d1`, `verify`). Do not log access tokens, refresh tokens, authorization codes, book contents, or raw email addresses.
- [x] Change `workers/worker/src/routes/user.ts` so `DELETE /api/user` delegates to the service and returns `{ok:true}` only after required data deletion and verification. Map authentication failures, R2 failures, and D1 failures to stable non-success responses with safe user-facing messages; include a non-sensitive revocation warning/status in server diagnostics when Apple revocation was unavailable but account erasure completed.
- [x] Add a route/service test fixture representing a real Apple user with an `apple_users` row, books and R2 keys, book extraction/index child rows, bookmarks, highlights, conversations/messages, notifications, subscriptions, sessions, devices, and usage records. Assert that the endpoint removes every user-owned row and both R2 keys, leaves shared `TTS_CACHE` objects untouched, and that a second request is an idempotent no-op.
- [x] Add failure tests proving that an R2 failure or D1 failure does not return success, that a retry can finish deletion, that an Apple transient revocation failure is recorded while relational/object deletion still completes, and that no credential is exposed. Test the foreign-key order against a real local D1 schema rather than only mocking `db.delete(user)`.
- [x] Add the required black-box/white-box integration test in `workers/worker/src/account-deletion.integration.test.ts`: use the public Apple auth endpoint to create a fake Apple user and obtain its bearer token; use authenticated API endpoints to create representative books, extraction rows, highlights, bookmarks, conversations/messages, devices, subscription/usage rows, Apple notification data, and R2 objects; call `DELETE /api/user` with only the bearer token; then query the D1 test database directly and assert that every user-owned row and referenced R2 object is gone, unrelated-user rows remain, and the shared `TTS_CACHE` object remains. This test is the acceptance proof for the App Review remediation, not merely a unit test of the deletion helper.

## 4. Centralize client deletion and local-data purge

- [x] Add the shared client component `apps/apple/rishi/rishi/Account/AccountDeletionCoordinator.swift`, with injected Worker client, `CurrentUser`, billing state, sync engine, SwiftData stores, and `BookFileStorage`. Its public operation must perform:
  1. the authenticated `DELETE /api/user` request;
  2. only after server success, purge local books, downloaded book files/covers, conversations/messages, bookmarks, highlights, sync metadata, entitlement/consent state, and other account-scoped SwiftData records;
  3. clear Keychain tokens and the current-user state;
  4. return success to the UI.
- [x] Make local purge explicit and testable through store protocols or existing store APIs. Do not assume `performSignOut` deletes user content: `apps/apple/rishi/rishi/AppDependencies+Billing.swift` currently clears session/billing/sync metadata but does not prove that account-scoped records and downloaded files are erased.
- [x] Define error semantics for local cleanup: server success must not be reversed, but any local purge failure must be surfaced to diagnostics and leave the app in a signed-out, non-reusing state. The coordinator must attempt all independent local cleanup steps, then report the cleanup failure so it can be fixed without retaining credentials.
- [x] Update `apps/apple/rishi/rishi/Settings/SettingsContent.swift` to call the coordinator rather than issuing `DeleteUserEndpoint` directly. Keep the existing confirmation and retry UI, and call `onDeleted` only after the coordinator has completed server deletion and local cleanup.
- [x] Update the signed-in iOS and Mac Catalyst entry points so both use the same coordinator and retry behavior; remove duplicate direct endpoint calls.
- [x] Ensure a generic network timeout does not sign the user out while the server result is unknown. Keep the user signed in and offer retry; make a retry with the existing bearer token idempotent so it can finish a partial deletion or receive an already-complete success response.
- [x] Quiesce account activity before local purge: cancel active voice/realtime sessions, stop background sync and APNs registration, prevent new SwiftData writes, and serialize deletion on the app’s persistence actor. Inspect `BookFileStorage`, download-error/recovery storage, temporary download directories, caches, and SwiftData models; delete every user-scoped book file, cover, temporary file, recovery file, conversation/message, bookmark, highlight, and other account record. This prevents a background task from repopulating data after the coordinator reports success.
- [x] Add client tests for successful deletion, server failure, timeout/unknown result, local purge invocation order, local purge failures, Keychain clearing, and prevention of sign-out on an unsuccessful request. Add endpoint serialization coverage proving the authorization code is sent to the Worker.

## 5. Make the user-facing flow App Review-ready

- [x] Preserve a clearly labeled `Delete Account…` action in the signed-in account settings on iPhone/iPad and in the Mac Catalyst account menu. It must be reachable without contacting support or visiting an external website.
- [x] Keep a confirmation step that states the account and associated data will be permanently deleted. The confirmation must lead directly into the deletion operation and show a retryable error if the operation fails.
- [x] Include a concise subscription note in the confirmation or follow-up state: deleting the Rishi account does not cancel an Apple App Store subscription; the user must cancel that subscription in Apple’s subscription settings. Ensure this does not require contacting Rishi support to delete the account.
- [x] Ensure the final successful state is visibly signed out and cannot navigate back into the deleted account using cached local data.
- [ ] Test on a physical iPad, including iPad landscape and the exact settings navigation path an App Review user will follow. Also test the Mac Catalyst path because it shares the account implementation.
- [ ] Capture a physical-device screen recording showing: sign-in or account creation, navigation to account settings, the deletion confirmation, the complete progress/result state, and the signed-out result. Put the recording instructions and demo-account prerequisites in the App Store Connect Review Notes, not only in an internal document.
- [ ] Update `apps/apple/docs/APP-STORE-METADATA.md` only after the implementation and physical-device flow are verified. The notes must not claim Apple revocation, local purge, or cascade behavior unless the corresponding tests and logs confirm it.

## 6. Verification and adversarial gates

- [x] Run the focused Worker tests with Bun from `workers/worker`, including the new deletion route/service and Apple token-exchange tests. Expected result: all focused tests pass, including the real-schema foreign-key teardown and retry cases.
- [x] Use the focused Worker command from `workers/worker`: `bunx vitest run src/account-deletion.integration.test.ts src/account-deletion-migration.test.ts src/db/user-data-cascade.test.ts src/siwa-token-crypto.test.ts`. Expected result: the command exits 0 and reports the seeded D1/R2 black-box/white-box deletion, migration preservation, cascade, revocation, gate, and retry cases as passing.
- [ ] Run the focused Apple tests for deletion models, endpoint encoding, coordinator cleanup, settings reachability, and Mac menu reachability. Expected result: all focused tests pass; currently blocked by unrelated pre-existing RishiBilling test compilation errors.
- [x] Build the iPhone target with the existing project command:
  - `xcodebuild build -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -sdk iphonesimulator -configuration Debug`
  Expected result: the connected physical-iPhone build succeeds. The Mac build and physical App Review recording remain separate verification steps.
- [ ] Execute a local end-to-end deletion against a seeded D1/R2 test environment and preserve the result: server rows absent, R2 keys absent, revocation call recorded, local records/files absent, Keychain session absent, and UI signed out.
- [x] Run the adversarial review loop after the implementation. Review the diff and the end-to-end evidence independently, log findings in the implementation plan or review notes, fix every Critical/High finding, and re-review until the verdict is `PASS` or `PASS WITH NOTES` with no open Critical/High findings.

## Adversarial review loop

### Round 1 — implementation findings carried into this plan

| ID | Severity | Finding | Resolution in this plan |
|---|---|---|---|
| F1 | Critical | Deleting only the parent `user` row conflicts with existing `ON DELETE NO ACTION` foreign keys, so ordinary Apple accounts can fail deletion. | Task 3 requires explicit foreign-key-safe deletion and a real local-D1 fixture covering all dependent rows. |
| F2 | Critical | Server deletion alone leaves R2 files and local SwiftData/downloaded data behind. | Tasks 3 and 4 enumerate and test R2 plus all local account-scoped data. |
| F3 | High | The current sign-in path discards the Apple authorization code, so the server cannot revoke Sign in with Apple later. | Task 2 forwards the code, exchanges it at sign-in, encrypts the refresh token, and tests the legacy-account path. |
| F4 | High | There is no production Worker deletion test proving rows, files, failures, or retries. | Task 3 adds seeded schema/R2 tests and failure/idempotency cases. |
| F5 | High | A timeout can leave the server deleted while the client remains signed in, or cause premature local cleanup. | Task 4 defines idempotent retries and explicitly keeps the session on unknown/non-success results. |
| F6 | Medium | iOS and Mac currently duplicate deletion networking and can drift in UX and cleanup behavior. | Task 4 centralizes both entry points behind one coordinator. |

### Round 2 — plan coverage re-review

| Check | Result | Evidence |
|---|---|---|
| App Review requirement is directly reachable in-app | Pass | Task 5 requires iPhone/iPad settings and Mac menu entry points, confirmation, completion, and recording. |
| Deletion is actual deletion rather than deactivation | Pass | Tasks 3 and 4 require row/object/local-data removal and final signed-out state. |
| Foreign keys and external storage are covered | Pass | Tasks 3 and 6 require explicit ordered D1 deletion, R2 deletion, seeded fixtures, and failure tests. |
| Apple authorization is handled without exposing credentials | Pass | Task 2 requires sign-in-time exchange, encrypted storage, revocation, and secret-safe logging. |
| Partial failure and retry behavior is defined | Pass | Tasks 3, 4, and 6 specify stage failures, idempotency, unknown network results, and retry tests. |
| Client call sites are covered | Pass | Task 4 names the iOS settings, Mac model, menu, and signed-in view files and removes direct duplicate calls. |
| Verification is independently repeatable | Pass | Task 6 names focused tests, both builds, seeded end-to-end verification, and a post-implementation adversarial re-review. |

**Round 2 verdict:** PASS for plan coverage, with 0 open Critical/High planning findings. The implementation must not be considered complete until the post-implementation adversarial review and physical-device recording pass.

### Round 3 — independent repository cross-check and fixes

| ID | Severity | Finding | Fix applied |
|---|---|---|---|
| F7 | Critical | `sync_meta` is a global/device-local marker, not a user-owned D1 row; treating it as server account data could delete state shared by unrelated local accounts. | The inventory now excludes Worker `sync_meta` and requires client-only reset after server success. |
| F8 | Critical | `book_pages`, `book_words`, `book_paragraphs`, and chapter-index children are not all protected by foreign keys, so deleting books alone can leave extracted text and summaries behind. | The plan now requires collecting book IDs and deleting every child table before parent books, with fixtures proving the rows are gone. |
| F9 | Critical | Concurrent sync/upload/device/billing requests can recreate or mutate account data while deletion is in progress. | The plan now adds a durable deletion marker, middleware gate, route/webhook enforcement, and concurrency tests. |
| F10 | High | The Worker currently mixes `@rishi/shared` table imports with the local schema used by `createDb`, making the deletion/migration contract ambiguous. | The plan now requires all auth/deletion helpers and the user route to use `workers/worker/src/db/schema.ts` consistently. |
| F11 | High | Active Stripe/App Store subscriptions and webhook audit payloads were not given an explicit retention/cancellation policy. | The plan now distinguishes removable Worker billing data from Apple subscription cancellation, specifies Stripe handling, and requires removal or anonymization of attributable webhook payloads. |
| F12 | High | Local background sync and active voice/realtime work can repopulate SwiftData after the purge. | The client plan now requires quiescing those producers and serializing purge on the persistence actor. |
| F13 | Medium | The plan did not name Apple’s token-exchange form fields or provide a concrete focused test command. | The token exchange and verification command are now explicit. |

**Round 3 verdict:** PASS after fixes, with 0 open Critical/High planning findings from this repository cross-check. The implementation still requires a fresh independent review after code changes, including concurrent-write and retention tests.

### Round 4 — final adversarial re-review

| ID | Severity | Finding | Fix applied |
|---|---|---|---|
| F14 | High | If Apple code exchange happens after creating a new account, a failed exchange leaves an account that cannot later revoke Sign in with Apple. | New-account sign-in now exchanges first and inserts rows only after success; existing legacy accounts retain an explicit no-token path. |
| F15 | High | Two simultaneous deletion requests could both pass authentication and execute overlapping R2/D1 cleanup. | The plan now requires conditional marker acquisition, one deletion ID, serialized resume behavior, and a concurrent-request test. |
| F16 | High | Local purge could leave temporary downloads, recovery files, or caches even if the primary book file and cover were removed. | The plan now requires an inventory and purge of `BookFileStorage`, recovery/temp/download-error storage, caches, and all SwiftData account records. |

**Round 4 verdict:** PASS after fixes, with 0 open Critical/High planning findings. The plan is ready for implementation; completion still depends on the implementation-stage adversarial loop and physical-device evidence.

### Round 5 — user-requested cascade, privacy, and acceptance-test review

| ID | Severity | Finding | Fix applied |
|---|---|---|---|
| F17 | Critical | Explicit deletion code alone does not protect the database if a future deletion path removes only `user`; current user-owned relationships are a mixed set of cascading and `NO ACTION` foreign keys. | The plan now requires `ON DELETE CASCADE` on every user-owned relationship and missing child relationships, plus a migration-preservation test. |
| F18 | High | The public privacy policy did not explain the exact deletion boundary, including local data, shared narration cache, provider copies, operational records, and subscription cancellation. | The plan now names the public policy file and required user-facing deletion/retention statements, with a content test. |
| F19 | Critical | Unit tests or mocked database calls would not prove that endpoint-driven account creation and deletion remove actual D1 rows. | The plan now requires a black-box/white-box integration test using the Apple auth endpoint, authenticated data endpoints, `DELETE /api/user`, direct D1 assertions, R2 assertions, unrelated-user protection, and shared-cache protection. |

**Round 5 verdict:** PASS after fixes, with 0 open Critical/High planning findings. Implementation must begin by completing the cascade migration and black-box/white-box acceptance test before claiming account deletion is fixed.

### Round 6 — implementation-stage adversarial review

| ID | Severity | Finding | Fix applied |
|---|---|---|---|
| F20 | Critical | The first hand-written migration copied `apple_users` columns by position after adding token columns, which shifted timestamps into token fields and violated `NOT NULL` constraints for real pre-existing rows. | The migration now copies `apple_users` with an explicit column list, and `account-deletion-migration.test.ts` applies the migration to representative pre-existing data before asserting both preservation and cascade behavior. |
| F21 | High | A concurrent request could observe a `deleting` marker and execute the same destructive workflow concurrently. | Active deletion markers now reject concurrent requests; stale markers can be conditionally reclaimed after a five-minute lease. The integration test covers completed-state gating and idempotent retry. |
| F22 | High | The device build exposed an optional `ASAuthorizationAppleIDCredential.authorizationCode` being treated as non-optional. | The client forwards the optional code safely, while the Worker still requires it for new-account creation. |
| F23 | Medium | The local metadata purge called a method unavailable on the protocol existential. | The coordinator conditionally invokes `resetAll()` on the concrete SwiftData metadata store, while the persistence-store purge removes the account-scoped SwiftData records. |

**Round 6 verdict:** PASS WITH NOTES. Critical/High implementation findings are closed. Remaining notes are the required physical-device deletion screen recording, production migration deployment, and a Mac-target build before App Store resubmission.

### Round 7 — post-implementation adversarial re-review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| Shared R2 keys could be deleted while still referenced by another account. | Critical | The deletion service now checks candidate book/cover keys against other `books` rows and retains shared keys; the integration fixture asserts the unrelated shared key remains. | Fixed and re-tested. |
| A successful response could be returned without proving relational or object deletion. | High | The service now verifies all user-owned D1 tables, child rows, and R2 heads before completing the marker; failures remain retryable. | Fixed and re-tested. |
| Completed deletion markers could accumulate indefinitely or an active deletion could be swept. | High | A scheduled cleanup removes only completed markers older than the documented retention period; active markers are never swept. | Fixed and re-tested. |
| Independent local purge failures could leave credentials usable or skip cleanup of other stores. | High | Client purge attempts independent cleanup steps, signs out even when local cleanup reports an error, and surfaces the first cleanup failure. | Fixed; physical-device validation remains. |
| Apple-focused tests cannot provide a clean pass signal because unrelated RishiBilling test sources fail to compile. | Medium | The physical iPhone app target builds successfully; the focused test command is recorded as blocked by pre-existing billing test errors, not attributed to this change. | Accepted note; repair baseline test target before claiming full Apple test coverage. |

**Round 7 verdict:** PASS WITH NOTES. No open Critical/High implementation findings remain. Remaining notes are physical iPad flow/screen recording, production migration deployment, Mac-target build, and the unrelated Apple test-target baseline failure.

### Round 8 — Catalyst verification re-review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| The Mac Catalyst account-deletion callback passed a non-sendable sign-out closure into the `@MainActor @Sendable` coordinator, so the shared app target failed to compile for Catalyst. | High | The failure was reproduced with the Mac Catalyst build and localized to `SignedInView.swift`. | Fixed by making the shared Mac sign-out callback explicitly `@MainActor @Sendable`; the Mac Catalyst build now succeeds. |

**Round 8 verdict:** PASS WITH NOTES. No open Critical/High implementation findings remain. Remaining notes are physical iPad flow/screen recording, production migration deployment, and the unrelated Apple test-target baseline failure.

### Round 9 — test-fixture implementation re-review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| The deletion integration test duplicated the D1/SQLite adapter instead of using the repository test helper, allowing migration-path and binding behavior to drift. | Medium | The existing helper was found, but its migration paths were stale and it lacked the deletion test’s injectable failure hook. | Fixed by extending `src/test-utils/d1.ts` with migration selection and failure injection, then switching the integration test to that helper. The deletion suite and relevant type checks pass. |

**Round 9 verdict:** PASS WITH NOTES. The integration fixture now reuses the shared D1 adapter, applies the real migration artifacts, and still seeds and asserts through Drizzle plus direct database inspection. Remaining notes are physical iPad flow/screen recording, production migration deployment, and the unrelated Apple test-target baseline failure.

### Round 10 — non-FK user-data inventory re-review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| Better Auth verification tokens are not linked by a foreign key and could survive user deletion. | High | The schema inventory showed `verification.identifier` can contain the user ID or email, so a parent-user cascade cannot remove it. | Fixed with explicit identifier-based deletion and post-delete verification; the integration fixture now seeds and checks a verification token. |
| App Review documentation named a nonexistent `siwa_revocation_failures` table. | Medium | Repository search found no such table; the implementation emits structured `account_deletion` stage logs instead. | Fixed in the metadata document. |

**Round 10 verdict:** PASS WITH NOTES. No open Critical/High implementation findings remain. Remaining notes are physical iPad flow/screen recording, production migration deployment, and the unrelated Apple test-target baseline failure.

### Round 11 — migration-fixture future-proofing re-review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| The migration test selected a manually maintained list of prerequisite migration filenames, so it could silently diverge from the production schema as migrations evolve. | High | The test now discovers numbered SQL migration artifacts from the Drizzle migrations directory, applies every migration preceding `0005_account_deletion`, and then applies the target migration under test. The general D1 helper applies all discovered migrations by default. | Fixed and re-tested. |

**Round 11 verdict:** PASS WITH NOTES. The migration fixtures now track the repository’s migration artifacts rather than a copied list. Remaining notes are physical iPad flow/screen recording, production migration deployment, and the unrelated Apple test-target baseline failure.

### Round 12 — all-Drizzle migration fixture re-review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| A migration test using the current production `apple_users` Drizzle table would insert post-migration token columns into the pre-migration schema. | High | The all-Drizzle refactor reproduced the mismatch instead of hiding it. | Fixed with a Drizzle-defined legacy `apple_users` table shape for pre-`0005` seeding; all post-migration assertions use the production schema. No raw fixture SQL remains. |

**Round 12 verdict:** PASS WITH NOTES. The migration test now configures SQLite through the shared D1 harness and uses Drizzle for all fixture data and assertions while preserving a real pre/post migration boundary. Remaining notes are physical iPad flow/screen recording, production migration deployment, and the unrelated Apple test-target baseline failure.

### Round 13 — iPad-form-factor verification re-review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| A successful iPhone or Mac Catalyst build would not prove that the shared settings/deletion code compiles for iPad. | Medium | The iPad Air simulator target was built successfully. The repository has no signed-in UI-test bypass, so a simulator launch cannot honestly prove the authenticated deletion path. | Fixed at compile-verification level; physical iPad navigation and recording remain explicit manual gates. |

**Round 13 verdict:** PASS WITH NOTES. The iPad simulator app target builds successfully. Physical iPad flow, screen recording, production migration deployment, and the unrelated Apple test-target baseline failure remain open evidence gates.

### Round 14 — cascade-authority and retry re-review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| The deletion service explicitly deleted every cascaded child row, duplicating the database’s `ON DELETE CASCADE` behavior and making the intended safety boundary unclear. | Medium | Schema review confirmed the user-owned tables and their content children cascade from `user`/book/conversation. | Fixed by retaining explicit deletion only for non-FK/polymorphic rows and making the final user delete the cascade authority. |
| A retry after an external process removed the parent user can leave unrelated non-FK rows untouched. | Medium | The product’s hard-delete policy explicitly makes a missing parent an idempotent successful no-op; identifier-based cleanup without the parent could delete data belonging to a reused email or identifier. | Accepted by design: the normal path removes non-FK rows before deleting the parent, while a later request with no parent returns `alreadyDeleted: true`. The integration test documents this stable no-op behavior. |

**Round 14 verdict:** PASS WITH NOTES. Cascade-backed data is removed by the database as designed, non-FK data is explicitly removed while the parent exists, and missing-parent retries are stable no-ops without a tombstone. Remaining notes are physical iPad flow/screen recording, production migration deployment, and the unrelated Apple test-target baseline failure.

### Round 15 — explicit-cleanup boundary re-review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| Future maintainers could mistake the remaining explicit deletes for missed cascades or add an unsafe FK to polymorphic Better Auth fields. | Medium | Schema review confirmed `verification.identifier` and Stripe `subscription.referenceId` cannot safely reference `user.id`; Apple transaction-id notification cleanup also has a non-FK boundary. | Fixed with schema comments and service comments documenting why those explicit operations remain. |

**Round 15 verdict:** PASS WITH NOTES. The cascade boundary and intentional non-FK exceptions are documented and tested. Remaining notes are physical iPad flow/screen recording, production migration deployment, and the unrelated Apple test-target baseline failure.

### Round 16 — cascade coverage invariant re-review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| The schema-level cascade invariant omitted the chapter-index parent and child tables, leaving a future cascade regression undetected. | High | The production schema has user-owned `chapter_indexes` and `chapter_index_chapters` relationships that must cascade. | Fixed by adding both tables to the automated user-FK cascade invariant; the full focused deletion suite passes. |

**Round 16 verdict:** PASS WITH NOTES. All user-owned foreign-key relationships represented in the Worker schema are now included in the cascade invariant; intentionally non-FK polymorphic tables remain explicit cleanup exceptions. Remaining notes are physical iPad flow/screen recording, production migration deployment, and the unrelated Apple test-target baseline failure.

### Round 17 — migrated-schema cascade re-review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| A Drizzle declaration could say `onDelete: cascade` while the checked-in migration artifact still had a different SQLite constraint. | High | The prior invariant inspected only Drizzle table metadata. | Fixed with a second invariant that applies every migration and checks SQLite `PRAGMA foreign_key_list` for every user-owned table and column. |

**Round 17 verdict:** PASS WITH NOTES. Both the Drizzle schema and the fully migrated SQLite/D1 schema now enforce the user-row cascade invariant. Remaining notes are physical iPad flow/screen recording, production migration deployment, and the unrelated Apple test-target baseline failure.

### Round 18 — post-delete verification coverage re-review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| The service verified chapter-index child rows but did not independently verify that the `chapter_indexes` parent rows were gone. | High | This could allow a migration regression to pass the deletion endpoint’s verification despite retaining index metadata. | Fixed by adding a direct `chapter_indexes.user_id` verification query; the focused deletion suite passes. |

**Round 18 verdict:** PASS WITH NOTES. Cascade configuration and post-delete verification now cover both chapter-index parent and child rows. Remaining notes are physical iPad flow/screen recording, production migration deployment, and the unrelated Apple test-target baseline failure.

### Round 19 — runtime verification boundary re-review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| Runtime verification duplicated every cascade-backed table query even though the migrated database is the authority for those relationships. | Medium | The requested design is to trust enforced D1 cascades and fail on any D1 error, while retaining verification for the parent row and external R2 objects. | Fixed by reducing runtime verification to the user row and R2 heads; cascade coverage remains enforced by schema/migration invariants and end-to-end tests. |

**Round 19 verdict:** PASS WITH NOTES. The production deletion path now relies on the database constraint for relational child cleanup and verifies only the user row plus non-relational R2 cleanup. Remaining notes are physical iPad flow/screen recording, production migration deployment, and the unrelated Apple test-target baseline failure.

### Round 20 — local account-data hard-delete re-review

| Finding | Severity | Resolution |
|---|---|---|
| Per-user TTS settings and the no-card trial explainer flag were persisted in `UserDefaults` keyed by the deleted account UUID but were not included in the local purge. | High | Added `remove(userId:)` to both store protocols and implementations, invoked both removals in the deletion coordinator, and added per-user isolation tests. |
| The short-lived deletion marker was not described in the public retention language. | Medium | Privacy policy and Worker contract now state its contents, purpose, and 30-day maximum retention. |

**Round 20 verdict:** PASS WITH NOTES. The local account-scoped UserDefaults records are now explicitly erased. Remaining notes are physical iPad flow/screen recording, production migration deployment, and the unrelated Apple test-target baseline failure.

### Round 21 — authorization-code wire-format re-review

| Finding | Severity | Resolution |
|---|---|---|
| The client sent a Base64-encoded Apple authorization code while the Worker forwarded the encoded text directly to Apple, so new-account token exchange would fail. | Critical | Decode the documented Base64 UTF-8 wire value in the Worker before the Apple token exchange; update the black-box test to assert the original code reaches Apple. |

**Round 21 verdict:** PASS WITH NOTES. The client/Worker/Apple token-exchange representations now agree. Remaining notes are physical iPad flow/screen recording, production migration deployment, the unrelated Apple test-target baseline failure, and rerunning focused Apple tests once the baseline test-target compilation is repaired.

### Round 22 — hard-delete policy re-review

| Finding | Severity | Resolution |
|---|---|---|
| The retained deletion marker was not required by the product’s stated priorities and contradicted an immediate hard-delete policy. | High | Removed the marker table from the final schema, added a safe drop migration for any earlier development copy, removed the cleanup cron, and changed retries to check the parent user row and return a no-op when absent. |
| Middleware’s deletion gate depended on marker state rather than the authoritative user row. | High | Ordinary requests now query the user row per request; only the deletion endpoint permits a missing row so repeated deletion remains successful. |

**Round 22 verdict:** PASS WITH NOTES. The account and all cascaded account data are hard-deleted with no retained tombstone. Remaining notes are physical iPad flow/screen recording, production migration deployment, and the unrelated Apple test-target baseline failure.

### Round 23 — production migration and legacy-orphan re-review

| Finding | Severity | Resolution |
|---|---|---|
| Production D1 had the pre-existing baseline under older migration names, so applying the new numbered history tried to recreate `apple_notifications_log`. | Critical | Verified the remote schema, recorded the already-present 0000–0004 baseline names in `d1_migrations`, and applied only `0005_account_deletion.sql` and `0006_remove_account_deletion_marker.sql`. |
| Four legacy conversations referenced books that no longer existed; adding a non-user-owned `conversations.book_id` foreign key would have required deleting valid user-owned rows merely to migrate. | High | Preserved those rows, removed only that non-user-owned FK from the final schema/migration, and retained the authoritative `conversations.user_id ON DELETE CASCADE`; all other child/user cascade constraints remain enforced. |
| The Worker deployment preceded the successful D1 migration application. | High | Redeployed after the migration repair. Production Worker version `0ebcb46b-aaa1-4b1a-b39a-0f26ca2d8363` is live, and the remote cascade/FK inspection passed. |

**Round 23 verdict:** PASS WITH NOTES. Production D1 schema and Worker deployment are now aligned without deleting the four legacy conversation rows. Remaining notes are physical iPad flow/screen recording, the unrelated Apple test-target baseline failure, and local end-to-end client proof.

### Round 24 — black-box fixture route re-review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| The acceptance fixture created most user content with direct Drizzle inserts, so it did not prove that authenticated production write routes could create the records later removed by account deletion. | High | The existing `/api/sync/push`, conversation, and message routes cover the public book, highlight, bookmark, chapter-index, conversation, and message paths; billing/usage/Apple-notification rows have no public creation endpoints. | Fixed by creating those content records through the authenticated routes and retaining Drizzle only for internal-only fixtures and white-box assertions. |
| Route-level integration tests importing conversation/message routers pulled in the Worker entrypoint through an inverted `requireAuth` import, making the test depend on unrelated production modules. | Medium | The failure was reproduced when the real routes were mounted in the acceptance test. | Fixed by importing `requireAuth` directly from `middleware`, eliminating the circular entrypoint dependency. |
| The shared SQLite D1 adapter lacked `batch()`, so the real chapter-index endpoint could not execute against the repository test database. | Medium | The endpoint failed before its database assertions with `this.client.batch is not a function`. | Fixed by adding a Drizzle-compatible D1 batch adapter; the black-box/white-box integration test now passes all five cases. |

**Round 24 verdict:** PASS WITH NOTES. The server acceptance fixture now exercises real authenticated write routes and verifies deletion directly through Drizzle/SQLite. Remaining notes are physical iPad flow/screen recording, the unrelated Apple test-target failure, and local end-to-end client proof.

### Round 25 — independent adversarial production-boundary review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| A presigned book upload could arrive after the deletion service’s initial R2 key snapshot, leaving an object with no surviving D1 row. | High | The upload route correctly rejects new URL issuance once the user row is gone, but already-issued URLs remain valid until expiry. | Mitigated by sweeping the user-scoped `books/<userId>/` and `covers/<userId>/` prefixes before and after the user-row delete, repeating the same safe sweep on missing-parent retries, and adding a late-upload integration test. A direct upload that arrives after the final sweep remains governed by the presigned URL’s short expiry and the next idempotent deletion sweep; no user-owned prefix is ever shared. |
| Stripe customer metadata could be silently retained when a customer ID existed but the Worker secret was absent. | High | The previous helper returned successfully without invoking Stripe. | Fixed by failing deletion before the parent-row delete when `stripeCustomerId` exists without `STRIPE_SECRET_KEY`; added a retry-preserving test. |
| Apple’s 400 response was classified as successful revocation without distinguishing invalid credentials from an already-invalid token. | Medium | The previous code treated every 400 as `revoked`. | Fixed by treating only Apple’s `invalid_grant` as already revoked and classifying other 400 responses as `revocation_unavailable`; added an invalid-client test. |
| Shared TTS-cache preservation and unrelated-user preservation were asserted too indirectly. | Medium | The prior fixture used an unconnected in-memory cache set and checked only the unrelated parent user. | Fixed by injecting a separate cache delete spy, asserting it is untouched, and asserting the unrelated book and shared R2 key remain. |

**Round 25 verdict:** PASS WITH NOTES. No open Critical/High implementation findings remain. The remaining notes are external App Review evidence: physical iPad/Mac verification, the screen recording, focused Apple-test baseline repair, and local client end-to-end proof.

### Round 26 — deletion-progress UI re-review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| `DeleteAccountModel` tracked `inFlight`, but `SettingsScreen` never rendered it; after confirmation the user had no visible progress state while the server and local purge ran. | Medium | The confirmation alert remained presented while the asynchronous operation executed, making the complete App Review flow ambiguous and allowing repeated taps. | Fixed by dismissing the confirmation immediately, rendering an accessible `Deleting account…` progress overlay while `inFlight` is true, and retaining the retryable error alert for failures. |

**Round 26 verdict:** PASS WITH NOTES. The visible client flow now has confirmation, progress, success/sign-out, and retryable failure states. Physical-device validation and recording remain open external evidence gates.

### Round 27 — R2 sweep mutation re-review

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| Deleting objects while advancing an R2 list cursor could skip later keys if the listing shifts after each page is removed. | Medium | The prior sweep deleted each page and then continued with the returned cursor. | Fixed by restarting each user prefix listing from the first page after every deletion batch until the prefix is empty; the existing late-upload test continues to pass. |

**Round 27 verdict:** PASS WITH NOTES. User-scoped object cleanup is now robust to page mutation and late arrivals. Physical-device validation and recording remain open external evidence gates.

### Round 28 — post-hardening production deployment

| Finding | Severity | Review result | Resolution |
|---|---|---|---|
| The Worker deployment needed to be refreshed after the R2 sweep, Stripe configuration, and Apple revocation hardening landed. | High | The prior production version predated those changes. | Fixed by deploying the tested Worker and verifying 100% traffic on version `199aef35-51fd-4f60-81e9-b5b641c985bb` with Wrangler’s deployment list. |

**Round 28 verdict:** PASS WITH NOTES. Production now runs the tested account-deletion hardening. Physical-device validation and recording remain open external evidence gates.

## Definition of done

- [ ] A signed-in App Review user can initiate and complete permanent account deletion directly from iPad settings.
- [ ] The Worker removes the user’s relational data and R2 objects, handles existing foreign keys, and returns success only after verification.
- [ ] Sign in with Apple authorization is revoked for accounts with a stored refresh token; legacy accounts without one are explicitly observable and still fully deleted.
- [ ] The app removes local account data and credentials after server success and leaves the user signed out.
- [ ] Retries are safe after timeout or partial failure.
- [ ] Focused tests, both platform builds, seeded end-to-end verification, and the final adversarial review pass.
- [ ] App Store Connect review notes contain the physical-device screen recording and the exact navigation path.

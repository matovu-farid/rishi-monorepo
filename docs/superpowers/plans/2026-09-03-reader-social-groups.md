# Rishi Reader Social Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build persistent Reading Groups with rotating book cycles and automatically organized five-person-or-smaller voice Reading Sessions, while preserving the current Apple shared-reading transport and website-only copyright workflow.

**Architecture:** Add a group/cycle/membership domain to the primary Worker and D1, exposing new versioned `/api/v1/reading-groups/...` routes. Keep the existing Apple shared-reading voice, WebRTC, controller, progress, and book-preparation primitives as the session transport; group APIs decide who may enter which session. Add a small public website workflow for copyright reports and appeals, backed by a restricted review queue and exact-hash enforcement. Apple Debug and Release builds continue using the canonical production Worker and sharing endpoints.

**Tech Stack:** Cloudflare Worker, Hono, D1, Drizzle-generated migrations, Durable Objects for session coordination, SwiftUI/Swift Concurrency, existing LiveKit WebRTC mesh, existing Rishi library/book services, Next.js website, Sentry/structured logging, XCTest/Swift Testing, Bun worker commands.

---

## Scope decomposition

This is three independently testable workstreams:

1. **Group domain and session assignment:** Worker/D1 APIs, membership, cycles, automatic partitioning, notifications.
2. **Apple client:** group discovery, approval, session selection, automatic library save, and reuse of current voice/session transport.
3. **Website trust and safety:** copyright reports, appeals, review decisions, exact-hash blocklist, and policy pages.

Do not merge these into one unreviewed implementation batch. Each workstream must pass its own tests and adversarial review before the next dependent work begins.

## File map

### Worker and database

- Modify: `workers/worker/src/db/schema.ts` — Drizzle definitions for groups, admins, members, cycles, sessions, session members, notifications, copyright cases, and exact-hash blocks.
- Create: `workers/worker/src/services/reading-groups.ts` — transactional domain operations: create group, request/approve membership, choose book, assign sessions, leave/remove, and transition cycles.
- Create: `workers/worker/src/routes/reading-groups.ts` — authenticated `/api/v1/reading-groups` route family.
- Create: `workers/worker/src/services/copyright-enforcement.ts` — report state transitions, exact-hash block checks, link revocation, and post-session cleanup commands.
- Modify: `workers/worker/src/index.ts` — mount the versioned routes and preserve all legacy routes unchanged.
- Create or modify: `workers/worker/src/routes/reading-groups.test.ts` and `workers/worker/src/services/reading-groups.test.ts` — API and domain coverage.
- Create or modify: `workers/worker/src/routes/copyright-report.ts` and its tests if the website submits directly to the Worker.
- Generate: `workers/worker/drizzle/` migration artifacts with `bunx drizzle-kit generate --config=drizzle.config.ts`; never hand-author migration SQL.

### Apple client

- Create: `apps/apple/rishi/rishi/ReadingGroups/ReadingGroupModels.swift` — group, membership, cycle, assignment, and notification DTOs.
- Create: `apps/apple/rishi/rishi/ReadingGroups/ReadingGroupsAPI.swift` — typed `/api/v1/reading-groups` client using the existing Worker endpoint configuration and bearer-token refresh behavior.
- Create: `apps/apple/rishi/rishi/ReadingGroups/ReadingGroupsStore.swift` — account-scoped group list, pending requests, current cycle, and notification state.
- Create: `apps/apple/rishi/rishi/ReadingGroups/ReadingGroupsView.swift` — searchable public groups, private identifier/invite entry, membership status, and current cycle.
- Create: `apps/apple/rishi/rishi/ReadingGroups/ReadingGroupDetailView.swift` — member-visible group detail, current book, session assignment, schedules, and admin actions.
- Create: `apps/apple/rishi/rishi/ReadingGroups/ReadingGroupAdminView.swift` — approval queue, member removal, book selection, and session membership adjustment.
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingAPI.swift` — accept group/cycle/session context without changing existing legacy sharing contracts.
- Modify: `apps/apple/rishi/rishi/SharedReading/SessionBookService.swift` — make automatic save idempotent by user and exact content hash, reusing an existing library copy when present.
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingSessionView.swift` and `SharedReadingSessionCoordinator.swift` — show group/cycle/session context and reconcile controller departure/transfer behavior.
- Modify: `apps/apple/rishi/rishi/App/AppRouter.swift`, `Library/LibraryRootView.swift`, and `RootView.swift` — add group entry points and deep-link routing.
- Create or modify: `apps/apple/rishi/rishiTests/ReadingGroups/*.swift` — model, API, assignment, state, notification, and UI behavior tests.

### Website and policy

- Create: `apps/web/src/app/copyright-report/page.tsx` — public report form with verified email, work/material locator, evidence upload, and required statements.
- Create: `apps/web/src/app/copyright-appeal/page.tsx` — public appeal form using case/reference information and permission evidence.
- Create: `apps/web/src/app/copyright-report/confirmation/page.tsx` — neutral submission confirmation without exposing private case details.
- Create: `apps/web/src/lib/copyright-report-schema.ts` — shared server-side validation for report and appeal fields.
- Modify: the website footer/help/legal navigation — link to the report and appeal pages.
- Publish after counsel review: `docs/policies/2026-09-03-rishi-reader-social-rules-and-terms-draft.md` as the source for final public rules, not as a substitute for legal review.

## Data and API contract

Use Drizzle schema objects as the source of truth. The D1 domain should include:

- `reading_groups`: owner, name, visibility, age band, current cycle, timestamps, and lifecycle status.
- `reading_group_admins`: group/user relation and role.
- `reading_group_members`: requested/active/rejected/removed status, age band, and timestamps.
- `reading_cycles`: group, book, selected-by user, schedule defaults, status, and history timestamps.
- `reading_sessions`: cycle, capacity fixed at five, schedule, status, controller, and lifecycle timestamps.
- `reading_session_members`: one active session membership per user and cycle, with assignment source and timestamps.
- `reading_notifications`: account-scoped in-app notification records with optional push-delivery state.
- `copyright_cases`: report/appeal state, evidence references, review decision, and retention timestamps.
- `copyright_hash_blocks`: exact SHA-256 hash, status, source case, review state, and timestamps.

The Worker must enforce the invariants transactionally:

- Public group discovery returns only explicitly public groups.
- Membership approval is required for every public group.
- Only owners/admins may perform their documented operations.
- A group has one current cycle/book.
- A cycle may have many sessions, but each session has at most five members.
- A user has at most one active session membership per cycle.
- An exact blocked hash cannot be newly hosted or used to initialize a new session.
- Legacy unversioned APIs and existing `/v1` sharing behavior remain unchanged; new group APIs use `/api/v1`, and new session transport semantics use the versioned sharing transport required by the API-versioning policy.

Define and test these route families:

```text
GET    /api/v1/reading-groups?query=&visibility=public
POST   /api/v1/reading-groups
GET    /api/v1/reading-groups/:groupId
POST   /api/v1/reading-groups/:groupId/join-requests
POST   /api/v1/reading-groups/:groupId/members/:userId/approve
POST   /api/v1/reading-groups/:groupId/members/:userId/reject
DELETE /api/v1/reading-groups/:groupId/members/:userId
POST   /api/v1/reading-groups/:groupId/cycles
GET    /api/v1/reading-groups/:groupId/cycles/current
POST   /api/v1/reading-groups/:groupId/cycles/:cycleId/sessions/assign
PATCH  /api/v1/reading-groups/:groupId/sessions/:sessionId
POST   /api/v1/reading-groups/:groupId/sessions/:sessionId/join
POST   /api/v1/reading-groups/:groupId/sessions/:sessionId/leave
GET    /api/v1/notifications
```

Every mutation accepts an idempotency key where a retry could otherwise create a duplicate group, cycle, assignment, notification, or share operation.

## Task 1: Lock the domain invariants with tests

**Files:**

- Create: `workers/worker/src/services/reading-groups.test.ts`
- Create: `workers/worker/src/routes/reading-groups.test.ts`
- Test: existing Worker test configuration under `workers/worker`

- [ ] Write tests for public-only search, exact private identifiers, and mandatory approval.
- [ ] Write tests for owner/admin permissions and immediate member removal.
- [ ] Write tests for one current book, cycle history, and old-session closure when a new book is selected.
- [ ] Write tests for automatic five-person partitioning, member-selected sessions, overflow assignment, and one-session-per-member-per-cycle.
- [ ] Write tests for idempotent retries and duplicate exact-hash rejection.
- [ ] Run `bun test` from `workers/worker` and confirm the new tests fail for missing domain operations before implementation.

## Task 2: Add the Drizzle schema and Worker domain service

**Files:**

- Modify: `workers/worker/src/db/schema.ts`
- Create: `workers/worker/src/services/reading-groups.ts`
- Generate: `workers/worker/drizzle/` artifacts

- [ ] Add the tables and indexes required by the data contract, including unique constraints for active membership and exact hash blocks.
- [ ] Implement transactional group creation, join requests, approval/rejection, removal, cycle creation, session partitioning, assignment changes, and notifications using Drizzle only.
- [ ] Make assignment deterministic: preserve a member’s chosen session when it has capacity; otherwise select the earliest available session by creation time; create another session when all are full.
- [ ] Implement cycle transition so the previous cycle remains queryable, active old sessions stop accepting new members, and the new cycle is used for all new assignments.
- [ ] Generate migrations with `bunx drizzle-kit generate --config=drizzle.config.ts` from `workers/worker`.
- [ ] Run `bun test` and the repository’s D1 migration verification command, confirming the schema and generated migration metadata agree.

## Task 3: Mount versioned Worker routes and preserve compatibility

**Files:**

- Create: `workers/worker/src/routes/reading-groups.ts`
- Modify: `workers/worker/src/index.ts`
- Test: `workers/worker/src/routes/reading-groups.test.ts`

- [ ] Add authenticated `/api/v1/reading-groups` routes with explicit request/response schemas and stable error codes.
- [ ] Return actionable errors for full sessions, removed members, stale cycles, blocked hashes, unauthorized admin actions, and duplicate requests.
- [ ] Keep existing unversioned routes and the frozen legacy sharing protocol untouched.
- [ ] Add route tests for authentication, authorization, validation, idempotency, and response compatibility.
- [ ] Run `bun test` and `bun run typecheck` from `workers/worker`.

## Task 4: Implement website copyright reporting and appeals

**Files:**

- Create: `apps/web/src/app/copyright-report/page.tsx`
- Create: `apps/web/src/app/copyright-appeal/page.tsx`
- Create: `apps/web/src/app/copyright-report/confirmation/page.tsx`
- Create: `apps/web/src/lib/copyright-report-schema.ts`
- Create or modify: the website’s server route/client used to submit validated forms

- [ ] Build structured forms for corporate-owner/authorized-representative identity, work identification, Rishi locator, evidence, verified email, accuracy statement, and good-faith statement.
- [ ] Allow submissions without a Rishi account and verify the reporter’s email before review begins.
- [ ] Build the appeal form with a case reference and permission/license evidence.
- [ ] Store evidence behind restricted access and store only references in general operational logs.
- [ ] Implement report status transitions: submitted, under review, validated, rejected, appealed, restored, and closed.
- [ ] Implement exact SHA-256 block creation and link revocation only after validation; near matches must create a manual-review flag, never an automatic removal.
- [ ] Add tests for invalid evidence metadata, duplicate submissions, verified-email gating, exact-match enforcement, appeal restoration, and evidence retention cleanup.

## Task 5: Add Apple group APIs, models, and store

**Files:**

- Create: `apps/apple/rishi/rishi/ReadingGroups/ReadingGroupModels.swift`
- Create: `apps/apple/rishi/rishi/ReadingGroups/ReadingGroupsAPI.swift`
- Create: `apps/apple/rishi/rishi/ReadingGroups/ReadingGroupsStore.swift`
- Modify: the shared Apple endpoint/configuration path used by `SharedReadingAPI`

- [ ] Define Codable models matching the Worker contract, including stable error codes and membership/session states.
- [ ] Implement bearer authentication, refresh-on-401, request timeouts, retry classification, and structured logging using existing Apple networking conventions.
- [ ] Keep the production HTTP and sharing endpoints centralized; do not add local-worker or feature-specific endpoint overrides.
- [ ] Add idempotency keys to group creation, join requests, book picks, assignments, and notifications.
- [ ] Add Swift tests for decoding, auth refresh, timeout/error mapping, duplicate retry behavior, and blocked-hash responses.

## Task 6: Build the Apple group and admin surfaces

**Files:**

- Create: `apps/apple/rishi/rishi/ReadingGroups/ReadingGroupsView.swift`
- Create: `apps/apple/rishi/rishi/ReadingGroups/ReadingGroupDetailView.swift`
- Create: `apps/apple/rishi/rishi/ReadingGroups/ReadingGroupAdminView.swift`
- Modify: `apps/apple/rishi/rishi/App/AppRouter.swift`, `Library/LibraryRootView.swift`, and `RootView.swift`

- [ ] Add public-group search, exact private-group entry, invitation handling, request status, and approval-state presentation.
- [ ] Show pre-approval group information without exposing member/admin identities.
- [ ] Show the current book, cycle history, session assignment, per-session schedule, and session capacity.
- [ ] Add admin controls for approvals, removals, book selection from the admin library, session membership adjustment, and controller transfer.
- [ ] Add in-app notifications and optional push registration without email as a default.
- [ ] Add UI tests for the low-friction path: request → approval → automatic assignment → automatic library save → session join.

## Task 7: Integrate groups with existing Apple shared reading

**Files:**

- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingAPI.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/SessionBookService.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingSessionView.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingSessionCoordinator.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingMicrophonePolicy.swift` only if required by the existing voice rules
- Test: `apps/apple/rishi/rishiTests/SharedReading/` and new `apps/apple/rishi/rishiTests/ReadingGroups/`

- [ ] Pass group, cycle, and session identity into existing session admission without changing the established voice protocol.
- [ ] Make `SessionBookService` reuse an existing personal library copy when the exact content hash already exists, preventing duplicate books.
- [ ] Preserve automatic library saving when a member joins.
- [ ] Preserve five-person server enforcement and the Apple voice rules: open mics when appropriate, TTS gating, hold-to-talk, speaker floor, and TTS ducking.
- [ ] Reconcile the UI’s “automatic controller transfer” behavior with Worker behavior for controller departure, including host departure and reconnect grace.
- [ ] Add tests for session assignment, active-session joins, controller transfer, controller departure, reconnect, book hash mismatch, duplicate import, and blocked new-cycle initialization.

## Task 8: Notifications, observability, and operational controls

**Files:**

- Modify: Worker notification service and `workers/worker/src/index.ts` as needed
- Modify: `apps/apple/rishi/rishi/ReadingGroups/ReadingGroupsStore.swift`
- Modify: `apps/apple/docs/superpowers/specs/2026-08-31-shared-reading-observability-design.md` if the event catalog changes

- [ ] Emit structured events for group creation, join request, approval, rejection, assignment, cycle transition, session full, automatic save, hash block, appeal, restoration, and cleanup.
- [ ] Include correlation identifiers, group/cycle/session IDs, user IDs where permitted, error codes, and retryability; never log book contents or ownership evidence.
- [ ] Send production exceptions to Sentry without exposing private report evidence in breadcrumbs or event payloads.
- [ ] Add a restricted review audit trail for copyright decisions and hash-block changes.
- [ ] Add health/version checks and a runbook for the canonical production Worker and sharing Worker.

## Task 9: End-to-end verification and rollout

**Files:**

- Create or modify: Apple shared-reading integration/UI tests under `apps/apple/rishi/rishiTests/`
- Create or modify: Worker integration tests under `workers/worker`
- Create: a rollout checklist under `apps/apple/docs/superpowers/plans/` if the release needs a separate operational runbook

- [ ] Run Worker tests and typecheck with Bun from `workers/worker`.
- [ ] Run targeted Apple tests for group APIs, library deduplication, shared voice policy, controller transfer, and session assignment.
- [ ] Build the Apple app with the production endpoints and verify no `127.0.0.1:8787` endpoint is present in Debug or Release configuration.
- [ ] Test two distinct authenticated Apple accounts: one on iPhone 17 Pro and one on Mac Catalyst, with no duplicate app instances or unmanaged local Worker processes.
- [ ] Verify the end-to-end path: public search or invite → approval → assignment → automatic book save → voice session → synchronized reader state → session leave/rejoin.
- [ ] Verify a validated exact-hash claim blocks all Rishi-hosted matches, does not touch external copies, and prevents the next session while allowing an already-active session to finish.
- [ ] Roll out behind a server-side feature gate, inspect Sentry and structured events, and expand only after session-join, automatic-save, voice, and error rates are healthy.

## Adversarial review loop

Run an independent review at research, plan, and implementation stages. Record findings in the relevant GitHub planning issue and re-review until no Critical or High findings remain.

Required review checks:

- **Authorization:** public discovery must never reveal private groups; every group mutation must verify owner/admin/member role server-side.
- **Capacity:** concurrent join/assignment requests must not create a sixth participant or assign a user to two sessions for one cycle.
- **Compatibility:** existing legacy APIs and installed Apple clients must keep their contracts; new behavior uses explicit versions.
- **Book privacy:** automatic library save must be idempotent and must not duplicate a file already present by exact hash.
- **Voice safety:** controller and speaker-floor transitions must be server-authoritative and recover correctly after reconnects and controller departure.
- **Copyright enforcement:** only validated exact hashes trigger automatic global blocking; evidence and report contents must not leak into logs or ordinary user responses.
- **Age safety:** adult/minor session separation must be enforced by the Worker, not only by Apple UI filtering.
- **Failure recovery:** every network, book-preparation, save, assignment, and session transition failure must produce a user-visible retryable state and structured diagnostics.

Known contradictions already resolved in this plan:

- The old five-member group-wide cap is replaced by a larger group with five-member sessions.
- The old “one live session per group” statement is replaced by multiple sessions for the same current book.
- Earlier group-copy deletion language is narrowed: group/session access ends, while a personal library copy remains.
- The old three-person/Tauri design is superseded by the five-person Apple/Electron-era transport rules.

## Completion gate

Implementation is ready for release only when the product specification and rules draft have counsel review, all Critical/High adversarial findings are closed, the Worker and Apple tests pass, the two-account Apple smoke test succeeds, and the production endpoint/version audit confirms compatibility with installed clients.

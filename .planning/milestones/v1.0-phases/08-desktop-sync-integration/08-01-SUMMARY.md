---
phase: 08-desktop-sync-integration
plan: 01
subsystem: database
tags: [diesel, sqlite, migration, kysely, sync, uuid]

# Dependency graph
requires:
  - phase: 04-bidirectional-sync
    provides: shared Drizzle schema (books, highlights, conversations, messages, sync_meta)
provides:
  - Desktop SQLite schema with sync columns on books table
  - highlights, conversations, messages, sync_meta tables on desktop
  - UUID sync_id backfill for existing books on app startup
  - Kysely TypeScript interface matching migrated schema
affects: [08-02-PLAN, 08-03-PLAN]

# Tech tracking
tech-stack:
  added: []
  patterns: [diesel-migration-with-rust-backfill, sync-schema-parity-across-platforms]

key-files:
  created:
    - apps/main/src-tauri/migrations/2026-04-06-000000_add_sync_tables/up.sql
    - apps/main/src-tauri/migrations/2026-04-06-000000_add_sync_tables/down.sql
  modified:
    - apps/main/src-tauri/src/schema.rs
    - apps/main/src-tauri/src/models.rs
    - apps/main/src-tauri/src/sql.rs
    - apps/main/src-tauri/src/db.rs
    - apps/main/src/modules/kysley.ts

key-decisions:
  - "In-memory SQLite migration tests in db.rs (not separate test file) for access to embedded MIGRATIONS constant"
  - "Rust UUID backfill as safety net after SQL randomblob-based backfill in migration"
  - "Removed Kysely createTable calls since Diesel migrations now manage all schema"

patterns-established:
  - "Sync schema parity: desktop SQLite tables match mobile/D1 schema for bidirectional sync"
  - "Dual backfill: SQL migration does bulk backfill, Rust startup does safety-net check"

requirements-completed: [DSYNC-01]

# Metrics
duration: 8min
completed: 2026-04-06
---

# Phase 08 Plan 01: Desktop Sync Schema Migration Summary

**Diesel migration adds sync columns to books, creates highlights/conversations/messages/sync_meta tables, backfills UUIDs, and updates Kysely TS interface**

## Performance

- **Duration:** 8 min
- **Started:** 2026-04-06T12:35:50Z
- **Completed:** 2026-04-06T12:44:00Z
- **Tasks:** 2
- **Files modified:** 7

## Accomplishments
- Diesel migration adds 11 sync columns to existing books table and creates 4 new tables matching mobile/D1 schema
- UUID sync_id backfill runs both in SQL migration (randomblob) and as Rust startup safety net (uuid::Uuid::new_v4)
- Existing epub location values automatically copied to current_cfi column
- 5 in-memory migration tests verify all new columns and tables exist
- Kysely DB interface updated with all sync columns and new table types

## Task Commits

Each task was committed atomically:

1. **Task 1: Create Diesel migration and update Rust schema/models** - `2b2e958` (feat)
2. **Task 2: Update Kysely DB interface with sync tables and columns** - `7827ce5` (feat)

## Files Created/Modified
- `apps/main/src-tauri/migrations/2026-04-06-000000_add_sync_tables/up.sql` - Adds sync columns to books, creates highlights/conversations/messages/sync_meta tables
- `apps/main/src-tauri/migrations/2026-04-06-000000_add_sync_tables/down.sql` - Drops new tables (column drops not supported in SQLite)
- `apps/main/src-tauri/src/schema.rs` - Diesel table macros with sync columns and new tables
- `apps/main/src-tauri/src/models.rs` - Rust model structs with sync fields and new table models
- `apps/main/src-tauri/src/sql.rs` - Book/BookInsertable structs with sync fields, updated From impl
- `apps/main/src-tauri/src/db.rs` - backfill_sync_ids function, 5 migration tests
- `apps/main/src/modules/kysley.ts` - Kysely DB interface with sync columns and new table types

## Decisions Made
- Placed migration tests inside `db.rs` as `#[cfg(test)]` module rather than separate test file, because `embed_migrations!` constant is private to the module
- Added Rust-side UUID backfill as safety net after the SQL randomblob-based backfill in the migration
- Removed Kysely createTable calls for books and chunk_data since Diesel migrations now manage all schema creation

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed BookInsertable new fields as Option types**
- **Found during:** Task 1 (updating sql.rs)
- **Issue:** New sync fields on BookInsertable needed to be Option types so existing callers (save_book) don't need to provide them
- **Fix:** Made format, sync_version, is_dirty, is_deleted as Option<> on BookInsertable (they have SQL defaults)
- **Files modified:** apps/main/src-tauri/src/sql.rs
- **Verification:** cargo build succeeds, existing tests pass
- **Committed in:** 2b2e958 (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Auto-fix necessary for backward compatibility with existing book insertion code. No scope creep.

## Issues Encountered
- Pre-existing test infrastructure issue: sql::tests fail with "readonly database" when run alongside other test modules due to shared OnceLock<Pool> state. Not caused by this change, not in scope to fix.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Desktop SQLite schema now matches mobile/D1 for sync participation
- Ready for Plan 02 (sync engine) to implement push/pull against Worker API
- Kysely TS interface ready for frontend sync status UI

---
*Phase: 08-desktop-sync-integration*
*Completed: 2026-04-06*

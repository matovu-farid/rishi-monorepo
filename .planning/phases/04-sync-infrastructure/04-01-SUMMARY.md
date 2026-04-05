---
phase: 04-sync-infrastructure
plan: 01
subsystem: api, database, infra
tags: [drizzle, d1, r2, hono, cloudflare-workers, presigned-urls, aws4fetch, sync]

# Dependency graph
requires:
  - phase: 03-pdf-reader-file-management
    provides: "Mobile SQLite schema with books table, Worker with Hono + Clerk auth"
provides:
  - "Shared Drizzle schema package (@rishi/shared) with books table + sync columns"
  - "D1 database binding and R2 bucket binding on Worker"
  - "POST /api/sync/push and GET /api/sync/pull endpoints with JWT auth"
  - "POST /api/sync/upload-url and POST /api/sync/download-url presigned URL endpoints"
  - "createDb factory for D1 Drizzle instance"
  - "Sync types (PushRequest, PushResponse, PullResponse, UploadUrlRequest, etc.)"
affects: [04-02, 04-03, 05-reading-progress, 08-desktop-sync]

# Tech tracking
tech-stack:
  added: [drizzle-orm, drizzle-kit, aws4fetch, "@rishi/shared workspace package"]
  patterns: [shared-schema-package, d1-drizzle-factory, hono-sub-app-routes, presigned-url-with-aws4fetch, lww-conflict-resolution, filePath-coverPath-exclusion]

key-files:
  created:
    - packages/shared/package.json
    - packages/shared/src/schema.ts
    - packages/shared/src/sync-types.ts
    - packages/shared/src/index.ts
    - workers/worker/src/db/drizzle.ts
    - workers/worker/src/routes/sync.ts
    - workers/worker/src/routes/upload.ts
    - workers/worker/drizzle.config.ts
  modified:
    - workers/worker/package.json
    - workers/worker/wrangler.jsonc
    - workers/worker/src/index.ts
    - workers/worker/tsconfig.json

key-decisions:
  - "Shared schema in @rishi/shared workspace package for D1 and mobile SQLite parity"
  - "userId column added to books table for server-side multi-user scoping (null on mobile)"
  - "filePath and coverPath stripped from D1 upserts and pull responses to prevent path contamination"
  - "aws4fetch with signQuery:true for presigned URLs (no Content-Type in signed headers)"
  - "LWW conflict resolution based on updatedAt timestamp comparison"
  - "Global file dedup by fileHash across all users"

patterns-established:
  - "Shared schema: @rishi/shared exports Drizzle table definitions used by both Worker and mobile"
  - "Route sub-apps: Hono sub-apps in src/routes/ mounted via app.route() on main app"
  - "D1 factory: createDb(c.env.DB) returns typed Drizzle instance"
  - "Path exclusion: filePath/coverPath always stripped before D1 writes and after D1 reads"

requirements-completed: [SYNC-01, SYNC-02, SYNC-03]

# Metrics
duration: ~15min
completed: 2026-04-06
---

# Phase 4 Plan 1: Sync Infrastructure API Summary

**Shared Drizzle schema package with D1/R2 Worker bindings, sync push/pull endpoints with LWW conflict resolution, and presigned URL generation via aws4fetch**

## Performance

- **Duration:** ~15 min (across sessions with checkpoint)
- **Started:** 2026-04-06
- **Completed:** 2026-04-06
- **Tasks:** 3 (2 auto + 1 checkpoint verification)
- **Files modified:** 16

## Accomplishments
- Created `@rishi/shared` workspace package with Drizzle schema defining books table with sync columns (syncVersion, isDirty, isDeleted, userId, fileHash, fileR2Key, coverR2Key)
- Implemented sync push/pull Worker endpoints with LWW conflict resolution, userId scoping, and filePath/coverPath exclusion from D1
- Implemented presigned URL endpoints for R2 upload/download using aws4fetch with global file deduplication by content hash
- Configured Worker with D1 database binding (rishi-sync) and R2 bucket binding (rishi-books)

## Task Commits

Each task was committed atomically:

1. **Task 1: Create shared schema package and Worker D1/R2 setup** - `343d0c3` (feat)
2. **Task 2: Implement sync push/pull and presigned URL Worker routes** - `9752963` (feat)
3. **Task 3: Verify D1/R2 creation and Worker deployment** - checkpoint:human-verify (user approved)

Additional: `9d3f906` (chore) - shared package lockfile and gitignore

## Files Created/Modified
- `packages/shared/package.json` - Shared schema package definition with drizzle-orm dependency
- `packages/shared/src/schema.ts` - Drizzle sqliteTable definitions for books (with sync columns) and syncMeta
- `packages/shared/src/sync-types.ts` - TypeScript interfaces for push/pull/upload/download request/response
- `packages/shared/src/index.ts` - Re-exports from schema and sync-types
- `packages/shared/tsconfig.json` - TypeScript config for shared package
- `workers/worker/src/db/drizzle.ts` - D1 Drizzle instance factory (createDb)
- `workers/worker/src/routes/sync.ts` - POST /push and GET /pull sync endpoints with JWT auth
- `workers/worker/src/routes/upload.ts` - POST /upload-url and POST /download-url presigned URL endpoints
- `workers/worker/drizzle.config.ts` - Drizzle Kit config for D1 migrations
- `workers/worker/wrangler.jsonc` - Added D1 and R2 bindings, nodejs_compat flag
- `workers/worker/src/index.ts` - Extended CloudflareBindings, mounted sync and upload route sub-apps
- `workers/worker/package.json` - Added drizzle-orm, aws4fetch, @rishi/shared dependencies
- `workers/worker/tsconfig.json` - Updated for shared package references

## Decisions Made
- Used `@rishi/shared` as a workspace package so both Worker and mobile can import the same Drizzle schema definitions
- Added `userId` column to books table -- null on mobile (single-user device), populated by server during push for multi-user scoping
- filePath and coverPath are strictly excluded from D1 upserts and pull responses to prevent local path contamination across devices
- Used aws4fetch with `signQuery: true` for presigned URLs, avoiding Content-Type in signed headers (per research findings)
- LWW (Last Writer Wins) conflict resolution: server compares `updatedAt` timestamps, newer wins, older returned as conflict
- Global file deduplication by `fileHash` -- if any user already uploaded the same file, skip re-upload and reuse R2 key

## Deviations from Plan

None - plan executed exactly as written.

## User Setup Required

The following infrastructure was set up during the checkpoint verification (Task 3):
- D1 database `rishi-sync` created via `wrangler d1 create`
- R2 bucket `rishi-books` created via `wrangler r2 bucket create`
- R2 CORS policy configured for mobile presigned URL uploads
- R2 API token created with Object Read & Write permissions
- Worker secrets set: R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, CLOUDFLARE_ACCOUNT_ID
- D1 migration generated and applied locally

## Issues Encountered
None

## Next Phase Readiness
- Server-side sync API is complete and deployed -- ready for mobile sync engine (Plan 04-02)
- Shared schema package ready for mobile Drizzle migration (Plan 04-02)
- Presigned URL endpoints ready for file upload/download integration (Plan 04-03)
- D1 migration applied locally; remote migration needed before production use

## Self-Check: PASSED

All key files verified present. All task commits (343d0c3, 9752963) verified in git history.

---
*Phase: 04-sync-infrastructure*
*Completed: 2026-04-06*

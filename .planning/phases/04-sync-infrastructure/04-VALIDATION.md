---
phase: 04
slug: sync-infrastructure
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-04-06
---

# Phase 04 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Manual + integration tests via wrangler dev |
| **Config file** | none — Wave 0 installs |
| **Quick run command** | `cd workers/worker && npx wrangler dev` (then curl endpoints) |
| **Full suite command** | Manual E2E: import book on mobile -> verify sync -> check D1/R2 |
| **Estimated runtime** | ~120 seconds (manual) |

---

## Sampling Rate

- **After every task commit:** Run `cd workers/worker && npx wrangler dev` + curl tests for Worker plans; build mobile app for mobile plans
- **After every plan wave:** Full push/pull cycle test with mobile app
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 120 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 04-01-01 | 01 | 1 | SYNC-01, SYNC-02, SYNC-03 | integration | `cd /Users/faridmatovu/projects/rishi-monorepo && cat packages/shared/src/schema.ts \| grep -c "sqliteTable" && cat workers/worker/wrangler.jsonc \| grep -c "rishi-sync" && cat workers/worker/src/index.ts \| grep -c "D1Database"` | N/A | ⬜ pending |
| 04-01-02 | 01 | 1 | SYNC-03 | integration | `cd /Users/faridmatovu/projects/rishi-monorepo && grep -c "POST.*push\|GET.*pull" workers/worker/src/routes/sync.ts && grep -c "upload-url\|download-url" workers/worker/src/routes/upload.ts` | N/A | ⬜ pending |
| 04-01-03 | 01 | 1 | SYNC-01, SYNC-02 | checkpoint | Manual: create D1, R2, curl test endpoints | N/A | ⬜ pending |
| 04-02-01 | 02 | 2 | SYNC-07 | integration | `cd /Users/faridmatovu/projects/rishi-monorepo && grep -c "drizzle" apps/mobile/lib/db.ts && grep -c "isDirty\|is_dirty\|triggerSyncOnWrite" apps/mobile/lib/book-storage.ts` | N/A | ⬜ pending |
| 04-02-02 | 02 | 2 | SYNC-04 | integration | `cd /Users/faridmatovu/projects/rishi-monorepo && grep -c "async function sync\|async function push\|async function pull" apps/mobile/lib/sync/engine.ts && grep -c "startSyncTriggers\|triggerSyncOnWrite\|stopSyncTriggers" apps/mobile/lib/sync/triggers.ts` | N/A | ⬜ pending |
| 04-03-01 | 03 | 3 | SYNC-05 | integration | `cd /Users/faridmatovu/projects/rishi-monorepo && grep -c "hashBookFile\|uploadBookFile\|downloadBookFile" apps/mobile/lib/sync/file-sync.ts` | N/A | ⬜ pending |
| 04-03-02 | 03 | 3 | SYNC-05, SYNC-06 | integration | `cd /Users/faridmatovu/projects/rishi-monorepo && grep -c "hashBookFile\|uploadBookFile" apps/mobile/lib/file-import.ts && grep -c "getBookForReading\|downloadBookFile" apps/mobile/lib/book-storage.ts && grep -c "getBookForReading" apps/mobile/app/reader/\[id\].tsx apps/mobile/app/reader/pdf/\[id\].tsx` | N/A | ⬜ pending |
| 04-03-03 | 03 | 3 | SYNC-05, SYNC-06, SYNC-07 | checkpoint | Manual: import-sync-download E2E across devices | N/A | ⬜ pending |

*Status: ⬜ pending . ✅ green . ❌ red . ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `packages/shared/` — new package for shared Drizzle schema
- [ ] `workers/worker/drizzle.config.ts` — D1 migration config
- [ ] `apps/mobile/drizzle.config.ts` — Expo migration config
- [ ] `apps/mobile/babel.config.js` — add `babel-plugin-inline-import` for .sql files
- [ ] `apps/mobile/metro.config.js` — add 'sql' to source extensions
- [ ] D1 database creation: `npx wrangler d1 create rishi-sync`
- [ ] R2 bucket creation: `npx wrangler r2 bucket create rishi-books`
- [ ] R2 API token creation for presigned URLs (Cloudflare dashboard)
- [ ] R2 CORS configuration for mobile direct uploads

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Mobile syncs on foreground | SYNC-04 | Requires real AppState transitions | Toggle app to background and back, verify sync fires |
| Mobile syncs on write (debounced) | SYNC-04 | Requires inserting a book on device | Import book, wait 2s, check D1 for record |
| Mobile syncs periodically | SYNC-04 | Requires waiting 5 minutes | Leave app open, verify sync after 5 min |
| Book uploads to R2 on import | SYNC-05 | Requires real file import flow | Import book, check R2 bucket for object |
| Book downloads from R2 on demand | SYNC-06 | Requires second device or cleared data | Sign in on second device, open synced book |
| Offline local ops succeed | SYNC-07 | Requires airplane mode | Enable airplane mode, import book, verify in library |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 120s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** pending

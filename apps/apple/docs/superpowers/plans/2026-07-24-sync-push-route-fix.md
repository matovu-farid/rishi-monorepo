# Restore Production Sync Push Route

> **Status:** Implemented and deployed. Production smoke checks pass.

**Goal:** Make `POST /api/sync/push` available in production and prevent future deployments from silently shipping without it.

**Architecture:** The iOS client already uses the correct shared WorkerClient transport and `/api/sync/push` path. The Worker source declares the route, but production previously returned 404 only for this endpoint. The fix removes the sync route's circular auth import, deploys the current Worker, and adds a CI smoke gate requiring the route to reach authentication and return 401 without credentials.

**Tech Stack:** Cloudflare Workers, Hono, Bun, Vitest, Swift Package Manager, GitHub Actions.

## Changes

- `workers/worker/src/routes/sync.ts` imports `requireAuth` directly from `../middleware`.
- `workers/worker/src/routes/sync-push.test.ts` mocks the direct middleware and Worker DB schema seams; all 13 sync-push tests pass.
- `.github/workflows/deploy-worker.yml` probes five sync routes after deployment and fails unless each returns 401 without credentials.
- `apps/apple/docs/RUNBOOK-BILLING-WORKER.md` documents the `/api/sync/push` smoke command and 401/404 interpretation.

## Verification

- Worker focused suite: `bunx vitest run src/routes/sync-push.test.ts` — 13 passed.
- RishiSync package: `swift test` — 123 tests passed.
- Full Worker suite was attempted; 35 unrelated existing tests fail due current Cloudflare runtime/import and billing fixture issues.
- Production deployment succeeded with Worker version `32966583-637f-4ac6-8a9c-b7c38ccc02ad`.
- Production probes returned 401 for `/api/sync/push`, upload-url, download-url, changes, conversations, TTS, and voice.

## Adversarial review loop

Each round: review → log findings → update the implementation → re-review.

### Round 1 — Review

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | High | CI had no production route check, allowing a deployed 404 to recur. | Added post-deploy smoke checks requiring 401 for all sync routes. |
| 2 | High | Existing sync tests mocked `../index`; the direct middleware import made them hit real auth. | Updated mocks to `../middleware` and `../db/schema`; focused suite is green. |
| 3 | Medium | Sync auth import created a circular dependency through `index.ts`. | Import middleware directly. |

**Round 1 result:** Findings resolved; re-review required.

### Round 2 — Re-review

Independent review found no concrete spec or code-quality issues. Production probes confirmed `/api/sync/push` now returns 401 instead of 404 while regression endpoints remain reachable.

**Round 2 result:** PASS — 0 open Critical or High issues.

## Scope

- No iOS production code, database migration, or rollback was added.
- Existing unrelated Settings changes were preserved.
- The production sync route now reaches authentication; an authenticated device push is the remaining user-level confirmation.

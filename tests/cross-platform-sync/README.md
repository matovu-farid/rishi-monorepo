# tests/cross-platform-sync

End-to-end test that proves a book imported on **Electron desktop** shows up
on **mobile** after both clients sign in as the same Better-Auth user.

The desktop half is driven by Playwright. The mobile half is driven by Detox
(iOS Simulator only — Android parity is intentionally TODO).

## Prerequisites

| Tool | Version |
|------|---------|
| Node | 22.x (matches monorepo) |
| pnpm | 10.22.0 (pin per `project_pnpm_pin`) |
| Xcode | latest with iOS 26.2 simulator runtime |
| iPhone 17 simulator | booted before running |
| Cloudflare Wrangler | for the local worker |

The local worker MUST run with both:

```
ENABLE_TEST_AUTH=true
TEST_AUTH_SECRET=<some-value>
```

These gate the `POST /test/sign-in` and `DELETE /test/users/:email` routes that
the orchestrator uses to provision and tear down the throwaway test user. They
are **not** set in production — see `workers/worker/src/routes/test-auth.ts`.

## One-time setup

```sh
cd tests/cross-platform-sync
pnpm install
```

This pulls Playwright. Detox is already installed in `apps/mobile/` — the
orchestrator invokes the existing `apps/mobile/e2e:build` script.

## Running

### 1. Start the local worker

In a separate terminal:

```sh
cd workers/worker
ENABLE_TEST_AUTH=true TEST_AUTH_SECRET=devsecret \
  pnpm exec wrangler dev --port 8787
```

Confirm the test routes are gated correctly:

```sh
curl -s http://localhost:8787/test/sign-in  # → 404 (no header)
curl -s http://localhost:8787/test/sign-in -H 'X-Test-Auth-Secret: devsecret' \
     -H 'Content-Type: application/json' -d '{}'  # → 400 (gate passed, body missing)
```

### 2. Run the orchestrator

```sh
WORKER_URL=http://localhost:8787 \
  TEST_AUTH_SECRET=devsecret \
  pnpm --filter rishi-cross-platform-sync-tests run run
```

What you'll see:

```
[orchestrator] test email: test+sync-abcd1234@rishi.test
[orchestrator] worker:     http://localhost:8787
[orchestrator] signed in: userId=xxx
[orchestrator] === Desktop (Playwright) spec ===
[orchestrator] building electron with VITE_WORKER_URL=http://localhost:8787
... electron-vite build output ...
... playwright test output ...
[orchestrator] === Mobile (Detox) spec ===
[orchestrator] building mobile with EXPO_PUBLIC_WORKER_URL=http://localhost:8787
... detox build output ...
... detox test output ...
[orchestrator] ALL SPECS PASSED
[orchestrator] cleaning up test+sync-abcd1234@rishi.test ...
[orchestrator] cleanup: deleted=true
```

### Partial runs

```sh
pnpm --filter rishi-cross-platform-sync-tests run run -- --skip-mobile
pnpm --filter rishi-cross-platform-sync-tests run run -- --skip-desktop
pnpm --filter rishi-cross-platform-sync-tests run run -- --skip-cleanup
```

`--skip-cleanup` keeps the test user around — useful when debugging mobile-side
sync. Don't use this in CI; the worker has no scheduled GC for orphan users.

## Manual cleanup

If the orchestrator crashed and left a user behind, `.last-user.json` contains
the email + worker URL + secret. Tear it down with:

```sh
EMAIL=$(jq -r .email tests/cross-platform-sync/.last-user.json)
SECRET=$(jq -r .testAuthSecret tests/cross-platform-sync/.last-user.json)
URL=$(jq -r .workerUrl tests/cross-platform-sync/.last-user.json)
curl -X DELETE "$URL/test/users/$(printf %s "$EMAIL" | jq -sRr @uri)" \
  -H "X-Test-Auth-Secret: $SECRET"
```

## What the test proves

| Step | Where | Assertion |
|------|-------|-----------|
| Worker test-auth gate is open | orchestrator | `POST /test/sign-in` returned 200 |
| Electron renderer respects `VITE_WORKER_URL` | Playwright | `window.__RISHI_WORKER_URL__` matches |
| Electron main process accepts the injected session | Playwright | `window.api.auth.getSession()` returns the test user |
| Electron imports an EPUB + pushes it | Playwright | `GET /api/sync/pull` shows the book row with FIXTURE_TITLE |
| Mobile auth-store accepts the same session | Detox `set-session` bridge | App lands on `(tabs)` not `(auth)` |
| Mobile pulls + renders the desktop's book | Detox | `book-row-title` element with text=FIXTURE_TITLE appears |
| Cleanup is idempotent | orchestrator finally | `DELETE /test/users/:email` returns 200 then 404 |

## Files of interest

- `src/run.ts` — orchestrator
- `src/worker-client.ts` — `/test/sign-in` + `/test/users/:email` client
- `playwright/desktop-import.spec.ts` — desktop half
- `../../apps/mobile/e2e/cross-platform-sync.test.ts` — mobile half
- `fixtures/test-book.epub` — the book that round-trips

## Known limitations / blockers

- **Android**: not configured. Same `.detoxrc.js` gap as the existing mobile e2e
  suite — when Android parity work picks up, add an `android.emu.debug`
  configuration to `apps/mobile/.detoxrc.js`.
- **Worker URL is required**: the orchestrator does NOT default to the prod
  worker — that would risk creating real users in prod if `ENABLE_TEST_AUTH`
  were ever flipped on by accident. You must pass `WORKER_URL` explicitly.
- **Single-worker Detox**: Detox can only drive one simulator at a time, so the
  test is serial. Total runtime ~5-8 minutes from cold (most of it is the
  electron-builder rebuild and the iOS xcodebuild).

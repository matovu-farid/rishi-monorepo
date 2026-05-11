# Handover — Better Auth migration + Redis-polling desktop handoff

**Session ended:** 2026-05-10
**State:** code-complete and deployed to production. End-to-end user testing pending.

## TL;DR for the next agent

1. **Migration from Clerk to Better Auth is done**, deployed, and serving traffic. Worker, web app, and Electron desktop are all on Better Auth.
2. **Desktop ↔ web auth handoff just switched from custom URL scheme deep-links to Redis polling** (this commit: `f0a19bea`). The deep-link approach was abandoned because macOS Launch Services kept routing the click to a stale `/Applications/Rishi.app v1.3.21` instead of the running build.
3. The user has **not yet tested the end-to-end flow**. They saw a `Cannot find module '@electron-toolkit/utils'` from the stale installed app and asked for the polling rewrite right after.
4. **Phase 4 manual items** (App Store resubmission, Help-tab bug verification, MAS target config) are still pending.

## Current production state

| Component | URL | Notes |
|---|---|---|
| Worker | `https://api.fidexa.org` | Cloudflare Workers, custom domain auto-provisioned, all secrets set, Better Auth + magic-link + Google + passkey plugins |
| Web | `https://rishi.fidexa.org` | Next.js on Vercel, env minimised to `NEXT_PUBLIC_API_URL` + `SENTRY_AUTH_TOKEN` |
| Desktop | local builds only, no MAS deploy yet | Code at `apps/rishi-electron`, build via `pnpm run build:mac:debug` |
| D1 | `rishi-sync` | Better Auth tables (`user`, `session`, `account`, `verification`, `passkey`) live, all data tables empty |
| R2 | `rishi-books` | Empty bucket, no orphans |
| Redis | Upstash (UPSTASH_REDIS_REST_URL/TOKEN secrets on worker) | Used by `/desktop/start`, `/desktop/start/complete`, `/desktop/poll` |

## Auth flow as of this commit

```
Desktop                Worker                    Web app                Browser
   |                      |                         |                      |
   |--POST /desktop/start-→                         |                      |
   |  {code_challenge,    |                         |                      |
   |   mode, email?}      |                         |                      |
   |                      |--Redis SET state:<u>    |                      |
   |←--{state, web_url}---|                         |                      |
   |                      |                         |                      |
   |--shell.openExternal(web_url)----------------------------→ open browser|
   |                                                                       |
   |  poll loop (every 2s):                                                |
   |--POST /desktop/poll---→                                               |
   |  {state, verifier}    |                                               |
   |                       |--Redis GET result:<u>                         |
   |←--204 (still pending)-|                                               |
   |                                                                       |
   |  ... user signs in via magic-link or Google in browser ...            |
   |                                                                       |
   |                       ←-POST /desktop/start/complete--                |
   |                       |  {state}, session cookie                      |
   |                       |--Redis GET state, write result, DEL state     |
   |                       |--→ {ok: true}                                 |
   |                                                  ←-show "you can close"|
   |  next poll tick:                                                      |
   |--POST /desktop/poll---→                                               |
   |←--200 {session_token}-|                                               |
   |  writeSession() + focus window                                        |
```

PKCE prevents anyone who knows the `state` (e.g., from a hijacked URL) from claiming the session — the `code_verifier` only lives in the desktop's memory.

## Where everything lives

### Worker (`workers/worker/`)
- `src/auth.ts` — Better Auth instance with magic-link, Google, passkey plugins; Resend for email.
- `src/routes/desktop.ts` — `/start`, `/start/complete`, `/poll` (Redis-backed).
- `src/index.ts` — Hono app, mounts `/api/auth/*` (Better Auth), `/desktop/*`, `/api/sync`, etc. `requireAuth` middleware uses Better Auth `getSession`. Dev-bypass header preserved.
- `src/email-templates/magic-link.tsx` — React Email + Tailwind component, rendered to HTML at send time.
- `wrangler.jsonc` — KV `RISHI_DESKTOP_STATE` is allocated but **no longer used** (kept around in case we want to revert; can be removed safely).
- Secrets on prod: `BETTER_AUTH_SECRET`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `RESEND_API_KEY`, `UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN`, `OPENAI_API_KEY`, `DEEPGRAM_KEY`, `R2_*`.

### Web (`apps/web/`)
- `src/lib/auth-client.ts` — Better Auth React client with `magicLinkClient` + `passkeyClient`.
- `src/components/desktop-handoff-listener.tsx` — calls `/desktop/start/complete` and shows "Return to Rishi" banner. **No longer redirects to `rishi-electron://`**.
- `src/components/auth-buttons.tsx` — header sign-in / sign-out / email display.
- `src/app/sign-in/page.tsx` — magic-link primary, Google + Passkey buttons below.
- `src/app/settings/account/page.tsx` — sign-out + delete-account + add-passkey.
- `src/middleware.ts` — cookie-gate for `/settings/*` (no Clerk).
- Vercel env vars: `NEXT_PUBLIC_API_URL=https://api.fidexa.org` + `SENTRY_AUTH_TOKEN`.

### Desktop (`apps/rishi-electron/`)
- `src/main/auth/` — auth-service (polling orchestration), pkce, session-store (safeStorage), index (IPC handlers).
- `src/main/auth/deep-link.ts` — **deleted** in `f0a19bea`. If someone needs it back for a non-auth use case, recover from git history.
- `src/main/index.ts` — single-instance lock no longer parses `argv` for deep-links; just focuses the existing window.
- `src/preload/index.ts` — exposes `window.api.auth.{startMagicLink, startGoogle, getSession, signOut, deleteAccount, getToken, onSessionChange, isMacAppStore}`.
- `src/preload/types.ts` — `AuthApi` and `AuthUser` interfaces.
- `src/renderer/src/components/auth/SignInModal.tsx` — magic-link + Google (hidden when `process.mas`).
- `src/renderer/src/routes/settings/account.tsx` — sign-out + delete-account UI.
- `src/renderer/src/stores/authStore.ts` — Zustand, sourced from IPC.
- `src/renderer/src/hooks/useHydrateAuth.tsx` — hydrates from IPC + subscribes to `session-changed`.

### Shared schema (`packages/shared/src/schema.ts`)
- Existing data tables (`books`, `highlights`, `conversations`, `messages`, etc.) — `userId text("user_id")` is unconstrained; will hold Better Auth UUIDs going forward.
- Better Auth tables appended: `user`, `session`, `account`, `verification`, `passkey` — all standard Better Auth schema.

## What still needs doing

### Tested and working (verified in this session):
- ✅ Worker `/api/auth/ok` returns 200
- ✅ Worker `/desktop/start` returns state + web_url
- ✅ Worker `/desktop/poll` returns 204 for pending state, 410 for unknown
- ✅ Worker tsc clean (only pre-existing `embeddings.ts` errors remain)
- ✅ Web tsc clean
- ✅ Web sign-in page reachable at `https://rishi.fidexa.org/sign-in` (200)
- ✅ Desktop builds clean (`pnpm run build:mac:debug`)
- ✅ Desktop tests pass (318 tests, including new pkce.test.ts)
- ✅ Web tests pass (44)

### NOT tested end-to-end yet (next agent should):
- ⚠️ Real magic-link delivery via Resend (depends on `fidexa.org` DKIM/SPF/DMARC being green in Resend dashboard — **operator must verify before testing**)
- ⚠️ Click-link-in-email → web sign-in → handoff to desktop poll
- ⚠️ Google OAuth flow
- ⚠️ Passkey registration on settings page (Better Auth's `addPasskey` from `@better-auth/passkey/client`)
- ⚠️ Passkey sign-in (only verified the route exists; actual WebAuthn ceremony in browser context untested)
- ⚠️ `/api/text/completions` (AI chat) authentication after a real sign-in
- ⚠️ Sync flow with new Better Auth user IDs

### Pending operator action:
1. **Resend domain verification** — confirm `fidexa.org` shows green for SPF + DKIM + DMARC at https://resend.com/domains. Currently using key `re_N7WL...` from money-lending project; that key's account must own the verified `fidexa.org` sender.
2. **End-to-end test** the magic-link flow manually (open https://rishi.fidexa.org/sign-in in browser, enter email, click link, confirm signed in).
3. **End-to-end desktop test** — relaunch the rebuilt `dist/mac-arm64/Rishi.app/Contents/MacOS/Rishi` (or replace `/Applications/Rishi.app` first; old v1.3.21 is still installed and Launch Services may still route there for `open` commands). Sign in via magic link, confirm desktop polls and signs in.
4. **MAS target** — `electron-builder.yml` lacks a `mas` target config. Add `target: { target: 'mas' }` block + provisioning profile when ready for App Store resubmission.
5. **Help tab bug** (Apple guideline 2.1(a)) — code at `src/renderer/src/components/HelpMenu.tsx` looks fine on inspection (Radix DropdownMenu with proper Portal + z-50). Reproduce in actual MAS build before assuming it's still broken.
6. **App Store Connect resubmission** — manual; review notes template in spec doc.
7. **Old Clerk app** — still active at the `clerk.fidexa.org` tenant. Zero MAUs but you can delete the Clerk application whenever you want — no code dependency anymore.

### Cleanup nits the next agent could pick up if motivated:
- `wrangler.jsonc` has `RISHI_DESKTOP_STATE` KV namespace allocated but no code uses it. Remove from config + delete namespace.
- `apps/rishi-electron/src/main/auth/index.ts` — `registerAuthIpc` accepts `getMainWindow` parameter that's now unused (it was for the deep-link handler). Either remove the parameter or wire it back if there's a future use.
- `electron-builder.yml` is unchanged from the user's WIP commit — has the `notarize: true` setting that requires real Developer ID for `pnpm run build:mac` (production build). Debug build via `build:mac:debug` works ad-hoc signed.
- `embeddings.ts` typescript errors — pre-existing, not from this migration. Worth fixing eventually.
- `apps/web` previously had `bun.lockb` and `package-lock.json`; both removed in favor of `pnpm-lock.yaml`. CI should be updated if it expected the old layout.

## Commits worth knowing about

```
f0a19bea  feat(auth): switch desktop handoff from deep-links to Redis polling
16247637  chore: align deployed URLs (api.fidexa.org + rishi.fidexa.org)
30c0c13a  chore(worker): bind api.fidexa.org as custom domain
8a9d76f6  wip: snapshot of in-app OAuth attempt + debug build infra
```

The pre-`8a9d76f6` baseline is the last commit before any of this work started. To completely revert, `git reset --hard 5b67be96` (the version-bump that preceded the user's WIP changes).

## Spec + plan documents

- `docs/superpowers/specs/2026-05-09-better-auth-migration-design.md` — design spec (still valid, but the section describing the deep-link callback flow is now out of date; the architecture is Redis polling per `feedback_redis_polling_auth.md` memory).
- `docs/superpowers/plans/2026-05-09-better-auth-migration.md` — original 40-task implementation plan. All implementation tasks (1-36) marked complete. Tasks 37 (Help bug), 38 (e2e), 39 (MAS variant), 40 (App Store resubmit) are operator-pending.

## User preferences (memories) you should respect

- `feedback_redis_polling_auth.md` — Redis polling > deep-links for desktop OAuth (this is *the* architectural choice you should default to in the future)
- `feedback_email_templates.md` — react-email + Tailwind for transactional emails, not plain HTML
- `feedback_use_subagents.md` — always use subagents (Agent tool) for tasks
- `project_macos_mic_entitlements.md` — macOS voice chat needs signed builds for mic access

## Worker logs

Real-time tail in production: https://dash.cloudflare.com/?to=/:account/workers/services/view/rishi-worker

Or via wrangler:
```
cd workers/worker && pnpm wrangler tail
```

When the user reports a sign-in problem, this is the first thing to check.

## Quick verification commands

```bash
# Worker reachable + Better Auth mounted
curl https://api.fidexa.org/api/auth/ok
# → {"ok":true}

# Initiate a Google flow (no email needed for this mode)
curl -X POST https://api.fidexa.org/desktop/start \
  -H "Content-Type: application/json" \
  -d '{"code_challenge":"<43-char-base64url>","mode":"oauth-google"}'
# → {"state":"<uuid>","web_url":"https://rishi.fidexa.org/sign-in?login=true&provider=google&state=..."}

# Poll a non-existent state — should 410
curl -X POST https://api.fidexa.org/desktop/poll \
  -H "Content-Type: application/json" \
  -d '{"state":"00000000-0000-0000-0000-000000000000","code_verifier":"<43+ chars>"}'
# → {"error":"expired"}, status 410

# Web reachable
curl -o /dev/null -w "%{http_code}\n" https://rishi.fidexa.org/sign-in
# → 200
```

Generate a valid PKCE pair for manual testing:
```bash
VERIFIER=$(openssl rand -base64 32 | tr '/+' '_-' | tr -d '=' | head -c 43)
CHALLENGE=$(printf "%s" "$VERIFIER" | openssl dgst -sha256 -binary | base64 | tr '/+' '_-' | tr -d '=')
echo "verifier: $VERIFIER"
echo "challenge: $CHALLENGE"
```

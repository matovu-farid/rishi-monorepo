# Better Auth migration — design

**Status:** approved 2026-05-09
**Scope:** Replace Clerk with Better Auth across `workers/worker`, `apps/web`, and `apps/rishi-electron`. Tauri (`apps/main`) is being deprecated and is out of scope.

## Background

The Electron app's current Clerk integration hangs on the Google passkey screen because macOS refuses to surface the platform authenticator from a non-allowlisted app. The previously-attempted fix — embedded `BrowserWindow` popups for OAuth — is what triggered an App Store rejection (guideline 4: "user is taken to the default web browser"; guideline 4.8: SIWA missing/broken; guideline 5.1.1(v): no in-app account deletion).

The deeper issue: Clerk's `<SignIn>` UI library owns the auth ceremony in ways that make platform-native auth (ASWebAuthenticationSession, `ASAuthorizationController`) hard to plug in. Switching to Better Auth gives us:

- An API-first auth boundary we control end-to-end.
- Self-hosted on Cloudflare Workers (the existing `workers/worker`), no per-user pricing past 10K MAUs.
- Built-in passkey, organization, and SSO plugins for future expansion (no paid-tier upgrades required).
- A magic-link-primary flow that sidesteps platform-authenticator restrictions entirely.

## Decision summary

| Question | Decision |
|---|---|
| Auth provider | Better Auth, self-hosted on `workers/worker` |
| User migration | None — wipe Clerk, start fresh (zero/tiny user base) |
| Distribution targets | Mac App Store (MAS) **and** direct DMG |
| MAS sign-in methods | Magic link only |
| DMG sign-in methods | Magic link + Google |
| Apple SIWA | Not in v1 (deferred; would need native module) |
| Passkey | Not in v1 (spike after magic-link ships) |
| Email delivery | Resend (free tier: 3K emails/mo) |
| OAuth bridge for desktop | Web app + worker, PKCE flow (existing pattern) |
| Account deletion | In-app via `auth.api.deleteUser()` (Apple guideline 5.1.1(v)) |

## System architecture

Three components, each with a clear boundary:

### `workers/worker` — identity authority

Cloudflare Worker, Hono framework, D1 database. Hosts the Better Auth instance. Exposes:

- `GET|POST /auth/*` — Better Auth's mounted handler (sign-in, sign-out, OAuth callbacks, magic-link verification, session lookup, account deletion)
- `POST /desktop/start` — desktop sends `{ code_challenge, redirect_scheme, mode }`, returns `{ state, web_url }`. State stored in KV (5-min TTL).
- `POST /desktop/exchange` — desktop sends `{ code, code_verifier }`, returns `{ session_token }` after PKCE validation.
- `/sync/*`, `/upload/*` — existing routes, auth middleware swapped from `@hono/clerk-auth` to a Better Auth session middleware.

### `apps/web` — auth UX surface and OAuth bridge

Next.js. Already serves as the auth bridge for the desktop via PKCE; we keep that shape. New responsibilities:

- Better Auth Next.js client replaces `@clerk/nextjs`.
- Sign-in / sign-up pages built with shadcn (Better Auth doesn't ship UI; the codebase already uses Radix/shadcn).
- `DesktopHandoffListener` (replaces `ClerkListener`) — same logic: read `?login=true&state=...&code_challenge=...&redirect_scheme=...` from URL; after sign-in, mint an authorization code via `/desktop/start`, redirect to `${redirect_scheme}://auth/callback?code=...&state=...`.
- Magic-link verification page — Better Auth handles the email-link verification at `/api/auth/verify-magic-link?token=...`. After verification the user lands signed-in; if `?login=true&state=...` is present, the desktop handoff fires.
- Account settings page (`/settings/account`) with delete-account button.

### `apps/rishi-electron` — thin OAuth client

The desktop app holds zero auth UI complexity:

- All `@clerk/clerk-react` imports removed.
- New `src/main/auth/` module talks HTTP to the worker. No Better Auth import — the desktop is a pure OAuth client.
- Deep-link infrastructure restored (`rishi-electron://auth/callback` registration via `setAsDefaultProtocolClient`; `app.on('open-url')` for macOS; `second-instance` argv parsing for Windows/Linux).
- Session token stored in `safeStorage` (keychain on macOS, DPAPI on Windows, libsecret on Linux).
- Renderer reads session via `window.api.auth.getSession()`. Never sees the token directly.

## Data flows

### Magic-link sign-in (primary path on both MAS and DMG)

```
1. User types email in renderer, clicks "Continue"
2. Renderer → main: ipcInvoke('auth:start-magic-link', email)
3. Main:
   - generates PKCE pair (code_verifier, code_challenge)
   - POST /desktop/start { email, code_challenge, redirect_scheme: 'rishi-electron', mode: 'magic-link' }
   - worker stores { state -> code_challenge, email } in KV
   - worker calls Better Auth's signInMagicLink internally with callbackURL=app.fidexa.org/?login=true&state=<state>
   - worker returns { state }
4. Main: stores code_verifier in memory keyed by state
5. Renderer: shows "check your email" UI

6. User opens email, clicks link → opens browser to api.fidexa.org/api/auth/verify-magic-link?token=...
7. Worker: validates magic-link token, signs user in (sets session cookie), redirects to app.fidexa.org/?login=true&state=<state>
8. Web app: DesktopHandoffListener sees ?login=true&state, makes authenticated POST to /desktop/start/complete
   - worker verifies session, generates auth code, returns { code }
9. Web app: window.location = 'rishi-electron://auth/callback?code=<code>&state=<state>'
10. OS routes URL to Rishi.app:
    - macOS: app.on('open-url') fires
    - Windows/Linux: second-instance event fires with URL in argv
11. Main:
    - matches state, retrieves stored code_verifier
    - POST /desktop/exchange { code, code_verifier }
    - worker validates PKCE, returns Better Auth session token
    - main stores token in safeStorage, broadcasts session-changed
12. Renderer: useAuthStore.setUser(session.user), modal closes
```

### Google sign-in (DMG only)

```
1. User clicks "Sign in with Google" (button hidden when process.mas === true)
2. Renderer → main: ipcInvoke('auth:start-google')
3. Main:
   - generates PKCE pair
   - POST /desktop/start { code_challenge, redirect_scheme, mode: 'oauth-google' }
   - worker stores state, returns { web_url: 'app.fidexa.org/?login=true&google=1&state=<state>' }
4. Main: shell.openExternal(web_url)

5. User's browser opens app.fidexa.org/?login=true&google=1&state=<state>
6. Web app: middleware sees ?google=1, redirects to /api/auth/sign-in/social?provider=google&callbackURL=...
7. Better Auth redirects to Google OAuth
8. User authenticates with Google (passkey, password, whatever — works because real browser)
9. Google redirects to api.fidexa.org/api/auth/callback/google
10. Better Auth validates, creates session, redirects back to app.fidexa.org/?login=true&state=<state>
11. From here, identical to magic-link steps 8-12
```

### Existing protected routes (sync, upload)

```
1. Desktop reads session token from safeStorage
2. Attaches to outbound API requests as Authorization: Bearer <token>
3. Worker's sessionMiddleware calls auth.api.getSession({ headers })
4. If valid, sets user on Hono context; route handlers proceed
5. If invalid, returns 401; renderer treats as signed-out, prompts sign-in
```

## Better Auth configuration

`workers/worker/src/auth.ts` (new):

```ts
import { betterAuth } from "better-auth"
import { magicLink } from "better-auth/plugins"
import { drizzleAdapter } from "better-auth/adapters/drizzle"
import { db } from "./db"
import { Resend } from "resend"

export function createAuth(env: Env) {
  return betterAuth({
    database: drizzleAdapter(db, { provider: "sqlite" }),
    secret: env.BETTER_AUTH_SECRET,
    baseURL: env.PUBLIC_API_URL,
    trustedOrigins: [env.PUBLIC_WEB_URL, "rishi-electron://"],
    emailAndPassword: { enabled: false },
    socialProviders: {
      google: {
        clientId: env.GOOGLE_CLIENT_ID,
        clientSecret: env.GOOGLE_CLIENT_SECRET,
      },
    },
    user: {
      // Enables auth.api.deleteUser() — required for Apple guideline 5.1.1(v)
      deleteUser: { enabled: true },
    },
    plugins: [
      magicLink({
        sendMagicLink: async ({ email, url }) => {
          const resend = new Resend(env.RESEND_API_KEY)
          await resend.emails.send({
            from: "Rishi <auth@fidexa.org>",
            to: email,
            subject: "Sign in to Rishi",
            html: magicLinkEmailTemplate({ url }),
          })
        },
        expiresIn: 60 * 10,
      }),
    ],
    session: {
      expiresIn: 60 * 60 * 24 * 30,
      updateAge: 60 * 60 * 24,
    },
    advanced: { cookiePrefix: "rishi" },
  })
}
```

## Database schema

Better Auth provides standard tables (generated via `pnpm dlx @better-auth/cli generate`):

| Table | Purpose |
|---|---|
| `user` | Identity row (id, email, name, image, createdAt) |
| `session` | Active sessions (token, userId, expiresAt, ipAddress, userAgent) |
| `account` | OAuth provider links (userId, providerId, accountId, accessToken) |
| `verification` | Magic-link tokens, OAuth state, password reset tokens |

Existing app tables (`books`, `chunks`, `vectors`, etc.) remain unchanged. Foreign-key columns referencing `user.id` get added in a separate migration after Better Auth tables exist.

## Email setup

- Provider: **Resend** (3K emails/month free)
- Sender: `auth@fidexa.org` (DNS verification required: SPF, DKIM, DMARC records)
- Plain HTML magic-link template — owned in `workers/worker/src/email-templates/magic-link.ts`
- Bounces and complaints surface in Resend dashboard

## Secrets

New worker environment variables:

```
BETTER_AUTH_SECRET     # 32-byte random — `openssl rand -base64 32`
GOOGLE_CLIENT_ID       # Google Cloud Console OAuth 2.0 web client
GOOGLE_CLIENT_SECRET
RESEND_API_KEY
PUBLIC_API_URL         # https://api.fidexa.org
PUBLIC_WEB_URL         # https://app.fidexa.org
```

Removed:

```
CLERK_PUBLISHABLE_KEY
CLERK_SECRET_KEY
CLERK_WEBHOOK_SIGNING_SECRET   # if present
```

Same renaming applies to web app env vars (Vercel) and desktop's existing Clerk publishable key reference.

## Google OAuth client config

Google Cloud Console → OAuth 2.0 Web client:

- Authorized redirect URI: `https://api.fidexa.org/api/auth/callback/google`
- Authorized JavaScript origins: `https://app.fidexa.org`

The desktop never appears in Google's allowlist — it never talks to Google directly.

## Desktop file-by-file changes

### New files

- `src/main/auth/index.ts` — IPC handler registration
- `src/main/auth/auth-service.ts` — orchestration (start magic-link, start OAuth, handle callback, get/set/clear session)
- `src/main/auth/pkce.ts` — `generatePkcePair()` helper (pure, unit-testable)
- `src/main/auth/session-store.ts` — `safeStorage`-backed session token persistence
- `src/main/auth/deep-link.ts` — protocol registration + URL forwarding (restores removed code)

### Modified files

- `src/main/index.ts` — remove `setWindowOpenHandler` OAuth popup branch; restore `DEEP_LINK_PROTOCOL`; wire `setupDeepLinkHandler(authService.handleCallback)`
- `src/preload/index.ts` — expose `window.api.auth.*`
- `src/preload/types.ts` — add auth namespace types
- `src/renderer/src/components/auth/SignInModal.tsx` — full rewrite: email input + send button + "check your email" state + Google button (DMG only)
- `src/renderer/src/components/auth/WelcomeModal.tsx` — wire to new IPC
- `src/renderer/src/components/auth/SignInBanner.tsx` — wire to new IPC
- `src/renderer/src/components/auth/PremiumFeatureDialog.tsx` — wire to new IPC
- `src/renderer/src/hooks/useHydrateAuth.tsx` — replace Clerk session sync with `window.api.auth.getSession()` + `onSessionChange`
- `src/renderer/src/stores/authStore.ts` — remove `signingIn`, `signInOpen`; add `signInPending`
- `src/renderer/src/lib/api.ts` — fetch session token via IPC for outbound API calls
- `src/renderer/src/routes/__root.tsx` — remove `<ClerkAuthSync>` import and render
- `src/renderer/src/components/HelpMenu.tsx` — fix the bug Apple's reviewer hit (separate concern, bundled in this PR)
- `package.json` — remove `@clerk/clerk-react`

### Deleted files

- `src/renderer/src/components/auth/ClerkAuth.tsx` (and `ClerkAuthSync` references)

### New settings UI

- `src/renderer/src/routes/settings/account.tsx` (or equivalent) — sign out + delete account buttons (delete required by Apple guideline 5.1.1(v))

## Web app changes

### New / modified

- `src/lib/auth.ts` — Better Auth client instance for the Next.js app
- `src/middleware.ts` — replace `clerkMiddleware` with Better Auth session middleware
- `src/app/layout.tsx` — replace `<ClerkProvider>` with Better Auth's React provider
- `src/app/sign-in/page.tsx` — new, magic-link-primary, with optional Google button
- `src/app/sign-up/page.tsx` — new (or merged with sign-in since magic-link doesn't distinguish)
- `src/app/settings/account/page.tsx` — delete-account UI
- `src/components/desktop-handoff-listener.tsx` — replaces `clerk-listener.tsx`
- `src/components/clerk-listener.tsx` — delete
- `src/app/page.tsx`, `src/components/header.tsx` — remove `<SignedIn>`, `<SignedOut>`, `<UserButton>`, replace with Better Auth equivalents
- `package.json` — remove `@clerk/nextjs`, add `better-auth`

## Worker changes

### New / modified

- `src/auth.ts` — Better Auth instance (above)
- `src/db/schema.ts` — add Better Auth tables (via `@better-auth/cli generate`)
- `drizzle/` — new migrations
- `src/index.ts` — mount `/auth/*` Better Auth handler; add `/desktop/*` PKCE routes; replace `clerkMiddleware` with `sessionMiddleware`
- `src/routes/desktop.ts` — new, PKCE start/exchange endpoints
- `src/routes/sync.ts`, `src/routes/upload.ts` — update auth middleware imports
- `src/email-templates/magic-link.ts` — new, plain HTML template
- `wrangler.toml` — new env var bindings; KV namespace for desktop state storage
- `package.json` — remove `@clerk/backend`, `@hono/clerk-auth`; add `better-auth`, `resend`

## Risks and open questions

### Resend email deliverability

Magic-link UX depends on email arriving promptly. Risks:

- Corporate email filters classify as spam (especially first send from a new domain)
- DMARC misconfiguration causes inbox-tab "promotions" filing
- Resend free tier 100/day cap could throttle if abuse occurs

Mitigation: warm the domain by sending a few legitimate emails first, monitor Resend dashboard for spam complaints, document the troubleshooting flow in `setup.md`.

### Apple App Store resubmission

This design fixes the three rejection reasons (guideline 4 browser handoff, guideline 4.8 SIWA, guideline 5.1.1(v) account deletion) but Apple may surface new issues we can't predict. Have demo magic-link credentials ready in App Store Connect review notes; cite RFC 8252 and Better Auth's pattern in the response.

### PKCE state KV TTL

5-minute TTL is reasonable for typical magic-link delivery (most arrive in <30s). If a user's email is delayed >5min, they'll click a link that errors. Option: bump to 30 min once we have data on actual delivery times.

### Session token security on disk

`safeStorage.encryptString` on macOS uses keychain-backed encryption tied to user account. On Windows uses DPAPI. On Linux requires libsecret (most distros have it). Failure modes:

- Linux without libsecret: tokens stored in plaintext (Electron's documented fallback). We'll detect and warn.
- macOS keychain reset (rare): user is signed out, no harm.

### Rate limiting

Better Auth's built-in rate limiter handles per-IP magic-link spam. Set `rateLimit: { window: 60, max: 5 }` so a single email can request at most 5 links per minute.

### Future: passkey

Once magic-link ships and we have a stable auth boundary, add `@better-auth/passkey` plugin. The desktop's WebAuthn surface for first-party passkeys (relying party = `app.fidexa.org`, not a third party) needs a small spike — uncertain whether Touch ID surfaces cleanly in a signed/notarized Electron renderer. Test before designing UX around it.

### Future: Apple SIWA

Adding SIWA later requires native ASAuthorizationController integration via a small Objective-C++ NAPI module. Not blocking v1.

## Out of scope

- Migration of existing Clerk users (we have zero / tiny user base)
- Apple SIWA (deferred)
- Passkey (deferred)
- Tauri app (`apps/main`) — being deprecated
- Mobile app (`apps/mobile`) — separate auth track if it exists
- Organizations / teams (Better Auth supports it; not needed v1)
- Two-factor / TOTP (deferred)

## What we need from the operator

Before development starts:

- Resend account + verified `fidexa.org` sender domain (~15 min, DNS edits)
- Google Cloud OAuth 2.0 Web client (~5 min)
- D1 database confirmed accessible (already exists from current worker)
- Cloudflare KV namespace for desktop state (~2 min in Cloudflare dashboard)
- App Store Connect review notes draft (separate work)

A `setup.md` in `workers/worker/` will document each step.

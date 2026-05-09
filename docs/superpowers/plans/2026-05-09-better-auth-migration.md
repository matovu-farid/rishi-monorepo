# Better Auth Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Clerk with self-hosted Better Auth across `workers/worker`, `apps/web`, and `apps/rishi-electron`. Magic-link primary, Google on DMG only, PKCE handoff via web app. Wipe existing Clerk users (zero/tiny user base).

**Architecture:** The worker hosts Better Auth + custom `/desktop/*` PKCE endpoints. The web app (Next.js) is the auth UI surface and OAuth bridge. The desktop is a thin OAuth client — opens browser via `shell.openExternal`, receives callback via `rishi-electron://` deep link, exchanges code for session, stores in `safeStorage`. No Better Auth client is imported in the desktop app.

**Tech Stack:** Better Auth + drizzle adapter; Cloudflare Workers + Hono + D1 + KV; Next.js 15 + Better Auth React client; Electron 39 + safeStorage + IPC; Resend for email.

**Spec:** [`docs/superpowers/specs/2026-05-09-better-auth-migration-design.md`](../specs/2026-05-09-better-auth-migration-design.md)

---

## Phases

- **Phase 1 — Worker (Tasks 1-12):** Better Auth instance, D1 schema, magic-link, Google OAuth, PKCE handoff. Testable with `curl` end-to-end before Phase 2 starts.
- **Phase 2 — Web app (Tasks 13-22):** Next.js sign-in, `DesktopHandoffListener`, settings/account. Testable in browser end-to-end before Phase 3 starts.
- **Phase 3 — Electron desktop (Tasks 23-36):** Deep-link, PKCE, IPC, session storage, sign-in modal rewrite. Tests against Phase 1+2.
- **Phase 4 — Cleanup + e2e (Tasks 37-40):** Remove Clerk packages, smoke test the full flow on macOS + Windows, fix HelpMenu bug.

Each task is self-contained — a fresh subagent should be able to execute it from the file paths and code shown without needing prior context.

---

## Operator prerequisites (do these in parallel with Phase 1)

These require humans clicking buttons in dashboards and don't block code:

- [ ] **A. Resend** — sign up, verify `fidexa.org` sender domain (SPF + DKIM + DMARC DNS records). Get API key. ~15 min.
- [ ] **B. Google Cloud OAuth 2.0 Web client** — Console → APIs & Services → Credentials → "OAuth 2.0 Client IDs" → "Web application". Authorized redirect URI: `https://api.fidexa.org/api/auth/callback/google`. Authorized JavaScript origin: `https://app.fidexa.org`. ~5 min.
- [ ] **C. Cloudflare KV namespace for desktop state** — `wrangler kv:namespace create RISHI_DESKTOP_STATE` (and a `--preview` for dev). Note both IDs. ~2 min.
- [ ] **D. Generate `BETTER_AUTH_SECRET`** — `openssl rand -base64 32`. Set via `wrangler secret put BETTER_AUTH_SECRET` for prod and dev environments.
- [ ] **E. Set Resend / Google secrets:** `wrangler secret put RESEND_API_KEY`, `wrangler secret put GOOGLE_CLIENT_ID`, `wrangler secret put GOOGLE_CLIENT_SECRET`.

---

# Phase 1 — Worker

## Task 1: Add Better Auth dependencies, scaffold module

**Files:**
- Modify: `workers/worker/package.json`
- Create: `workers/worker/src/auth.ts`

- [ ] **Step 1.1: Install dependencies**

```bash
cd workers/worker
pnpm add better-auth resend
pnpm add -D @better-auth/cli
```

- [ ] **Step 1.2: Create `auth.ts` skeleton**

Create `workers/worker/src/auth.ts`:

```ts
import { betterAuth } from "better-auth"
import { magicLink } from "better-auth/plugins"
import { drizzleAdapter } from "better-auth/adapters/drizzle"
import { Resend } from "resend"
import { createDb } from "./db/drizzle"
import { magicLinkEmail } from "./email-templates/magic-link"
import type { CloudflareBindings } from "./index"

export function createAuth(env: CloudflareBindings) {
  const db = createDb(env.DB)
  return betterAuth({
    database: drizzleAdapter(db, { provider: "sqlite" }),
    secret: env.BETTER_AUTH_SECRET,
    baseURL: env.PUBLIC_API_URL,
    trustedOrigins: [env.PUBLIC_WEB_URL, "rishi-electron://"],
    emailAndPassword: { enabled: false },
    user: {
      deleteUser: { enabled: true },
    },
    socialProviders: {
      google: {
        clientId: env.GOOGLE_CLIENT_ID,
        clientSecret: env.GOOGLE_CLIENT_SECRET,
      },
    },
    plugins: [
      magicLink({
        sendMagicLink: async ({ email, url }) => {
          const resend = new Resend(env.RESEND_API_KEY)
          await resend.emails.send({
            from: "Rishi <auth@fidexa.org>",
            to: email,
            subject: "Sign in to Rishi",
            html: magicLinkEmail({ url }),
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
    rateLimit: {
      window: 60,
      max: 5,
    },
  })
}

export type Auth = ReturnType<typeof createAuth>
```

- [ ] **Step 1.3: Commit**

```bash
git add workers/worker/package.json workers/worker/pnpm-lock.yaml workers/worker/src/auth.ts
git commit -m "feat(worker): scaffold better-auth instance"
```

---

## Task 2: Email template

**Files:**
- Create: `workers/worker/src/email-templates/magic-link.ts`

- [ ] **Step 2.1: Create plain HTML template**

Create `workers/worker/src/email-templates/magic-link.ts`:

```ts
export function magicLinkEmail({ url }: { url: string }): string {
  return `<!DOCTYPE html>
<html><body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:520px;margin:40px auto;color:#1a1a1a">
  <h1 style="font-size:22px;margin-bottom:24px">Sign in to Rishi</h1>
  <p style="font-size:15px;line-height:1.5">Click the button below to sign in. This link expires in 10 minutes.</p>
  <p style="margin:32px 0">
    <a href="${url}" style="background:#1a1a1a;color:#fff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:500">Sign in to Rishi</a>
  </p>
  <p style="font-size:13px;color:#666;line-height:1.5">If the button doesn't work, paste this link in your browser:<br><a href="${url}" style="color:#666;word-break:break-all">${url}</a></p>
  <p style="font-size:13px;color:#666;line-height:1.5;margin-top:32px">If you didn't request this, ignore this email.</p>
</body></html>`
}
```

- [ ] **Step 2.2: Commit**

```bash
git add workers/worker/src/email-templates/magic-link.ts
git commit -m "feat(worker): magic-link email template"
```

---

## Task 3: Generate D1 schema

**Files:**
- Modify: `packages/shared/src/schema.ts` (add Better Auth tables)
- Create: `workers/worker/drizzle/migrations/0001_better_auth.sql`

- [ ] **Step 3.1: Run Better Auth CLI to generate schema**

```bash
cd workers/worker
pnpm dlx @better-auth/cli@latest generate --output ./tmp-auth-schema.ts
```

This emits Drizzle table definitions for `user`, `session`, `account`, `verification`.

- [ ] **Step 3.2: Merge generated tables into shared schema**

Append the generated tables (rename `tmp-auth-schema.ts` exports to PascalCase if needed, or copy as-is) into `packages/shared/src/schema.ts`. Standard Better Auth tables for SQLite/D1:

```ts
// ─── Better Auth tables ────────────────────────────────────────────────────────

export const user = sqliteTable("user", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  email: text("email").notNull().unique(),
  emailVerified: integer("email_verified", { mode: "boolean" }).notNull(),
  image: text("image"),
  createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
  updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
})

export const session = sqliteTable("session", {
  id: text("id").primaryKey(),
  expiresAt: integer("expires_at", { mode: "timestamp" }).notNull(),
  token: text("token").notNull().unique(),
  createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
  updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
  ipAddress: text("ip_address"),
  userAgent: text("user_agent"),
  userId: text("user_id").notNull().references(() => user.id, { onDelete: "cascade" }),
})

export const account = sqliteTable("account", {
  id: text("id").primaryKey(),
  accountId: text("account_id").notNull(),
  providerId: text("provider_id").notNull(),
  userId: text("user_id").notNull().references(() => user.id, { onDelete: "cascade" }),
  accessToken: text("access_token"),
  refreshToken: text("refresh_token"),
  idToken: text("id_token"),
  accessTokenExpiresAt: integer("access_token_expires_at", { mode: "timestamp" }),
  refreshTokenExpiresAt: integer("refresh_token_expires_at", { mode: "timestamp" }),
  scope: text("scope"),
  password: text("password"),
  createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
  updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
})

export const verification = sqliteTable("verification", {
  id: text("id").primaryKey(),
  identifier: text("identifier").notNull(),
  value: text("value").notNull(),
  expiresAt: integer("expires_at", { mode: "timestamp" }).notNull(),
  createdAt: integer("created_at", { mode: "timestamp" }),
  updatedAt: integer("updated_at", { mode: "timestamp" }),
})
```

Delete `workers/worker/tmp-auth-schema.ts`.

- [ ] **Step 3.3: Generate the SQL migration**

```bash
cd workers/worker
pnpm drizzle-kit generate --config drizzle.config.ts
# Should produce drizzle/migrations/0001_<random>.sql
```

If `drizzle.config.ts` doesn't exist or points to wrong schema location, fix it to reference `packages/shared/src/schema.ts`.

- [ ] **Step 3.4: Apply migration to local D1**

```bash
pnpm wrangler d1 migrations apply rishi-sync --local
```

Verify with:
```bash
pnpm wrangler d1 execute rishi-sync --local --command "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('user','session','account','verification')"
```

Expected output: 4 rows.

- [ ] **Step 3.5: Commit**

```bash
git add packages/shared/src/schema.ts workers/worker/drizzle/migrations/
git commit -m "feat(db): add better-auth tables (user, session, account, verification)"
```

---

## Task 4: Add KV binding + new env vars to wrangler.jsonc

**Files:**
- Modify: `workers/worker/wrangler.jsonc`
- Modify: `workers/worker/src/index.ts` (CloudflareBindings interface)

- [ ] **Step 4.1: Update wrangler.jsonc**

Add to the existing `wrangler.jsonc`:

```jsonc
{
  // ... existing fields ...
  "kv_namespaces": [
    {
      "binding": "RISHI_DESKTOP_STATE",
      "id": "<paste prod KV id from operator prereq C>",
      "preview_id": "<paste preview KV id from operator prereq C>"
    }
  ],
  "vars": {
    "PUBLIC_API_URL": "https://api.fidexa.org",
    "PUBLIC_WEB_URL": "https://app.fidexa.org"
  }
}
```

- [ ] **Step 4.2: Update CloudflareBindings interface**

In `workers/worker/src/index.ts`, replace the existing `CloudflareBindings` interface:

```ts
export interface CloudflareBindings {
  DEEPGRAM_KEY: string;
  OPENAI_API_KEY: string;
  // Removed: CLERK_SECRET_KEY, CLERK_PUBLISHABLE_KEY
  BETTER_AUTH_SECRET: string;
  GOOGLE_CLIENT_ID: string;
  GOOGLE_CLIENT_SECRET: string;
  RESEND_API_KEY: string;
  PUBLIC_API_URL: string;
  PUBLIC_WEB_URL: string;
  UPSTASH_REDIS_REST_URL: string;
  UPSTASH_REDIS_REST_TOKEN: string;
  DEV_BYPASS_SECRET?: string;
  SENTRY_DSN?: string;
  DB: D1Database;
  BOOK_STORAGE: R2Bucket;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
  CLOUDFLARE_ACCOUNT_ID: string;
  RISHI_DESKTOP_STATE: KVNamespace;
}
```

- [ ] **Step 4.3: Regenerate types**

```bash
cd workers/worker
pnpm cf-typegen
```

- [ ] **Step 4.4: Commit**

```bash
git add workers/worker/wrangler.jsonc workers/worker/src/index.ts workers/worker/worker-configuration.d.ts
git commit -m "chore(worker): add KV binding + better-auth env vars"
```

---

## Task 5: Mount Better Auth handler in Hono

**Files:**
- Modify: `workers/worker/src/index.ts`

- [ ] **Step 5.1: Add `/auth/*` mount**

In `workers/worker/src/index.ts`, after the CORS middleware setup and before the existing route mounts, add:

```ts
import { createAuth } from "./auth"

// Better Auth handles all /api/auth/* internally
app.on(["GET", "POST"], "/api/auth/*", async (c) => {
  const auth = createAuth(c.env)
  return auth.handler(c.req.raw)
})
```

- [ ] **Step 5.2: Update CORS origin allow list**

Add `https://app.fidexa.org` (and dev URLs) to the existing CORS origin list:

```ts
app.use("*", cors({
  origin: [
    "https://rishi.fidexa.org",
    "https://app.fidexa.org",
    "tauri://localhost",
    "http://tauri.localhost",
    "http://localhost:3000",
    "http://localhost:5173",
    "http://localhost:5174",
  ],
  allowHeaders: ["Content-Type", "Authorization", "X-Dev-Bypass"],
  allowMethods: ["GET", "POST", "OPTIONS", "DELETE"],
  credentials: true,
}))
```

- [ ] **Step 5.3: Smoke test locally**

```bash
cd workers/worker
pnpm dev &
WORKER_PID=$!
sleep 3
curl -s http://localhost:8787/api/auth/ok
# Expected: {"status":"ok"}
kill $WORKER_PID
```

- [ ] **Step 5.4: Commit**

```bash
git add workers/worker/src/index.ts
git commit -m "feat(worker): mount better-auth at /api/auth"
```

---

## Task 6: Replace Clerk middleware with Better Auth session middleware

**Files:**
- Modify: `workers/worker/src/index.ts`
- Modify: `workers/worker/src/routes/sync.ts`
- Modify: `workers/worker/src/routes/upload.ts`

- [ ] **Step 6.1: Add `sessionMiddleware`**

Add to `workers/worker/src/index.ts` (replace `clerkMiddleware` import + usage):

```ts
import type { Context, Next } from "hono"

// Replaces @hono/clerk-auth's clerkMiddleware + getAuth pattern.
// Sets c.var.userId from the validated Better Auth session.
async function sessionMiddleware(c: Context<{ Bindings: CloudflareBindings; Variables: { userId: string } }>, next: Next) {
  const auth = createAuth(c.env)
  const session = await auth.api.getSession({ headers: c.req.raw.headers })

  // Dev bypass support — preserved from Clerk era for local development
  const devBypass = c.req.header("X-Dev-Bypass")
  if (devBypass && c.env.DEV_BYPASS_SECRET && timingSafeEqual(devBypass, c.env.DEV_BYPASS_SECRET)) {
    c.set("userId", "dev-bypass-user")
    await next()
    return
  }

  if (!session) {
    return c.json({ error: "unauthorized" }, 401)
  }
  c.set("userId", session.user.id)
  await next()
}
```

- [ ] **Step 6.2: Apply middleware to protected routes**

Replace the existing `app.use("/sync/*", clerkMiddleware(), ...)` calls with:

```ts
app.use("/sync/*", sessionMiddleware)
app.use("/upload/*", sessionMiddleware)
app.route("/sync", syncRoutes)
app.route("/upload", uploadRoutes)
```

- [ ] **Step 6.3: Update routes to read userId from new var name**

In `workers/worker/src/routes/sync.ts` and `upload.ts`, find any `getAuth(c).userId` calls and replace with `c.var.userId`. Same shape, same value, just sourced via the new middleware.

- [ ] **Step 6.4: Remove Clerk imports**

In `workers/worker/src/index.ts`:
- Remove `import { createClerkClient } from "@clerk/backend"`
- Remove `import { clerkMiddleware, getAuth } from "@hono/clerk-auth"`
- Search the file for any remaining `clerk` references and clean them.

- [ ] **Step 6.5: Smoke test**

```bash
pnpm dev &
WORKER_PID=$!
sleep 3
# Without auth → 401
curl -s -o /dev/null -w "%{http_code}" http://localhost:8787/sync/pull
# Expected: 401
kill $WORKER_PID
```

- [ ] **Step 6.6: Commit**

```bash
git add workers/worker/src/index.ts workers/worker/src/routes/
git commit -m "refactor(worker): replace clerk middleware with better-auth session middleware"
```

---

## Task 7: Desktop PKCE start endpoint

**Files:**
- Create: `workers/worker/src/routes/desktop.ts`
- Modify: `workers/worker/src/index.ts`

- [ ] **Step 7.1: Create desktop routes**

Create `workers/worker/src/routes/desktop.ts`:

```ts
import { Hono } from "hono"
import { z } from "zod"
import { createAuth } from "../auth"
import type { CloudflareBindings } from "../index"

export const desktopRoutes = new Hono<{ Bindings: CloudflareBindings; Variables: { userId: string } }>()

const StartBody = z.object({
  code_challenge: z.string().min(43).max(128),
  redirect_scheme: z.literal("rishi-electron"),
  mode: z.enum(["magic-link", "oauth-google"]),
  email: z.string().email().optional(),
})

interface StoredState {
  code_challenge: string
  mode: "magic-link" | "oauth-google"
  email?: string
  createdAt: number
}

/**
 * Desktop initiates an auth flow.
 * - magic-link: server immediately sends an email with a link to the web app's bridge page.
 * - oauth-google: server returns a URL for the desktop to open in the system browser.
 *
 * In both cases we store the code_challenge under a short-lived `state` token; the web app
 * later mints an authorization code keyed to this state, which the desktop exchanges using
 * its code_verifier in /desktop/exchange.
 */
desktopRoutes.post("/start", async (c) => {
  const body = StartBody.safeParse(await c.req.json())
  if (!body.success) return c.json({ error: "bad_request", issues: body.error.issues }, 400)

  const state = crypto.randomUUID()
  const stored: StoredState = {
    code_challenge: body.data.code_challenge,
    mode: body.data.mode,
    email: body.data.email,
    createdAt: Date.now(),
  }
  await c.env.RISHI_DESKTOP_STATE.put(`state:${state}`, JSON.stringify(stored), {
    expirationTtl: 60 * 30, // 30 min
  })

  const webBase = c.env.PUBLIC_WEB_URL

  if (body.data.mode === "magic-link") {
    if (!body.data.email) return c.json({ error: "email_required" }, 400)
    const auth = createAuth(c.env)
    // Better Auth's signInMagicLink sends the email. The callbackURL points at the web app
    // with our state token attached so DesktopHandoffListener can complete the handoff.
    const callbackURL = `${webBase}/?login=true&state=${encodeURIComponent(state)}`
    await auth.api.signInMagicLink({
      body: { email: body.data.email, callbackURL },
    })
    return c.json({ state })
  }

  // oauth-google: bounce user through the web app, which kicks off Better Auth's OAuth
  const url = new URL(`${webBase}/sign-in`)
  url.searchParams.set("login", "true")
  url.searchParams.set("provider", "google")
  url.searchParams.set("state", state)
  return c.json({ state, web_url: url.toString() })
})
```

- [ ] **Step 7.2: Mount in `workers/worker/src/index.ts`**

```ts
import { desktopRoutes } from "./routes/desktop"
// ...
app.route("/desktop", desktopRoutes)
```

- [ ] **Step 7.3: Commit**

```bash
git add workers/worker/src/routes/desktop.ts workers/worker/src/index.ts
git commit -m "feat(worker): /desktop/start PKCE initiation endpoint"
```

---

## Task 8: Desktop handoff complete + exchange endpoints

**Files:**
- Modify: `workers/worker/src/routes/desktop.ts`

- [ ] **Step 8.1: Add `/start/complete` (called by web app after sign-in)**

Add to `workers/worker/src/routes/desktop.ts`:

```ts
const CompleteBody = z.object({ state: z.string().uuid() })

/**
 * Called by the web app after the user has signed in (via magic link or OAuth).
 * Mints a one-time authorization code keyed to the stored state. The code itself
 * is short-lived and can only be exchanged once via /desktop/exchange with the
 * matching code_verifier.
 */
desktopRoutes.post("/start/complete", async (c) => {
  const body = CompleteBody.safeParse(await c.req.json())
  if (!body.success) return c.json({ error: "bad_request" }, 400)

  // Web app's user must already be signed in (Better Auth session cookie attached)
  const auth = createAuth(c.env)
  const session = await auth.api.getSession({ headers: c.req.raw.headers })
  if (!session) return c.json({ error: "unauthorized" }, 401)

  const stateRaw = await c.env.RISHI_DESKTOP_STATE.get(`state:${body.data.state}`)
  if (!stateRaw) return c.json({ error: "state_expired" }, 400)
  const stored: StoredState = JSON.parse(stateRaw)

  const code = crypto.randomUUID()
  await c.env.RISHI_DESKTOP_STATE.put(
    `code:${code}`,
    JSON.stringify({
      code_challenge: stored.code_challenge,
      userId: session.user.id,
      sessionToken: session.session.token,
      createdAt: Date.now(),
    }),
    { expirationTtl: 60 * 5 } // 5 min — desktop should redeem fast
  )
  // State is single-use
  await c.env.RISHI_DESKTOP_STATE.delete(`state:${body.data.state}`)

  return c.json({ code })
})
```

- [ ] **Step 8.2: Add `/exchange`**

```ts
const ExchangeBody = z.object({
  code: z.string().uuid(),
  code_verifier: z.string().min(43).max(128),
})

async function sha256Base64Url(input: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input))
  return btoa(String.fromCharCode(...new Uint8Array(buf)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "")
}

/**
 * Desktop exchanges { code, code_verifier } for the session token. PKCE
 * verification: sha256(code_verifier) base64url-encoded must equal the stored
 * code_challenge.
 */
desktopRoutes.post("/exchange", async (c) => {
  const body = ExchangeBody.safeParse(await c.req.json())
  if (!body.success) return c.json({ error: "bad_request" }, 400)

  const codeRaw = await c.env.RISHI_DESKTOP_STATE.get(`code:${body.data.code}`)
  if (!codeRaw) return c.json({ error: "code_expired_or_used" }, 400)
  const stored = JSON.parse(codeRaw) as { code_challenge: string; sessionToken: string }

  const expectedChallenge = await sha256Base64Url(body.data.code_verifier)
  if (expectedChallenge !== stored.code_challenge) {
    return c.json({ error: "pkce_mismatch" }, 400)
  }

  // Single-use
  await c.env.RISHI_DESKTOP_STATE.delete(`code:${body.data.code}`)

  return c.json({ session_token: stored.sessionToken })
})
```

- [ ] **Step 8.3: Smoke test (still without web app — uses curl)**

```bash
pnpm dev &
WORKER_PID=$!
sleep 3

# 1. Generate PKCE pair
VERIFIER=$(openssl rand -hex 32)
CHALLENGE=$(echo -n "$VERIFIER" | shasum -a 256 -b | xxd -r -p | base64 | tr '/+' '_-' | tr -d '=')

# 2. Start magic-link flow
curl -s -X POST http://localhost:8787/desktop/start \
  -H "Content-Type: application/json" \
  -d "{\"code_challenge\":\"$CHALLENGE\",\"redirect_scheme\":\"rishi-electron\",\"mode\":\"magic-link\",\"email\":\"test@example.com\"}"
# Expected: {"state":"<uuid>"}

kill $WORKER_PID
```

(Email won't arrive without Resend wired up to a real domain; that's fine for now.)

- [ ] **Step 8.4: Commit**

```bash
git add workers/worker/src/routes/desktop.ts
git commit -m "feat(worker): /desktop/start/complete + /desktop/exchange PKCE handoff"
```

---

## Task 9: Account deletion endpoint (already provided by Better Auth)

**Files:**
- (No new files — `auth.api.deleteUser()` is enabled via the `user.deleteUser.enabled` flag set in Task 1)

- [ ] **Step 9.1: Verify endpoint exists**

```bash
pnpm dev &
WORKER_PID=$!
sleep 3
curl -s -o /dev/null -w "%{http_code}" -X DELETE http://localhost:8787/api/auth/delete-user
# Expected: 401 (no session) — confirms endpoint exists
kill $WORKER_PID
```

- [ ] **Step 9.2: No commit (verification only)**

---

## Task 10: Remove Clerk dependencies from worker

**Files:**
- Modify: `workers/worker/package.json`
- Modify: `workers/worker/src/index.ts`

- [ ] **Step 10.1: Remove from package.json**

```bash
cd workers/worker
pnpm remove @clerk/backend @hono/clerk-auth
```

- [ ] **Step 10.2: Search for stragglers**

```bash
grep -rn "clerk" workers/worker/src/
# Should be empty
```

If any remain, delete them or replace with Better Auth equivalents.

- [ ] **Step 10.3: Commit**

```bash
git add workers/worker/package.json workers/worker/pnpm-lock.yaml
git commit -m "chore(worker): drop @clerk/backend and @hono/clerk-auth"
```

---

## Task 11: Apply migration to remote D1

**Files:** none (deployment step)

- [ ] **Step 11.1: Apply Better Auth tables to prod D1**

```bash
cd workers/worker
pnpm wrangler d1 migrations apply rishi-sync --remote
```

- [ ] **Step 11.2: Deploy worker (test environment first if you have one)**

```bash
pnpm wrangler deploy
```

- [ ] **Step 11.3: Verify deployed worker handles Better Auth**

```bash
curl -s https://api.fidexa.org/api/auth/ok
# Expected: {"status":"ok"}
```

- [ ] **Step 11.4: No commit (deployment only)**

---

## Task 12: Phase 1 acceptance test

**Files:** none (verification only)

- [ ] **Step 12.1: Manually trigger magic-link send**

Run with the operator-provided email and your deployed worker:

```bash
curl -X POST https://api.fidexa.org/desktop/start \
  -H "Content-Type: application/json" \
  -d '{"code_challenge":"abc123def456ghi789jkl012mno345pqr678stu901vwx234","redirect_scheme":"rishi-electron","mode":"magic-link","email":"<your-real-email>"}'
```

- [ ] **Step 12.2: Verify magic-link email arrives in your inbox**

The email link will point to `app.fidexa.org/?login=true&state=...`. Phase 2 will make that page work — for now, it just confirms the email pipeline.

- [ ] **Step 12.3: Verify state was stored in KV**

```bash
pnpm wrangler kv:key list --namespace-id=<prod-id> | head -5
# Should show state:<uuid> entries
```

If all three checks pass, **Phase 1 is complete.** Proceed to Phase 2.

---

# Phase 2 — Web app (Next.js)

## Task 13: Add Better Auth, drop Clerk

**Files:**
- Modify: `apps/web/package.json`

- [ ] **Step 13.1: Install / remove**

```bash
cd apps/web
pnpm add better-auth
pnpm remove @clerk/nextjs
```

- [ ] **Step 13.2: Commit**

```bash
git add apps/web/package.json apps/web/pnpm-lock.yaml
git commit -m "chore(web): swap @clerk/nextjs for better-auth"
```

---

## Task 14: Create Better Auth client + server config

**Files:**
- Create: `apps/web/src/lib/auth.ts`
- Create: `apps/web/src/lib/auth-client.ts`

- [ ] **Step 14.1: Server-side instance** (mirrors worker config but client-side won't use this directly — it's only for any server actions)

Create `apps/web/src/lib/auth.ts`:

```ts
import { betterAuth } from "better-auth"
import { magicLinkClient } from "better-auth/client/plugins"

// The web app does NOT host a Better Auth instance — the worker does. This file
// only exists in case server components / server actions need to read sessions
// directly without a network round-trip. For now, all auth lives at the worker.
//
// Most code should import from auth-client.ts instead.
export const BETTER_AUTH_BASE_URL = process.env.NEXT_PUBLIC_API_URL ?? "https://api.fidexa.org"
```

- [ ] **Step 14.2: React client**

Create `apps/web/src/lib/auth-client.ts`:

```ts
import { createAuthClient } from "better-auth/react"
import { magicLinkClient } from "better-auth/client/plugins"

export const authClient = createAuthClient({
  baseURL: process.env.NEXT_PUBLIC_API_URL ?? "https://api.fidexa.org",
  plugins: [magicLinkClient()],
})

// Re-export the hooks the rest of the app will use
export const {
  useSession,
  signIn,
  signOut,
  signUp,
} = authClient
```

- [ ] **Step 14.3: Add env var**

In `apps/web/.env.local` (and Vercel project settings):

```
NEXT_PUBLIC_API_URL=https://api.fidexa.org
```

- [ ] **Step 14.4: Commit**

```bash
git add apps/web/src/lib/auth.ts apps/web/src/lib/auth-client.ts apps/web/.env.local.example
git commit -m "feat(web): better-auth react client"
```

---

## Task 15: Replace `clerkMiddleware`

**Files:**
- Modify: `apps/web/src/middleware.ts`

- [ ] **Step 15.1: Replace middleware**

Rewrite `apps/web/src/middleware.ts`:

```ts
import { NextRequest, NextResponse } from "next/server"

/**
 * Lightweight middleware: redirects /protected/* to /sign-in if no session
 * cookie is present. We don't validate the session here (that costs a worker
 * round-trip per request); we just check for the cookie's existence as a
 * cheap gatekeeper. Server components / API routes that need verified
 * sessions call authClient.getSession() themselves.
 */
export function middleware(req: NextRequest) {
  const isProtected = req.nextUrl.pathname.startsWith("/settings")
  if (!isProtected) return NextResponse.next()

  const sessionCookie = req.cookies.get("rishi.session_token")
  if (!sessionCookie) {
    const signInUrl = new URL("/sign-in", req.url)
    signInUrl.searchParams.set("returnTo", req.nextUrl.pathname)
    return NextResponse.redirect(signInUrl)
  }
  return NextResponse.next()
}

export const config = {
  matcher: ["/settings/:path*"],
}
```

- [ ] **Step 15.2: Commit**

```bash
git add apps/web/src/middleware.ts
git commit -m "refactor(web): replace clerkMiddleware with cookie-gate redirect"
```

---

## Task 16: Replace `<ClerkProvider>` in layout

**Files:**
- Modify: `apps/web/src/app/layout.tsx`

- [ ] **Step 16.1: Strip Clerk imports + wrappers**

Open `apps/web/src/app/layout.tsx`. Remove:
- `import { ClerkProvider, SignInButton, SignUpButton, SignedIn, SignedOut, UserButton } from "@clerk/nextjs"`
- The `<ClerkProvider>` wrapper around children

Replace with a plain layout. Better Auth doesn't require a provider — `useSession` works directly.

- [ ] **Step 16.2: Update header / sign-in buttons**

Wherever the layout renders `<SignedIn>` / `<SignedOut>` / `<UserButton>`, replace with a small client component that uses `useSession`:

Create `apps/web/src/components/auth-buttons.tsx`:

```tsx
"use client"

import { useSession, signOut } from "@/lib/auth-client"
import Link from "next/link"
import { Button } from "@/components/ui/button"

export function AuthButtons() {
  const { data: session, isPending } = useSession()

  if (isPending) return <div className="h-9 w-20" />

  if (session) {
    return (
      <div className="flex items-center gap-2">
        <Link href="/settings/account" className="text-sm">
          {session.user.email}
        </Link>
        <Button variant="ghost" size="sm" onClick={() => signOut()}>
          Sign out
        </Button>
      </div>
    )
  }

  return (
    <div className="flex items-center gap-2">
      <Link href="/sign-in"><Button variant="ghost">Sign in</Button></Link>
      <Link href="/sign-in"><Button>Get started</Button></Link>
    </div>
  )
}
```

Use it in the layout / header where the Clerk buttons used to be.

- [ ] **Step 16.3: Commit**

```bash
git add apps/web/src/app/layout.tsx apps/web/src/components/auth-buttons.tsx apps/web/src/components/header.tsx
git commit -m "refactor(web): replace ClerkProvider with AuthButtons component"
```

---

## Task 17: Sign-in page

**Files:**
- Create: `apps/web/src/app/sign-in/page.tsx`

- [ ] **Step 17.1: Create magic-link sign-in page**

Create `apps/web/src/app/sign-in/page.tsx`:

```tsx
"use client"

import { useState, useEffect } from "react"
import { useSearchParams, useRouter } from "next/navigation"
import { authClient, signIn } from "@/lib/auth-client"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"

export default function SignInPage() {
  const router = useRouter()
  const params = useSearchParams()
  const provider = params.get("provider")
  const returnTo = params.get("returnTo") ?? "/"

  const [email, setEmail] = useState("")
  const [status, setStatus] = useState<"idle" | "sending" | "sent" | "error">("idle")
  const [errorMsg, setErrorMsg] = useState<string>("")

  // If ?provider=google, kick off OAuth immediately
  useEffect(() => {
    if (provider === "google") {
      signIn.social({
        provider: "google",
        callbackURL: window.location.href.replace("provider=google", ""),
      })
    }
  }, [provider])

  async function sendMagicLink(e: React.FormEvent) {
    e.preventDefault()
    setStatus("sending")
    setErrorMsg("")
    try {
      await authClient.signIn.magicLink({
        email,
        callbackURL: window.location.origin + (params.toString() ? "/?" + params.toString() : returnTo),
      })
      setStatus("sent")
    } catch (err: any) {
      setErrorMsg(err.message ?? "Failed to send link")
      setStatus("error")
    }
  }

  if (status === "sent") {
    return (
      <div className="max-w-md mx-auto py-20 text-center">
        <h1 className="text-2xl font-bold mb-4">Check your email</h1>
        <p className="text-muted-foreground mb-6">
          We sent a sign-in link to <span className="font-medium">{email}</span>. Open it on this device to continue.
        </p>
        <Button variant="ghost" onClick={() => setStatus("idle")}>Use a different email</Button>
      </div>
    )
  }

  return (
    <div className="max-w-md mx-auto py-20">
      <h1 className="text-2xl font-bold mb-2">Sign in to Rishi</h1>
      <p className="text-muted-foreground mb-6">We'll email you a link to sign in instantly.</p>
      <form onSubmit={sendMagicLink} className="space-y-3">
        <Input
          type="email"
          required
          autoFocus
          placeholder="you@example.com"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          disabled={status === "sending"}
        />
        <Button type="submit" className="w-full" disabled={status === "sending"}>
          {status === "sending" ? "Sending…" : "Continue"}
        </Button>
        {errorMsg && <p className="text-sm text-destructive">{errorMsg}</p>}
      </form>
      <div className="my-6 flex items-center gap-2">
        <div className="flex-1 h-px bg-border" />
        <span className="text-xs text-muted-foreground">OR</span>
        <div className="flex-1 h-px bg-border" />
      </div>
      <Button
        variant="outline"
        className="w-full"
        onClick={() =>
          signIn.social({ provider: "google", callbackURL: window.location.href })
        }
      >
        Continue with Google
      </Button>
    </div>
  )
}
```

- [ ] **Step 17.2: Smoke test in browser**

```bash
cd apps/web
pnpm dev &
WEB_PID=$!
sleep 5
open http://localhost:3000/sign-in
# Type an email, click Continue, verify "Check your email" UI appears
kill $WEB_PID
```

- [ ] **Step 17.3: Commit**

```bash
git add apps/web/src/app/sign-in/page.tsx
git commit -m "feat(web): magic-link sign-in page"
```

---

## Task 18: Desktop handoff listener

**Files:**
- Create: `apps/web/src/components/desktop-handoff-listener.tsx`
- Delete: `apps/web/src/components/clerk-listener.tsx`

- [ ] **Step 18.1: Create the new listener**

Create `apps/web/src/components/desktop-handoff-listener.tsx`:

```tsx
"use client"

import { useEffect, useRef } from "react"
import { useSearchParams } from "next/navigation"
import { useSession } from "@/lib/auth-client"

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "https://api.fidexa.org"

/**
 * When the desktop app sends a user to app.fidexa.org/?login=true&state=...,
 * we wait for them to be signed in (via magic-link or social), then ask the
 * worker to mint a one-time authorization code and redirect to
 * rishi-electron://auth/callback?code=...&state=...
 */
export function DesktopHandoffListener() {
  const params = useSearchParams()
  const { data: session, isPending } = useSession()
  const hasRedirectedRef = useRef(false)

  useEffect(() => {
    if (hasRedirectedRef.current) return
    if (isPending) return

    const isHandoff = params.get("login") === "true"
    const state = params.get("state")
    if (!isHandoff || !state) return
    if (!session) return // wait for sign-in to complete

    hasRedirectedRef.current = true

    void (async () => {
      const res = await fetch(`${API_URL}/desktop/start/complete`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ state }),
        credentials: "include",
      })

      if (!res.ok) {
        console.error("[desktop-handoff] complete failed", await res.text())
        return
      }

      const { code } = (await res.json()) as { code: string }
      window.location.href = `rishi-electron://auth/callback?code=${encodeURIComponent(code)}&state=${encodeURIComponent(state)}`
    })()
  }, [session, isPending, params])

  return null
}
```

- [ ] **Step 18.2: Mount in layout**

In `apps/web/src/app/layout.tsx`, render `<DesktopHandoffListener />` somewhere (e.g., top of `<body>`). Wrap in `<Suspense>` to satisfy Next.js's `useSearchParams` rule:

```tsx
import { Suspense } from "react"
import { DesktopHandoffListener } from "@/components/desktop-handoff-listener"

// inside <body>:
<Suspense fallback={null}>
  <DesktopHandoffListener />
</Suspense>
```

- [ ] **Step 18.3: Delete old listener**

```bash
rm apps/web/src/components/clerk-listener.tsx
# Search for any imports of it and remove
grep -rn "clerk-listener\|ClerkListener" apps/web/src/
# Remove any matches found
```

- [ ] **Step 18.4: Commit**

```bash
git add apps/web/src/components/desktop-handoff-listener.tsx apps/web/src/app/layout.tsx
git rm apps/web/src/components/clerk-listener.tsx
git commit -m "feat(web): desktop handoff listener replaces clerk-listener"
```

---

## Task 19: Account settings page (delete account)

**Files:**
- Create: `apps/web/src/app/settings/account/page.tsx`

- [ ] **Step 19.1: Create page**

Create `apps/web/src/app/settings/account/page.tsx`:

```tsx
"use client"

import { useState } from "react"
import { useRouter } from "next/navigation"
import { authClient, useSession, signOut } from "@/lib/auth-client"
import { Button } from "@/components/ui/button"
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle, AlertDialogTrigger } from "@/components/ui/alert-dialog"

export default function AccountSettingsPage() {
  const router = useRouter()
  const { data: session } = useSession()
  const [deleting, setDeleting] = useState(false)

  if (!session) return null

  async function handleDelete() {
    setDeleting(true)
    try {
      await authClient.deleteUser()
      router.push("/")
    } catch (err: any) {
      alert("Failed to delete account: " + (err.message ?? "unknown"))
      setDeleting(false)
    }
  }

  return (
    <div className="max-w-2xl mx-auto py-12 space-y-8">
      <header>
        <h1 className="text-2xl font-bold">Account</h1>
        <p className="text-muted-foreground">{session.user.email}</p>
      </header>

      <section className="space-y-4">
        <h2 className="text-lg font-semibold">Sign out</h2>
        <Button variant="outline" onClick={() => signOut()}>Sign out</Button>
      </section>

      <section className="space-y-4 pt-8 border-t">
        <h2 className="text-lg font-semibold text-destructive">Danger zone</h2>
        <p className="text-sm text-muted-foreground">Permanently delete your account, library, and all sync data. This cannot be undone.</p>
        <AlertDialog>
          <AlertDialogTrigger asChild>
            <Button variant="destructive" disabled={deleting}>Delete account</Button>
          </AlertDialogTrigger>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Delete account?</AlertDialogTitle>
              <AlertDialogDescription>
                Your account, all books synced to the cloud, highlights, and reading progress will be permanently removed.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancel</AlertDialogCancel>
              <AlertDialogAction onClick={handleDelete} className="bg-destructive">Delete</AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </section>
    </div>
  )
}
```

- [ ] **Step 19.2: Commit**

```bash
git add apps/web/src/app/settings/account/page.tsx
git commit -m "feat(web): account settings page with delete-account"
```

---

## Task 20: Remove all remaining Clerk references in web

**Files:**
- Various `apps/web/src/**/*.{ts,tsx}`

- [ ] **Step 20.1: Find stragglers**

```bash
grep -rn "clerk\|@clerk" apps/web/src/
```

- [ ] **Step 20.2: For each match, replace with Better Auth equivalent**

Common patterns:
- `useUser()` → `useSession()` (returns `{ data: { user, session } }` shape)
- `useAuth()` → `useSession()`
- `<SignedIn>` → `{session && (...)}`
- `<SignedOut>` → `{!session && (...)}`
- `<UserButton>` → custom dropdown with avatar + email + sign out

- [ ] **Step 20.3: Verify build succeeds**

```bash
cd apps/web
pnpm build
```

Expected: build completes without "Cannot find module '@clerk/nextjs'" errors.

- [ ] **Step 20.4: Commit**

```bash
git add apps/web/src/
git commit -m "refactor(web): remove all clerk references"
```

---

## Task 21: Update existing pages that referenced Clerk auth state

**Files:**
- `apps/web/src/atoms/state.ts` (if it stores Clerk-specific state)
- `apps/web/src/lib/redis.ts` (if it stored Clerk user IDs)

- [ ] **Step 21.1: Audit + update**

```bash
grep -n "clerk\|userId.*clerk" apps/web/src/atoms/ apps/web/src/lib/
```

For each match: rename Clerk-specific identifiers to neutral names (`userId` → `userId`, no change needed if already neutral).

- [ ] **Step 21.2: Commit**

```bash
git add apps/web/src/
git commit -m "refactor(web): neutralize clerk-named state and storage"
```

---

## Task 22: Phase 2 acceptance test

**Files:** none (verification only)

- [ ] **Step 22.1: Deploy to Vercel preview**

```bash
cd apps/web
vercel --no-clipboard
# Note the preview URL
```

- [ ] **Step 22.2: Test magic-link end-to-end on preview**

In a browser:
1. Open `<preview-url>/sign-in`
2. Enter your email, click Continue
3. Wait for email
4. Click link → should sign you in and land on the home page

- [ ] **Step 22.3: Test desktop handoff (curl-simulated)**

```bash
# 1. Initiate desktop flow (use the production worker)
curl -X POST https://api.fidexa.org/desktop/start \
  -H "Content-Type: application/json" \
  -d '{"code_challenge":"<challenge>","redirect_scheme":"rishi-electron","mode":"magic-link","email":"<your-email>"}'
# → {"state":"<uuid>"}

# 2. Click the magic-link in your email — it should land you at app.fidexa.org/?login=true&state=<uuid>
# 3. DesktopHandoffListener should fire and try to redirect to rishi-electron://...
#    (Browser will say "open in app?" — cancel for now since the desktop hasn't migrated yet)

# 4. Verify the code endpoint at least responds:
#    Open dev tools → Network tab on app.fidexa.org → confirm POST /desktop/start/complete returned {code: "<uuid>"}
```

If the listener fires and posts to `/desktop/start/complete`, **Phase 2 is complete**. Proceed to Phase 3.

---

# Phase 3 — Electron desktop

## Task 23: Drop Clerk, scaffold auth module

**Files:**
- Modify: `apps/rishi-electron/package.json`
- Create: `apps/rishi-electron/src/main/auth/index.ts` (empty for now)

- [ ] **Step 23.1: Remove Clerk dep**

```bash
cd apps/rishi-electron
pnpm remove @clerk/clerk-react
```

- [ ] **Step 23.2: Create empty module skeleton**

```bash
mkdir -p src/main/auth
touch src/main/auth/index.ts
touch src/main/auth/auth-service.ts
touch src/main/auth/pkce.ts
touch src/main/auth/session-store.ts
touch src/main/auth/deep-link.ts
```

- [ ] **Step 23.3: Commit**

```bash
git add apps/rishi-electron/package.json apps/rishi-electron/pnpm-lock.yaml apps/rishi-electron/src/main/auth/
git commit -m "chore(electron): drop @clerk/clerk-react, scaffold auth module"
```

---

## Task 24: PKCE module (with tests)

**Files:**
- Create: `apps/rishi-electron/src/main/auth/pkce.ts`
- Create: `apps/rishi-electron/src/main/auth/pkce.test.ts`

- [ ] **Step 24.1: Write the failing test**

Create `apps/rishi-electron/src/main/auth/pkce.test.ts`:

```ts
import { describe, it, expect } from "vitest"
import { generatePkcePair, verifyPkce } from "./pkce"

describe("PKCE", () => {
  it("generates a code_verifier between 43 and 128 chars (RFC 7636)", () => {
    const { code_verifier } = generatePkcePair()
    expect(code_verifier.length).toBeGreaterThanOrEqual(43)
    expect(code_verifier.length).toBeLessThanOrEqual(128)
  })

  it("generates a code_verifier using only the unreserved character set", () => {
    const { code_verifier } = generatePkcePair()
    expect(code_verifier).toMatch(/^[A-Za-z0-9\-._~]+$/)
  })

  it("the code_challenge is base64url(sha256(code_verifier))", async () => {
    const { code_verifier, code_challenge } = generatePkcePair()
    expect(await verifyPkce(code_verifier, code_challenge)).toBe(true)
  })

  it("verifyPkce rejects mismatched verifier", async () => {
    const { code_challenge } = generatePkcePair()
    expect(await verifyPkce("wrong-verifier", code_challenge)).toBe(false)
  })

  it("each call returns a unique pair", () => {
    const a = generatePkcePair()
    const b = generatePkcePair()
    expect(a.code_verifier).not.toBe(b.code_verifier)
    expect(a.code_challenge).not.toBe(b.code_challenge)
  })
})
```

- [ ] **Step 24.2: Run the failing test**

```bash
cd apps/rishi-electron
pnpm test src/main/auth/pkce.test.ts
```

Expected: FAIL with "Cannot find module './pkce'" or similar.

- [ ] **Step 24.3: Implement**

Create `apps/rishi-electron/src/main/auth/pkce.ts`:

```ts
import { createHash, randomBytes } from "node:crypto"

export interface PkcePair {
  code_verifier: string
  code_challenge: string
}

function base64url(input: Buffer): string {
  return input.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

export function generatePkcePair(): PkcePair {
  // 32 random bytes → 43-char base64url, RFC-7636 compliant
  const code_verifier = base64url(randomBytes(32))
  const code_challenge = base64url(createHash("sha256").update(code_verifier).digest())
  return { code_verifier, code_challenge }
}

export async function verifyPkce(verifier: string, challenge: string): Promise<boolean> {
  const expected = base64url(createHash("sha256").update(verifier).digest())
  return expected === challenge
}
```

- [ ] **Step 24.4: Run tests, verify pass**

```bash
pnpm test src/main/auth/pkce.test.ts
```

Expected: 5 passing.

- [ ] **Step 24.5: Commit**

```bash
git add apps/rishi-electron/src/main/auth/pkce.ts apps/rishi-electron/src/main/auth/pkce.test.ts
git commit -m "feat(electron): pkce helper with tests"
```

---

## Task 25: Session store (safeStorage-backed)

**Files:**
- Create: `apps/rishi-electron/src/main/auth/session-store.ts`

- [ ] **Step 25.1: Implement**

Create `apps/rishi-electron/src/main/auth/session-store.ts`:

```ts
import { safeStorage, app } from "electron"
import { promises as fs } from "node:fs"
import { join } from "node:path"

const FILE = "session.enc"

function path() {
  return join(app.getPath("userData"), FILE)
}

/**
 * Reads the encrypted session token from disk and decrypts via safeStorage.
 * Returns null if no token is stored or decryption fails (e.g. keychain reset).
 */
export async function readSession(): Promise<string | null> {
  try {
    const buf = await fs.readFile(path())
    if (!safeStorage.isEncryptionAvailable()) {
      // Linux without libsecret — fall back to plaintext (Electron's default)
      return buf.toString("utf-8")
    }
    return safeStorage.decryptString(buf)
  } catch (err: any) {
    if (err.code === "ENOENT") return null
    console.warn("[session-store] read failed", err)
    return null
  }
}

export async function writeSession(token: string): Promise<void> {
  if (safeStorage.isEncryptionAvailable()) {
    const enc = safeStorage.encryptString(token)
    await fs.writeFile(path(), enc, { mode: 0o600 })
  } else {
    await fs.writeFile(path(), token, { mode: 0o600, encoding: "utf-8" })
  }
}

export async function clearSession(): Promise<void> {
  try {
    await fs.unlink(path())
  } catch (err: any) {
    if (err.code !== "ENOENT") throw err
  }
}
```

- [ ] **Step 25.2: Commit**

```bash
git add apps/rishi-electron/src/main/auth/session-store.ts
git commit -m "feat(electron): safeStorage-backed session token store"
```

---

## Task 26: Deep-link handler (restore removed code)

**Files:**
- Create: `apps/rishi-electron/src/main/auth/deep-link.ts`

- [ ] **Step 26.1: Implement**

Create `apps/rishi-electron/src/main/auth/deep-link.ts`:

```ts
import { app, BrowserWindow } from "electron"

export const DEEP_LINK_PROTOCOL = "rishi-electron"

export type DeepLinkCallback = (url: string) => void

/**
 * Registers `rishi-electron://` as a custom URL scheme owned by this app and
 * wires the OS-specific dispatch:
 *
 *   - macOS: app.on('open-url') fires with the URL
 *   - Windows / Linux: when the OS opens the URL, it relaunches the app with
 *     the URL appended to argv. Our single-instance lock catches the relaunch
 *     in the `second-instance` event.
 */
export function setupDeepLinkHandler(onCallback: DeepLinkCallback, getMainWindow: () => BrowserWindow | null): void {
  // Custom scheme registration
  if (process.defaultApp) {
    if (process.argv.length >= 2) {
      app.setAsDefaultProtocolClient(DEEP_LINK_PROTOCOL, process.execPath, [
        process.argv[1],
      ])
    }
  } else {
    app.setAsDefaultProtocolClient(DEEP_LINK_PROTOCOL)
  }

  // macOS dispatch
  app.on("open-url", (event, url) => {
    event.preventDefault()
    handleUrl(url, onCallback, getMainWindow)
  })

  // Windows / Linux dispatch — we can't replace the existing single-instance
  // listener, so caller must invoke this from inside their handler. See
  // src/main/index.ts for the integration.
}

export function handleUrl(url: string, onCallback: DeepLinkCallback, getMainWindow: () => BrowserWindow | null): void {
  if (!url.startsWith(`${DEEP_LINK_PROTOCOL}://`)) return
  const win = getMainWindow()
  if (win) {
    if (win.isMinimized()) win.restore()
    win.focus()
  }
  onCallback(url)
}

/** Scan a process argv for a deep-link URL. Returns null if none found. */
export function findDeepLinkInArgv(argv: string[]): string | null {
  return argv.find((a) => a.startsWith(`${DEEP_LINK_PROTOCOL}://`)) ?? null
}
```

- [ ] **Step 26.2: Commit**

```bash
git add apps/rishi-electron/src/main/auth/deep-link.ts
git commit -m "feat(electron): deep-link handler module"
```

---

## Task 27: Auth service (orchestration)

**Files:**
- Create: `apps/rishi-electron/src/main/auth/auth-service.ts`

- [ ] **Step 27.1: Implement**

Create `apps/rishi-electron/src/main/auth/auth-service.ts`:

```ts
import { shell, BrowserWindow, app } from "electron"
import { generatePkcePair } from "./pkce"
import { readSession, writeSession, clearSession } from "./session-store"

const API_URL = process.env.RISHI_API_URL ?? "https://api.fidexa.org"

interface PendingAuth {
  state: string
  code_verifier: string
  startedAt: number
}

interface User {
  id: string
  email: string
  name?: string
  image?: string
}

class AuthService {
  private pending: Map<string, PendingAuth> = new Map()
  private currentUser: User | null = null
  private listeners: Set<(user: User | null) => void> = new Set()

  async hydrate(): Promise<void> {
    const token = await readSession()
    if (!token) return
    this.currentUser = await this.fetchUser(token)
    this.notify()
  }

  getUser(): User | null {
    return this.currentUser
  }

  onChange(cb: (user: User | null) => void): () => void {
    this.listeners.add(cb)
    return () => this.listeners.delete(cb)
  }

  private notify() {
    for (const cb of this.listeners) cb(this.currentUser)
  }

  async startMagicLink(email: string): Promise<void> {
    const { code_verifier, code_challenge } = generatePkcePair()
    const res = await fetch(`${API_URL}/desktop/start`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        email,
        code_challenge,
        redirect_scheme: "rishi-electron",
        mode: "magic-link",
      }),
    })
    if (!res.ok) throw new Error(`magic-link send failed: ${res.status}`)
    const { state } = (await res.json()) as { state: string }
    this.pending.set(state, { state, code_verifier, startedAt: Date.now() })
  }

  async startGoogleSignIn(): Promise<void> {
    if (process.mas) throw new Error("google_unavailable_on_mas")
    const { code_verifier, code_challenge } = generatePkcePair()
    const res = await fetch(`${API_URL}/desktop/start`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        code_challenge,
        redirect_scheme: "rishi-electron",
        mode: "oauth-google",
      }),
    })
    if (!res.ok) throw new Error(`oauth start failed: ${res.status}`)
    const { state, web_url } = (await res.json()) as { state: string; web_url: string }
    this.pending.set(state, { state, code_verifier, startedAt: Date.now() })
    await shell.openExternal(web_url)
  }

  async handleCallback(url: string): Promise<void> {
    const parsed = new URL(url)
    const code = parsed.searchParams.get("code")
    const state = parsed.searchParams.get("state")
    if (!code || !state) {
      console.warn("[auth] malformed callback url", url)
      return
    }
    const pending = this.pending.get(state)
    if (!pending) {
      console.warn("[auth] state not pending or expired", state)
      return
    }
    this.pending.delete(state)

    const res = await fetch(`${API_URL}/desktop/exchange`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, code_verifier: pending.code_verifier }),
    })
    if (!res.ok) {
      console.error("[auth] exchange failed", await res.text())
      return
    }
    const { session_token } = (await res.json()) as { session_token: string }
    await writeSession(session_token)
    this.currentUser = await this.fetchUser(session_token)
    this.notify()
  }

  async signOut(): Promise<void> {
    const token = await readSession()
    if (token) {
      await fetch(`${API_URL}/api/auth/sign-out`, {
        method: "POST",
        headers: { Cookie: `rishi.session_token=${token}` },
      }).catch(() => {})
    }
    await clearSession()
    this.currentUser = null
    this.notify()
  }

  async deleteAccount(): Promise<void> {
    const token = await readSession()
    if (!token) return
    const res = await fetch(`${API_URL}/api/auth/delete-user`, {
      method: "DELETE",
      headers: { Cookie: `rishi.session_token=${token}` },
    })
    if (!res.ok) throw new Error(`delete failed: ${res.status}`)
    await clearSession()
    this.currentUser = null
    this.notify()
  }

  async getSessionToken(): Promise<string | null> {
    return await readSession()
  }

  private async fetchUser(token: string): Promise<User | null> {
    const res = await fetch(`${API_URL}/api/auth/get-session`, {
      headers: { Cookie: `rishi.session_token=${token}` },
    })
    if (!res.ok) return null
    const data = (await res.json()) as { user: User } | null
    return data?.user ?? null
  }
}

export const authService = new AuthService()
```

- [ ] **Step 27.2: Commit**

```bash
git add apps/rishi-electron/src/main/auth/auth-service.ts
git commit -m "feat(electron): auth-service orchestration layer"
```

---

## Task 28: IPC handlers

**Files:**
- Modify: `apps/rishi-electron/src/main/auth/index.ts`

- [ ] **Step 28.1: Wire IPC**

Replace the empty `apps/rishi-electron/src/main/auth/index.ts`:

```ts
import { ipcMain, BrowserWindow } from "electron"
import { authService } from "./auth-service"
import { setupDeepLinkHandler, handleUrl, findDeepLinkInArgv } from "./deep-link"

export function registerAuthIpc(getMainWindow: () => BrowserWindow | null): void {
  // Hydrate stored session on app start
  void authService.hydrate()

  // Broadcast changes to all renderer processes
  authService.onChange((user) => {
    for (const win of BrowserWindow.getAllWindows()) {
      win.webContents.send("session-changed", user)
    }
  })

  setupDeepLinkHandler((url) => void authService.handleCallback(url), getMainWindow)

  ipcMain.handle("auth:start-magic-link", async (_evt, email: string) => {
    await authService.startMagicLink(email)
  })

  ipcMain.handle("auth:start-google", async () => {
    await authService.startGoogleSignIn()
  })

  ipcMain.handle("auth:get-session", () => authService.getUser())

  ipcMain.handle("auth:sign-out", async () => {
    await authService.signOut()
  })

  ipcMain.handle("auth:delete-account", async () => {
    await authService.deleteAccount()
  })

  ipcMain.handle("auth:get-token", async () => await authService.getSessionToken())
}

export { handleUrl, findDeepLinkInArgv }
```

- [ ] **Step 28.2: Commit**

```bash
git add apps/rishi-electron/src/main/auth/index.ts
git commit -m "feat(electron): auth IPC handlers"
```

---

## Task 29: Wire auth into main process; remove old OAuth popup

**Files:**
- Modify: `apps/rishi-electron/src/main/index.ts`

- [ ] **Step 29.1: Remove OAuth popup branch**

In `apps/rishi-electron/src/main/index.ts`, find the `mainWindow.webContents.setWindowOpenHandler(...)` block. Replace its body with:

```ts
mainWindow.webContents.setWindowOpenHandler((details) => {
  // No more in-app OAuth popups — auth runs via system browser + deep-link.
  // Anything that opens a window goes to the system browser.
  if (details.url.startsWith("http:") || details.url.startsWith("https:") || details.url.startsWith("mailto:")) {
    shell.openExternal(details.url)
  }
  return { action: "deny" }
})
```

- [ ] **Step 29.2: Register auth IPC + extend single-instance handler**

Add at the top of the file:

```ts
import { registerAuthIpc, handleUrl, findDeepLinkInArgv } from "./auth"
import { authService } from "./auth/auth-service"
```

In the existing `app.requestSingleInstanceLock()` block, extend the `second-instance` listener:

```ts
} else {
  app.on("second-instance", (_event, argv) => {
    // Windows/Linux: deep-link URLs arrive as command-line args
    const deepLinkUrl = findDeepLinkInArgv(argv)
    if (deepLinkUrl) {
      handleUrl(deepLinkUrl, (url) => void authService.handleCallback(url), () => mainWindow)
    }
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore()
      mainWindow.focus()
    }
  })
}
```

In `app.whenReady().then(...)`, after `createWindow()`:

```ts
registerAuthIpc(() => mainWindow)
```

- [ ] **Step 29.3: Handle the case where the app is launched FROM a deep link**

After `createWindow()`:

```ts
// Windows/Linux: app may have been launched from a deep link (cold start)
const initialDeepLink = findDeepLinkInArgv(process.argv)
if (initialDeepLink) {
  void authService.handleCallback(initialDeepLink)
}
```

- [ ] **Step 29.4: Commit**

```bash
git add apps/rishi-electron/src/main/index.ts
git commit -m "feat(electron): wire auth IPC + restore deep-link handling"
```

---

## Task 30: Preload bridge

**Files:**
- Modify: `apps/rishi-electron/src/preload/index.ts`
- Modify: `apps/rishi-electron/src/preload/types.ts`

- [ ] **Step 30.1: Expose auth surface**

In `apps/rishi-electron/src/preload/index.ts`, inside the existing `contextBridge.exposeInMainWorld('api', { ... })`, add:

```ts
auth: {
  startMagicLink: (email: string) => ipcRenderer.invoke("auth:start-magic-link", email),
  startGoogle: () => ipcRenderer.invoke("auth:start-google"),
  getSession: () => ipcRenderer.invoke("auth:get-session"),
  signOut: () => ipcRenderer.invoke("auth:sign-out"),
  deleteAccount: () => ipcRenderer.invoke("auth:delete-account"),
  getToken: () => ipcRenderer.invoke("auth:get-token"),
  onSessionChange: (cb: (user: User | null) => void) => {
    const handler = (_e: unknown, user: User | null) => cb(user)
    ipcRenderer.on("session-changed", handler)
    return () => ipcRenderer.removeListener("session-changed", handler)
  },
  isMacAppStore: !!process.mas,
},
```

- [ ] **Step 30.2: Update types**

In `apps/rishi-electron/src/preload/types.ts`:

```ts
export interface User {
  id: string
  email: string
  name?: string
  image?: string
}

export interface AuthApi {
  startMagicLink: (email: string) => Promise<void>
  startGoogle: () => Promise<void>
  getSession: () => Promise<User | null>
  signOut: () => Promise<void>
  deleteAccount: () => Promise<void>
  getToken: () => Promise<string | null>
  onSessionChange: (cb: (user: User | null) => void) => () => void
  isMacAppStore: boolean
}

// In the existing Api interface:
export interface Api {
  // ... existing fields ...
  auth: AuthApi
}
```

- [ ] **Step 30.3: Commit**

```bash
git add apps/rishi-electron/src/preload/
git commit -m "feat(electron): preload bridge for auth IPC"
```

---

## Task 31: Rewrite SignInModal

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/auth/SignInModal.tsx`

- [ ] **Step 31.1: Replace with magic-link UI**

Replace the entire contents of `SignInModal.tsx`:

```tsx
import { useState } from "react"
import { useAuthStore } from "@/stores/authStore"
import { X } from "lucide-react"

const isMacAppStore = window.api?.auth?.isMacAppStore ?? false

export default function SignInModal(): React.JSX.Element {
  const open = useAuthStore((s) => s.signInOpen)
  const closeSignIn = useAuthStore((s) => s.closeSignIn)
  const [email, setEmail] = useState("")
  const [status, setStatus] = useState<"idle" | "sending" | "sent" | "error">("idle")
  const [errorMsg, setErrorMsg] = useState("")

  if (!open) return <></>

  async function send(e: React.FormEvent) {
    e.preventDefault()
    setStatus("sending")
    setErrorMsg("")
    try {
      await window.api.auth.startMagicLink(email)
      setStatus("sent")
    } catch (err: any) {
      setErrorMsg(err.message ?? "Failed to send link")
      setStatus("error")
    }
  }

  async function google() {
    try {
      await window.api.auth.startGoogle()
      setStatus("sent") // browser opened; will close modal once session arrives
    } catch (err: any) {
      setErrorMsg(err.message ?? "Failed to start Google sign-in")
      setStatus("error")
    }
  }

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/50" onClick={closeSignIn}>
      <div className="bg-white rounded-2xl p-6 max-w-md w-full mx-4 shadow-xl relative" onClick={(e) => e.stopPropagation()}>
        <button onClick={closeSignIn} className="absolute right-4 top-4 text-gray-400 hover:text-gray-700"><X size={18} /></button>

        {status === "sent" ? (
          <div className="text-center py-4">
            <h2 className="text-xl font-bold mb-2">Check your email</h2>
            <p className="text-gray-600 mb-4">We sent a sign-in link to <strong>{email}</strong>. Open it on this device.</p>
            <button onClick={() => setStatus("idle")} className="text-sm text-gray-500 underline">Use a different email</button>
          </div>
        ) : (
          <>
            <h2 className="text-xl font-bold mb-2">Sign in to Rishi</h2>
            <p className="text-gray-600 mb-4 text-sm">We'll email you a link to sign in instantly.</p>
            <form onSubmit={send} className="space-y-2">
              <input
                type="email"
                required
                autoFocus
                placeholder="you@example.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                disabled={status === "sending"}
                className="w-full px-3 py-2 border border-gray-300 rounded-lg"
              />
              <button type="submit" disabled={status === "sending"} className="w-full px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50">
                {status === "sending" ? "Sending…" : "Continue"}
              </button>
              {errorMsg && <p className="text-sm text-red-600">{errorMsg}</p>}
            </form>
            {!isMacAppStore && (
              <>
                <div className="flex items-center gap-2 my-4"><div className="flex-1 h-px bg-gray-200" /><span className="text-xs text-gray-400">OR</span><div className="flex-1 h-px bg-gray-200" /></div>
                <button onClick={google} className="w-full px-4 py-2 border border-gray-300 rounded-lg hover:bg-gray-50">
                  Continue with Google
                </button>
              </>
            )}
          </>
        )}
      </div>
    </div>
  )
}
```

- [ ] **Step 31.2: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/auth/SignInModal.tsx
git commit -m "feat(electron): rewrite SignInModal for magic-link flow"
```

---

## Task 32: Rewrite useHydrateAuth + authStore

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/hooks/useHydrateAuth.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/stores/authStore.ts`

- [ ] **Step 32.1: Update authStore**

Replace `apps/rishi-electron/src/renderer/src/stores/authStore.ts`:

```ts
import { create } from "zustand"
import { devtools } from "zustand/middleware"
import type { User } from "@preload/types"

const WELCOME_SEEN_KEY = "rishi:welcome-seen"

interface AuthState {
  user: User | null
  authHydrated: boolean
  welcomeSeen: boolean
  bannerDismissed: boolean
  signInOpen: boolean

  setUser: (user: User | null) => void
  setAuthHydrated: (value: boolean) => void
  hydrateAuth: () => void
  dismissBanner: () => void
  dismissWelcome: () => void
  setWelcomeSeen: () => void
  openSignIn: () => void
  closeSignIn: () => void
}

export const useAuthStore = create<AuthState>()(
  devtools(
    (set) => ({
      user: null,
      authHydrated: false,
      welcomeSeen: false,
      bannerDismissed: false,
      signInOpen: false,

      setUser: (user) => set({ user }),
      setAuthHydrated: (value) => set({ authHydrated: value }),
      openSignIn: () => set({ signInOpen: true }),
      closeSignIn: () => set({ signInOpen: false }),

      hydrateAuth: () => {
        try {
          const value = localStorage.getItem(WELCOME_SEEN_KEY)
          set({ welcomeSeen: value === "1" })
        } catch (err) {
          console.warn("[authStore] failed to read welcome-seen flag", err)
          set({ welcomeSeen: true })
        }
      },

      dismissBanner: () => set({ bannerDismissed: true }),

      dismissWelcome: () => {
        set({ welcomeSeen: true, bannerDismissed: true })
        try { localStorage.setItem(WELCOME_SEEN_KEY, "1") } catch {}
      },

      setWelcomeSeen: () => {
        set({ welcomeSeen: true })
        try { localStorage.setItem(WELCOME_SEEN_KEY, "1") } catch {}
      },
    }),
    { name: "auth-store" }
  )
)
```

- [ ] **Step 32.2: Update useHydrateAuth**

Replace `apps/rishi-electron/src/renderer/src/hooks/useHydrateAuth.tsx`:

```tsx
import { useEffect } from "react"
import { useAuthStore } from "@/stores/authStore"

export function useHydrateAuth(): void {
  const setUser = useAuthStore((s) => s.setUser)
  const setAuthHydrated = useAuthStore((s) => s.setAuthHydrated)
  const hydrateAuth = useAuthStore((s) => s.hydrateAuth)
  const closeSignIn = useAuthStore((s) => s.closeSignIn)

  useEffect(() => {
    hydrateAuth()
    void window.api.auth.getSession().then((user) => {
      setUser(user)
      setAuthHydrated(true)
    })
    const off = window.api.auth.onSessionChange((user) => {
      setUser(user)
      if (user) closeSignIn()
    })
    return off
  }, [setUser, setAuthHydrated, hydrateAuth, closeSignIn])
}
```

- [ ] **Step 32.3: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/hooks/useHydrateAuth.tsx apps/rishi-electron/src/renderer/src/stores/authStore.ts
git commit -m "refactor(electron): replace clerk auth hydration with IPC-based"
```

---

## Task 33: Update WelcomeModal, SignInBanner, PremiumFeatureDialog

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/auth/WelcomeModal.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/components/auth/SignInBanner.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/components/auth/PremiumFeatureDialog.tsx`

- [ ] **Step 33.1: WelcomeModal — remove `Sign in` button text from Clerk modal**

Confirm the existing component already calls `openSignIn` from the store (it does in current code at `WelcomeModal.tsx:9`). Just verify the import paths still resolve. No code changes likely needed.

- [ ] **Step 33.2: SignInBanner — same**

Same check; the existing banner uses `useAuthStore` and `openSignIn` directly. No code changes needed.

- [ ] **Step 33.3: PremiumFeatureDialog — replace Clerk usage**

Open `apps/rishi-electron/src/renderer/src/components/auth/PremiumFeatureDialog.tsx`. Find any `useClerk` / `useUser` imports. Replace with `useAuthStore` for user + `openSignIn` for triggering the modal.

- [ ] **Step 33.4: LoginButton, HelpMenu**

Same audit:

```bash
grep -rn "@clerk\|useClerk\|useUser\|useAuth\b\|useSession" apps/rishi-electron/src/renderer/src/components/
```

Replace any matches following the same pattern (use `useAuthStore` for user, IPC for actions).

- [ ] **Step 33.5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/auth/ apps/rishi-electron/src/renderer/src/components/HelpMenu.tsx apps/rishi-electron/src/renderer/src/components/LoginButton.tsx
git commit -m "refactor(electron): components use useAuthStore + IPC instead of clerk hooks"
```

---

## Task 34: Update API client to use IPC token

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/lib/api.ts`

- [ ] **Step 34.1: Replace Clerk token retrieval**

In `apps/rishi-electron/src/renderer/src/lib/api.ts`, find the function/hook that fetches the Clerk session token (search for `getToken` or `Clerk`). Replace with:

```ts
async function getAuthHeaders(): Promise<Record<string, string>> {
  const token = await window.api.auth.getToken()
  return token ? { Cookie: `rishi.session_token=${token}` } : {}
}
```

Apply these headers to outbound `fetch` calls in `getBooks`, `pushSync`, `pullSync`, etc.

- [ ] **Step 34.2: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/lib/api.ts
git commit -m "refactor(electron): api uses IPC-supplied session token"
```

---

## Task 35: Delete ClerkAuth.tsx + remove from root route

**Files:**
- Delete: `apps/rishi-electron/src/renderer/src/components/auth/ClerkAuth.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/routes/__root.tsx`

- [ ] **Step 35.1: Remove import + render**

In `apps/rishi-electron/src/renderer/src/routes/__root.tsx`:
- Remove `import { ClerkAuthSync } from "@/components/auth/ClerkAuth"`
- Remove `<ClerkAuthSync />` from the JSX

- [ ] **Step 35.2: Delete the file**

```bash
rm apps/rishi-electron/src/renderer/src/components/auth/ClerkAuth.tsx
```

- [ ] **Step 35.3: Verify no stragglers**

```bash
grep -rn "@clerk\|ClerkAuth\|useClerk\|ClerkProvider" apps/rishi-electron/src/
# Should be empty
```

- [ ] **Step 35.4: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/routes/__root.tsx
git rm apps/rishi-electron/src/renderer/src/components/auth/ClerkAuth.tsx
git commit -m "chore(electron): remove ClerkAuth integration"
```

---

## Task 36: Settings/account page with delete

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/routes/settings/account.tsx` (or wherever existing settings routes live — adjust path)

- [ ] **Step 36.1: Audit existing settings layout**

```bash
find apps/rishi-electron/src/renderer/src/routes -type d -name "settings*" 2>/dev/null
ls apps/rishi-electron/src/renderer/src/routes/
```

Place the new route appropriately. If no settings exists yet, create `apps/rishi-electron/src/renderer/src/routes/settings.tsx` as an index.

- [ ] **Step 36.2: Create account page**

```tsx
import { createFileRoute } from "@tanstack/react-router"
import { useState } from "react"
import { useAuthStore } from "@/stores/authStore"

export const Route = createFileRoute("/settings/account")({
  component: AccountSettings,
})

function AccountSettings() {
  const user = useAuthStore((s) => s.user)
  const [deleting, setDeleting] = useState(false)
  const [confirmOpen, setConfirmOpen] = useState(false)

  if (!user) return <p className="p-8">Sign in to manage your account.</p>

  async function handleDelete() {
    setDeleting(true)
    try {
      await window.api.auth.deleteAccount()
    } catch (err: any) {
      alert("Failed to delete account: " + (err.message ?? "unknown"))
    } finally {
      setDeleting(false)
      setConfirmOpen(false)
    }
  }

  return (
    <div className="max-w-2xl mx-auto p-8 space-y-8">
      <header>
        <h1 className="text-2xl font-bold">Account</h1>
        <p className="text-gray-600">{user.email}</p>
      </header>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold">Sign out</h2>
        <button
          className="px-4 py-2 border border-gray-300 rounded-lg hover:bg-gray-50"
          onClick={() => window.api.auth.signOut()}
        >Sign out</button>
      </section>

      <section className="pt-8 border-t space-y-3">
        <h2 className="text-lg font-semibold text-red-600">Danger zone</h2>
        <p className="text-sm text-gray-600">Permanently delete your account, library, and all sync data.</p>
        {!confirmOpen ? (
          <button onClick={() => setConfirmOpen(true)} className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700">
            Delete account
          </button>
        ) : (
          <div className="border border-red-300 rounded-lg p-4 bg-red-50 space-y-3">
            <p className="font-medium">Are you sure? This cannot be undone.</p>
            <div className="flex gap-2">
              <button onClick={handleDelete} disabled={deleting} className="px-4 py-2 bg-red-600 text-white rounded-lg disabled:opacity-50">
                {deleting ? "Deleting…" : "Yes, delete"}
              </button>
              <button onClick={() => setConfirmOpen(false)} className="px-4 py-2 border border-gray-300 rounded-lg">Cancel</button>
            </div>
          </div>
        )}
      </section>
    </div>
  )
}
```

- [ ] **Step 36.3: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/routes/settings/
git commit -m "feat(electron): account settings with delete-account"
```

---

# Phase 4 — End-to-end + cleanup

## Task 37: Fix Help tab bug (rejection 2.1(a))

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/HelpMenu.tsx`

- [ ] **Step 37.1: Diagnose**

```bash
cd apps/rishi-electron
pnpm dev
# Click Help tab. Apple's reviewer reported it "highlights and does not respond when clicked".
# Inspect via DevTools, check the click handler.
```

- [ ] **Step 37.2: Fix the unresponsive handler**

The exact fix depends on what's broken. Common causes:
- Event handler not actually wired (missing `onClick`)
- Pointer-events disabled by Tailwind class
- z-index covering the click target

Apply the fix.

- [ ] **Step 37.3: Verify by clicking the button**

- [ ] **Step 37.4: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/HelpMenu.tsx
git commit -m "fix(electron): Help tab clickable (Apple rejection 2.1(a))"
```

---

## Task 38: Smoke test full magic-link flow

**Files:** none (manual verification)

- [ ] **Step 38.1: Build a debug Electron build**

```bash
cd apps/rishi-electron
pnpm run build:mac:debug
```

- [ ] **Step 38.2: Launch and exercise the magic-link flow**

```bash
RISHI_DEBUG=1 ./dist/mac-arm64/Rishi.app/Contents/MacOS/Rishi
```

In the app:
1. Click Sign in
2. Enter your email
3. Click Continue → see "check your email"
4. Open email, click magic link
5. Browser opens app.fidexa.org → completes sign-in → redirects to `rishi-electron://auth/callback`
6. macOS asks "Open in Rishi?" — click Open
7. Verify desktop receives session, modal closes, user info appears

- [ ] **Step 38.3: Test sign-out + delete-account**

- [ ] **Step 38.4: Test Google sign-in (DMG behavior — `process.mas` is false on debug build)**

- [ ] **Step 38.5: No commit (verification only)**

---

## Task 39: Build MAS variant + verify Google button hidden

**Files:** none (verification only)

- [ ] **Step 39.1: Build MAS variant**

(Use existing `electron-builder` MAS configuration if present, or add `mac.target: ["mas"]` for a one-off build.)

```bash
pnpm wrangler mas-build  # or whatever script you have
```

- [ ] **Step 39.2: Verify in MAS build**

Launch the MAS .app. Open the sign-in modal. Confirm the **Google button is not rendered** (because `window.api.auth.isMacAppStore === true`).

- [ ] **Step 39.3: No commit (verification only)**

---

## Task 40: Update App Store Connect submission

**Files:** none (App Store Connect dashboard)

- [ ] **Step 40.1: Add review notes**

In App Store Connect → App Information → App Review Information:

- **Demo account:** _provide a working email + state that magic-link will be sent_
- **Notes:**
  ```
  Sign-in is via magic link (one-time email link). To test:
  1. Click "Sign in"
  2. Enter the demo email above
  3. The reviewer will receive a sign-in email at that address
  4. Click the link in the email to complete sign-in

  Account deletion is available at Settings → Account → Delete account.

  This app uses RFC 8252 (OAuth 2.0 for Native Apps) pattern: the magic link
  is opened by the user's email client, not by the app via `shell.openExternal`.
  This is the same approach used by Notion, Linear, Slack, and Cursor.
  ```

- [ ] **Step 40.2: Submit for review**

- [ ] **Step 40.3: No commit (deployment-adjacent only)**

---

# Final acceptance

After all 40 tasks complete:

- [ ] Magic-link sign-in works end-to-end on macOS, Windows, Linux (DMG)
- [ ] Magic-link sign-in works on MAS build
- [ ] Google sign-in works on DMG build
- [ ] Google sign-in button is hidden on MAS build
- [ ] Account deletion works (verify user row removed from D1)
- [ ] Sign-out clears local session
- [ ] Existing `/sync` and `/upload` routes work with new auth
- [ ] No `@clerk/*` imports remain anywhere in the repo:
  ```bash
  grep -rn "@clerk\|@hono/clerk-auth" apps/ workers/ packages/
  # Should be empty
  ```
- [ ] Help tab bug fixed
- [ ] Worker tests pass; web app builds; Electron typechecks; e2e tests pass
- [ ] App Store Connect resubmission accepted

---

## Notes for executors

- **Don't skip the smoke tests in Tasks 5, 8, 12, 17, 22, 38, 39.** They catch most regressions before later phases get contaminated.
- **Phase 1's `pnpm dev`** runs the worker on `localhost:8787`. If you've changed `PUBLIC_API_URL` or `PUBLIC_WEB_URL`, override per-shell with env vars.
- **TypeScript errors in `src/main/vectordb/embeddings.ts` are pre-existing.** Don't fix them as part of this work.
- **Drizzle migrations are append-only.** Never edit existing migration files; create new ones.
- **Better Auth's React client uses **cookies**, not bearer tokens, by default.** The desktop's IPC layer adapts this by sending the cookie value as a Cookie header on outbound requests.

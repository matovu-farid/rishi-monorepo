import { Hono } from "hono"
import { Redis } from "@upstash/redis/cloudflare"
import { z } from "zod"
import { createAuth } from "../auth"
import type { CloudflareBindings } from "../index"

/**
 * Mobile-app counterpart to `/desktop/*` (workers/worker/src/routes/desktop.ts).
 *
 * Design summary — purely ADDITIVE. Electron's `/desktop/*` flow is untouched.
 *
 *   1. POST /mobile/start
 *      Body: { code_challenge, state?, provider? }
 *      Stores the PKCE challenge + provider in Redis under `mobile:state:<state>`,
 *      then returns `{ state, authUrl }`. authUrl bounces the mobile user
 *      through the web app, which signs them in via the social provider and
 *      then calls POST /mobile/start/complete from the web app side.
 *
 *      The authUrl carries `flow=mobile&client=mobile` so the web app's
 *      handoff listener can tell mobile completions apart from desktop
 *      completions (which call /desktop/start/complete instead).
 *
 *   2. POST /mobile/start/complete
 *      Called from the web app after the user signs in (web Better-Auth
 *      session cookie attached). Writes a `mobile:result:<state>` record
 *      containing the bearer session token + user id + the original PKCE
 *      challenge. Mirrors /desktop/start/complete.
 *
 *   3. GET /mobile/start/complete
 *      The user-agent redirect target. 302s to
 *      `rishimobile://auth/callback?state=<state>` (NO token in URL — PKCE
 *      not yet proven). The mobile app captures the deep link and runs the
 *      verifier exchange below.
 *
 *   4. POST /mobile/start/verify
 *      Body: { state, code_verifier }
 *      The mobile app sends the verifier *out-of-band* from the OAuth
 *      callback URL. The worker hashes it, compares against the stored
 *      challenge, and returns `{ session_token, user_id }` on success.
 *      Single-use: the result record is deleted on success. Mirrors the
 *      PKCE proof in /desktop/poll, just over a single-shot POST rather
 *      than a polling loop (mobile doesn't need polling — it knows when
 *      it's been deep-linked back to).
 *
 * Why not put the token in the deep-link URL (as the readiness doc's
 * example suggested)? Anything in the deep-link URL is observable by
 * other apps on the device that register the same scheme prefix.
 * Keeping the bearer token behind a verifier-bound POST is the same
 * protection /desktop/poll provides for Electron. The executor brief
 * explicitly authorized this choice:
 *
 *   "If that conflicts with Better-Auth conventions, follow whatever
 *    pattern workers/worker/src/routes/desktop.ts already uses for
 *    /desktop/start/complete — consistency with electron is more
 *    important than the spec wording."
 */
export const mobileRoutes = new Hono<{
  Bindings: CloudflareBindings
  Variables: { userId: string }
}>()

const STATE_TTL_SECONDS = 60 * 30 // 30 min — matches desktop
const RESULT_TTL_SECONDS = 60 * 5 // 5 min — mobile should verify immediately after deep link

const ALLOWED_PROVIDERS = ["google", "apple", "password"] as const

const StartBody = z.object({
  code_challenge: z.string().min(43).max(128),
  state: z.uuid().optional(),
  provider: z.enum(ALLOWED_PROVIDERS).optional(),
})

const CompletePostBody = z.object({
  state: z.uuid(),
})

const CompleteGetQuery = z.object({
  state: z.uuid(),
})

const VerifyBody = z.object({
  state: z.uuid(),
  code_verifier: z.string().min(43).max(128),
})

interface StoredState {
  code_challenge: string
  provider: (typeof ALLOWED_PROVIDERS)[number]
  createdAt: number
}

interface StoredResult {
  code_challenge: string
  session_token: string
  user_id: string
  createdAt: number
}

function stateKey(state: string) {
  return `mobile:state:${state}`
}

function resultKey(state: string) {
  return `mobile:result:${state}`
}

async function sha256Base64Url(input: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input))
  return btoa(String.fromCharCode(...new Uint8Array(buf)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "")
}

// ─── POST /start ──────────────────────────────────────────────────────────────
mobileRoutes.post("/start", async (c) => {
  const parsed = StartBody.safeParse(await c.req.json().catch(() => null))
  if (!parsed.success) {
    return c.json({ error: "bad_request", issues: parsed.error.issues }, 400)
  }

  const provider = parsed.data.provider ?? "google"
  const state = parsed.data.state ?? crypto.randomUUID()

  const redis = Redis.fromEnv(c.env)
  const stored: StoredState = {
    code_challenge: parsed.data.code_challenge,
    provider,
    createdAt: Date.now(),
  }
  await redis.set(stateKey(state), stored, { ex: STATE_TTL_SECONDS })

  // Build the URL the mobile client opens in a browser session. It points at
  // the web app's sign-in page with mobile-flow markers — the web app then
  // initiates the actual OAuth/social provider redirect via Better-Auth.
  const webBase = c.env.PUBLIC_WEB_URL
  const authUrl = new URL(`${webBase}/sign-in`)
  authUrl.searchParams.set("login", "true")
  authUrl.searchParams.set("provider", provider)
  authUrl.searchParams.set("state", state)
  authUrl.searchParams.set("client", "mobile")
  authUrl.searchParams.set("flow", "mobile")

  return c.json({ state, authUrl: authUrl.toString() })
})

// ─── POST /start/complete ─────────────────────────────────────────────────────
// Called by the web app after the user has signed in. Mirrors
// /desktop/start/complete: requires a valid web session, writes a result
// record under the same state, and consumes the state record.
mobileRoutes.post("/start/complete", async (c) => {
  const parsed = CompletePostBody.safeParse(await c.req.json().catch(() => null))
  if (!parsed.success) return c.json({ error: "bad_request" }, 400)

  const auth = await createAuth(c.env)
  const session = await auth.api.getSession({ headers: c.req.raw.headers })
  if (!session) return c.json({ error: "unauthorized" }, 401)

  const redis = Redis.fromEnv(c.env)
  const stored = (await redis.get<StoredState>(stateKey(parsed.data.state))) ?? null
  if (!stored) return c.json({ error: "state_expired" }, 400)

  const result: StoredResult = {
    code_challenge: stored.code_challenge,
    session_token: session.session.token,
    user_id: session.user.id,
    createdAt: Date.now(),
  }
  await redis.set(resultKey(parsed.data.state), result, { ex: RESULT_TTL_SECONDS })
  // State is single-use; consume once handed off.
  await redis.del(stateKey(parsed.data.state))

  return c.json({ ok: true })
})

// ─── GET /start/complete ──────────────────────────────────────────────────────
// User-agent redirect target. The web app sends the browser here after it
// writes the result record; we 302 into rishimobile://auth/callback so the
// mobile OS hands control back to the app. Token is NOT in the URL.
mobileRoutes.get("/start/complete", async (c) => {
  const stateParam = c.req.query("state")
  const parsed = CompleteGetQuery.safeParse({ state: stateParam })
  if (!parsed.success) return c.json({ error: "bad_request" }, 400)

  const redis = Redis.fromEnv(c.env)
  const result = await redis.get<StoredResult>(resultKey(parsed.data.state))
  if (!result) return c.json({ error: "state_expired" }, 400)

  const deepLink = `rishimobile://auth/callback?state=${encodeURIComponent(parsed.data.state)}`
  return c.redirect(deepLink, 302)
})

// ─── POST /start/verify (PKCE-bound token exchange) ───────────────────────────
mobileRoutes.post("/start/verify", async (c) => {
  const parsed = VerifyBody.safeParse(await c.req.json().catch(() => null))
  if (!parsed.success) return c.json({ error: "bad_request" }, 400)

  const redis = Redis.fromEnv(c.env)
  const result = await redis.get<StoredResult>(resultKey(parsed.data.state))
  if (!result) return c.json({ error: "expired" }, 410)

  const expected = await sha256Base64Url(parsed.data.code_verifier)
  if (expected !== result.code_challenge) {
    // Do NOT consume the result on a failed verify — otherwise an attacker
    // who guesses `state` can wipe a legitimate user's pending exchange.
    return c.json({ error: "pkce_mismatch" }, 403)
  }

  // Single-use — a replay must fail.
  await redis.del(resultKey(parsed.data.state))

  return c.json({ session_token: result.session_token, user_id: result.user_id })
})

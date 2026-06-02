import { Hono } from "hono"
import { Redis } from "@upstash/redis/cloudflare"
import { z } from "zod"
import { createAuth } from "../auth"
import type { CloudflareBindings } from "../index"

export const desktopRoutes = new Hono<{ Bindings: CloudflareBindings; Variables: { userId: string } }>()

const StartBody = z.object({
  code_challenge: z.string().min(43).max(128),
  redirect_scheme: z.literal("rishi-electron").optional(), // legacy field, ignored — kept for back-compat
  mode: z.enum(["magic-link", "oauth-google"]),
  email: z.email().optional(),
})

const STATE_TTL_SECONDS = 60 * 30 // 30 min — covers slow email delivery
const RESULT_TTL_SECONDS = 60 * 5 // 5 min — desktop should be polling immediately
const COMPLETED_TTL_SECONDS = STATE_TTL_SECONDS // keep idempotency window aligned with the original state lifetime

interface StoredState {
  code_challenge: string
  mode: "magic-link" | "oauth-google"
  email?: string
  createdAt: number
}

interface StoredResult {
  code_challenge: string
  session_token: string
  user_id: string
  createdAt: number
}

interface StoredCompleted {
  user_id: string
  createdAt: number
}

function stateKey(state: string) {
  return `desktop:state:${state}`
}

function resultKey(state: string) {
  return `desktop:result:${state}`
}

function completedKey(state: string) {
  return `desktop:completed:${state}`
}

async function sha256Base64Url(input: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input))
  return btoa(String.fromCharCode(...new Uint8Array(buf)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "")
}

/**
 * Desktop initiates an auth flow.
 * - magic-link: server immediately sends an email with a link to the web app's bridge page.
 * - oauth-google: server returns a URL for the desktop to open in the system browser.
 *
 * The desktop stores the returned `state` along with its locally-generated PKCE
 * `code_verifier`, then polls /desktop/poll until the web app reports completion.
 *
 * No deep-link callback is involved — the web app writes the result into Redis
 * keyed by `state`, and the desktop pulls it via polling.
 */
desktopRoutes.post("/start", async (c) => {
  const body = StartBody.safeParse(await c.req.json())
  if (!body.success) return c.json({ error: "bad_request", issues: body.error.issues }, 400)

  const redis = Redis.fromEnv(c.env)
  const state = crypto.randomUUID()
  const stored: StoredState = {
    code_challenge: body.data.code_challenge,
    mode: body.data.mode,
    email: body.data.email,
    createdAt: Date.now(),
  }
  await redis.set(stateKey(state), stored, { ex: STATE_TTL_SECONDS })

  const webBase = c.env.PUBLIC_WEB_URL

  if (body.data.mode === "magic-link") {
    if (!body.data.email) return c.json({ error: "email_required" }, 400)
    const auth = createAuth(c.env)
    // Better Auth's signInMagicLink sends the email. The callbackURL points at the web app
    // with our state token attached so the DesktopHandoffListener can complete the handoff
    // by writing the resulting session into Redis.
    const callbackURL = `${webBase}/?login=true&state=${encodeURIComponent(state)}`
    await auth.api.signInMagicLink({
      body: { email: body.data.email, callbackURL },
      headers: c.req.raw.headers,
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

const CompleteBody = z.object({ state: z.uuid() })

/**
 * Called by the web app after the user has signed in (via magic link or OAuth).
 * Reads the original `code_challenge` from the state record, then writes a
 * `result` record under the same state. The waiting desktop poll picks it up.
 *
 * Both the state record and the result record are scoped per-state, so multiple
 * concurrent sign-in attempts don't collide.
 */
desktopRoutes.post("/start/complete", async (c) => {
  const body = CompleteBody.safeParse(await c.req.json())
  if (!body.success) return c.json({ error: "bad_request" }, 400)

  // Web app's user must already be signed in (Better Auth session cookie attached)
  const auth = createAuth(c.env)
  const session = await auth.api.getSession({ headers: c.req.raw.headers })
  if (!session) return c.json({ error: "unauthorized" }, 401)

  const redis = Redis.fromEnv(c.env)
  const stored = (await redis.get<StoredState>(stateKey(body.data.state))) ?? null
  if (!stored) {
    // State record is gone — either never existed, expired, or already consumed.
    // A stale browser tab from the original handoff may re-POST after the desktop
    // has already polled; treat that as idempotent for the same signed-in user.
    const completed = await redis.get<StoredCompleted>(completedKey(body.data.state))
    if (completed && completed.user_id === session.user.id) {
      return c.json({ ok: true })
    }
    return c.json({ error: "state_expired" }, 400)
  }

  const result: StoredResult = {
    code_challenge: stored.code_challenge,
    session_token: session.session.token,
    user_id: session.user.id,
    createdAt: Date.now(),
  }
  await redis.set(resultKey(body.data.state), result, { ex: RESULT_TTL_SECONDS })
  // Sentinel scopes idempotency to the same user; a different user re-POSTing
  // the same state after consumption still gets 400.
  const completed: StoredCompleted = {
    user_id: session.user.id,
    createdAt: Date.now(),
  }
  await redis.set(completedKey(body.data.state), completed, { ex: COMPLETED_TTL_SECONDS })
  // State is single-use; once handed off, the original state record is no longer needed
  await redis.del(stateKey(body.data.state))

  return c.json({ ok: true })
})

const PollBody = z.object({
  state: z.uuid(),
  code_verifier: z.string().min(43).max(128),
})

/**
 * Desktop polls until the web app reports completion. PKCE verification:
 * `sha256(code_verifier)` base64url-encoded must equal the stored `code_challenge`.
 *
 * Response codes:
 *   200 — sign-in completed; body is `{ session_token }`
 *   204 — still pending; desktop should poll again
 *   400 — bad request (malformed body)
 *   403 — PKCE mismatch (verifier does not match challenge)
 *   410 — state expired before completion
 *
 * Each successful poll deletes the result record (single-use).
 */
desktopRoutes.post("/poll", async (c) => {
  const body = PollBody.safeParse(await c.req.json())
  if (!body.success) return c.json({ error: "bad_request" }, 400)

  const redis = Redis.fromEnv(c.env)

  const result = await redis.get<StoredResult>(resultKey(body.data.state))
  if (!result) {
    // Either the user hasn't completed sign-in yet, or the whole flow expired.
    // We can't easily tell the difference without an extra read; the desktop's
    // own timeout (~10 min) handles the expired case.
    const stillPendingState = await redis.get(stateKey(body.data.state))
    if (stillPendingState) {
      // No body — 204
      return c.body(null, 204)
    }
    return c.json({ error: "expired" }, 410)
  }

  const expected = await sha256Base64Url(body.data.code_verifier)
  if (expected !== result.code_challenge) {
    return c.json({ error: "pkce_mismatch" }, 403)
  }

  // Single-use — delete result so a second poll with the same state fails
  await redis.del(resultKey(body.data.state))

  return c.json({ session_token: result.session_token })
})

const CancelBody = z.object({
  states: z.array(z.uuid()).max(50),
})

/**
 * Best-effort cleanup for in-flight states the desktop has abandoned (sign-out,
 * delete-account). Deletes both the state and result records so a stale email
 * link click can't write a session into Redis for an attempt the desktop has
 * already given up on.
 *
 * Unauthenticated by design — knowing the state UUID is the only "permission"
 * required, mirroring the trust model of /desktop/poll.
 */
desktopRoutes.post("/cancel", async (c) => {
  const body = CancelBody.safeParse(await c.req.json())
  if (!body.success) return c.json({ error: "bad_request" }, 400)
  if (body.data.states.length === 0) return c.json({ ok: true })

  const redis = Redis.fromEnv(c.env)
  const keys = body.data.states.flatMap((s) => [stateKey(s), resultKey(s), completedKey(s)])
  await redis.del(...keys)
  return c.json({ ok: true })
})

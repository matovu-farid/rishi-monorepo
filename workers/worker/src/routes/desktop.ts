import { Hono } from "hono"
import { z } from "zod"
import { createAuth } from "../auth"
import type { CloudflareBindings } from "../index"

export const desktopRoutes = new Hono<{ Bindings: CloudflareBindings; Variables: { userId: string } }>()

const StartBody = z.object({
  code_challenge: z.string().min(43).max(128),
  redirect_scheme: z.literal("rishi-electron"),
  mode: z.enum(["magic-link", "oauth-google"]),
  email: z.email().optional(),
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

const ExchangeBody = z.object({
  code: z.uuid(),
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

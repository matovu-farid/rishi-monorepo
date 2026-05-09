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

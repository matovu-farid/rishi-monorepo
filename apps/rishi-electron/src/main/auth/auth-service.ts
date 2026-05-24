import { shell, BrowserWindow } from 'electron'
import { generatePkcePair } from './pkce'
import { readSession, writeSession, clearSession } from './session-store'

const API_URL = process.env.RISHI_API_URL ?? 'https://api.fidexa.org'

const POLL_INTERVAL_MS = 2_000
const POLL_TIMEOUT_MS = 10 * 60 * 1_000 // 10 min — covers slow email + click-then-walk-away

interface PollHandle {
  state: string
  code_verifier: string
  startedAt: number
  abort: AbortController
  cancel: () => void
}

interface User {
  id: string
  email: string
  name?: string
  image?: string
}

class AuthService {
  /** Active polls keyed by state. We allow multiple simultaneous flows. */
  private polls: Map<string, PollHandle> = new Map()
  private currentUser: User | null = null
  private listeners: Set<(user: User | null) => void> = new Set()

  async hydrate(): Promise<void> {
    // E2E-only short-circuit: cross-platform-sync test injects a worker-issued
    // session token via env so Playwright can sign the app in without driving
    // the OAuth browser dance. Gated on the env var being present — production
    // builds never see it. Mirror of the worker's `ENABLE_TEST_AUTH` gate and
    // mobile's `setSessionForE2E` (lib/auth.ts).
    const e2eToken = process.env.RISHI_E2E_SESSION_TOKEN
    if (e2eToken && e2eToken.length > 0) {
      await writeSession(e2eToken)
    }

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
    return () => {
      this.listeners.delete(cb)
    }
  }

  private notify() {
    for (const cb of this.listeners) cb(this.currentUser)
  }

  /**
   * Magic-link flow:
   *   - Worker emails the user a link to the web app
   *   - User clicks link → web signs them in → web POSTs to /desktop/start/complete
   *   - We start polling /desktop/poll immediately; pick up the result on the next tick
   */
  async startMagicLink(email: string): Promise<void> {
    const { code_verifier, code_challenge } = generatePkcePair()
    const res = await fetch(`${API_URL}/desktop/start`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email,
        code_challenge,
        mode: 'magic-link'
      })
    })
    if (!res.ok) throw new Error(`magic-link send failed: ${res.status}`)
    const { state } = (await res.json()) as { state: string }
    this.startPolling(state, code_verifier)
  }

  /**
   * Google OAuth flow (DMG-only — `process.mas` blocks it on App Store builds):
   *   - Worker returns a web URL we open in the system browser
   *   - User completes Google sign-in there → web POSTs to /desktop/start/complete
   *   - We poll for the result the same way as magic-link
   */
  async startGoogleSignIn(): Promise<void> {
    if (process.mas) throw new Error('google_unavailable_on_mas')
    const { code_verifier, code_challenge } = generatePkcePair()
    const res = await fetch(`${API_URL}/desktop/start`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        code_challenge,
        mode: 'oauth-google'
      })
    })
    if (!res.ok) throw new Error(`oauth start failed: ${res.status}`)
    const { state, web_url } = (await res.json()) as { state: string; web_url: string }
    this.startPolling(state, code_verifier)
    await shell.openExternal(web_url)
  }

  /** Cancel any in-flight sign-in attempts. Used on sign-out and on app shutdown. */
  cancelAllPolls(): void {
    for (const handle of this.polls.values()) handle.cancel()
    this.polls.clear()
  }

  /**
   * Spawns a background loop that polls /desktop/poll for the given state
   * until the worker returns a session token, the timeout elapses, or the
   * caller cancels.
   *
   * Multiple concurrent polls are allowed (e.g., user retries sign-in with a
   * different email) — they're keyed by state and cancel each other only when
   * one succeeds and triggers a global session-changed event.
   */
  private startPolling(state: string, code_verifier: string): void {
    const abort = new AbortController()
    const handle: PollHandle = {
      state,
      code_verifier,
      startedAt: Date.now(),
      abort,
      cancel: () => {
        abort.abort()
      }
    }
    this.polls.set(state, handle)

    // Read the abort flag through a function call rather than a direct
    // property read on the signal: TS's control-flow analysis narrows
    // `signal.aborted` to `false` once any earlier check has run, but in
    // reality `abort.abort()` is invoked externally via `handle.cancel`
    // (a closure TS can't trace) AND can fire during any `await` window.
    // A function call defeats the narrowing because TS treats the return
    // type as `boolean` at every call site. The `while (true)` form is
    // explicitly permitted by `allowConstantLoopConditions` in
    // eslint.config.mjs.
    const isAborted = (): boolean => abort.signal.aborted
    void (async () => {
      while (true) {
        if (isAborted()) {
          // External abort (signOut/cancelAllPolls) — exit cleanly without
          // re-emitting the delete (already done by cancelAllPolls).
          return
        }
        if (Date.now() - handle.startedAt > POLL_TIMEOUT_MS) {
          console.warn('[auth] poll timeout for state', state)
          this.polls.delete(state)
          return
        }

        let res: Response
        try {
          // eslint-disable-next-line no-await-in-loop -- Polling loop: must await the poll response before deciding whether to keep polling.
          res = await fetch(`${API_URL}/desktop/poll`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ state, code_verifier }),
            signal: abort.signal
          })
        } catch (err) {
          if (isAborted()) {
            // signOut/cancelAllPolls aborted us mid-flight — exit cleanly.
            this.polls.delete(state)
            return
          }
          // Transient network error — log and try again next tick
          console.warn('[auth] poll fetch failed (will retry)', err)
          // eslint-disable-next-line no-await-in-loop -- Polling loop: backoff between retries.
          await sleep(POLL_INTERVAL_MS)
          continue
        }

        // Re-check after every await — a signOut that races with a successful
        // /desktop/poll response must NOT result in a writeSession.
        if (isAborted()) {
          this.polls.delete(state)
          return
        }

        if (res.status === 204) {
          // Still pending
          // eslint-disable-next-line no-await-in-loop -- Polling loop: backoff between polls while pending.
          await sleep(POLL_INTERVAL_MS)
          continue
        }

        if (res.status === 200) {
          // eslint-disable-next-line no-await-in-loop -- Polling loop: parse session_token before persisting and exiting.
          const { session_token } = (await res.json()) as { session_token: string }
          // Double-check post-await: signOut may have aborted while we were
          // parsing JSON. If so, do NOT persist — that would un-sign-out.
          if (isAborted()) {
            this.polls.delete(state)
            return
          }
          this.polls.delete(state)
          // A successful sign-in supersedes any other in-flight attempts
          this.cancelAllPolls()
          // eslint-disable-next-line no-await-in-loop -- Polling loop: must persist session before fetching user (token read from disk).
          await writeSession(session_token)
          // eslint-disable-next-line no-await-in-loop -- Polling loop: fetchUser depends on the freshly-written session.
          this.currentUser = await this.fetchUser(session_token)
          this.notify()
          // Bring the app to the foreground so the user sees the result
          for (const win of BrowserWindow.getAllWindows()) {
            if (win.isMinimized()) win.restore()
            win.focus()
          }
          return
        }

        // 400/403/410 etc. — terminal failure for this state
        // eslint-disable-next-line no-await-in-loop -- Polling loop: read error body before exiting.
        const body = await res.text().catch(() => '')
        console.error('[auth] poll terminal error', res.status, body)
        this.polls.delete(state)
        return
      }
    })()
  }

  async signOut(): Promise<void> {
    // ORDERING IS LOAD-BEARING: we abort the in-flight poll's AbortController
    // synchronously, *before* clearing the session store. If we cleared first,
    // a poll whose 200 response was already in flight could land its
    // writeSession AFTER the clear and un-sign-out the user. Cancelling first
    // ensures the poll callback short-circuits on its post-await
    // `abort.signal.aborted` check.
    //
    // Capture in-flight poll states before cancelling so we can clean them up
    // server-side too — otherwise stale state/result records sit in Redis until
    // their TTL expires, and a races-with-old-attempt scenario can hand the
    // desktop the wrong session token.
    const pendingStates = Array.from(this.polls.keys())
    this.cancelAllPolls()

    const token = await readSession()
    if (token) {
      // Better Auth's sign-out enforces Content-Type: application/json — without
      // it, returns 415 and the DB session stays alive. Same for the body.
      const res = await fetch(`${API_URL}/api/auth/sign-out`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`
        },
        body: '{}'
      }).catch((err: unknown) => {
        console.warn('[auth] sign-out request failed', err)
        return null
      })
      if (res && !res.ok) {
        const body = await res.text().catch(() => '')
        console.warn('[auth] sign-out non-OK', res.status, body)
      }
    }

    if (pendingStates.length > 0) {
      await fetch(`${API_URL}/desktop/cancel`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ states: pendingStates })
      }).catch((err: unknown) => {
        console.warn('[auth] desktop/cancel request failed', err)
      })
    }

    await clearSession()
    this.currentUser = null
    this.notify()
  }

  async deleteAccount(): Promise<void> {
    const pendingStates = Array.from(this.polls.keys())
    this.cancelAllPolls()
    const token = await readSession()
    if (!token) return
    const res = await fetch(`${API_URL}/api/auth/delete-user`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`
      },
      body: '{}'
    })
    if (!res.ok) throw new Error(`delete failed: ${res.status}`)
    if (pendingStates.length > 0) {
      await fetch(`${API_URL}/desktop/cancel`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ states: pendingStates })
      }).catch((err: unknown) => {
        console.warn('[auth] desktop/cancel request failed', err)
      })
    }
    await clearSession()
    this.currentUser = null
    this.notify()
  }

  async getSessionToken(): Promise<string | null> {
    return await readSession()
  }

  private async fetchUser(token: string): Promise<User | null> {
    const res = await fetch(`${API_URL}/api/auth/get-session`, {
      headers: { Authorization: `Bearer ${token}` }
    })
    if (!res.ok) return null
    const data = (await res.json()) as { user: User } | null
    return data?.user ?? null
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms)
  })
}

export const authService = new AuthService()

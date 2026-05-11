import { shell, BrowserWindow } from "electron"
import { generatePkcePair } from "./pkce"
import { readSession, writeSession, clearSession } from "./session-store"

const API_URL = process.env.RISHI_API_URL ?? "https://api.fidexa.org"

const POLL_INTERVAL_MS = 2_000
const POLL_TIMEOUT_MS = 10 * 60 * 1_000 // 10 min — covers slow email + click-then-walk-away

interface PollHandle {
  state: string
  code_verifier: string
  startedAt: number
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
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        email,
        code_challenge,
        mode: "magic-link",
      }),
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
    if (process.mas) throw new Error("google_unavailable_on_mas")
    const { code_verifier, code_challenge } = generatePkcePair()
    const res = await fetch(`${API_URL}/desktop/start`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        code_challenge,
        mode: "oauth-google",
      }),
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
    let cancelled = false
    const handle: PollHandle = {
      state,
      code_verifier,
      startedAt: Date.now(),
      cancel: () => {
        cancelled = true
      },
    }
    this.polls.set(state, handle)

    void (async () => {
      while (!cancelled) {
        if (Date.now() - handle.startedAt > POLL_TIMEOUT_MS) {
          console.warn("[auth] poll timeout for state", state)
          this.polls.delete(state)
          return
        }

        let res: Response
        try {
          res = await fetch(`${API_URL}/desktop/poll`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ state, code_verifier }),
          })
        } catch (err) {
          // Transient network error — log and try again next tick
          console.warn("[auth] poll fetch failed (will retry)", err)
          await sleep(POLL_INTERVAL_MS)
          continue
        }

        if (res.status === 204) {
          // Still pending
          await sleep(POLL_INTERVAL_MS)
          continue
        }

        if (res.status === 200) {
          const { session_token } = (await res.json()) as { session_token: string }
          this.polls.delete(state)
          // A successful sign-in supersedes any other in-flight attempts
          this.cancelAllPolls()
          await writeSession(session_token)
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
        const body = await res.text().catch(() => "")
        console.error("[auth] poll terminal error", res.status, body)
        this.polls.delete(state)
        return
      }
    })()
  }

  async signOut(): Promise<void> {
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
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${token}`,
        },
        body: "{}",
      }).catch((err) => {
        console.warn("[auth] sign-out request failed", err)
        return null
      })
      if (res && !res.ok) {
        const body = await res.text().catch(() => "")
        console.warn("[auth] sign-out non-OK", res.status, body)
      }
    }

    if (pendingStates.length > 0) {
      await fetch(`${API_URL}/desktop/cancel`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ states: pendingStates }),
      }).catch((err) => {
        console.warn("[auth] desktop/cancel request failed", err)
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
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: "{}",
    })
    if (!res.ok) throw new Error(`delete failed: ${res.status}`)
    if (pendingStates.length > 0) {
      await fetch(`${API_URL}/desktop/cancel`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ states: pendingStates }),
      }).catch((err) => {
        console.warn("[auth] desktop/cancel request failed", err)
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
      headers: { Authorization: `Bearer ${token}` },
    })
    if (!res.ok) return null
    const data = (await res.json()) as { user: User } | null
    return data?.user ?? null
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

export const authService = new AuthService()

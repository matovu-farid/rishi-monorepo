import { shell } from "electron"
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
    return () => {
      this.listeners.delete(cb)
    }
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
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Cookie: `rishi.session_token=${token}`,
      },
      body: "{}",
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

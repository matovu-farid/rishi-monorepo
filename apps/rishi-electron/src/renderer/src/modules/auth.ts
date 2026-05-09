/**
 * Auth module — Clerk session JWT helpers.
 *
 * Sign-in is rendered in-app via Clerk's <SignIn /> component. The Clerk
 * SDK exposes the active session globally on `window.Clerk`, so renderer-side
 * helpers can fetch a fresh JWT outside of React without going through a hook.
 *
 * The worker verifies the Clerk session token directly (via @hono/clerk-auth),
 * so there is no longer a separate worker-issued JWT or PKCE deep-link flow.
 */

interface ClerkSession {
  getToken: () => Promise<string | null>
}

interface ClerkGlobal {
  session?: ClerkSession | null
  loaded?: boolean
}

declare global {
  interface Window {
    Clerk?: ClerkGlobal
  }
}

/**
 * Fetch a fresh Clerk session JWT, suitable for `Authorization: Bearer <token>`.
 * Returns `null` when no user is signed in or Clerk hasn't finished loading.
 */
export async function getAuthToken(): Promise<string | null> {
  const session = window.Clerk?.session
  if (!session) return null
  try {
    return await session.getToken()
  } catch {
    return null
  }
}

export async function clearAuth(): Promise<void> {
  return window.electron.clearAuth()
}

export async function getUserFromStore() {
  return window.electron.getUserFromStore()
}

export async function saveUserToStore(user: any) {
  return window.electron.saveUserToStore(user)
}

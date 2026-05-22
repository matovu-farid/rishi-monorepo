/**
 * Mobile auth (Batch 1C) — Better-Auth deep-link flow against the
 * worker `/mobile/*` routes. Replaces the legacy Clerk-exchange code path.
 *
 * Flow:
 *   1. `signIn(provider)` → @rishi/shared.startAuthSession() →
 *      worker POST /mobile/start → { authUrl, state }
 *   2. Open `authUrl` via `expo-web-browser.openAuthSessionAsync` with
 *      `rishimobile://auth/callback` as the return scheme.
 *   3. When the browser dismisses with `type: 'success'`, parse `state`
 *      out of the deep-link URL.
 *   4. POST /mobile/start/verify { state, code_verifier } via
 *      @rishi/shared.completeAuthSession() → { session_token, user_id }
 *   5. Persist `session_token` to expo-secure-store under `rishi.bearer`
 *      and return.
 *
 * The `code_verifier` is held in memory between (1) and (4) so it never
 * leaves the device — the worker only ever sees the challenge until (4).
 *
 * `apiClient` in `lib/api.ts` consumes `getSessionToken()` to attach the
 * bearer to every authenticated request.
 */
// Polyfill crypto.getRandomValues on RN. expo-crypto provides it on iOS/Android
// (the import is side-effecting). In tests the polyfill is a no-op — the test
// file polyfills with node:crypto.webcrypto before importing this module.
import 'expo-crypto'

import * as SecureStore from 'expo-secure-store'
import * as WebBrowser from 'expo-web-browser'
import { startAuthSession, completeAuthSession } from '@rishi/shared/auth/startAuthSession'

const BEARER_KEY = 'rishi.bearer'
const REDIRECT_URI = 'rishimobile://auth/callback'

export const WORKER_API_URL =
  process.env.EXPO_PUBLIC_WORKER_URL || 'https://rishi-worker.fidexa.workers.dev'

export type AuthProvider = 'google' | 'apple' | 'password'

export interface SignInResult {
  session_token: string
  user_id: string
}

/**
 * Kick off a Better-Auth sign-in. Opens an in-app browser, waits for the
 * `rishimobile://auth/callback` deep link, verifies the PKCE proof out-of-band,
 * and persists the resulting bearer token.
 *
 * @throws if the user cancels the browser, the callback URL is malformed,
 *         or the worker rejects the PKCE proof.
 */
export async function signIn(provider: AuthProvider = 'google'): Promise<SignInResult> {
  const { authUrl, state, verifier } = await startAuthSession({
    apiUrl: WORKER_API_URL,
    provider,
  })

  const result = await WebBrowser.openAuthSessionAsync(authUrl, REDIRECT_URI)

  if (result.type !== 'success' || !result.url) {
    throw new Error(`Sign-in cancelled or dismissed (type=${result.type})`)
  }

  const callbackState = parseStateFromCallback(result.url)
  if (!callbackState) {
    throw new Error('Sign-in callback URL is missing the required `state` parameter')
  }
  if (callbackState !== state) {
    // Different state than we started with — likely a stale deep link from a
    // previous attempt. Refuse to proceed.
    throw new Error('Sign-in state mismatch — refusing to proceed')
  }

  const { session_token, user_id } = await completeAuthSession({
    apiUrl: WORKER_API_URL,
    state,
    verifier,
  })

  await SecureStore.setItemAsync(BEARER_KEY, session_token)
  return { session_token, user_id }
}

/**
 * Clear the cached bearer token. Called from the sign-out UI and from
 * `apiClient` when the worker returns 401 (forced re-auth).
 */
export async function signOut(): Promise<void> {
  await SecureStore.deleteItemAsync(BEARER_KEY)
}

/** Read the cached bearer token. Returns null when not signed in. */
export async function getSessionToken(): Promise<string | null> {
  return SecureStore.getItemAsync(BEARER_KEY)
}

/** Convenience: true iff `getSessionToken()` would return non-null. */
export async function isAuthenticated(): Promise<boolean> {
  const t = await getSessionToken()
  return t != null && t.length > 0
}

/**
 * E2E-only: persist a worker-issued session token and hydrate the auth store.
 *
 * Used by the `e2e-action=set-session` deep-link bridge in `app/_layout.tsx`
 * so the cross-platform sync test can sign the app in as a worker-created
 * test user without going through the in-app browser OAuth dance.
 *
 * This mirrors the tail of `signIn()` (secure-store write + zustand
 * `setSession` call) but skips the PKCE handshake.
 *
 * Gated on `IS_E2E_TEST` at the caller — this function itself does NOT check
 * the flag because the production bundle never reaches the bridge.
 */
export async function setSessionForE2E(params: {
  token: string
  userId: string
  email: string | null
}): Promise<void> {
  await SecureStore.setItemAsync(BEARER_KEY, params.token)
  // Dynamic import to keep this module's import graph free of the zustand
  // store (which pulls in MMKV — slow on cold-start for the OAuth path).
  const { useAuthStore } = await import('@/lib/stores/authStore')
  useAuthStore.getState().setSession(params.token, params.userId, params.email)
}

// ── helpers ──────────────────────────────────────────────────────────────────
function parseStateFromCallback(url: string): string | null {
  // Manual parse — `URL` exists in modern RN and Node test envs, but the
  // `?` may legitimately be missing on malformed callbacks. Be defensive.
  const q = url.indexOf('?')
  if (q < 0) return null
  const params = new URLSearchParams(url.substring(q + 1))
  const state = params.get('state')
  return state && state.length > 0 ? state : null
}

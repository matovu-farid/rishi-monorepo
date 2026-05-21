/**
 * Authenticated fetch wrapper for the worker API.
 *
 * Post-Batch-1C: the bearer token is the Better-Auth session token persisted
 * to expo-secure-store by `lib/auth.ts`. There is no longer a Clerk-exchange
 * step — the token IS the session.
 *
 * On 401, we clear the cached bearer and surface the error so the caller can
 * route to the sign-in screen. Silent re-authentication is not possible
 * without re-running the deep-link flow.
 */
import { getSessionToken, signOut, WORKER_API_URL } from './auth'
import { buildDevBypassHeaders, readDevBypassSecret } from './api-dev-bypass'

/**
 * Authenticated fetch. Resolves with the raw Response so the caller can
 * inspect status and body. Throws when no session token is available
 * (caller should redirect to sign-in).
 */
export async function apiClient(
  path: string,
  options: RequestInit = {},
): Promise<Response> {
  const token = await getSessionToken()
  if (!token) {
    throw new Error('Unable to obtain Worker session token. User must sign in.')
  }

  // N01 — Mirror electron's X-Dev-Bypass behaviour. In a dev build with a
  // configured secret, send the header so the worker treats the call as a
  // dev request (skips premium gating). Production builds never send it.
  const devBypassHeaders = buildDevBypassHeaders({
    isDev: typeof __DEV__ !== 'undefined' && __DEV__ === true,
    secret: readDevBypassSecret(),
  })

  const url = `${WORKER_API_URL}${path}`
  const response = await fetch(url, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...options.headers,
      Authorization: `Bearer ${token}`,
      ...devBypassHeaders,
    },
  })

  // 401 means the worker rejected the token (revoked / expired). Clear it so
  // the next call forces a fresh sign-in instead of looping with a dead token.
  if (response.status === 401) {
    await signOut()
    throw new Error('Session expired (401). User must sign in again.')
  }

  return response
}

/**
 * Compatibility shim — older call sites passed a "getClerkToken" function
 * here. We no longer need it (the session token lives in secure-store), but
 * the symbol is kept as a no-op so existing imports don't break until they're
 * cleaned up in a follow-up refactor.
 *
 * @deprecated Remove call sites; the worker session token is fetched directly
 *   from `getSessionToken()` now.
 */
export function initApiClient(_getToken?: () => Promise<string | null>): void {
  // Intentionally a no-op. Kept to avoid breaking `app/(tabs)/_layout.tsx`
  // until that file is updated in the same batch.
}

export { WORKER_API_URL }

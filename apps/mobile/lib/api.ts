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
// Note: `buildDevBypassHeaders` is intentionally NOT imported here. `apiClient`
// throws when no bearer is available, so by construction every request it
// emits already carries `Authorization: Bearer …`. Sending `X-Dev-Bypass`
// alongside the bearer (the prior behaviour) violated the helper's docstring
// ("only when no bearer") and short-circuited the worker's real premium gate
// for signed-in dev users (GAT-107 / #79). The helper remains exported from
// `./api-dev-bypass` for a hypothetical future anonymous-request path.

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

  const url = `${WORKER_API_URL}${path}`
  const response = await fetch(url, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...options.headers,
      Authorization: `Bearer ${token}`,
      // GAT-107 (#79): bearer XOR dev-bypass. Since `token` is guaranteed
      // non-empty above, the dev-bypass header is omitted unconditionally
      // here. The helper's intended use is for unauthenticated requests
      // that need to exercise dev-only worker endpoints.
    },
  })

  // 401 means the worker rejected the token (revoked / expired). Clear it so
  // the next call forces a fresh sign-in instead of looping with a dead token.
  //
  // H1-03: clear both the secure-store bearer AND the in-memory authStore.
  // `signOut()` alone only wipes secure-store, so the UI would keep showing
  // the user as signed-in even though every subsequent request now fails
  // with "no session token". The authStore import is lazy (require inside
  // the branch) to avoid pulling Zustand into modules that don't need it
  // and to dodge the test-mock ordering issues that an eager import would
  // create for callers that mock `@/lib/api`.
  if (response.status === 401) {
    await signOut()
    try {
      const { useAuthStore } = require('@/lib/stores/authStore') as {
        useAuthStore: { getState: () => { clearSession: () => void } }
      }
      useAuthStore.getState().clearSession()
    } catch (err) {
      console.warn('[api] failed to clear authStore after 401:', err)
    }
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

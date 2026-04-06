import { getWorkerToken, exchangeToken, clearWorkerToken, WORKER_API_URL } from './auth'

type GetClerkToken = () => Promise<string | null>

let _getClerkToken: GetClerkToken | null = null

/**
 * Initialize the API client with the Clerk getToken function.
 * Must be called once from a component that has access to useAuth().
 */
export function initApiClient(getClerkToken: GetClerkToken) {
  _getClerkToken = getClerkToken
}

/**
 * Authenticated fetch wrapper.
 *
 * 1. Gets Worker JWT from SecureStore
 * 2. If no JWT (or expired), exchanges Clerk token for a new Worker JWT
 * 3. Makes the request with Authorization: Bearer <worker_jwt>
 * 4. On 401 response, clears stored JWT, re-exchanges, and retries ONCE
 */
export async function apiClient(
  path: string,
  options: RequestInit = {}
): Promise<Response> {
  let token = await getWorkerToken()

  // If no valid token, exchange
  if (!token) {
    token = await refreshWorkerToken()
  }

  if (!token) {
    throw new Error('Unable to obtain Worker JWT. User may need to re-authenticate.')
  }

  const url = `${WORKER_API_URL}${path}`
  const response = await fetch(url, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...options.headers,
      'Authorization': `Bearer ${token}`,
    },
  })

  // If 401, try refreshing token once
  if (response.status === 401) {
    await clearWorkerToken()
    const newToken = await refreshWorkerToken()

    if (!newToken) {
      throw new Error('Re-authentication failed. User needs to sign in again.')
    }

    return fetch(url, {
      ...options,
      headers: {
        'Content-Type': 'application/json',
        ...options.headers,
        'Authorization': `Bearer ${newToken}`,
      },
    })
  }

  return response
}

/**
 * Exchange Clerk session token for a Worker JWT.
 * Uses the getClerkToken function registered via initApiClient.
 */
async function refreshWorkerToken(): Promise<string | null> {
  if (!_getClerkToken) {
    console.error('API client not initialized. Call initApiClient(getToken) first.')
    return null
  }

  const clerkToken = await _getClerkToken()
  if (!clerkToken) {
    return null
  }

  try {
    const result = await exchangeToken(clerkToken)
    return result.token
  } catch (error) {
    console.error('Token exchange failed:', error)
    return null
  }
}

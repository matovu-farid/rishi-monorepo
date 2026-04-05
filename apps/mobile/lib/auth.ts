import * as SecureStore from 'expo-secure-store'

const WORKER_JWT_KEY = 'worker_jwt'
const WORKER_JWT_EXPIRY_KEY = 'worker_jwt_expiry'
const WORKER_API_URL = process.env.EXPO_PUBLIC_WORKER_URL || 'https://rishi-worker.fidexa.workers.dev'

interface ExchangeResponse {
  token: string
  expiresAt: number
  user: {
    id: string
    firstName: string | null
    lastName: string | null
    fullName: string | null
    username: string | null
    imageUrl: string
    hasImage: boolean
    lastSignInAt: number | null
    externalId: string | null
  }
}

/**
 * Exchange a Clerk session token for a Worker JWT.
 * Stores the JWT and its expiry in SecureStore.
 * Returns the exchange response.
 */
export async function exchangeToken(clerkSessionToken: string): Promise<ExchangeResponse> {
  const response = await fetch(`${WORKER_API_URL}/api/auth/exchange`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${clerkSessionToken}`,
      'Content-Type': 'application/json',
    },
  })

  if (!response.ok) {
    const body = await response.json().catch(() => ({}))
    throw new Error(body.error || `Token exchange failed with status ${response.status}`)
  }

  const data: ExchangeResponse = await response.json()

  await SecureStore.setItemAsync(WORKER_JWT_KEY, data.token)
  await SecureStore.setItemAsync(WORKER_JWT_EXPIRY_KEY, String(data.expiresAt))

  return data
}

/**
 * Get the stored Worker JWT if it exists and is not expired.
 * Returns null if no token or token is expired (with 5-minute buffer).
 */
export async function getWorkerToken(): Promise<string | null> {
  const token = await SecureStore.getItemAsync(WORKER_JWT_KEY)
  const expiryStr = await SecureStore.getItemAsync(WORKER_JWT_EXPIRY_KEY)

  if (!token || !expiryStr) return null

  const expiry = parseInt(expiryStr, 10)
  const now = Math.floor(Date.now() / 1000)
  const BUFFER_SECONDS = 300 // 5 minutes before actual expiry

  if (now >= expiry - BUFFER_SECONDS) {
    // Token expired or about to expire
    await clearWorkerToken()
    return null
  }

  return token
}

/**
 * Clear stored Worker JWT and expiry.
 */
export async function clearWorkerToken(): Promise<void> {
  await SecureStore.deleteItemAsync(WORKER_JWT_KEY)
  await SecureStore.deleteItemAsync(WORKER_JWT_EXPIRY_KEY)
}

export { WORKER_API_URL }

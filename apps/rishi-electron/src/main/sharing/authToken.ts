import { authService } from '../auth/index.js'
import type { SharingSignedJwt } from '../../preload/ipc-contract.js'

/**
 * Returns the current user's session JWT for use as the signed token in
 * sharing handshakes. The token is sourced from the auth service; if the
 * user is not signed in this rejects with `not_authenticated`.
 *
 * The `expiresAt` value is an advisory client-side hint (5 minutes from
 * now) — the worker is the source of truth for token expiry.
 */
export async function getSigningJwt(): Promise<SharingSignedJwt> {
  const token = await authService.getSessionToken()
  if (!token) {
    throw new Error('not_authenticated')
  }
  return { jwt: token, expiresAt: Date.now() + 5 * 60 * 1000 }
}

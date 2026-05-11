/**
 * Auth module — thin renderer-side wrappers over the auth IPC surface.
 *
 * The main process owns the Better Auth session token (encrypted at rest
 * via Electron `safeStorage`). The renderer never sees raw cookies; it
 * just asks the preload bridge for whatever it needs at the moment.
 */

/**
 * Returns the current Better Auth session token, or `null` if not signed in.
 * Token is fetched via IPC from the main process where it's stored encrypted.
 *
 * Suitable for forwarding to backends that accept the same token (we send
 * it as an `Authorization: Bearer …` header to the worker — `Cookie` is a
 * forbidden header in Chromium's fetch and is silently dropped).
 */
export async function getAuthToken(): Promise<string | null> {
  return await window.api.auth.getToken()
}

/** Whether this build is destined for the Mac App Store. */
export const isMacAppStore = window.api?.auth?.isMacAppStore ?? false

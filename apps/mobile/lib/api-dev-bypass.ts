/**
 * N01 — Dev-bypass header helper for the mobile worker client.
 *
 * Electron's `apps/rishi-electron/src/renderer/src/lib/api.ts` adds an
 * `X-Dev-Bypass: <secret>` header to API requests when no auth bearer is
 * available, so dev builds can hit premium endpoints (TTS, realtime
 * secrets, sync) without an active subscription. The worker checks the
 * header against the `DEV_BYPASS_SECRET` env var and lets the request
 * through in dev environments.
 *
 * Mobile reads the secret from Expo's runtime config (`Constants.expoConfig
 * .extra.devBypassSecret`) — see `app.config.ts`. If unset, no header is
 * emitted.
 *
 * The helper is a pure function so it can be unit-tested without RN globals.
 */
import Constants from 'expo-constants'

/**
 * Read the dev-bypass secret from Expo runtime config. Returns null if
 * unset. Safe to call outside React.
 */
export function readDevBypassSecret(): string | null {
  // Expo's extra block survives both expoConfig and manifest paths.
  const extra =
    (Constants?.expoConfig?.extra as Record<string, unknown> | undefined) ?? {}
  const raw = extra.devBypassSecret
  if (typeof raw === 'string' && raw.length > 0) return raw
  // Process env support for tests / CI.
  const envSecret = process.env?.DEV_BYPASS_SECRET
  if (typeof envSecret === 'string' && envSecret.length > 0) return envSecret
  return null
}

export interface DevBypassInputs {
  isDev: boolean
  secret: string | null | undefined
}

/**
 * Build the header object to spread into a fetch request. Returns `{}`
 * unless `isDev=true` AND a non-empty secret is supplied.
 */
export function buildDevBypassHeaders(
  inputs: DevBypassInputs,
): Record<string, string> {
  if (!inputs.isDev) return {}
  const secret = inputs.secret
  if (typeof secret !== 'string' || secret.length === 0) return {}
  return { 'X-Dev-Bypass': secret }
}

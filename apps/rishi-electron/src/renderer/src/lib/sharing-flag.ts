/**
 * Returns true if the shared-reading feature UI should be shown.
 *
 * Layer 1 — Build-time: VITE_SHARING_ENABLED=1 (set in the release build pipeline).
 * Layer 2 — Runtime: localStorage key `rishi:sharing-enabled` = '1'.
 *           Lets internal testers opt in on a production build without a redeploy.
 *           Clear the key to opt back out: localStorage.removeItem('rishi:sharing-enabled').
 *
 * Rollback (all users): redeploy without VITE_SHARING_ENABLED set.
 */
export function isSharingEnabled(): boolean {
  if (import.meta.env.VITE_SHARING_ENABLED === '1') return true
  try {
    return localStorage.getItem('rishi:sharing-enabled') === '1'
  } catch {
    return false
  }
}

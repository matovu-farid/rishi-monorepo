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

/**
 * Phase 2/3 rollout gate: combines `isSharingEnabled()` with
 * `VITE_SHARING_ROLLOUT_PCT` for a deterministic per-user shard.
 *
 * Semantics:
 *  - If the feature flag is off, always returns false.
 *  - If `VITE_SHARING_ROLLOUT_PCT` is unset/empty, behave as if pct=100 so
 *    Phase 0 / Phase 1 / Phase 3 builds keep working without env changes.
 *    Phase 2 (e.g. 10%) is opted in by explicitly setting
 *    VITE_SHARING_ROLLOUT_PCT=10.
 *  - pct >= 100 → all users in bucket.
 *  - pct <= 0   → no users in bucket (early-out for clarity).
 *  - Otherwise: deterministic FNV-style hash of userId mod 100 < pct.
 *
 * The hash is stable across calls so a given userId always lands in the
 * same bucket — no flapping between renders.
 */
export function isSharingEnabledForUser(userId: string): boolean {
  if (!isSharingEnabled()) return false
  const raw = import.meta.env.VITE_SHARING_ROLLOUT_PCT
  const ROLLOUT_PCT = raw === undefined || raw === '' ? 100 : Number(raw)
  if (ROLLOUT_PCT >= 100) return true
  if (ROLLOUT_PCT <= 0) return false
  // Deterministic bucket: same user always gets same answer.
  let hash = 0
  for (let i = 0; i < userId.length; i++) hash = (hash * 31 + userId.charCodeAt(i)) >>> 0
  return hash % 100 < ROLLOUT_PCT
}

# Shared Reading — Staged Rollout Runbook

## Phase 0: Internal (team only, no redeploy needed)

**Trigger:** Worker deployed, Plan 2 merged, E2E suite green.

**Enable:** Each tester opens Electron DevTools console (View → Toggle DevTools) and runs:
```js
localStorage.setItem('rishi:sharing-enabled', '1')
// Then reload: location.reload()
```

**Disable:** `localStorage.removeItem('rishi:sharing-enabled')` + reload.

**Watch during Phase 0:**
- Logpush → R2 bucket `rishi-sharing-logs`: look for `session.created` and `peer.admitted` events.
- Cloudflare dashboard → Workers → `rishi-sharing-worker` → Metrics: CPU time, request count.
- Sentry (existing Electron SDK): filter by tag `feature=sharing`.

---

## Phase 1: Opt-in Beta

**Trigger:** No P0 bugs in Phase 0 after 1 week.

**How:** Ship a new Electron build with `VITE_SHARING_ENABLED=1`.
Add a "Beta: Shared Reading" toggle in Settings UI (Plan 2 scope).
The toggle sets/clears `localStorage['rishi:sharing-enabled']`.
The feature is OFF by default even with `VITE_SHARING_ENABLED=1` until the user flips the toggle.

**Rollback:** Deploy a new build with `VITE_SHARING_ENABLED` unset.
All users lose the UI on next auto-update. Existing live sessions complete normally.

---

## Phase 2: 10% of users

**Trigger:** Beta stable for 2 weeks, ICE failure rate < 5% of sessions.

**How:** Add a shard gate to `sharing-flag.ts` (in addition to the existing flags):

```ts
export function isSharingEnabledForUser(userId: string): boolean {
  if (!isSharingEnabled()) return false
  const ROLLOUT_PCT = Number(import.meta.env.VITE_SHARING_ROLLOUT_PCT ?? 0)
  if (ROLLOUT_PCT >= 100) return true
  // Deterministic bucket: same user always gets same answer.
  let hash = 0
  for (let i = 0; i < userId.length; i++) hash = (hash * 31 + userId.charCodeAt(i)) >>> 0
  return (hash % 100) < ROLLOUT_PCT
}
```

Ship build with `VITE_SHARING_ENABLED=1 VITE_SHARING_ROLLOUT_PCT=10`.
Reader toolbar calls `isSharingEnabledForUser(me.userId)` instead of `isSharingEnabled()`.

**Rollback:** Redeploy with `VITE_SHARING_ROLLOUT_PCT=0` (or omit env var entirely).

---

## Phase 3: 50% → 100%

Increment `VITE_SHARING_ROLLOUT_PCT` in successive builds: 50, then 100.
At 100%, simplify: remove the PCT gate and keep `VITE_SHARING_ENABLED=1` only.

---

## Telemetry gate — pause rollout if any threshold is breached

| Signal | Source | Threshold |
|---|---|---|
| Worker error rate | Logpush saved query 4 | > 1% in any 5-min window |
| `session.ended reason=error` | Logpush saved query 3 | > 5% of sessions in 1h |
| ICE failure modal shown | Sentry breadcrumb `sharing.ice_failed` | > 10% of sessions |
| File transfer `FAILED` events | Sentry tag `actor=fileTransferActor` | > 3% of transfers |
| Worker CPU P99 | Cloudflare Workers Metrics | > 50ms sustained 5 min |

**How to pause:** Redeploy with `VITE_SHARING_ROLLOUT_PCT=0`. Users at Phase 2+ lose the UI on next auto-update. Sessions already live are unaffected until participants leave.

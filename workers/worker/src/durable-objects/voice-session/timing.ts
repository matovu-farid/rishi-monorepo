/** Voice Chat ledger interval length (ms). */
export const VOICE_INTERVAL_MS = 30_000;

/** Abandoned realtime registration grace (ms). */
export const REGISTRATION_GRACE_MS = 10_000;

/** Idle window before inactivity_timeout (ms). */
export const INACTIVITY_TIMEOUT_MS = 5 * 60_000;

/**
 * Idle age from `lastActivityAt` only. Null last → treat as idle immediately
 * (do not fall back to tick-bumped `updatedAt`).
 */
export function idleAgeMs(lastActivityAt: number | null | undefined, now: number): number | null {
  if (lastActivityAt == null) return null;
  return now - lastActivityAt;
}

/**
 * Whether tick should terminate for inactivity.
 * Applies to all live voice sessions once client_activity pings ship.
 */
export function shouldTerminateForInactivity(
  lastActivityAt: number | null | undefined,
  now: number,
  _sessionKind?: "cascade" | "realtime",
): boolean {
  return lastActivityAt == null || now - lastActivityAt >= INACTIVITY_TIMEOUT_MS;
}

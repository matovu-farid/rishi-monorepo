export const CONFIG = {
  MAX_PARTICIPANTS: 5,
  VIEWER_SLOT_GRACE_MS: 30_000,
  HOST_GRACE_MS: 120_000,
  APPROVAL_TIMEOUT_MS: 120_000,
  STORAGE_PURGE_AFTER_END_MS: 5 * 60_000,
  JOIN_TOKEN_TTL_MS: 24 * 60 * 60_000,
  RECONNECT_TOKEN_BUFFER_MS: 5_000,
  PING_TIMEOUT_MS: 30_000,
  RATE_LIMITS: {
    sessionsPerUserPerHour: 10,
    joinAttemptsPerIpPerToken: 5,
    framesPerSocketPerSec: 60,
    requestSharerCooldownMs: 15_000,
    sdpRelaysPerSession: 200,
  },
} as const;

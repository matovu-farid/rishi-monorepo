export type VoiceSessionErrorCode =
  | "session_already_active"
  | "insufficient_credits"
  | "insufficient_paid_allowance"
  | "no_active_session"
  | "session_id_mismatch"
  | "nonce_mismatch"
  | "nonce_replayed"
  | "call_already_registered"
  | "hangup_failed";

/**
 * All voice-session-related failures the `UserUsageLedger` DO can throw are
 * instances of this class so callers (and, eventually, the plan-4 route) can
 * branch on `.code` instead of parsing `.message` strings.
 */
export class VoiceSessionError extends Error {
  readonly code: VoiceSessionErrorCode;

  constructor(code: VoiceSessionErrorCode, message: string) {
    super(message);
    this.name = "VoiceSessionError";
    this.code = code;
  }
}

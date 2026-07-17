export type VoiceSessionTerminalReason =
  | "voice_session_time_cap"
  | "trial_credits_exhausted"
  | "registration_timeout";

/** Sent as a follow-up `session_ended` reason if OpenAI hangup never succeeds after bounded retries. */
export type HangupFailureReason = "provider_hangup_failed";

export type ControlMessage =
  | {
      type: "allowance_remaining";
      rishiSessionId: string;
      remainingCredits: number;
      remainingIntervals: number;
    }
  | { type: "session_ending"; rishiSessionId: string }
  | {
      type: "session_ended";
      rishiSessionId: string;
      reason: VoiceSessionTerminalReason | HangupFailureReason;
    }
  | { type: "session_error"; rishiSessionId: string; code: string; message: string };

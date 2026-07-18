import type { VoiceSessionStatus } from "../user-usage-ledger/schema";

export type VoiceSessionTerminalReason =
  | "voice_session_time_cap"
  | "trial_credits_exhausted"
  | "registration_timeout"
  | "plan_voice_allowance_exhausted";

/** Sent as a follow-up `session_ended` reason if OpenAI hangup never succeeds after bounded retries. */
export type HangupFailureReason = "provider_hangup_failed";

export type ControlMessage =
  | {
      type: "allowance_remaining";
      rishiSessionId: string;
      remainingTrialCredits: number;
      remainingVoiceChatSeconds: number;
      remainingIntervals: number;
    }
  | { type: "session_ending"; rishiSessionId: string }
  | {
      type: "session_ended";
      rishiSessionId: string;
      reason: VoiceSessionTerminalReason | HangupFailureReason;
    }
  | { type: "session_error"; rishiSessionId: string; code: string; message: string }
  | {
      /**
       * Sent exactly once, immediately after every successful control-WebSocket
       * upgrade (a brand-new connect AND a reconnect after a drop, app
       * relaunch, or DO hibernation), so the client resyncs to current state
       * instead of replaying a complete history. `reason` is present only
       * when `status === "terminal"`. Built by `UserUsageLedger.fetch()`
       * (2026-07-17-voice-control-websocket.md) from
       * `getSessionSnapshot()`'s (2026-07-17-user-usage-ledger-voice-session.md)
       * return value.
       */
      type: "snapshot";
      rishiSessionId: string;
      status: VoiceSessionStatus;
      remainingTrialCredits?: number;
      remainingVoiceChatSeconds?: number;
      remainingIntervals?: number;
      reason?: VoiceSessionTerminalReason;
    };

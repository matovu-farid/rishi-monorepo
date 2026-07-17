import type { Context } from "hono";

import type { VoiceSessionErrorCode } from "../durable-objects/voice-session/errors";

/**
 * Cloudflare Workers RPC does not propagate custom `Error` subclasses or
 * their own properties across a Durable Object RPC boundary — only
 * `.message` (and, for the ECMAScript-standard Error subtypes only,
 * `.name`) survive a `stub.createVoiceSession()` / `stub.registerCallId()`
 * call. See
 * https://developers.cloudflare.com/workers/runtime-apis/rpc/error-handling/
 * ("Own properties of error objects... are not propagated back to the
 * caller.") This means the Durable Object's `VoiceSessionError.code` (set by
 * `2026-07-17-user-usage-ledger-voice-session.md`'s
 * `durable-objects/voice-session/errors.ts`) does NOT arrive here as `.code`
 * and `err instanceof VoiceSessionError` is always `false` — see
 * `2026-07-17-voice-sessions-route.md`'s "Important correction before you
 * start" section. This table matches on a stable substring of each of the
 * ledger's exact, hand-verified message strings instead. If the ledger's
 * message wording ever changes, this table must be updated to match, or the
 * affected error silently falls through to the generic 500 branch in
 * `voiceSessionErrorResponse` below.
 */
interface VoiceSessionErrorMapping {
  code: VoiceSessionErrorCode;
  status: 400 | 402 | 404 | 409;
  wireCode: string;
}

const VOICE_SESSION_ERROR_MATCHERS: ReadonlyArray<{
  test: (message: string) => boolean;
  mapping: VoiceSessionErrorMapping;
}> = [
  {
    // createVoiceSession(): "a voice session is already active for this user"
    test: (m) => m.includes("voice session is already active"),
    mapping: { code: "session_already_active", status: 409, wireCode: "VOICE_SESSION_ALREADY_ACTIVE" },
  },
  {
    // createVoiceSession(): `only ${n} trial credits remain; need at least ${k}`
    test: (m) => m.includes("trial credits remain; need at least"),
    mapping: { code: "insufficient_credits", status: 402, wireCode: "INSUFFICIENT_TRIAL_CREDITS" },
  },
  {
    // createVoiceSession(): `only ${n}s of paid Voice Chat allowance remain; need at least ${k}s`
    // Not documented in the original plan (added by the ledger's later
    // paid-plan support) — matched here on the same "insufficient
    // allowance" shape as INSUFFICIENT_TRIAL_CREDITS above, since it is the
    // same 402/"buy more" signal for a paid-plan account instead of a trial
    // account. See this file's deviation note in the plan execution report.
    test: (m) => m.includes("of paid Voice Chat allowance remain; need at least"),
    mapping: { code: "insufficient_paid_allowance", status: 402, wireCode: "INSUFFICIENT_PAID_ALLOWANCE" },
  },
  {
    // registerCallId(): "no active voice session to register a call against"
    test: (m) => m.includes("no active voice session to register"),
    mapping: { code: "no_active_session", status: 404, wireCode: "NO_ACTIVE_VOICE_SESSION" },
  },
  {
    // registerCallId(): "rishiSessionId does not match the active session"
    test: (m) => m.includes("does not match the active session"),
    mapping: { code: "session_id_mismatch", status: 400, wireCode: "VOICE_SESSION_ID_MISMATCH" },
  },
  {
    // registerCallId(): "this session has already completed call-ID registration"
    test: (m) => m.includes("already completed call-ID registration"),
    mapping: { code: "call_already_registered", status: 409, wireCode: "CALL_ALREADY_REGISTERED" },
  },
  {
    // registerCallId(): "this registration nonce has already been used"
    test: (m) => m.includes("registration nonce has already been used"),
    mapping: { code: "nonce_replayed", status: 409, wireCode: "REGISTRATION_NONCE_REPLAYED" },
  },
  {
    // registerCallId(): "registration nonce did not verify"
    test: (m) => m.includes("registration nonce did not verify"),
    mapping: { code: "nonce_mismatch", status: 400, wireCode: "REGISTRATION_NONCE_INVALID" },
  },
];

function classifyVoiceSessionError(err: unknown): VoiceSessionErrorMapping | null {
  if (!(err instanceof Error)) return null;
  for (const { test, mapping } of VOICE_SESSION_ERROR_MATCHERS) {
    if (test(err.message)) return mapping;
  }
  return null;
}

/**
 * Converts any error thrown by a `createVoiceSession()`/`registerCallId()`
 * RPC call into a Hono JSON response. `err.message` is always the real
 * ledger-side message (that part of the error does survive RPC), so
 * unrecognized `VoiceSessionError`s still surface a useful message even if
 * this file's matcher table is out of date — they just get a generic 500
 * instead of the specific 4xx. Never throws.
 */
export function voiceSessionErrorResponse(c: Context, err: unknown): Response {
  const mapping = classifyVoiceSessionError(err);
  const message = err instanceof Error ? err.message : "Unexpected error";

  if (mapping) {
    console.warn(
      JSON.stringify({ event: "voice_sessions.rejected", code: mapping.code, wireCode: mapping.wireCode }),
    );
    return c.json({ error: message, code: mapping.wireCode }, mapping.status);
  }

  console.error(JSON.stringify({ event: "voice_sessions.unexpected_error", message }));
  return c.json({ error: "Unexpected error", code: "INTERNAL_ERROR" }, 500);
}

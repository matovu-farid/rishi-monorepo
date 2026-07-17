import { createDb } from "../db/drizzle";
import { usageAuditLog } from "../db/schema";

/**
 * Exact `event.kind` values to use — one per item in the pricing/trial
 * design doc's "Telemetry, abuse, and rollout controls" section: "write
 * auditable provider-use events for cache result, request size, reservation
 * outcome, generated duration, model/rate-card version, Realtime token
 * totals, session duration, plan source, and terminal reason." Callers
 * MUST use one of these — inventing ad-hoc kind strings means downstream
 * dashboards/alerts built on `usageAuditLog.eventType` silently miss events.
 */
export type ProviderUsageEventKind =
  | "cache_result" // TTS: "hit" | "miss" — did this request avoid an OpenAI call
  | "request_size" // TTS: input character count of the request
  | "reservation_outcome" // ledger reservation: "committed" | "released" (+ why)
  | "generated_duration" // TTS: parsed audio duration in seconds (server-measured, never client playback time)
  | "model_rate_card_version" // which OpenAI model + which DEFAULT_RATES snapshot priced this event
  | "realtime_token_totals" // Voice Chat: audio/text input+output token counts for one session or one 30s tick
  | "session_duration" // Voice Chat: total seconds a session ran, recorded at terminal state
  | "plan_source" // which plan (trial | reader | voice) funded this unit of usage
  | "terminal_reason"; // Voice Chat: why a session ended — mirrors session_ended's reasons (voice_session_time_cap | trial_credits_exhausted | plan_voice_allowance_exhausted | subscription_required | provider_hangup_failed)

/**
 * Writes one row to the EXISTING `usage_audit_log` table (added by plan 1;
 * this module does not create a second table). `userId` is nullable for
 * system-level events with no single owning user (e.g. a reconciliation
 * sweep) — matches `usageAuditLog.userId`'s own nullability.
 *
 * NEVER put any of the following into `details` — these are provider-use
 * events, not application logs, and get treated as durable/queryable
 * accounting data:
 *   - book text / narration input text (privacy — this is the user's own
 *     library content, never provider-accounting metadata)
 *   - audio bytes, audio URLs, or any other raw media
 *   - ephemeral secrets: OpenAI Realtime client secrets, session/JWT tokens
 *   - OpenAI `call_id` values — the no-card-credit-trial design doc is
 *     explicit that a call ID is "never exposed to another user or
 *     returned by public APIs"; that rule applies here too.
 * `details` should only ever carry small, structured accounting facts:
 * counts, durations, enum-like strings, model/version identifiers, boolean
 * outcomes — the kind of thing you'd be comfortable displaying on an
 * internal ops dashboard.
 */
export async function recordProviderUsageEvent(
  env: Env,
  userId: string | null,
  event: { kind: ProviderUsageEventKind; details: Record<string, unknown> },
): Promise<void> {
  const db = createDb(env.DB);
  await db
    .insert(usageAuditLog)
    .values({
      id: crypto.randomUUID(),
      userId,
      eventType: event.kind,
      details: JSON.stringify(event.details),
      createdAt: new Date(),
    })
    .run();
}

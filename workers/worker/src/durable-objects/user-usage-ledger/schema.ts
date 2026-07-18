import { sqliteTable, text, integer } from "drizzle-orm/sqlite-core";

// `UserUsageLedger` is one Durable Object per user, so `trialLedger` only
// ever holds a single row per object, addressed by this fixed id.
export const TRIAL_LEDGER_ROW_ID = "trial";

export const trialLedger = sqliteTable("trial_ledger", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull(),
  initialCredits: integer("initial_credits").notNull(),
  usedCredits: integer("used_credits").notNull(),
  grantedAt: integer("granted_at").notNull(), // epoch ms
});

// Shared by trial TTS reservations (this plan) and future trial/paid voice
// interval reservations (plan 3/4) — same reserve/commit/release lifecycle,
// so one table now avoids a schema migration when voice intervals land.
export const reservations = sqliteTable("reservations", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull(),
  kind: text("kind", { enum: ["tts", "voice_interval"] }).notNull(),
  amount: integer("amount").notNull(),
  // "expired" is a distinct terminal status from "released": both return
  // the reservation's hold on the pool, but "expired" is set only by the
  // alarm-driven reconciliation sweep (`reconcileStaleReservations` in
  // ledger.ts) for a reservation whose owning request never came back to
  // commit or release it, whereas "released" is always an explicit
  // caller action.
  status: text("status", { enum: ["pending", "committed", "released", "expired"] }).notNull(),
  createdAt: integer("created_at").notNull(), // epoch ms; also this reservation's "reservedAt" for staleness checks
  settledAt: integer("settled_at"), // epoch ms, null while pending
  // Which allowance pool was active AT RESERVATION TIME, captured once in
  // `reserveTts()` and read back (never re-derived) in
  // `commitTtsReservation()` — see that method's doc comment for why.
  // Nullable because reservations created before this column existed
  // (and any restored from an older DO snapshot) won't have it set; those
  // fall back to the pre-fix "re-derive the active pool at commit time"
  // behavior.
  poolKind: text("pool_kind", { enum: ["trial", "paid"] }),
  // `currentAllowancePeriod.periodId` this reservation was reserved
  // against. Only ever set when `poolKind === "paid"`.
  allowancePeriodId: text("allowance_period_id"),
});

// Voice-chat session lifecycle — one row per Rishi voice session (not per
// interval). Added by 2026-07-17-user-usage-ledger-voice-session.md, which
// extends this same Durable Object. `planKind` defaults to "trial" and is
// otherwise unused by this plan so a later plan can add a "reader"/"voice"
// paid-session kind without a schema migration.
export const voiceSession = sqliteTable("voice_session", {
  rishiSessionId: text("rishi_session_id").primaryKey(),
  planKind: text("plan_kind", { enum: ["trial", "reader", "voice"] })
    .notNull()
    .default("trial"),
  status: text("status", {
    enum: ["pending_registration", "active", "terminal"],
  }).notNull(),
  capIntervals: integer("cap_intervals").notNull(),
  consumedIntervals: integer("consumed_intervals").notNull().default(0),
  creditsPerInterval: integer("credits_per_interval").notNull(),
  nonceIssuedAt: integer("nonce_issued_at").notNull(), // epoch ms
  nonceSignature: text("nonce_signature").notNull(),
  nonceUsed: integer("nonce_used", { mode: "boolean" }).notNull().default(false),
  callId: text("call_id"),
  callRegisteredAt: integer("call_registered_at"), // epoch ms, null until registered
  terminalReason: text("terminal_reason", {
    enum: [
      "voice_session_time_cap",
      "trial_credits_exhausted",
      "registration_timeout",
      "plan_voice_allowance_exhausted",
    ],
  }),
  terminalAt: integer("terminal_at"), // epoch ms
  hangupStatus: text("hangup_status", {
    enum: ["not_started", "pending", "succeeded", "failed_permanently"],
  })
    .notNull()
    .default("not_started"),
  hangupAttempts: integer("hangup_attempts").notNull().default(0),
  createdAt: integer("created_at").notNull(), // epoch ms
  updatedAt: integer("updated_at").notNull(), // epoch ms
});

export type VoiceSessionRow = typeof voiceSession.$inferSelect;
export type NewVoiceSessionRow = typeof voiceSession.$inferInsert;
export type VoiceSessionStatus = VoiceSessionRow["status"];
export type HangupStatus = VoiceSessionRow["hangupStatus"];

// Mirrors the user's single CURRENT paid allowance period (Reader or
// Voice). This is the DO-local enforcement authority for paid narration/
// Voice Chat usage — the same role `trialLedger` plays for trial credits.
// D1's `allowancePeriod` table (plan 1, workers/worker/src/db/schema.ts) is
// the durable reporting/history mirror, kept in sync by whichever caller
// invokes `UserUsageLedger.syncAllowancePeriod()` (the not-yet-written
// StoreKit-entitlement-sync plan) — this table never writes back to D1
// itself. There is exactly one row, fixed id `CURRENT_ALLOWANCE_PERIOD_ROW_ID`,
// upserted in place and never deleted: its mere existence plus a
// `periodEnd` comparison against "now" is enough to distinguish "never had
// a paid period" (no row) from "had one, now lapsed" (row exists, expired)
// from "currently active" (row exists, unexpired) — see the plan's "Design
// decisions" section for why no separate boolean flag column is needed.
export const CURRENT_ALLOWANCE_PERIOD_ROW_ID = "current";

export const currentAllowancePeriod = sqliteTable("current_allowance_period", {
  id: text("id").primaryKey(),
  // Matches the D1 `allowancePeriod.id` row this mirror was synced from,
  // so paid-usage settlement can target the right D1 row via `ctx.waitUntil`.
  periodId: text("period_id").notNull(),
  plan: text("plan", { enum: ["reader", "voice"] }).notNull(),
  periodStart: integer("period_start").notNull(), // epoch ms
  periodEnd: integer("period_end").notNull(), // epoch ms
  narrationSecondsTotal: integer("narration_seconds_total").notNull(),
  narrationSecondsUsed: integer("narration_seconds_used").notNull().default(0),
  voiceChatSecondsTotal: integer("voice_chat_seconds_total").notNull(),
  voiceChatSecondsUsed: integer("voice_chat_seconds_used").notNull().default(0),
  updatedAt: integer("updated_at").notNull(), // epoch ms
});

export type CurrentAllowancePeriodRow = typeof currentAllowancePeriod.$inferSelect;
export type NewCurrentAllowancePeriodRow = typeof currentAllowancePeriod.$inferInsert;

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
  status: text("status", { enum: ["pending", "committed", "released"] }).notNull(),
  createdAt: integer("created_at").notNull(), // epoch ms
  settledAt: integer("settled_at"), // epoch ms, null while pending
});

// Voice-chat session lifecycle — one row per Rishi voice session (not per
// interval). Added by 2026-07-17-user-usage-ledger-voice-session.md, which
// extends this same Durable Object. `planKind` defaults to "trial" and is
// otherwise unused by this plan so a later plan can add a "reader"/"voice"
// paid-session kind without a schema migration.
export const voiceSession = sqliteTable("voice_session", {
  rishiSessionId: text("rishi_session_id").primaryKey(),
  planKind: text("plan_kind").notNull().default("trial"),
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
    enum: ["voice_session_time_cap", "trial_credits_exhausted", "registration_timeout"],
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

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

import { desc, eq, sql } from "drizzle-orm";
import type { DrizzleSqliteDODatabase } from "drizzle-orm/durable-sqlite";

import {
  voiceSession,
  type HangupStatus,
  type NewVoiceSessionRow,
  type VoiceSessionRow,
} from "../user-usage-ledger/schema";
import type { VoiceSessionTerminalReason } from "./messages";

/**
 * Rows that block creating a new voice session: a live session, or a
 * terminal session whose OpenAI hangup is still unresolved (`not_started` /
 * `pending`). Spec: the client must not start another live session that
 * would steal this DO's single alarm until hangup resolves
 * (`succeeded` / `failed_permanently`).
 */
export async function findLiveVoiceSession(
  db: DrizzleSqliteDODatabase,
): Promise<VoiceSessionRow | null> {
  const rows = await db
    .select()
    .from(voiceSession)
    .where(
      sql`${voiceSession.status} IN ('pending_registration', 'active')
          OR (${voiceSession.status} = 'terminal' AND ${voiceSession.hangupStatus} IN ('not_started', 'pending'))`,
    )
    .orderBy(desc(voiceSession.updatedAt))
    .limit(1);
  return rows[0] ?? null;
}

export async function findVoiceSessionById(
  db: DrizzleSqliteDODatabase,
  rishiSessionId: string,
): Promise<VoiceSessionRow | null> {
  const rows = await db
    .select()
    .from(voiceSession)
    .where(eq(voiceSession.rishiSessionId, rishiSessionId));
  return rows[0] ?? null;
}

/**
 * The single row the `alarm()` handler should act on: whichever of
 * (a) a live session awaiting registration or ticking, or
 * (b) a terminal session whose OpenAI hangup hasn't resolved yet,
 * was touched most recently. There is at most one such row at a time given
 * "one active voice session per account".
 */
export async function findRowNeedingAlarm(
  db: DrizzleSqliteDODatabase,
): Promise<VoiceSessionRow | null> {
  const rows = await db
    .select()
    .from(voiceSession)
    .where(
      sql`${voiceSession.status} IN ('pending_registration', 'active')
          OR (${voiceSession.status} = 'terminal' AND ${voiceSession.hangupStatus} IN ('not_started', 'pending'))`,
    )
    .orderBy(desc(voiceSession.updatedAt))
    .limit(1);
  return rows[0] ?? null;
}

export async function insertVoiceSession(
  db: DrizzleSqliteDODatabase,
  row: NewVoiceSessionRow,
): Promise<void> {
  await db.insert(voiceSession).values(row);
}

export async function markNonceUsedAndRegisterCall(
  db: DrizzleSqliteDODatabase,
  rishiSessionId: string,
  callId: string,
  now: number,
): Promise<void> {
  await db
    .update(voiceSession)
    .set({ status: "active", nonceUsed: true, callId, callRegisteredAt: now, updatedAt: now })
    .where(eq(voiceSession.rishiSessionId, rishiSessionId));
}

export async function incrementConsumedIntervals(
  db: DrizzleSqliteDODatabase,
  rishiSessionId: string,
  now: number,
): Promise<void> {
  await db
    .update(voiceSession)
    .set({
      consumedIntervals: sql`${voiceSession.consumedIntervals} + 1`,
      updatedAt: now,
    })
    .where(eq(voiceSession.rishiSessionId, rishiSessionId));
}

export async function markTerminal(
  db: DrizzleSqliteDODatabase,
  rishiSessionId: string,
  reason: VoiceSessionTerminalReason,
  now: number,
): Promise<void> {
  await db
    .update(voiceSession)
    .set({ status: "terminal", terminalReason: reason, terminalAt: now, updatedAt: now })
    .where(eq(voiceSession.rishiSessionId, rishiSessionId));
}

export async function setHangupStatus(
  db: DrizzleSqliteDODatabase,
  rishiSessionId: string,
  status: HangupStatus,
  attempts: number,
  now: number,
): Promise<void> {
  await db
    .update(voiceSession)
    .set({ hangupStatus: status, hangupAttempts: attempts, updatedAt: now })
    .where(eq(voiceSession.rishiSessionId, rishiSessionId));
}

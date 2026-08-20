import { asc, desc, eq, sql } from "drizzle-orm";
import type { DrizzleSqliteDODatabase } from "drizzle-orm/durable-sqlite";

import {
  voiceSession,
  type HangupStatus,
  type NewVoiceSessionRow,
  type VoiceSessionRow,
} from "../user-usage-ledger/schema";
import type { VoiceSessionTerminalReason } from "./messages";

/**
 * Rows that block creating a new voice session. Provider cleanup is tracked
 * separately: a terminal row may still need an OpenAI hangup retry, but it is
 * no longer a client-owned live session and must not block the next reader.
 */
export async function findLiveVoiceSession(
  db: DrizzleSqliteDODatabase,
): Promise<VoiceSessionRow | null> {
  const rows = await db
    .select()
    .from(voiceSession)
    .where(
      sql`${voiceSession.status} IN ('pending_registration', 'active')`,
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
 * Every row that may need alarm work. A new live session may coexist with
 * older terminal rows whose provider hangup is still retrying, so returning
 * only one row would starve one of those two responsibilities.
 */
export async function findRowsNeedingAlarm(
  db: DrizzleSqliteDODatabase,
): Promise<VoiceSessionRow[]> {
  return await db
    .select()
    .from(voiceSession)
    .where(
      sql`${voiceSession.status} IN ('pending_registration', 'active')
          OR (${voiceSession.status} = 'terminal' AND ${voiceSession.hangupStatus} IN ('not_started', 'pending'))`,
    )
    .orderBy(asc(voiceSession.updatedAt));
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
): Promise<boolean> {
  const result = await db
    .update(voiceSession)
    .set({
      status: "active",
      nonceUsed: true,
      callId,
      callRegisteredAt: now,
      lastActivityAt: now,
      updatedAt: now,
    })
    .where(
      sql`${voiceSession.rishiSessionId} = ${rishiSessionId}
          AND ${voiceSession.status} = 'pending_registration'
          AND ${voiceSession.nonceUsed} = false`,
    );
  return result.rowsWritten > 0;
}

/**
 * Bumps `lastActivityAt` for a live session only. No-op if the row is
 * missing or already terminal — callers fire-and-forget after
 * client_activity.
 */
export async function touchLastActivityAt(
  db: DrizzleSqliteDODatabase,
  rishiSessionId: string,
  now: number,
): Promise<void> {
  await db
    .update(voiceSession)
    .set({ lastActivityAt: now, updatedAt: now })
    .where(
      sql`${voiceSession.rishiSessionId} = ${rishiSessionId}
          AND ${voiceSession.status} IN ('pending_registration', 'active')`,
    );
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
  nextAttemptAt: number | null = null,
): Promise<void> {
  await db
    .update(voiceSession)
    .set({
      hangupStatus: status,
      hangupAttempts: attempts,
      nextHangupAttemptAt: nextAttemptAt,
      updatedAt: now,
    })
    .where(eq(voiceSession.rishiSessionId, rishiSessionId));
}

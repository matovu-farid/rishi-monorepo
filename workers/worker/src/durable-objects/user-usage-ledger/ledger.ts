import { DurableObject } from "cloudflare:workers";
import { and, eq, sql } from "drizzle-orm";
import { z } from "zod";
import { drizzle, type DrizzleSqliteDODatabase } from "drizzle-orm/durable-sqlite";
import { migrate } from "drizzle-orm/durable-sqlite/migrator";
import migrations from "../../../drizzle/ledger-do-migrations/migrations";
import { trialGrant, usageReservation, usageAuditLog, allowancePeriod } from "../../db/schema";
import { createDb } from "../../db/drizzle";
import {
  InsufficientAllowanceError,
  ReservationNotFoundError,
  ReservationStateError,
} from "./errors";
import {
  reservations,
  trialLedger,
  TRIAL_LEDGER_ROW_ID,
  currentAllowancePeriod,
  CURRENT_ALLOWANCE_PERIOD_ROW_ID,
  type CurrentAllowancePeriodRow,
} from "./schema";
import type { VoiceSessionRow, VoiceSessionStatus } from "./schema";
import { TRIAL_INITIAL_CREDITS, TRIAL_TTS_COST_CREDITS } from "./types";
import type { EntitlementSnapshot } from "./types";
import { VoiceSessionError } from "../voice-session/errors";
import { mintRegistrationNonce, verifyRegistrationNonce } from "../voice-session/nonce";
import {
  findLiveVoiceSession,
  findRowNeedingAlarm,
  findVoiceSessionById,
  incrementConsumedIntervals,
  insertVoiceSession,
  markNonceUsedAndRegisterCall,
  markTerminal,
  setHangupStatus,
} from "../voice-session/sql";
import { callOpenAiHangup } from "../voice-session/openai-hangup";
import type { ControlMessage, VoiceSessionTerminalReason } from "../voice-session/messages";

const CREDITS_PER_INTERVAL = 2;
const CAP_INTERVALS_TRIAL = 40; // 20 minutes at the 30s cadence
const INTERVAL_MS = 30_000;
const ClientControlMessageSchema = z.object({ type: z.literal("client_ack") });
/** How long a session may sit `pending_registration` before it's reconciled as abandoned. Documented per the spec's "short grace period" requirement. */
const REGISTRATION_GRACE_MS = 10_000;
/**
 * Bounded OpenAI-hangup retry backoff. Attempt 1 happens immediately when a
 * session goes terminal (inside `terminateSession`); if it fails, the alarm
 * retries at these offsets (5 total attempts including the first). After
 * the 5th failure the session's `hangupStatus` becomes `failed_permanently`
 * and a `provider_hangup_failed` notification is broadcast; the durable
 * `terminalReason` is never overwritten by a hangup failure.
 */
const HANGUP_BACKOFF_MS = [5_000, 15_000, 30_000, 60_000];
const MAX_HANGUP_ATTEMPTS = HANGUP_BACKOFF_MS.length + 1;

/**
 * One `UserUsageLedger` Durable Object per authenticated Rishi user,
 * addressed via `env.USER_USAGE_LEDGER.getByName(userId)`. `userId` is
 * recovered inside the object via `ctx.id.name` — never address this DO
 * via `idFromString()` or `newUniqueId()`, since `ctx.id.name` is only
 * populated for objects addressed by name.
 *
 * Concurrency model — see "Concurrency model" in the plan this class was
 * built from (docs/superpowers/plans/2026-07-17-user-usage-ledger-trial-tts.md)
 * for the full reasoning. Summary: `this.db` (Drizzle over this object's own
 * SQLite-backed `ctx.storage`) is the sole authority for balance decisions.
 * D1 (`this.env.DB`, via the shared `createDb()` helper) only ever receives
 * a best-effort mirror scheduled with `ctx.waitUntil(...)` *after* the local
 * decision is committed — a D1 failure can produce a stale audit copy, but
 * can never cause an overspend or block a caller.
 */
export class UserUsageLedger extends DurableObject<Env> {
  private readonly db: DrizzleSqliteDODatabase;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.db = drizzle(ctx.storage, { logger: false });

    // Must complete before any request/RPC call is processed.
    ctx.blockConcurrencyWhile(async () => {
      migrate(this.db, migrations);
    });
  }

  // ── Public RPC methods ──────────────────────────────────────────────

  /**
   * Grants the one-time 100-credit trial if this account doesn't already
   * have a trial ledger row. Idempotent — safe to call on every request.
   *
   * The design implies an eager grant at signup. This method is the seam
   * for that: once wired up, the signup flow should call
   * `env.USER_USAGE_LEDGER.getByName(userId).grantTrialIfAbsent()` directly
   * after account creation. That wiring is explicitly out of scope for this
   * plan (follow-up). Every other public method below also calls this
   * defensively so the ledger behaves correctly even before that signup
   * wiring exists.
   */
  async grantTrialIfAbsent(): Promise<void> {
    const userId = this.requireUserId();
    const existing = await this.db
      .select()
      .from(trialLedger)
      .where(eq(trialLedger.id, TRIAL_LEDGER_ROW_ID));
    if (existing.length > 0) return;

    const grantedAt = Date.now();
    await this.db.insert(trialLedger).values({
      id: TRIAL_LEDGER_ROW_ID,
      userId,
      initialCredits: TRIAL_INITIAL_CREDITS,
      usedCredits: 0,
      grantedAt,
    });

    this.ctx.waitUntil(this.mirrorGrantToD1(userId, grantedAt));
  }

  /**
   * Precedence (see "Design decisions" #2 for why no separate boolean flag
   * is needed):
   *   1. A `currentAllowancePeriod` mirror row exists and is unexpired →
   *      `reader_active`/`voice_active`, keyed off its own `plan` field.
   *   2. A row exists but has expired (no fresher sync has landed since
   *      it lapsed) → `subscription_expired`.
   *   3. No row has ever existed for this account → fall back to the
   *      trial logic exactly as plan 2 implemented it.
   */
  async getEntitlementSnapshot(): Promise<EntitlementSnapshot> {
    const period = await this.getCurrentAllowancePeriodRow();
    if (period) {
      const now = Date.now();
      if (period.periodEnd > now) {
        const remainingNarrationSeconds = await this.remainingPaidNarrationSeconds(period);
        const remainingVoiceChatSeconds = Math.max(
          0,
          period.voiceChatSecondsTotal - period.voiceChatSecondsUsed,
        );
        return {
          state: period.plan === "reader" ? "reader_active" : "voice_active",
          periodEnd: period.periodEnd,
          remainingNarrationSeconds,
          remainingVoiceChatSeconds,
        };
      }
      return { state: "subscription_expired" };
    }

    await this.grantTrialIfAbsent();
    const remaining = await this.remainingTrialCredits();
    if (remaining <= 0) return { state: "trial_exhausted" };
    return { state: "trial_active", remainingCredits: remaining };
  }

  /**
   * Reserves trial allowance for one TTS generation.
   *
   * `estimateCredits` is accepted to match the shared method contract used
   * by the future paid-narration reservation path (duration-based estimate,
   * a later plan) — it is NOT used to size this reservation. Trial TTS
   * always costs exactly `TRIAL_TTS_COST_CREDITS` regardless of text
   * length, per the product spec.
   *
   * Throws `InsufficientAllowanceError` if remaining trial credit (after
   * subtracting other outstanding pending reservations) is below the cost.
   */
  async reserveTts(estimateCredits: number): Promise<{ reservationId: string }> {
    void estimateCredits; // unused in the trial-only path; see doc comment above

    await this.grantTrialIfAbsent();
    const userId = this.requireUserId();
    const remaining = await this.remainingTrialCredits();
    if (remaining < TRIAL_TTS_COST_CREDITS) {
      this.ctx.waitUntil(
        this.appendAuditLog(userId, "tts_reservation_rejected", {
          reason: "trial_credits_exhausted",
        }),
      );
      throw new InsufficientAllowanceError();
    }

    const reservationId = crypto.randomUUID();
    const createdAt = Date.now();
    await this.db.insert(reservations).values({
      id: reservationId,
      userId,
      kind: "tts",
      amount: TRIAL_TTS_COST_CREDITS,
      status: "pending",
      createdAt,
      settledAt: null,
    });

    this.ctx.waitUntil(
      this.mirrorReserveToD1({
        id: reservationId,
        userId,
        amount: TRIAL_TTS_COST_CREDITS,
        createdAt,
      }),
    );

    return { reservationId };
  }

  /**
   * Commits a pending TTS reservation, deducting its credits from the
   * trial balance. Idempotent: committing an already-committed reservation
   * is a no-op and does not double-charge. Throws `ReservationStateError`
   * if the reservation was already released (invalid transition).
   */
  async commitTtsReservation(reservationId: string): Promise<void> {
    const reservation = await this.findReservation(reservationId);
    if (!reservation) throw new ReservationNotFoundError(reservationId);
    if (reservation.status === "committed") return;
    if (reservation.status === "released") {
      throw new ReservationStateError(reservationId, reservation.status, "commit");
    }

    const userId = this.requireUserId();
    const settledAt = Date.now();

    await this.db
      .update(reservations)
      .set({ status: "committed", settledAt })
      .where(eq(reservations.id, reservationId));

    await this.db
      .update(trialLedger)
      .set({ usedCredits: sql`${trialLedger.usedCredits} + ${reservation.amount}` })
      .where(eq(trialLedger.id, TRIAL_LEDGER_ROW_ID));

    this.ctx.waitUntil(
      this.mirrorCommitToD1(reservationId, userId, reservation.amount, settledAt),
    );
  }

  /**
   * Releases a pending TTS reservation without charging any credits.
   * Idempotent: releasing an already-released reservation is a no-op.
   * Throws `ReservationStateError` if the reservation was already
   * committed (money already spent — cannot be un-charged via release).
   */
  async releaseTtsReservation(reservationId: string): Promise<void> {
    const reservation = await this.findReservation(reservationId);
    if (!reservation) throw new ReservationNotFoundError(reservationId);
    if (reservation.status === "released") return;
    if (reservation.status === "committed") {
      throw new ReservationStateError(reservationId, reservation.status, "release");
    }

    const userId = this.requireUserId();
    const settledAt = Date.now();

    await this.db
      .update(reservations)
      .set({ status: "released", settledAt })
      .where(eq(reservations.id, reservationId));

    this.ctx.waitUntil(
      this.mirrorReleaseToD1(reservationId, userId, reservation.amount, settledAt),
    );
  }

  /**
   * Upserts the DO-local mirror of this user's single CURRENT paid
   * allowance period. Called by the (not yet written) StoreKit-
   * entitlement-sync plan after it verifies an Apple transaction and
   * writes/updates the corresponding D1 `allowancePeriod` row — this
   * method never writes to D1 itself; see "Design decisions" #1.
   *
   * Resyncing the SAME period id (e.g. a repeated foreground sync) never
   * resets `narrationSecondsUsed`/`voiceChatSecondsUsed` — only a
   * genuinely new period id (upgrade/renewal/crossgrade, or this
   * account's first-ever paid period) starts usage back at zero.
   */
  async syncAllowancePeriod(period: {
    id: string;
    plan: "reader" | "voice";
    periodStart: number;
    periodEnd: number;
    narrationSecondsTotal: number;
    voiceChatSecondsTotal: number;
  }): Promise<void> {
    const userId = this.requireUserId();
    const now = Date.now();
    const existing = await this.getCurrentAllowancePeriodRow();

    if (existing && existing.periodId === period.id) {
      await this.db
        .update(currentAllowancePeriod)
        .set({
          plan: period.plan,
          periodStart: period.periodStart,
          periodEnd: period.periodEnd,
          narrationSecondsTotal: period.narrationSecondsTotal,
          voiceChatSecondsTotal: period.voiceChatSecondsTotal,
          updatedAt: now,
        })
        .where(eq(currentAllowancePeriod.id, CURRENT_ALLOWANCE_PERIOD_ROW_ID));
    } else {
      await this.db
        .insert(currentAllowancePeriod)
        .values({
          id: CURRENT_ALLOWANCE_PERIOD_ROW_ID,
          periodId: period.id,
          plan: period.plan,
          periodStart: period.periodStart,
          periodEnd: period.periodEnd,
          narrationSecondsTotal: period.narrationSecondsTotal,
          narrationSecondsUsed: 0,
          voiceChatSecondsTotal: period.voiceChatSecondsTotal,
          voiceChatSecondsUsed: 0,
          updatedAt: now,
        })
        .onConflictDoUpdate({
          target: currentAllowancePeriod.id,
          set: {
            periodId: period.id,
            plan: period.plan,
            periodStart: period.periodStart,
            periodEnd: period.periodEnd,
            narrationSecondsTotal: period.narrationSecondsTotal,
            narrationSecondsUsed: 0,
            voiceChatSecondsTotal: period.voiceChatSecondsTotal,
            voiceChatSecondsUsed: 0,
            updatedAt: now,
          },
        });
    }

    this.ctx.waitUntil(
      this.appendAuditLog(userId, "allowance_period.synced", {
        periodId: period.id,
        plan: period.plan,
        periodEnd: period.periodEnd,
        isNewPeriod: !existing || existing.periodId !== period.id,
      }),
    );
  }

  // ── Paid-allowance read helpers (Part A/B/C/D all use these) ───────────

  private async getCurrentAllowancePeriodRow(): Promise<CurrentAllowancePeriodRow | null> {
    const [row] = await this.db
      .select()
      .from(currentAllowancePeriod)
      .where(eq(currentAllowancePeriod.id, CURRENT_ALLOWANCE_PERIOD_ROW_ID));
    return row ?? null;
  }

  /** Returns the current period row only if it exists AND has not expired. */
  private async getActiveAllowancePeriod(
    now: number = Date.now(),
  ): Promise<CurrentAllowancePeriodRow | null> {
    const row = await this.getCurrentAllowancePeriodRow();
    if (!row) return null;
    return row.periodEnd > now ? row : null;
  }

  /**
   * Remaining paid narration seconds, minus the sum of currently-pending
   * `"tts"`-kind reservation amounts — the same double-spend protection
   * `remainingTrialCredits()` (plan 2) applies to trial credits, applied
   * here to the paid pool. See "Design decisions" #3 for why a pending
   * reservation's amount is trusted to already be in seconds without a
   * separate unit marker.
   */
  private async remainingPaidNarrationSeconds(
    period: CurrentAllowancePeriodRow,
  ): Promise<number> {
    const pending = await this.db
      .select({ amount: reservations.amount })
      .from(reservations)
      .where(and(eq(reservations.status, "pending"), eq(reservations.kind, "tts")));
    const pendingTotal = pending.reduce((sum, row) => sum + row.amount, 0);
    return Math.max(0, period.narrationSecondsTotal - period.narrationSecondsUsed - pendingTotal);
  }

  /**
   * Verifies at least one interval's worth of trial credits is available,
   * mints a Rishi session ID and single-use registration nonce, and records
   * the trial session cap (40 intervals / 20 minutes). Rejects if a session
   * is already active for this user.
   *
   * Returns session bookkeeping ONLY. The calling route (plan 4's
   * `2026-07-17-voice-control-websocket.md`, not yet written) is
   * responsible for also minting and returning the OpenAI client secret —
   * see the existing `/api/realtime/client_secrets` route in
   * `workers/worker/src/index.ts` for the pattern to reuse there.
   */
  async createVoiceSession(): Promise<{
    rishiSessionId: string;
    nonce: string;
    capIntervals: number;
  }> {
    const live = await findLiveVoiceSession(this.db);
    if (live) {
      throw new VoiceSessionError(
        "session_already_active",
        "a voice session is already active for this user",
      );
    }

    const remainingCredits = await this.remainingTrialCredits();
    if (remainingCredits < CREDITS_PER_INTERVAL) {
      throw new VoiceSessionError(
        "insufficient_credits",
        `only ${remainingCredits} trial credits remain; need at least ${CREDITS_PER_INTERVAL}`,
      );
    }

    const userId = this.requireUserId();
    const rishiSessionId = crypto.randomUUID();
    const now = Date.now();
    const minted = await mintRegistrationNonce(
      rishiSessionId,
      userId,
      this.env.VOICE_SESSION_NONCE_SECRET,
      now,
    );

    await insertVoiceSession(this.db, {
      rishiSessionId,
      planKind: "trial",
      status: "pending_registration",
      capIntervals: CAP_INTERVALS_TRIAL,
      consumedIntervals: 0,
      creditsPerInterval: CREDITS_PER_INTERVAL,
      nonceIssuedAt: minted.issuedAtMs,
      nonceSignature: minted.signatureB64Url,
      nonceUsed: false,
      callId: null,
      callRegisteredAt: null,
      terminalReason: null,
      terminalAt: null,
      hangupStatus: "not_started",
      hangupAttempts: 0,
      createdAt: now,
      updatedAt: now,
    });

    await this.ctx.storage.setAlarm(now + REGISTRATION_GRACE_MS);
    await this.appendAuditLog(userId, "voice_session.created", { rishiSessionId });

    return { rishiSessionId, nonce: minted.nonce, capIntervals: CAP_INTERVALS_TRIAL };
  }

  /**
   * Accepts a call ID once only when it belongs to the active session and
   * the nonce matches. Single-use: a replayed nonce or a second
   * registration attempt against the same session throws.
   */
  async registerCallId(rishiSessionId: string, callId: string, nonce: string): Promise<void> {
    const userId = this.requireUserId();
    const row = await findLiveVoiceSession(this.db);

    if (!row) {
      throw new VoiceSessionError(
        "no_active_session",
        "no active voice session to register a call against",
      );
    }
    if (row.rishiSessionId !== rishiSessionId) {
      throw new VoiceSessionError(
        "session_id_mismatch",
        "rishiSessionId does not match the active session",
      );
    }
    if (row.status !== "pending_registration") {
      throw new VoiceSessionError(
        "call_already_registered",
        "this session has already completed call-ID registration",
      );
    }
    if (row.nonceUsed) {
      throw new VoiceSessionError("nonce_replayed", "this registration nonce has already been used");
    }

    const valid = await verifyRegistrationNonce(
      nonce,
      rishiSessionId,
      userId,
      this.env.VOICE_SESSION_NONCE_SECRET,
      { issuedAtMs: row.nonceIssuedAt, signatureB64Url: row.nonceSignature },
    );
    if (!valid) {
      throw new VoiceSessionError("nonce_mismatch", "registration nonce did not verify");
    }

    const now = Date.now();
    await markNonceUsedAndRegisterCall(this.db, rishiSessionId, callId, now);
    // The first 30-second charge is scheduled from the moment registration
    // succeeds, not from session creation — an app that takes a few seconds
    // to complete WebRTC negotiation doesn't lose part of its first interval.
    await this.ctx.storage.setAlarm(now + INTERVAL_MS);
    await this.appendAuditLog(userId, "voice_session.call_registered", { rishiSessionId, callId });

    const remainingCredits = await this.remainingTrialCredits();
    // `broadcastToActiveSockets` does not exist yet — plan 4
    // (2026-07-17-voice-control-websocket.md) adds it to this same class,
    // alongside `fetch()`/`webSocketMessage`/`webSocketClose`/
    // `webSocketError`. See this plan's "Prerequisite" section.
    this.broadcastToActiveSockets({
      type: "allowance_remaining",
      rishiSessionId,
      remainingCredits,
      remainingIntervals: row.capIntervals - row.consumedIntervals,
    });
  }

  /**
   * The single alarm for this DO drives three unrelated transitions,
   * disambiguated by the row's own `status`/`hangupStatus`:
   *  - `pending_registration` past its grace period → abandoned-session reconciliation.
   *  - `active` → the next 30-second credit/interval tick.
   *  - `terminal` with `hangupStatus` not yet resolved → bounded hangup retry.
   */
  async alarm(): Promise<void> {
    const row = await findRowNeedingAlarm(this.db);
    if (!row) return;

    const userId = this.requireUserId();
    const now = Date.now();

    if (row.status === "pending_registration") {
      if (now - row.createdAt < REGISTRATION_GRACE_MS) {
        await this.ctx.storage.setAlarm(row.createdAt + REGISTRATION_GRACE_MS);
        return;
      }
      await markTerminal(this.db, row.rishiSessionId, "registration_timeout", now);
      await this.appendAuditLog(userId, "voice_session.abandoned", { rishiSessionId: row.rishiSessionId });
      // `broadcastToActiveSockets` is added by plan 4 — see "Prerequisite".
      this.broadcastToActiveSockets({
        type: "session_ended",
        rishiSessionId: row.rishiSessionId,
        reason: "registration_timeout",
      });
      // No callId was ever registered, so there is nothing to hang up on OpenAI's side.
      return;
    }

    if (row.status === "active") {
      await this.tickActiveSession(row, userId, now);
      return;
    }

    // status === "terminal" and hangup hasn't resolved yet: bounded retry.
    if (row.callId) {
      await this.attemptHangup(row.rishiSessionId, row.callId, userId, row.hangupAttempts);
    }
  }

  /**
   * Checks and deducts `CREDITS_PER_INTERVAL` trial credits for one 30s
   * interval. Only ever `await`s calls against `this.db` with nothing else
   * awaited in between — per plan 2's "Concurrency model" section, this DO's
   * synchronous SQLite storage plus the runtime's input gates already make
   * that sequence atomic, so no `ctx.storage.transactionSync` wrapper is
   * needed here.
   */
  private async tickActiveSession(row: VoiceSessionRow, userId: string, now: number): Promise<void> {
    const remainingCredits = await this.remainingTrialCredits();
    if (remainingCredits < CREDITS_PER_INTERVAL) {
      await this.terminateSession(row, "trial_credits_exhausted", userId, now);
      return;
    }

    await this.db
      .update(trialLedger)
      .set({ usedCredits: sql`${trialLedger.usedCredits} + ${CREDITS_PER_INTERVAL}` })
      .where(eq(trialLedger.id, TRIAL_LEDGER_ROW_ID));
    await incrementConsumedIntervals(this.db, row.rishiSessionId, now);

    const spentRemainingCredits = remainingCredits - CREDITS_PER_INTERVAL;
    const consumedIntervals = row.consumedIntervals + 1;
    const remainingIntervals = row.capIntervals - consumedIntervals;

    await this.appendAuditLog(userId, "voice_session.interval_charged", {
      rishiSessionId: row.rishiSessionId,
      consumedIntervals,
      remainingCredits: spentRemainingCredits,
    });

    // `broadcastToActiveSockets` is added by plan 4 — see "Prerequisite".
    this.broadcastToActiveSockets({
      type: "allowance_remaining",
      rishiSessionId: row.rishiSessionId,
      remainingCredits: spentRemainingCredits,
      remainingIntervals,
    });

    if (remainingIntervals === 1) {
      this.broadcastToActiveSockets({ type: "session_ending", rishiSessionId: row.rishiSessionId });
    }

    if (remainingIntervals <= 0) {
      await this.terminateSession(row, "voice_session_time_cap", userId, Date.now());
      return;
    }

    await this.ctx.storage.setAlarm(now + INTERVAL_MS);
  }

  private async terminateSession(
    row: VoiceSessionRow,
    reason: VoiceSessionTerminalReason,
    userId: string,
    now: number,
  ): Promise<void> {
    await markTerminal(this.db, row.rishiSessionId, reason, now);
    await this.appendAuditLog(userId, "voice_session.terminal", { rishiSessionId: row.rishiSessionId, reason });
    // `broadcastToActiveSockets` is added by plan 4 — see "Prerequisite".
    this.broadcastToActiveSockets({ type: "session_ended", rishiSessionId: row.rishiSessionId, reason });

    if (!row.callId) {
      // Terminated before a call was ever registered (shouldn't happen for
      // "active" sessions, but stay defensive) — nothing to hang up.
      await setHangupStatus(this.db, row.rishiSessionId, "succeeded", 0, now);
      return;
    }

    await setHangupStatus(this.db, row.rishiSessionId, "pending", 0, now);
    await this.attemptHangup(row.rishiSessionId, row.callId, userId, 0);
  }

  /**
   * Runs one hangup attempt and either marks the session's hangup resolved
   * (`succeeded` or `failed_permanently`) or schedules the next bounded
   * retry via the alarm. `attemptsSoFar` is the count of *previous*
   * attempts (0 on the first call from `terminateSession`).
   */
  private async attemptHangup(
    rishiSessionId: string,
    callId: string,
    userId: string,
    attemptsSoFar: number,
  ): Promise<void> {
    const attempt = attemptsSoFar + 1;
    try {
      await this.hangUpCall(callId);
      await setHangupStatus(this.db, rishiSessionId, "succeeded", attempt, Date.now());
      await this.appendAuditLog(userId, "voice_session.hangup_succeeded", { rishiSessionId, callId, attempt });
      return;
    } catch (err) {
      await this.appendAuditLog(userId, "voice_session.hangup_attempt_failed", {
        rishiSessionId,
        callId,
        attempt,
        error: (err as Error).message,
      });

      if (attempt >= MAX_HANGUP_ATTEMPTS) {
        await setHangupStatus(this.db, rishiSessionId, "failed_permanently", attempt, Date.now());
        console.error(
          JSON.stringify({
            event: "voice_session.hangup_failed_permanently",
            rishiSessionId,
            callId,
            userId,
            attempts: attempt,
          }),
        );
        // `broadcastToActiveSockets` is added by plan 4 — see "Prerequisite".
        this.broadcastToActiveSockets({
          type: "session_ended",
          rishiSessionId,
          reason: "provider_hangup_failed",
        });
        return;
      }

      await setHangupStatus(this.db, rishiSessionId, "pending", attempt, Date.now());
      const nextDelay = HANGUP_BACKOFF_MS[attempt - 1];
      await this.ctx.storage.setAlarm(Date.now() + nextDelay);
    }
  }

  /**
   * Makes the actual OpenAI hangup HTTP call using the same
   * `OPENAI_API_KEY` binding as `/api/realtime/client_secrets`
   * (`workers/worker/src/index.ts:~958`). Resolves on success; throws
   * `VoiceSessionError("hangup_failed", ...)` on failure — callers (only
   * `attemptHangup` above) handle bounded retry.
   */
  async hangUpCall(callId: string): Promise<void> {
    await callOpenAiHangup(this.env.OPENAI_API_KEY, callId);
  }

  /**
   * Plain internal data snapshot of a voice session's current status and
   * allowance — not a wire message itself. Used internally by this class
   * (nothing in this plan calls it yet) and, once plan 4
   * (2026-07-17-voice-control-websocket.md) lands, by that plan's `fetch()`
   * to build the initial `{ type: "snapshot", ... }` message it sends
   * right after accepting the control WebSocket, and by the Worker route
   * that plan adds as a pre-upgrade RPC check. Returns `null` if no
   * session with this id has ever existed on this ledger.
   */
  async getSessionSnapshot(rishiSessionId: string): Promise<{
    rishiSessionId: string;
    status: VoiceSessionStatus;
    remainingCredits?: number;
    remainingIntervals?: number;
    terminalReason?: VoiceSessionTerminalReason;
  } | null> {
    const row = await findVoiceSessionById(this.db, rishiSessionId);
    if (!row) return null;

    if (row.status === "terminal") {
      return {
        rishiSessionId,
        status: "terminal",
        terminalReason: row.terminalReason ?? undefined,
      };
    }

    const remainingCredits = await this.remainingTrialCredits();
    return {
      rishiSessionId,
      status: row.status,
      remainingCredits,
      remainingIntervals: row.capIntervals - row.consumedIntervals,
    };
  }

  // ---------- WS upgrade ----------
  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected websocket", { status: 426 });
    }

    const rishiSessionId = sessionIdFromControlPath(request.url);
    if (!rishiSessionId) {
      return new Response("Missing voice session id", { status: 400 });
    }

    // Defense in depth: the Worker route (workers/worker/src/routes/voice-sessions.ts)
    // already checked this via an RPC call to getSessionSnapshot before
    // forwarding, but the session could have ended in the interim (e.g.
    // this ledger's own alarm fired between that read and this request).
    const snapshot = await this.getSessionSnapshot(rishiSessionId);
    if (!snapshot) {
      return new Response("No matching voice session", { status: 404 });
    }

    const { 0: client, 1: server } = new WebSocketPair();
    // Hibernation API: the tag is the durable link between a socket and its
    // session, recoverable via `ctx.getTags(ws)` after a hibernation cycle
    // resets this object's in-memory state. There is no separate
    // `attachControlSocket` method — accept and the initial snapshot send
    // both happen inline here.
    this.ctx.acceptWebSocket(server, [rishiSessionId]);

    const snapshotMessage: ControlMessage =
      snapshot.status === "terminal"
        ? {
            type: "snapshot",
            rishiSessionId,
            status: "terminal",
            reason: snapshot.terminalReason,
          }
        : {
            type: "snapshot",
            rishiSessionId,
            status: snapshot.status,
            remainingCredits: snapshot.remainingCredits,
            remainingIntervals: snapshot.remainingIntervals,
          };
    this.sendControlMessage(server, snapshotMessage);

    return new Response(null, { status: 101, webSocket: client });
  }

  // ---------- Hibernation handlers ----------
  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    const text = typeof raw === "string" ? raw : new TextDecoder().decode(raw);
    let json: unknown;
    try {
      json = JSON.parse(text);
    } catch {
      this.sendControlError(ws, "Control message was not valid JSON.");
      return;
    }
    const parsed = ClientControlMessageSchema.safeParse(json);
    if (!parsed.success) {
      this.sendControlError(ws, "Unrecognized control message.");
      return;
    }
    // client_ack carries no enforcement weight — see the type's doc comment
    // in voice-session/messages.ts. Logged for audit only.
    console.log(
      JSON.stringify({ event: "voice_control.client_ack", rishiSessionId: this.rishiSessionIdFor(ws) }),
    );
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string, wasClean: boolean): Promise<void> {
    // workers/worker's compatibility_date (2025-11-17) predates the
    // `web_socket_auto_reply_to_close` default (workerd compat dates
    // 2026-04-07+), so this handler must still reciprocate the close frame
    // itself, or the client observes a 1006 instead of a clean close.
    // `ws.close()` is documented as a safe no-op if the socket is already
    // CLOSING/CLOSED, so this call is correct under either compat regime.
    try {
      ws.close(code, reason);
    } catch {
      // Already closed — nothing to reciprocate.
    }
    console.log(
      JSON.stringify({
        event: "voice_control.socket_closed",
        rishiSessionId: this.rishiSessionIdFor(ws),
        code,
        wasClean,
      }),
    );
  }

  async webSocketError(ws: WebSocket, error: unknown): Promise<void> {
    console.log(
      JSON.stringify({
        event: "voice_control.socket_error",
        rishiSessionId: this.rishiSessionIdFor(ws),
        message: error instanceof Error ? error.message : String(error),
      }),
    );
  }

  // ---------- Seam plan 3's alarm() already calls ----------
  /**
   * Sends `message` to every currently attached control socket for this
   * ledger. Plan 3's (2026-07-17-user-usage-ledger-voice-session.md) own
   * `registerCallId` and `alarm()` already call this every 30 seconds
   * (`allowance_remaining`, then `session_ending` on the final interval)
   * and once more at a terminal boundary (`session_ended`). The product
   * spec guarantees one active voice session per account, so every socket
   * `ctx.getWebSockets()` returns belongs to the same session — no
   * per-socket session filtering is needed here.
   */
  private broadcastToActiveSockets(message: ControlMessage): void {
    for (const ws of this.ctx.getWebSockets()) {
      this.sendControlMessage(ws, message);
    }
  }

  // ---------- Helpers ----------
  private sendControlMessage(ws: WebSocket, message: ControlMessage): void {
    try {
      ws.send(JSON.stringify(message));
    } catch (err) {
      console.error(
        JSON.stringify({
          event: "voice_control.send_failed",
          message: err instanceof Error ? err.message : String(err),
        }),
      );
    }
  }

  private sendControlError(ws: WebSocket, message: string): void {
    this.sendControlMessage(ws, {
      type: "session_error",
      rishiSessionId: this.rishiSessionIdFor(ws) ?? "",
      code: "bad_client_message",
      message,
    });
  }

  private rishiSessionIdFor(ws: WebSocket): string | undefined {
    return this.ctx.getTags(ws)[0];
  }

  // ── Internal helpers — DO-local storage reads (part of the atomic path) ──

  private requireUserId(): string {
    const userId = this.ctx.id.name;
    if (!userId) {
      throw new Error(
        "UserUsageLedger must be addressed via env.USER_USAGE_LEDGER.getByName(userId); " +
          "ctx.id.name was undefined (this DO was likely addressed via idFromString or newUniqueId).",
      );
    }
    return userId;
  }

  /**
   * "Remaining" subtracts the sum of all currently-pending reservation
   * amounts, not just `usedCredits`. A reservation that hasn't been
   * committed yet still holds a claim on the balance — otherwise two
   * concurrent `reserveTts()` calls could both pass this check against the
   * same unspent balance and later both commit, overspending.
   */
  private async remainingTrialCredits(): Promise<number> {
    const [ledger] = await this.db
      .select()
      .from(trialLedger)
      .where(eq(trialLedger.id, TRIAL_LEDGER_ROW_ID));
    if (!ledger) return 0;

    const pending = await this.db
      .select({ amount: reservations.amount })
      .from(reservations)
      .where(eq(reservations.status, "pending"));
    const pendingTotal = pending.reduce((sum, row) => sum + row.amount, 0);

    return ledger.initialCredits - ledger.usedCredits - pendingTotal;
  }

  private async findReservation(reservationId: string) {
    const [reservation] = await this.db
      .select()
      .from(reservations)
      .where(eq(reservations.id, reservationId));
    return reservation ?? null;
  }

  // ── D1 mirror writes — best-effort, never gate an authoritative decision ──
  //
  // Every method below is only ever called from `ctx.waitUntil(...)` after
  // the corresponding local (DO-storage) mutation has already completed.
  // Failures are logged and swallowed, never re-thrown: a stale D1 audit
  // copy is an acceptable outcome; blocking or corrupting the already-made
  // local decision is not. Follow-up: a Durable Object alarm-based
  // reconciliation pass (plan 3/4 scope) should retry failures using this
  // object's local storage as the source of truth.

  // `trialGrant.grantedAt`, `usageReservation.createdAt`/`settledAt`, and
  // `usageAuditLog.createdAt` are all Drizzle `{ mode: "timestamp_ms" }`
  // columns (Date-typed), per plan 1's schema — every epoch-ms `number`
  // this DO tracks locally is wrapped in `new Date(...)` before it is
  // written to one of these D1 tables.

  private async mirrorGrantToD1(userId: string, grantedAt: number): Promise<void> {
    try {
      const db = createDb(this.env.DB);
      await db
        .insert(trialGrant)
        .values({
          userId,
          initialCredits: TRIAL_INITIAL_CREDITS,
          usedCredits: 0,
          grantedAt: new Date(grantedAt),
        })
        .onConflictDoNothing();
    } catch (err) {
      console.error("UserUsageLedger.mirrorGrantToD1 failed", { userId, err });
    }
  }

  private async mirrorReserveToD1(row: {
    id: string;
    userId: string;
    amount: number;
    createdAt: number;
  }): Promise<void> {
    try {
      const db = createDb(this.env.DB);
      await db.insert(usageReservation).values({
        id: row.id,
        userId: row.userId,
        kind: "tts",
        amount: row.amount,
        status: "pending",
        createdAt: new Date(row.createdAt),
        settledAt: null,
        metadata: null,
      });
    } catch (err) {
      console.error("UserUsageLedger.mirrorReserveToD1 failed", { row, err });
    }
  }

  private async mirrorCommitToD1(
    reservationId: string,
    userId: string,
    amount: number,
    settledAt: number,
  ): Promise<void> {
    try {
      const db = createDb(this.env.DB);
      await db
        .update(usageReservation)
        .set({ status: "committed", settledAt: new Date(settledAt) })
        .where(eq(usageReservation.id, reservationId));
      await db
        .update(trialGrant)
        .set({ usedCredits: sql`${trialGrant.usedCredits} + ${amount}` })
        .where(eq(trialGrant.userId, userId));
      await db.insert(usageAuditLog).values({
        id: crypto.randomUUID(),
        userId,
        eventType: "tts_reservation_committed",
        details: JSON.stringify({ reservationId, amount }),
        createdAt: new Date(settledAt),
      });
    } catch (err) {
      console.error("UserUsageLedger.mirrorCommitToD1 failed", { reservationId, err });
    }
  }

  private async mirrorReleaseToD1(
    reservationId: string,
    userId: string,
    amount: number,
    settledAt: number,
  ): Promise<void> {
    try {
      const db = createDb(this.env.DB);
      await db
        .update(usageReservation)
        .set({ status: "released", settledAt: new Date(settledAt) })
        .where(eq(usageReservation.id, reservationId));
      await db.insert(usageAuditLog).values({
        id: crypto.randomUUID(),
        userId,
        eventType: "tts_reservation_released",
        details: JSON.stringify({ reservationId, amount }),
        createdAt: new Date(settledAt),
      });
    } catch (err) {
      console.error("UserUsageLedger.mirrorReleaseToD1 failed", { reservationId, err });
    }
  }

  private async appendAuditLog(
    userId: string,
    eventType: string,
    details: unknown,
  ): Promise<void> {
    try {
      const db = createDb(this.env.DB);
      await db.insert(usageAuditLog).values({
        id: crypto.randomUUID(),
        userId,
        eventType,
        details: JSON.stringify(details),
        createdAt: new Date(),
      });
    } catch (err) {
      console.error("UserUsageLedger.appendAuditLog failed", { userId, eventType, err });
    }
  }
}

/**
 * Extracts the `:id` path segment from a request URL shaped
 * `.../api/voice-sessions/<id>/control`. Robust to any route-prefix
 * differences between the Worker and what this DO sees, since it looks for
 * the literal `control` segment rather than assuming a fixed prefix depth.
 */
function sessionIdFromControlPath(url: string): string | null {
  const segments = new URL(url).pathname.split("/").filter(Boolean);
  const controlIndex = segments.indexOf("control");
  if (controlIndex <= 0) return null;
  return decodeURIComponent(segments[controlIndex - 1]!);
}

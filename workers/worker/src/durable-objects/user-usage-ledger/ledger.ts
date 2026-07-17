import { DurableObject } from "cloudflare:workers";
import { eq, sql } from "drizzle-orm";
import { drizzle, type DrizzleSqliteDODatabase } from "drizzle-orm/durable-sqlite";
import { migrate } from "drizzle-orm/durable-sqlite/migrator";
import migrations from "../../../drizzle/ledger-do-migrations/migrations";
import { trialGrant, usageReservation, usageAuditLog } from "../../db/schema";
import { createDb } from "../../db/drizzle";
import {
  InsufficientAllowanceError,
  ReservationNotFoundError,
  ReservationStateError,
} from "./errors";
import { reservations, trialLedger, TRIAL_LEDGER_ROW_ID } from "./schema";
import { TRIAL_INITIAL_CREDITS, TRIAL_TTS_COST_CREDITS } from "./types";
import type { EntitlementSnapshot } from "./types";
import { VoiceSessionError } from "../voice-session/errors";
import { mintRegistrationNonce, verifyRegistrationNonce } from "../voice-session/nonce";
import {
  findLiveVoiceSession,
  insertVoiceSession,
  markNonceUsedAndRegisterCall,
} from "../voice-session/sql";

const CREDITS_PER_INTERVAL = 2;
const CAP_INTERVALS_TRIAL = 40; // 20 minutes at the 30s cadence
const INTERVAL_MS = 30_000;
/** How long a session may sit `pending_registration` before it's reconciled as abandoned. Documented per the spec's "short grace period" requirement. */
const REGISTRATION_GRACE_MS = 10_000;

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

  async getEntitlementSnapshot(): Promise<EntitlementSnapshot> {
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

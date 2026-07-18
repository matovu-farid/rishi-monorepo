import { and, desc, eq } from "drizzle-orm";
import { allowancePeriod, appleSubscriptions, usageAuditLog } from "../db/schema";
import { createDb } from "../db/drizzle";
import { PLAN_ALLOWANCES, type ApplePlan } from "./apple-product-plans";

/**
 * Advances a calendar date by exactly one UTC month (JS `Date` handles
 * month-end overflow itself, e.g. Jan 31 -> Mar 3). Shared by both the
 * transaction-triggered period-opening path (`entitlement-sync.ts`) and
 * the time-based rollover path below -- every allowance period, however it
 * was opened, is exactly one calendar month long.
 */
export function addOneCalendarMonth(date: Date): Date {
  const result = new Date(date.getTime());
  result.setUTCMonth(result.getUTCMonth() + 1);
  return result;
}

// Bounds the rollover loop below. An annual subscription needs at most ~12
// monthly rollovers to reach "now" from its first period; this is a
// generous multiple of that to tolerate an account that hasn't synced in
// a long time, without risking an unbounded loop from a data anomaly.
const MAX_ROLLOVER_ITERATIONS = 36;

/**
 * Rehydrates the UserUsageLedger DO mirror from the user's most recent D1
 * `allowancePeriod` row. Idempotent: `syncAllowancePeriod` with the SAME
 * period id preserves `narrationSecondsUsed` / `voiceChatSecondsUsed`; only
 * a new period id resets counters. Covers the case where D1 insert succeeded
 * but the first DO sync RPC failed -- retries and `/me` rehydrate without
 * double-resetting usage.
 */
export async function syncCurrentAllowancePeriodToDo(
  env: Env,
  userId: string,
): Promise<void> {
  const db = createDb(env.DB);
  const current = await db
    .select()
    .from(allowancePeriod)
    .where(eq(allowancePeriod.userId, userId))
    .orderBy(desc(allowancePeriod.createdAt))
    .get();
  if (!current) return;

  await env.USER_USAGE_LEDGER.getByName(userId).syncAllowancePeriod({
    id: current.id,
    plan: current.plan,
    periodStart: current.periodStart.getTime(),
    periodEnd: current.periodEnd.getTime(),
    narrationSecondsTotal: current.narrationSecondsTotal,
    voiceChatSecondsTotal: current.voiceChatSecondsTotal,
  });
}

/**
 * Rolls a user's current allowance period forward, purely on wall-clock
 * time, when it has lapsed but the underlying Apple subscription's paid
 * term has not. This is what lets an annual subscriber get a fresh
 * monthly allowance in month 2, 3, ... 12 of their term WITHOUT a new
 * Apple transaction arriving -- Apple only sends a new transaction at
 * actual renewal (~once a year), not once a month.
 *
 * Decoupled from `applyAppleTransaction`'s transaction-triggered
 * classification on purpose: that function only runs allowance-period
 * side effects for a newly-verified Apple transaction; this function runs
 * on every entitlement read or sync (`/api/billing/me`,
 * `/api/billing/entitlement-sync`) regardless of whether a transaction
 * was submitted, because the boundary it reacts to is a monthly date, not
 * an Apple event.
 *
 * Each rolled-forward period's `sourceTransactionId` is copied forward
 * from the period it supersedes -- the whole chain for one paid term
 * traces back to the single Apple transaction that started it (the
 * initial purchase, or the most recent renewal/upgrade/crossgrade), which
 * is also how this function resolves the term's overall validity window:
 * `appleSubscriptions` keyed by that same transaction id already stores
 * Apple's `expiresDate` for it (`currentPeriodEnd`). No new column is
 * needed to track "subscription validity end" separately.
 *
 * No-ops the rollover loop (defensively) if: there is no paid period yet,
 * the current period hasn't lapsed, the anchor transaction row can't be
 * found, the anchor subscription is no longer active/in_grace (e.g. it was
 * refunded or canceled and its status was already updated by a real sync),
 * or the anchor's validity window has itself fully elapsed -- that last
 * case is the expected end-of-term state: no further rollover happens until
 * an actual Apple renewal transaction is verified.
 *
 * Always ends by syncing the current D1 period to the DO mirror (even when
 * no rollover ran) so a failed first-sync after D1 insert is healed on the
 * next `/me` or entitlement-sync call without resetting usage counters.
 *
 * CONCURRENCY: D1 unique on `(userId, periodStart)` + insert-with-
 * onConflictDoNothing means concurrent `/me` and entitlement-sync callers
 * cannot open two periods for the same monthly bucket. The loser re-reads
 * the winner and continues (or syncs that winner to the DO mirror).
 */
export async function rollAllowancePeriodsForward(
  env: Env,
  userId: string,
  now: Date = new Date(),
): Promise<void> {
  const db = createDb(env.DB);
  const nowMs = now.getTime();

  const mostRecentPeriod = await db
    .select()
    .from(allowancePeriod)
    .where(eq(allowancePeriod.userId, userId))
    .orderBy(desc(allowancePeriod.createdAt))
    .get();

  if (!mostRecentPeriod) return;

  if (
    mostRecentPeriod.sourceTransactionId &&
    mostRecentPeriod.periodEnd.getTime() <= nowMs
  ) {
    const anchorTransactionId = mostRecentPeriod.sourceTransactionId;
    const anchorSub = await db
      .select({
        status: appleSubscriptions.status,
        currentPeriodEnd: appleSubscriptions.currentPeriodEnd,
      })
      .from(appleSubscriptions)
      .where(eq(appleSubscriptions.appleTransactionId, anchorTransactionId))
      .get();

    if (
      anchorSub &&
      (anchorSub.status === "active" || anchorSub.status === "in_grace")
    ) {
      const validityEndMs = anchorSub.currentPeriodEnd.getTime();

      let priorPeriodId = mostRecentPeriod.id;
      let plan: ApplePlan = mostRecentPeriod.plan;
      let periodEndMs = mostRecentPeriod.periodEnd.getTime();

      for (
        let i = 0;
        i < MAX_ROLLOVER_ITERATIONS && periodEndMs <= nowMs && nowMs < validityEndMs;
        i++
      ) {
        const allowances = PLAN_ALLOWANCES[plan];
        const periodId = crypto.randomUUID();
        const periodStartMs = periodEndMs;
        const periodStart = new Date(periodStartMs);
        const periodEndDate = addOneCalendarMonth(periodStart);
        const createdAt = new Date();

        const insertResult = await db
          .insert(allowancePeriod)
          .values({
            id: periodId,
            userId,
            plan,
            periodStart,
            periodEnd: periodEndDate,
            narrationSecondsTotal: allowances.narrationSecondsTotal,
            narrationSecondsUsed: 0,
            voiceChatSecondsTotal: allowances.voiceChatSecondsTotal,
            voiceChatSecondsUsed: 0,
            transitionReason: "rollover",
            priorPeriodId,
            sourceTransactionId: anchorTransactionId,
            createdAt,
          })
          .onConflictDoNothing({
            target: [allowancePeriod.userId, allowancePeriod.periodStart],
          })
          .run();

        const inserted =
          ((insertResult as { meta?: { changes?: number } })?.meta?.changes ?? 0) > 0;

        if (inserted) {
          await db.insert(usageAuditLog).values({
            id: crypto.randomUUID(),
            userId,
            eventType: "allowance_period.rollover",
            details: JSON.stringify({
              priorPeriodId,
              newPeriodId: periodId,
              plan,
              sourceTransactionId: anchorTransactionId,
              periodStart: periodStartMs,
              periodEnd: periodEndDate.getTime(),
            }),
            createdAt,
          });

          priorPeriodId = periodId;
          periodEndMs = periodEndDate.getTime();
          continue;
        }

        // Concurrent caller already opened this bucket — adopt their row.
        const winner = await db
          .select()
          .from(allowancePeriod)
          .where(
            and(
              eq(allowancePeriod.userId, userId),
              eq(allowancePeriod.periodStart, periodStart),
            ),
          )
          .get();

        if (!winner) break;

        priorPeriodId = winner.id;
        plan = winner.plan;
        periodEndMs = winner.periodEnd.getTime();
      }
    }
  }

  // Rehydrate DO even when no rollover ran (active period, alreadyProcessed
  // retry after a failed first sync, etc.). Same-id path preserves usage.
  await syncCurrentAllowancePeriodToDo(env, userId);
}

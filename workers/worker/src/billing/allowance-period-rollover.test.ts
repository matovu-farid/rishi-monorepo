import { asc } from "drizzle-orm";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createDb } from "../db/drizzle";
import {
  allowancePeriod,
  appleSubscriptions,
  user,
} from "../db/schema";
import { createTestD1, type TestD1 } from "../test-utils/d1";
import { rollAllowancePeriodsForward } from "./allowance-period-rollover";

describe("legacy combined allowance rollover", () => {
  let d1: TestD1 | undefined;

  afterEach(() => d1?.close());

  it("preserves both historical totals in a combined successor", async () => {
    d1 = createTestD1();
    const db = createDb(d1);
    const periodStart = new Date("2026-01-01T00:00:00.000Z");
    const periodEnd = new Date("2026-02-01T00:00:00.000Z");
    const validityEnd = new Date("2026-04-01T00:00:00.000Z");
    const now = new Date("2026-02-15T00:00:00.000Z");
    const syncAllowancePeriod = vi.fn(async () => undefined);

    await db.insert(user).values({
      id: "user-combined",
      name: "Combined User",
      email: "combined@example.com",
      emailVerified: true,
      image: null,
      createdAt: periodStart,
      updatedAt: periodStart,
    });
    await db.insert(appleSubscriptions).values({
      appleTransactionId: "txn-combined",
      appleOriginalTransactionId: "original-combined",
      userId: "user-combined",
      productId: "legacy-combined",
      status: "active",
      currentPeriodEnd: validityEnd,
      environment: "Production",
      autoRenew: true,
    });
    await db.insert(allowancePeriod).values({
      id: "period-combined",
      userId: "user-combined",
      plan: "combined",
      periodStart,
      periodEnd,
      narrationSecondsTotal: 12_345,
      narrationSecondsUsed: 321,
      voiceChatSecondsTotal: 6_789,
      voiceChatSecondsUsed: 123,
      transitionReason: "initial",
      priorPeriodId: null,
      sourceTransactionId: "txn-combined",
      createdAt: periodStart,
    });

    await rollAllowancePeriodsForward(
      {
        DB: d1,
        USER_USAGE_LEDGER: {
          getByName: () => ({ syncAllowancePeriod }),
        },
      } as unknown as Env,
      "user-combined",
      now,
    );

    const periods = await db
      .select()
      .from(allowancePeriod)
      .orderBy(asc(allowancePeriod.periodStart));

    expect(periods).toHaveLength(2);
    expect(periods[1]).toMatchObject({
      plan: "combined",
      narrationSecondsTotal: 12_345,
      narrationSecondsUsed: 0,
      voiceChatSecondsTotal: 6_789,
      voiceChatSecondsUsed: 0,
      transitionReason: "rollover",
      priorPeriodId: "period-combined",
      sourceTransactionId: "txn-combined",
    });
    expect(syncAllowancePeriod).toHaveBeenCalledWith(
      expect.objectContaining({
        plan: "combined",
        narrationSecondsTotal: 12_345,
        voiceChatSecondsTotal: 6_789,
      }),
    );
  });
});

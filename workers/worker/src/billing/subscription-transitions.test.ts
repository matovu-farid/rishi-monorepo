import { describe, expect, it } from "vitest";
import {
  classifyTransition,
  type CurrentPeriodInfo,
} from "./subscription-transitions";

describe("legacy combined transition compatibility", () => {
  const combinedPeriod = {
    id: "combined-period",
    plan: "combined",
    productId: null,
    periodEnd: Date.parse("2026-03-01T00:00:00.000Z"),
  } as unknown as CurrentPeriodInfo;

  it("ranks an active combined period as Voice when Reader arrives", () => {
    expect(
      classifyTransition({
        currentPeriod: combinedPeriod,
        newPlan: "reader",
        newProductId: "rishi.reader.monthly",
        now: Date.parse("2026-02-01T00:00:00.000Z"),
      }),
    ).toEqual({
      kind: "downgraded_deferred",
      priorPeriodId: "combined-period",
    });
  });

  it("applies the Reader downgrade after a combined period expires", () => {
    expect(
      classifyTransition({
        currentPeriod: combinedPeriod,
        newPlan: "reader",
        newProductId: "rishi.reader.monthly",
        now: Date.parse("2026-04-01T00:00:00.000Z"),
      }),
    ).toEqual({
      kind: "downgraded_applied",
      priorPeriodId: "combined-period",
    });
  });
});

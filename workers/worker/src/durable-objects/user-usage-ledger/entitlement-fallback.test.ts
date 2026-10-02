import { describe, expect, it } from "vitest";
import { entitlementSnapshotWithoutActivePeriod } from "./types";

describe("entitlementSnapshotWithoutActivePeriod", () => {
  it("exposes remaining usage credits after a subscription period expires", () => {
    expect(entitlementSnapshotWithoutActivePeriod(42)).toEqual({
      state: "trial_active",
      remainingCredits: 42,
    });
  });

  it("keeps the expired-subscription state when no usage credits remain", () => {
    expect(entitlementSnapshotWithoutActivePeriod(0)).toEqual({
      state: "subscription_expired",
    });
  });
});

import { describe, test, expect } from "vitest";
import { isAllowedForBilledFeature } from "./sub-gate";

describe("isAllowedForBilledFeature", () => {
  test("status=active is allowed", () => {
    expect(
      isAllowedForBilledFeature({
        billingEnabled: true,
        userId: "u_1",
        subscriptionStatus: "active",
      }),
    ).toBe(true);
  });

  test("status=trialing is allowed (free-trial users should still get features)", () => {
    expect(
      isAllowedForBilledFeature({
        billingEnabled: true,
        userId: "u_1",
        subscriptionStatus: "trialing",
      }),
    ).toBe(true);
  });

  test("status=past_due is blocked (invoice failed, user needs to fix payment)", () => {
    expect(
      isAllowedForBilledFeature({
        billingEnabled: true,
        userId: "u_1",
        subscriptionStatus: "past_due",
      }),
    ).toBe(false);
  });

  test("status=canceled is blocked", () => {
    expect(
      isAllowedForBilledFeature({
        billingEnabled: true,
        userId: "u_1",
        subscriptionStatus: "canceled",
      }),
    ).toBe(false);
  });

  test("status=unpaid is blocked", () => {
    expect(
      isAllowedForBilledFeature({
        billingEnabled: true,
        userId: "u_1",
        subscriptionStatus: "unpaid",
      }),
    ).toBe(false);
  });

  test("status=incomplete is blocked (payment never completed at sign-up)", () => {
    expect(
      isAllowedForBilledFeature({
        billingEnabled: true,
        userId: "u_1",
        subscriptionStatus: "incomplete",
      }),
    ).toBe(false);
  });

  test("no subscription row at all is blocked (existing pre-plugin users)", () => {
    expect(
      isAllowedForBilledFeature({
        billingEnabled: true,
        userId: "u_1",
        subscriptionStatus: null,
      }),
    ).toBe(false);
  });

  test("billing disabled (no STRIPE_SECRET_KEY) is allowed — local dev", () => {
    expect(
      isAllowedForBilledFeature({
        billingEnabled: false,
        userId: "u_1",
        subscriptionStatus: null,
      }),
    ).toBe(true);
  });

  test("dev-bypass user is allowed regardless of subscription state", () => {
    expect(
      isAllowedForBilledFeature({
        billingEnabled: true,
        userId: "dev-user",
        subscriptionStatus: null,
      }),
    ).toBe(true);
  });
});

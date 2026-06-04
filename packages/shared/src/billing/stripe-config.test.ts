import { describe, test, expect } from "vitest";
import {
  STRIPE_TEST_IDS,
  STRIPE_LIVE_IDS,
  getStripeIds,
  getStripeIdsForKey,
} from "./stripe-config";

describe("getStripeIds", () => {
  test("returns test ids for 'test' mode", () => {
    expect(getStripeIds("test")).toBe(STRIPE_TEST_IDS);
  });

  test("returns live ids for 'live' mode when configured", () => {
    expect(getStripeIds("live")).toBe(STRIPE_LIVE_IDS);
  });
});

describe("getStripeIdsForKey", () => {
  test("returns live ids when key starts with sk_live_", () => {
    expect(getStripeIdsForKey("sk_live_abc123")).toBe(STRIPE_LIVE_IDS);
  });

  test("returns test ids when key starts with sk_test_", () => {
    expect(getStripeIdsForKey("sk_test_abc123")).toBe(STRIPE_TEST_IDS);
  });

  test("returns test ids when key is undefined", () => {
    expect(getStripeIdsForKey(undefined)).toBe(STRIPE_TEST_IDS);
  });

  test("returns test ids when key is empty string", () => {
    expect(getStripeIdsForKey("")).toBe(STRIPE_TEST_IDS);
  });

  test("returns test ids when key is malformed", () => {
    expect(getStripeIdsForKey("rk_live_restricted")).toBe(STRIPE_TEST_IDS);
  });
});

import { describe, test, expect, vi } from "vitest";
import { STRIPE_TEST_IDS } from "@rishi/shared/billing/stripe-config";
import { applyWelcomeCreditAndSubscription } from "./stripe";

function makeStripeStub() {
  const createBalanceTransaction = vi.fn().mockResolvedValue({});
  const createSubscription = vi.fn().mockResolvedValue({
    id: "sub_test_x",
    status: "active",
  });
  return {
    spy: { createBalanceTransaction, createSubscription },
    stripe: {
      customers: { createBalanceTransaction },
      subscriptions: { create: createSubscription },
    },
  };
}

describe("applyWelcomeCreditAndSubscription", () => {
  test("applies a -$1.00 USD customer balance credit", async () => {
    const { stripe, spy } = makeStripeStub();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await applyWelcomeCreditAndSubscription(stripe as any, "cus_test_a");
    expect(spy.createBalanceTransaction).toHaveBeenCalledTimes(1);
    expect(spy.createBalanceTransaction).toHaveBeenCalledWith(
      "cus_test_a",
      expect.objectContaining({
        amount: -100,
        currency: "usd",
      }),
    );
  });

  test("creates a metered subscription on the configured Stripe price", async () => {
    const { stripe, spy } = makeStripeStub();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await applyWelcomeCreditAndSubscription(stripe as any, "cus_test_b");
    expect(spy.createSubscription).toHaveBeenCalledTimes(1);
    expect(spy.createSubscription).toHaveBeenCalledWith(
      expect.objectContaining({
        customer: "cus_test_b",
        items: [{ price: STRIPE_TEST_IDS.priceId }],
      }),
    );
  });

  test("returns the created subscription id", async () => {
    const { stripe } = makeStripeStub();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const result = await applyWelcomeCreditAndSubscription(
      stripe as any,
      "cus_test_c",
    );
    expect(result.subscriptionId).toBe("sub_test_x");
  });
});

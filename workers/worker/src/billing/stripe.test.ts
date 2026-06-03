import { describe, test, expect, vi } from "vitest";
import { STRIPE_TEST_IDS } from "@rishi/shared/billing/stripe-config";
import { applyWelcomeCreditAndSubscription } from "./stripe";

function makeStripeStub() {
  const createBalanceTransaction = vi.fn().mockResolvedValue({});
  const createSubscription = vi.fn().mockResolvedValue({
    id: "sub_test_x",
    status: "active",
  });
  const updateCustomer = vi.fn().mockResolvedValue({});
  return {
    spy: { createBalanceTransaction, createSubscription, updateCustomer },
    stripe: {
      customers: { createBalanceTransaction, update: updateCustomer },
      subscriptions: { create: createSubscription },
    },
  };
}

describe("applyWelcomeCreditAndSubscription", () => {
  test("applies a -$1.00 USD customer balance credit", async () => {
    const { stripe, spy } = makeStripeStub();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await applyWelcomeCreditAndSubscription(stripe as any, "cus_test_a", null);
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
    await applyWelcomeCreditAndSubscription(stripe as any, "cus_test_b", null);
    expect(spy.createSubscription).toHaveBeenCalledTimes(1);
    expect(spy.createSubscription).toHaveBeenCalledWith(
      expect.objectContaining({
        customer: "cus_test_b",
        items: [{ price: STRIPE_TEST_IDS.priceId }],
        automatic_tax: { enabled: true },
      }),
    );
  });

  test("returns the created subscription id", async () => {
    const { stripe } = makeStripeStub();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const result = await applyWelcomeCreditAndSubscription(
      stripe as any,
      "cus_test_c",
      null,
    );
    expect(result.subscriptionId).toBe("sub_test_x");
  });

  test("updates customer tax location when IP is provided", async () => {
    const { stripe, spy } = makeStripeStub();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await applyWelcomeCreditAndSubscription(
      stripe as any,
      "cus_test_d",
      "203.0.113.42",
    );
    expect(spy.updateCustomer).toHaveBeenCalledTimes(1);
    expect(spy.updateCustomer).toHaveBeenCalledWith(
      "cus_test_d",
      expect.objectContaining({
        tax: { ip_address: "203.0.113.42", validate_location: "auto" },
      }),
    );
  });

  test("does not update customer when IP is null", async () => {
    const { stripe, spy } = makeStripeStub();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await applyWelcomeCreditAndSubscription(stripe as any, "cus_test_e", null);
    expect(spy.updateCustomer).not.toHaveBeenCalled();
  });
});

import { describe, test, expect, vi } from "vitest";
import { ensureCustomerAndPortal } from "./start";

const PRICE_ID = "price_test_xxx";

interface DbRow {
  stripeCustomerId: string | null;
  email: string;
}

function makeDeps(row: DbRow | null) {
  const customersCreate = vi
    .fn()
    .mockResolvedValue({ id: "cus_new" });
  const portalCreate = vi
    .fn()
    .mockResolvedValue({ url: "https://billing.stripe.com/p/session/test_xyz" });
  const stripe = {
    customers: { create: customersCreate },
    billingPortal: { sessions: { create: portalCreate } },
  };
  const getUserRow = vi.fn().mockResolvedValue(row);
  const updateUserStripeCustomerId = vi.fn().mockResolvedValue(undefined);
  const ensureCreditAndSubscription = vi
    .fn()
    .mockResolvedValue({ subscriptionId: "sub_new", steps: [] });
  return {
    stripe,
    spy: {
      customersCreate,
      portalCreate,
      getUserRow,
      updateUserStripeCustomerId,
      ensureCreditAndSubscription,
    },
    deps: {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe: stripe as any,
      priceId: PRICE_ID,
      userId: "user_1",
      returnUrl: "https://app.example/account",
      ip: "203.0.113.42",
      getUserRow,
      updateUserStripeCustomerId,
      ensureCreditAndSubscription,
    },
  };
}

describe("ensureCustomerAndPortal", () => {
  test("existing customer: skips create + ensureCreditAndSubscription, mints portal url", async () => {
    const { deps, spy } = makeDeps({
      stripeCustomerId: "cus_existing",
      email: "u@example.com",
    });
    const result = await ensureCustomerAndPortal(deps);
    expect(result).toEqual({
      url: "https://billing.stripe.com/p/session/test_xyz",
    });
    expect(spy.customersCreate).not.toHaveBeenCalled();
    expect(spy.updateUserStripeCustomerId).not.toHaveBeenCalled();
    expect(spy.ensureCreditAndSubscription).not.toHaveBeenCalled();
    expect(spy.portalCreate).toHaveBeenCalledWith({
      customer: "cus_existing",
      return_url: "https://app.example/account",
    });
  });

  test("missing customer: creates Stripe customer, persists, ensures credit+sub, mints portal", async () => {
    const { deps, spy } = makeDeps({
      stripeCustomerId: null,
      email: "new@example.com",
    });
    const result = await ensureCustomerAndPortal(deps);
    expect(result.url).toBe("https://billing.stripe.com/p/session/test_xyz");

    expect(spy.customersCreate).toHaveBeenCalledTimes(1);
    expect(spy.customersCreate).toHaveBeenCalledWith({
      email: "new@example.com",
      metadata: { userId: "user_1" },
    });

    expect(spy.updateUserStripeCustomerId).toHaveBeenCalledTimes(1);
    expect(spy.updateUserStripeCustomerId).toHaveBeenCalledWith("cus_new");

    expect(spy.ensureCreditAndSubscription).toHaveBeenCalledTimes(1);
    expect(spy.ensureCreditAndSubscription).toHaveBeenCalledWith(
      deps.stripe,
      "cus_new",
      PRICE_ID,
      "203.0.113.42",
    );

    expect(spy.portalCreate).toHaveBeenCalledWith({
      customer: "cus_new",
      return_url: "https://app.example/account",
    });
  });

  test("returnUrl is passed through to the portal session", async () => {
    const { deps, spy } = makeDeps({
      stripeCustomerId: "cus_existing",
      email: "u@example.com",
    });
    await ensureCustomerAndPortal({
      ...deps,
      returnUrl: "https://other.example/billing",
    });
    expect(spy.portalCreate).toHaveBeenCalledWith({
      customer: "cus_existing",
      return_url: "https://other.example/billing",
    });
  });

  test("ip null is forwarded to ensureCreditAndSubscription", async () => {
    const { deps, spy } = makeDeps({
      stripeCustomerId: null,
      email: "n@example.com",
    });
    await ensureCustomerAndPortal({ ...deps, ip: null });
    expect(spy.ensureCreditAndSubscription).toHaveBeenCalledWith(
      deps.stripe,
      "cus_new",
      PRICE_ID,
      null,
    );
  });

  test("throws when the user row is missing — caller shouldn't reach Stripe", async () => {
    const { deps, spy } = makeDeps(null);
    await expect(ensureCustomerAndPortal(deps)).rejects.toThrow(/user/i);
    expect(spy.customersCreate).not.toHaveBeenCalled();
    expect(spy.portalCreate).not.toHaveBeenCalled();
  });
});

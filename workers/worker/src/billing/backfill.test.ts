import { describe, test, expect, vi } from "vitest";
import { backfillOneUser, ensureCreditAndSubscription } from "./backfill";

const PRICE_ID = "price_test_xxx";

interface StubOptions {
  searchData?: Array<{ id: string; balance: number }>;
  listData?: Array<{
    id: string;
    status: string;
    items: { data: Array<{ price: { id: string } }> };
  }>;
}

function makeStripeStub(opts: StubOptions = {}) {
  const search = vi.fn().mockResolvedValue({ data: opts.searchData ?? [] });
  const create = vi.fn().mockResolvedValue({ id: "cus_new", balance: 0 });
  const createBalanceTransaction = vi.fn().mockResolvedValue({});
  const list = vi.fn().mockResolvedValue({ data: opts.listData ?? [] });
  const createSubscription = vi
    .fn()
    .mockResolvedValue({ id: "sub_new", status: "active" });
  const updateCustomer = vi.fn().mockResolvedValue({});
  // ensureCreditAndSubscription reads balance via customers.retrieve. Mirror
  // the balance the search/create result already exposes so the existing
  // backfill tests don't need per-test wiring.
  const retrieve = vi.fn().mockImplementation(async (id: string) => {
    const found = opts.searchData?.find((c) => c.id === id);
    return { id, balance: found?.balance ?? 0 };
  });
  return {
    spy: {
      search,
      create,
      createBalanceTransaction,
      list,
      createSubscription,
      updateCustomer,
      retrieve,
    },
    stripe: {
      customers: {
        search,
        create,
        createBalanceTransaction,
        update: updateCustomer,
        retrieve,
      },
      subscriptions: { list, create: createSubscription },
    },
  };
}

describe("backfillOneUser", () => {
  test("brand-new user: creates customer, applies credit, creates sub", async () => {
    const { stripe, spy } = makeStripeStub();
    const result = await backfillOneUser(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "user_1",
      "u1@example.com",
      PRICE_ID,
    );
    expect(result.steps).toEqual([
      "created-customer",
      "applied-credit",
      "created-sub",
    ]);
    expect(result.stripeCustomerId).toBe("cus_new");
    expect(result.subscriptionId).toBe("sub_new");
    expect(spy.search).toHaveBeenCalledTimes(1);
    expect(spy.create).toHaveBeenCalledTimes(1);
    expect(spy.createBalanceTransaction).toHaveBeenCalledTimes(1);
    expect(spy.createSubscription).toHaveBeenCalledTimes(1);
  });

  test("fully-backfilled user: reuses customer, skips credit, skips sub", async () => {
    const { stripe, spy } = makeStripeStub({
      searchData: [{ id: "cus_existing", balance: -100 }],
      listData: [
        {
          id: "sub_existing",
          status: "active",
          items: { data: [{ price: { id: PRICE_ID } }] },
        },
      ],
    });
    const result = await backfillOneUser(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "user_2",
      "u2@example.com",
      PRICE_ID,
    );
    expect(result.steps).toEqual([
      "reused-customer",
      "skipped-credit",
      "skipped-sub",
    ]);
    expect(result.stripeCustomerId).toBe("cus_existing");
    expect(result.subscriptionId).toBe("sub_existing");
    expect(spy.create).not.toHaveBeenCalled();
    expect(spy.createBalanceTransaction).not.toHaveBeenCalled();
    expect(spy.createSubscription).not.toHaveBeenCalled();
  });

  test("customer exists with no credit and no sub", async () => {
    const { stripe, spy } = makeStripeStub({
      searchData: [{ id: "cus_existing", balance: 0 }],
      listData: [],
    });
    const result = await backfillOneUser(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "user_3",
      "u3@example.com",
      PRICE_ID,
    );
    expect(result.steps).toEqual([
      "reused-customer",
      "applied-credit",
      "created-sub",
    ]);
    expect(result.stripeCustomerId).toBe("cus_existing");
    expect(spy.create).not.toHaveBeenCalled();
    expect(spy.createBalanceTransaction).toHaveBeenCalledTimes(1);
    expect(spy.createSubscription).toHaveBeenCalledTimes(1);
  });

  test("customer exists with credit but no sub", async () => {
    const { stripe, spy } = makeStripeStub({
      searchData: [{ id: "cus_existing", balance: -100 }],
      listData: [],
    });
    const result = await backfillOneUser(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "user_4",
      "u4@example.com",
      PRICE_ID,
    );
    expect(result.steps).toEqual([
      "reused-customer",
      "skipped-credit",
      "created-sub",
    ]);
    expect(spy.createBalanceTransaction).not.toHaveBeenCalled();
    expect(spy.createSubscription).toHaveBeenCalledTimes(1);
  });

  test("customer exists with sub against a different price: creates new sub on our price", async () => {
    const { stripe, spy } = makeStripeStub({
      searchData: [{ id: "cus_existing", balance: -100 }],
      listData: [
        {
          id: "sub_other",
          status: "active",
          items: { data: [{ price: { id: "price_other" } }] },
        },
      ],
    });
    const result = await backfillOneUser(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "user_5",
      "u5@example.com",
      PRICE_ID,
    );
    expect(result.steps).toEqual([
      "reused-customer",
      "skipped-credit",
      "created-sub",
    ]);
    expect(spy.createSubscription).toHaveBeenCalledTimes(1);
  });

  test("canceled sub on our price doesn't count as active: creates new sub", async () => {
    const { stripe, spy } = makeStripeStub({
      searchData: [{ id: "cus_existing", balance: -100 }],
      listData: [
        {
          id: "sub_canceled",
          status: "canceled",
          items: { data: [{ price: { id: PRICE_ID } }] },
        },
      ],
    });
    const result = await backfillOneUser(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "user_6",
      "u6@example.com",
      PRICE_ID,
    );
    expect(result.steps).toContain("created-sub");
    expect(result.steps).toContain("skipped-credit");
    expect(spy.createSubscription).toHaveBeenCalledTimes(1);
  });

  test("balance more negative than -100 skips credit (guard is <=, not ===)", async () => {
    const { stripe, spy } = makeStripeStub({
      searchData: [{ id: "cus_existing", balance: -250 }],
      listData: [],
    });
    const result = await backfillOneUser(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "user_7",
      "u7@example.com",
      PRICE_ID,
    );
    expect(result.steps).toContain("skipped-credit");
    expect(spy.createBalanceTransaction).not.toHaveBeenCalled();
  });

  test("customer create called with metadata.userId and US address", async () => {
    const { stripe, spy } = makeStripeStub();
    await backfillOneUser(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "user_8",
      "u8@example.com",
      PRICE_ID,
    );
    expect(spy.create).toHaveBeenCalledWith(
      expect.objectContaining({
        email: "u8@example.com",
        metadata: { userId: "user_8" },
        address: { country: "US" },
      }),
    );
  });

  test("new subscription created with automatic_tax and configured priceId", async () => {
    const { stripe, spy } = makeStripeStub();
    await backfillOneUser(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "user_9",
      "u9@example.com",
      PRICE_ID,
    );
    expect(spy.createSubscription).toHaveBeenCalledWith(
      expect.objectContaining({
        customer: "cus_new",
        items: [{ price: PRICE_ID }],
        automatic_tax: { enabled: true },
      }),
    );
  });

  test("onCustomerEnsured fires once with the customer id, before credit + sub calls", async () => {
    const { stripe, spy } = makeStripeStub();
    const callOrder: string[] = [];
    spy.createBalanceTransaction.mockImplementation(async () => {
      callOrder.push("credit");
      return {};
    });
    spy.createSubscription.mockImplementation(async () => {
      callOrder.push("sub");
      return { id: "sub_new", status: "active" };
    });
    const onCustomerEnsured = vi.fn(async (id: string) => {
      callOrder.push(`ensured:${id}`);
    });
    await backfillOneUser(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "user_10",
      "u10@example.com",
      PRICE_ID,
      { onCustomerEnsured },
    );
    expect(onCustomerEnsured).toHaveBeenCalledTimes(1);
    expect(onCustomerEnsured).toHaveBeenCalledWith("cus_new");
    expect(callOrder).toEqual(["ensured:cus_new", "credit", "sub"]);
  });

  test("onCustomerEnsured throwing aborts the backfill before credit + sub", async () => {
    const { stripe, spy } = makeStripeStub();
    const onCustomerEnsured = vi.fn(async () => {
      throw new Error("d1 write failed");
    });
    await expect(
      backfillOneUser(
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        stripe as any,
        "user_11",
        "u11@example.com",
        PRICE_ID,
        { onCustomerEnsured },
      ),
    ).rejects.toThrow("d1 write failed");
    expect(spy.createBalanceTransaction).not.toHaveBeenCalled();
    expect(spy.createSubscription).not.toHaveBeenCalled();
  });
});

describe("ensureCreditAndSubscription", () => {
  test("brand-new customer: applies credit, creates sub, updates tax IP", async () => {
    const { stripe, spy } = makeStripeStub();
    const result = await ensureCreditAndSubscription(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "cus_a",
      PRICE_ID,
      "203.0.113.42",
    );
    expect(result.steps).toEqual(["applied-credit", "created-sub"]);
    expect(result.subscriptionId).toBe("sub_new");
    expect(spy.updateCustomer).toHaveBeenCalledTimes(1);
    expect(spy.updateCustomer).toHaveBeenCalledWith(
      "cus_a",
      expect.objectContaining({
        tax: { ip_address: "203.0.113.42", validate_location: "auto" },
      }),
    );
    expect(spy.createBalanceTransaction).toHaveBeenCalledTimes(1);
    expect(spy.createSubscription).toHaveBeenCalledTimes(1);
  });

  test("already-credited (balance -100), no subs: skips credit, creates sub", async () => {
    const { stripe, spy } = makeStripeStub({
      searchData: [{ id: "cus_b", balance: -100 }],
      listData: [],
    });
    const result = await ensureCreditAndSubscription(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "cus_b",
      PRICE_ID,
      null,
    );
    expect(result.steps).toEqual(["skipped-credit", "created-sub"]);
    expect(spy.createBalanceTransaction).not.toHaveBeenCalled();
    expect(spy.createSubscription).toHaveBeenCalledTimes(1);
  });

  test("already-credited with active sub on our price: skips both", async () => {
    const { stripe, spy } = makeStripeStub({
      searchData: [{ id: "cus_c", balance: -100 }],
      listData: [
        {
          id: "sub_existing",
          status: "active",
          items: { data: [{ price: { id: PRICE_ID } }] },
        },
      ],
    });
    const result = await ensureCreditAndSubscription(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "cus_c",
      PRICE_ID,
      null,
    );
    expect(result.steps).toEqual(["skipped-credit", "skipped-sub"]);
    expect(result.subscriptionId).toBe("sub_existing");
    expect(spy.createBalanceTransaction).not.toHaveBeenCalled();
    expect(spy.createSubscription).not.toHaveBeenCalled();
  });

  test("canceled sub on our price + balance 0: credit applied, new sub created", async () => {
    const { stripe, spy } = makeStripeStub({
      searchData: [{ id: "cus_d", balance: 0 }],
      listData: [
        {
          id: "sub_canceled",
          status: "canceled",
          items: { data: [{ price: { id: PRICE_ID } }] },
        },
      ],
    });
    const result = await ensureCreditAndSubscription(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "cus_d",
      PRICE_ID,
      null,
    );
    expect(result.steps).toEqual(["applied-credit", "created-sub"]);
    expect(spy.createBalanceTransaction).toHaveBeenCalledTimes(1);
    expect(spy.createSubscription).toHaveBeenCalledTimes(1);
  });

  test("IP null: customers.update is NOT called", async () => {
    const { stripe, spy } = makeStripeStub();
    await ensureCreditAndSubscription(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "cus_e",
      PRICE_ID,
      null,
    );
    expect(spy.updateCustomer).not.toHaveBeenCalled();
  });

  test("IP provided: customers.update called with tax shape", async () => {
    const { stripe, spy } = makeStripeStub();
    await ensureCreditAndSubscription(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "cus_f",
      PRICE_ID,
      "198.51.100.7",
    );
    expect(spy.updateCustomer).toHaveBeenCalledTimes(1);
    expect(spy.updateCustomer).toHaveBeenCalledWith(
      "cus_f",
      expect.objectContaining({
        tax: { ip_address: "198.51.100.7", validate_location: "auto" },
      }),
    );
  });

  test("balance -250 (over-credited): skips credit (guard is <=, not ===)", async () => {
    const { stripe, spy } = makeStripeStub({
      searchData: [{ id: "cus_g", balance: -250 }],
      listData: [],
    });
    const result = await ensureCreditAndSubscription(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "cus_g",
      PRICE_ID,
      null,
    );
    expect(result.steps).toContain("skipped-credit");
    expect(spy.createBalanceTransaction).not.toHaveBeenCalled();
  });

  test("active sub against a different price: ignored, new sub on our price created", async () => {
    const { stripe, spy } = makeStripeStub({
      searchData: [{ id: "cus_h", balance: -100 }],
      listData: [
        {
          id: "sub_other",
          status: "active",
          items: { data: [{ price: { id: "price_other" } }] },
        },
      ],
    });
    const result = await ensureCreditAndSubscription(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      "cus_h",
      PRICE_ID,
      null,
    );
    expect(result.steps).toEqual(["skipped-credit", "created-sub"]);
    expect(spy.createSubscription).toHaveBeenCalledTimes(1);
  });

  test("idempotent: second call emits skipped-credit + skipped-sub, no writes", async () => {
    // Mutable state: after the first call applies credit + creates sub, the
    // next retrieve/list should reflect the new world so guards trip.
    let balance = 0;
    const customerId = "cus_idem";
    const subs: Array<{
      id: string;
      status: string;
      items: { data: Array<{ price: { id: string } }> };
    }> = [];

    const retrieve = vi.fn(async () => ({ id: customerId, balance }));
    const createBalanceTransaction = vi.fn(async () => {
      balance = -100;
      return {};
    });
    const list = vi.fn(async () => ({ data: subs }));
    const createSubscription = vi.fn(async () => {
      const sub = {
        id: "sub_idem",
        status: "active",
        items: { data: [{ price: { id: PRICE_ID } }] },
      };
      subs.push(sub);
      return sub;
    });
    const updateCustomer = vi.fn().mockResolvedValue({});

    const stripe = {
      customers: {
        retrieve,
        createBalanceTransaction,
        update: updateCustomer,
      },
      subscriptions: { list, create: createSubscription },
    };

    const first = await ensureCreditAndSubscription(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      customerId,
      PRICE_ID,
      null,
    );
    expect(first.steps).toEqual(["applied-credit", "created-sub"]);

    const second = await ensureCreditAndSubscription(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      stripe as any,
      customerId,
      PRICE_ID,
      null,
    );
    expect(second.steps).toEqual(["skipped-credit", "skipped-sub"]);
    expect(second.subscriptionId).toBe("sub_idem");

    // Exactly one write of each kind across both calls.
    expect(createBalanceTransaction).toHaveBeenCalledTimes(1);
    expect(createSubscription).toHaveBeenCalledTimes(1);
  });
});

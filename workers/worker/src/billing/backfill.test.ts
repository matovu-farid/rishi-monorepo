import { describe, test, expect, vi } from "vitest";
import { backfillOneUser } from "./backfill";

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
  return {
    spy: { search, create, createBalanceTransaction, list, createSubscription },
    stripe: {
      customers: { search, create, createBalanceTransaction },
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

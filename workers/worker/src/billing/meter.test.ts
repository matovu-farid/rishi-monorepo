import { describe, test, expect, vi } from "vitest";
import { METER_EVENT_NAME } from "@rishi/shared/billing/stripe-config";
import { reportMeterEvent } from "./meter";

function makeStripeStub() {
  const create = vi.fn().mockResolvedValue({ object: "billing.meter_event" });
  return {
    spy: create,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    stripe: { billing: { meterEvents: { create } } } as any,
  };
}

describe("reportMeterEvent", () => {
  test("fires a meter event with event_name, customer id, and value", async () => {
    const { stripe, spy } = makeStripeStub();
    await reportMeterEvent(stripe, "cus_x", 12345);
    expect(spy).toHaveBeenCalledTimes(1);
    expect(spy).toHaveBeenCalledWith({
      event_name: METER_EVENT_NAME,
      payload: { stripe_customer_id: "cus_x", value: "12345" },
    });
  });

  test("serializes value as a string (Stripe requires string-encoded numbers)", async () => {
    const { stripe, spy } = makeStripeStub();
    await reportMeterEvent(stripe, "cus_y", 7);
    expect(spy.mock.calls[0][0].payload.value).toBe("7");
    expect(typeof spy.mock.calls[0][0].payload.value).toBe("string");
  });

  test("is a no-op when stripe client is null (billing disabled)", async () => {
    const { spy } = makeStripeStub();
    await reportMeterEvent(null, "cus_x", 12345);
    expect(spy).not.toHaveBeenCalled();
  });

  test("is a no-op when customer id is null or empty", async () => {
    const { stripe, spy } = makeStripeStub();
    await reportMeterEvent(stripe, null, 12345);
    await reportMeterEvent(stripe, "", 12345);
    expect(spy).not.toHaveBeenCalled();
  });

  test("is a no-op for zero or negative values (nothing to report)", async () => {
    const { stripe, spy } = makeStripeStub();
    await reportMeterEvent(stripe, "cus_x", 0);
    await reportMeterEvent(stripe, "cus_x", -5);
    expect(spy).not.toHaveBeenCalled();
  });
});

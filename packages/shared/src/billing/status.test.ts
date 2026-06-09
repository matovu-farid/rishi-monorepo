import { describe, it, expect } from "vitest";
import {
  getBillingStatusBucket,
  getBillingStatusCopy,
  type BillingStatusBucket,
} from "./status";

describe("getBillingStatusBucket", () => {
  it("maps 'past_due' to past_due bucket", () => {
    expect(getBillingStatusBucket("past_due")).toBe("past_due");
  });

  it("maps 'unpaid' to past_due bucket (same UX as failed payment)", () => {
    expect(getBillingStatusBucket("unpaid")).toBe("past_due");
  });

  it("maps 'canceled' to canceled bucket", () => {
    expect(getBillingStatusBucket("canceled")).toBe("canceled");
  });

  it("maps 'incomplete' to incomplete bucket", () => {
    expect(getBillingStatusBucket("incomplete")).toBe("incomplete");
  });

  it("maps 'incomplete_expired' to incomplete bucket", () => {
    expect(getBillingStatusBucket("incomplete_expired")).toBe("incomplete");
  });

  it("maps null to unknown bucket", () => {
    expect(getBillingStatusBucket(null)).toBe("unknown");
  });

  it("maps undefined to unknown bucket", () => {
    expect(getBillingStatusBucket(undefined)).toBe("unknown");
  });

  it("maps empty string to unknown bucket", () => {
    expect(getBillingStatusBucket("")).toBe("unknown");
  });

  it("maps unrecognized strings to unknown bucket", () => {
    expect(getBillingStatusBucket("trialing")).toBe("unknown");
    expect(getBillingStatusBucket("active")).toBe("unknown");
    expect(getBillingStatusBucket("totally_made_up")).toBe("unknown");
  });
});

describe("getBillingStatusCopy", () => {
  const buckets: BillingStatusBucket[] = [
    "past_due",
    "canceled",
    "incomplete",
    "unknown",
  ];

  for (const bucket of buckets) {
    it(`returns non-empty title, body, and ctaLabel for '${bucket}'`, () => {
      const copy = getBillingStatusCopy(bucket);
      expect(copy.title.length).toBeGreaterThan(0);
      expect(copy.body.length).toBeGreaterThan(0);
      expect(copy.ctaLabel.length).toBeGreaterThan(0);
    });
  }

  it("returns the expected copy for past_due", () => {
    expect(getBillingStatusCopy("past_due")).toEqual({
      title: "Payment failed",
      body: "We couldn't charge your card. Update your payment method to keep using premium features.",
      ctaLabel: "Update payment method",
    });
  });

  it("returns the expected copy for canceled", () => {
    expect(getBillingStatusCopy("canceled")).toEqual({
      title: "Subscription canceled",
      body: "Your subscription was canceled. Reactivate it to keep using premium features.",
      ctaLabel: "Reactivate subscription",
    });
  });

  it("returns the expected copy for incomplete", () => {
    expect(getBillingStatusCopy("incomplete")).toEqual({
      title: "Finish setting up billing",
      body: "Your subscription setup didn't complete. Finish payment to unlock premium features.",
      ctaLabel: "Complete setup",
    });
  });

  it("returns the expected copy for unknown", () => {
    expect(getBillingStatusCopy("unknown")).toEqual({
      title: "Subscription required",
      body: "An active subscription is required to use this feature.",
      ctaLabel: "Manage subscription",
    });
  });
});

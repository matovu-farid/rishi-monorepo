/**
 * Tests for `BillingInactiveError` + `isBillingInactiveResponse` typeguard
 * (T-P1.3 / BILLING-002).
 *
 * These tests intentionally fail until `packages/shared/src/billing/errors.ts`
 * exists.
 */
import { describe, it, expect } from "vitest";
import {
  BillingInactiveError,
  isBillingInactiveResponse,
} from "./errors";

describe("BillingInactiveError", () => {
  it("is an instance of Error", () => {
    const e = new BillingInactiveError("canceled");
    expect(e).toBeInstanceOf(Error);
    expect(e).toBeInstanceOf(BillingInactiveError);
  });

  it("has the literal code 'BILLING_INACTIVE'", () => {
    const e = new BillingInactiveError("canceled");
    expect(e.code).toBe("BILLING_INACTIVE");
  });

  it("preserves subscriptionStatus passed to the constructor", () => {
    const e = new BillingInactiveError("canceled");
    expect(e.subscriptionStatus).toBe("canceled");
  });

  it("accepts null subscriptionStatus", () => {
    const e = new BillingInactiveError(null);
    expect(e.subscriptionStatus).toBeNull();
  });

  it("derives a human-readable message from the subscription status", () => {
    // The message MUST mention "subscription" so unhandled throws are
    // self-describing in logs; we don't pin the exact wording, just shape.
    const e = new BillingInactiveError("canceled");
    expect(e.message).toMatch(/subscription/i);
  });
});

describe("isBillingInactiveResponse", () => {
  it("returns true for a 402 with the expected body shape", () => {
    expect(
      isBillingInactiveResponse(402, {
        code: "BILLING_INACTIVE",
        subscriptionStatus: "canceled",
      }),
    ).toBe(true);
  });

  it("accepts null subscriptionStatus", () => {
    expect(
      isBillingInactiveResponse(402, {
        code: "BILLING_INACTIVE",
        subscriptionStatus: null,
      }),
    ).toBe(true);
  });

  it("returns false for a non-402 status (even with the right body)", () => {
    expect(
      isBillingInactiveResponse(500, {
        code: "BILLING_INACTIVE",
        subscriptionStatus: "canceled",
      }),
    ).toBe(false);
  });

  it("returns false for a 402 with a different code", () => {
    expect(
      isBillingInactiveResponse(402, {
        code: "SOMETHING_ELSE",
      }),
    ).toBe(false);
  });

  it("returns false for a 402 with no code field", () => {
    expect(
      isBillingInactiveResponse(402, { error: "something else" }),
    ).toBe(false);
  });

  it("returns false for non-object bodies (string, null, undefined)", () => {
    expect(isBillingInactiveResponse(402, "not-json")).toBe(false);
    expect(isBillingInactiveResponse(402, null)).toBe(false);
    expect(isBillingInactiveResponse(402, undefined)).toBe(false);
  });
});

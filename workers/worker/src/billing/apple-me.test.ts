import { describe, it, expect, vi } from "vitest";
import { handleBillingMe, type BillingMeDeps } from "./apple-me";

// 2027-06-11T00:00:00.000Z — ms-epoch (Apple's native unit; appleSubscriptions
// stores currentPeriodEnd in timestamp_ms mode so the DI hands a Date through).
const APPLE_MS = 1812585600000;
// 2027-07-12T00:00:00Z — seconds-since-1970 (Stripe's native unit; the
// production adapter converts the Drizzle `timestamp`-mode Date to seconds
// before handing it to the pure handler).
const STRIPE_SEC = 1815264000;

function makeDeps(
  opts: {
    appleRow?: { currentPeriodEnd: Date; status: string } | null;
    stripeRow?: { periodEnd: number; status: string } | null;
  } = {},
): BillingMeDeps & { _spy: {
  findAppleActive: ReturnType<typeof vi.fn>;
  findStripeActive: ReturnType<typeof vi.fn>;
} } {
  const findAppleActive = vi.fn(async () => opts.appleRow ?? null);
  const findStripeActive = vi.fn(async () => opts.stripeRow ?? null);
  return {
    db: { findAppleActive, findStripeActive },
    _spy: { findAppleActive, findStripeActive },
  };
}

describe("handleBillingMe", () => {
  it("Apple row active → premium=true, premiumUntil=apple ISO, Stripe not queried", async () => {
    const deps = makeDeps({
      appleRow: { currentPeriodEnd: new Date(APPLE_MS), status: "active" },
    });
    const result = await handleBillingMe({ deps, userId: "u1" });
    expect(result).toEqual({
      premium: true,
      premiumUntil: new Date(APPLE_MS).toISOString(),
    });
    expect(deps._spy.findStripeActive).not.toHaveBeenCalled();
  });

  it("No Apple, Stripe active → falls back to Stripe periodEnd (converted from seconds)", async () => {
    const deps = makeDeps({
      stripeRow: { periodEnd: STRIPE_SEC, status: "active" },
    });
    const result = await handleBillingMe({ deps, userId: "u1" });
    expect(result).toEqual({
      premium: true,
      premiumUntil: new Date(STRIPE_SEC * 1000).toISOString(),
    });
    expect(deps._spy.findStripeActive).toHaveBeenCalledOnce();
  });

  it("No subscriptions anywhere → premium=false, premiumUntil=null", async () => {
    const deps = makeDeps({});
    const result = await handleBillingMe({ deps, userId: "u1" });
    expect(result).toEqual({ premium: false, premiumUntil: null });
    expect(deps._spy.findAppleActive).toHaveBeenCalledOnce();
    expect(deps._spy.findStripeActive).toHaveBeenCalledOnce();
  });

  it("Apple row refunded → not returned by findAppleActive; falls back to Stripe", async () => {
    // findAppleActive returns null when status is refunded (the production
    // filter excludes anything not in ('active', 'in_grace')). This test
    // documents the contract: the handler relies on the resolver to apply
    // the status filter — it does NOT defensively re-filter inside the pure
    // function.
    const deps = makeDeps({
      appleRow: null,
      stripeRow: { periodEnd: STRIPE_SEC, status: "active" },
    });
    const result = await handleBillingMe({ deps, userId: "u1" });
    expect(result.premium).toBe(true);
  });

  it("premiumUntil is ISO8601 UTC Z-suffixed string", async () => {
    const deps = makeDeps({
      appleRow: { currentPeriodEnd: new Date(APPLE_MS), status: "active" },
    });
    const result = await handleBillingMe({ deps, userId: "u1" });
    expect(result.premiumUntil).toMatch(
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/,
    );
  });
});

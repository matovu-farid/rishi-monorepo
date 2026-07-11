import { describe, test, expect, vi } from "vitest";
import { createPortalSession } from "./portal";
function makeStripeStub(returnUrl = "https://billing.stripe.com/p/session/test_xyz") {
    const create = vi.fn().mockResolvedValue({ url: returnUrl });
    return {
        spy: create,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        stripe: { billingPortal: { sessions: { create } } },
    };
}
describe("createPortalSession", () => {
    test("creates a portal session for the given customer and return URL", async () => {
        const { stripe, spy } = makeStripeStub();
        const url = await createPortalSession(stripe, "cus_x", "https://app.example/account");
        expect(spy).toHaveBeenCalledWith({
            customer: "cus_x",
            return_url: "https://app.example/account",
        });
        expect(url).toBe("https://billing.stripe.com/p/session/test_xyz");
    });
    test("throws when the customer id is missing — caller shouldn't reach Stripe without one", async () => {
        const { stripe, spy } = makeStripeStub();
        await expect(createPortalSession(stripe, "", "https://app.example/account")).rejects.toThrow(/customer/i);
        expect(spy).not.toHaveBeenCalled();
    });
});

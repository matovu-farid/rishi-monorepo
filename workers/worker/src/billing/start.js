import { createPortalSession } from "./portal";
/**
 * Unified billing entry: guarantees the user has a Stripe customer +
 * subscription, then returns a portal URL. Never surfaces the 409
 * "no stripe customer" case that /api/billing/portal has — that's the
 * whole point of this helper.
 */
export async function ensureCustomerAndPortal(deps) {
    const row = await deps.getUserRow(deps.userId);
    if (!row) {
        throw new Error("ensureCustomerAndPortal: user not found");
    }
    let customerId = row.stripeCustomerId;
    if (!customerId) {
        const customer = await deps.stripe.customers.create({
            email: row.email,
            metadata: { userId: deps.userId },
        });
        customerId = customer.id;
        // Persist before sub create so the customer.subscription.created webhook
        // can map customer -> user via the Better-Auth Stripe plugin.
        await deps.updateUserStripeCustomerId(customerId);
        // Idempotent — safe even if a prior partial signup already left grants/subs.
        await deps.ensureCreditAndSubscription(deps.stripe, customerId, deps.priceId, deps.ip);
    }
    const url = await createPortalSession(deps.stripe, customerId, deps.returnUrl);
    return { url };
}

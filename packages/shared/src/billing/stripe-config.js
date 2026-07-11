/**
 * Stripe billing config — single source of truth for IDs the worker and web
 * app need to report usage and create subscriptions.
 *
 * Billing model: one metered Price denominated in micro-dollars of OpenAI cost.
 * The worker computes the USD cost of each OpenAI call and reports it as
 * `value = round(cost_usd * 1_000_000)` to the meter. The Price multiplies by
 * `0.00012` cents per unit, which works out to $1.20 charged per $1.00 of cost
 * — a 20% markup that holds across any model (chat, realtime, embeddings, tts).
 *
 * Math:
 *   1 micro-dollar         = $0.000001
 *   Price unit_amount_dec  = 0.00012 cents / micro-dollar
 *   1_000_000 units billed = 120 cents = $1.20  (vs $1.00 raw cost = 1.20x)
 */
export const MICRO_DOLLARS_PER_USD = 1_000_000;
export const MARKUP_MULTIPLIER = 1.2;
export const METER_EVENT_NAME = "openai_cost_micros";
export const STRIPE_TEST_IDS = {
    meterId: "mtr_test_61UnRo6Ki8qU1tp6D41CcIfMF2dQA3xI",
    productId: "prod_UdKVqsQgGN0Rcj",
    priceId: "price_1Te3qyCcIfMF2dQA2xrBWPQ1",
};
export const STRIPE_LIVE_IDS = {
    meterId: "mtr_61UnuMFlHxDgONTfm41CcIfMF2dQAIwS",
    productId: "prod_Udo1HFHrW3Zhn0",
    priceId: "price_1TeWPXCcIfMF2dQAXadBAJcK",
};
export function getStripeIds(mode) {
    if (mode === "live") {
        if (!STRIPE_LIVE_IDS) {
            throw new Error("STRIPE_LIVE_IDS not configured. Run the test-mode setup against live mode and update stripe-config.ts.");
        }
        return STRIPE_LIVE_IDS;
    }
    return STRIPE_TEST_IDS;
}
/**
 * Derive the right billing IDs from the Stripe secret key prefix. Matches
 * both unrestricted (`sk_live_…`) and restricted (`rk_live_…`) live keys.
 * Anything else (test keys, undefined) picks test. This lets the worker
 * and scripts use a single env var and have the meter/product/price follow
 * automatically — no extra mode flag to forget.
 */
export function getStripeIdsForKey(secretKey) {
    return getStripeIds(/^(sk|rk)_live_/.test(secretKey ?? "") ? "live" : "test");
}
export function usdToMicroDollars(usd) {
    return Math.round(usd * MICRO_DOLLARS_PER_USD);
}

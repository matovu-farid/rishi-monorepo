import Stripe from "stripe";
// Per-process memo. Cloudflare Workers re-instantiate this module on cold
// start; the Stripe client is just an HTTP wrapper so the cost is small.
let cachedStripe = null;
let cachedKey = null;
export function createStripeClient(secretKey) {
    if (cachedStripe && cachedKey === secretKey)
        return cachedStripe;
    cachedStripe = new Stripe(secretKey, {
        // Workers runtime uses fetch, not Node http.
        httpClient: Stripe.createFetchHttpClient(),
    });
    cachedKey = secretKey;
    return cachedStripe;
}

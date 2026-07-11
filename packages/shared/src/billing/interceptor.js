/**
 * T-P1.3 — BILLING-002.
 *
 * `checkBillingGate(response)` inspects a fetch `Response` for a billing-gate
 * signal (HTTP 402 with `{ code: 'BILLING_INACTIVE', subscriptionStatus }`)
 * and throws `BillingInactiveError` when it matches. Every other response
 * shape — non-402, 402 with a different code, 402 with an unparseable or
 * empty body — is a no-op passthrough.
 *
 * The response body is read via `response.clone()` so the caller can still
 * `await response.json()` downstream.
 *
 * See SPEC §3.2 (BILLING-002).
 */
import { BillingInactiveError, isBillingInactiveResponse, } from "./errors";
export async function checkBillingGate(response) {
    if (response.status !== 402)
        return;
    let bodyText;
    try {
        // Clone so the caller can still consume the original body.
        bodyText = await response.clone().text();
    }
    catch {
        // Body unreadable — treat as non-matching, leave to caller.
        return;
    }
    if (bodyText === "")
        return;
    let parsed;
    try {
        parsed = JSON.parse(bodyText);
    }
    catch {
        // Non-JSON body — not a BILLING_INACTIVE payload.
        return;
    }
    if (!isBillingInactiveResponse(402, parsed))
        return;
    throw new BillingInactiveError(parsed.subscriptionStatus);
}

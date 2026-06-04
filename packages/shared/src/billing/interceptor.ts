/**
 * T-P1.3 — BILLING-002 (RED phase placeholder).
 *
 * Final shape (per SPEC §3.2):
 *
 *   export async function checkBillingGate(response: Response): Promise<void>
 *
 * Throws `BillingInactiveError` when the response is a 402 with body
 * `{ code: 'BILLING_INACTIVE', subscriptionStatus }`. Clones the
 * response so the body remains readable downstream.
 *
 * Currently a no-op placeholder — the shared `interceptor.test.ts` suite
 * is the canonical red harness; this file exists so dependent mobile red
 * tests can `require('@rishi/shared/billing/interceptor')` without a
 * module-resolution error.
 */

export async function checkBillingGate(_response: Response): Promise<void> {
  // Placeholder — no-op until T-P1.3 implements the real interceptor.
}

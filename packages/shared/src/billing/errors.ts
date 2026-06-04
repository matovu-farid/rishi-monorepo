/**
 * T-P1.3 — BILLING-002 placeholder (red phase).
 *
 * Minimal exports so dependent test files can `require(...)` without a
 * module-resolution error. The real implementation lands in T-P1.3 — see
 * `errors.test.ts` and SPEC §3.2.
 *
 * The class deliberately does NOT preserve `subscriptionStatus` and the
 * predicate deliberately always returns false, so the red `errors.test.ts`
 * suite stays red where it must (instance carries status, predicate
 * detects shape) and only `instanceof` / `.code` checks (necessary for
 * downstream mobile red tests to even reach their assertion) pass.
 */

export class BillingInactiveError extends Error {
  readonly code = 'BILLING_INACTIVE' as const
  readonly subscriptionStatus: string | null = null

  constructor(_subscriptionStatus: string | null) {
    super('BillingInactiveError placeholder — T-P1.3.')
    this.name = 'BillingInactiveError'
  }
}

export function isBillingInactiveResponse(
  _status: number,
  _body: unknown,
): _body is { code: 'BILLING_INACTIVE'; subscriptionStatus: string | null } {
  return false
}

/**
 * T-P1.3 — BILLING-002.
 *
 * `BillingInactiveError` is thrown by the shared billing interceptor when a
 * backend response signals that the user's subscription is inactive (HTTP 402
 * with `{ code: 'BILLING_INACTIVE', subscriptionStatus }`). Surfaces should
 * catch this and route the user to the billing upgrade flow.
 *
 * See SPEC §3.2 (BILLING-002) for the full contract.
 */

export class BillingInactiveError extends Error {
  readonly code = "BILLING_INACTIVE" as const;
  readonly subscriptionStatus: string | null;

  constructor(subscriptionStatus: string | null, message?: string) {
    super(
      message ??
        `Billing inactive — subscriptionStatus=${subscriptionStatus ?? "unknown"}`,
    );
    this.name = "BillingInactiveError";
    this.subscriptionStatus = subscriptionStatus;
    // Set prototype explicitly for cross-realm `instanceof` reliability
    // (e.g. when the error crosses Node ↔ jsdom ↔ workers boundaries).
    Object.setPrototypeOf(this, BillingInactiveError.prototype);
  }

  /**
   * Duck-typed check that survives cross-realm boundaries (where a plain
   * `instanceof` can fail because the prototype chain doesn't match).
   */
  static isInstance(err: unknown): err is BillingInactiveError {
    if (err instanceof BillingInactiveError) return true;
    return (
      typeof err === "object" &&
      err !== null &&
      (err as { code?: unknown }).code === "BILLING_INACTIVE"
    );
  }
}

/**
 * Type guard: does `(status, body)` look like a BILLING_INACTIVE 402 payload?
 *
 * Only returns true when:
 *   - `status === 402`
 *   - `body` is a non-null object
 *   - `body.code === 'BILLING_INACTIVE'`
 */
export function isBillingInactiveResponse(
  status: number,
  body: unknown,
): body is { code: "BILLING_INACTIVE"; subscriptionStatus: string | null } {
  if (status !== 402) return false;
  if (typeof body !== "object" || body === null) return false;
  return (body as { code?: unknown }).code === "BILLING_INACTIVE";
}

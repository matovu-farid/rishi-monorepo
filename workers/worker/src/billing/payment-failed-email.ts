import type Stripe from "stripe";
import { Resend } from "resend";

export type PaymentFailedEmailDeps = {
  resendApiKey: string;
  fromAddress: string;
  portalUrl: string | null;
};

export type ResolvedUser = { email: string; name: string | null };

type EmailPayload = {
  from: string;
  to: string;
  subject: string;
  html: string;
};

function formatUsdFromCents(amountInCents: number): string {
  const dollars = amountInCents / 100;
  return `$${dollars.toFixed(2)}`;
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Build the payload for a payment-failed email. Pure: takes the
 * resolved user + deps and returns the message envelope, or null when
 * the event isn't `invoice.payment_failed` (so callers can short-circuit
 * without an extra type-guard).
 */
export function buildPaymentFailedEmail(
  event: Stripe.Event,
  user: ResolvedUser,
  deps: PaymentFailedEmailDeps,
): EmailPayload | null {
  if (event.type !== "invoice.payment_failed") return null;

  const invoice = event.data.object as Stripe.Invoice;
  const amount = formatUsdFromCents(invoice.amount_due ?? 0);
  const greetingName = user.name && user.name.trim().length > 0 ? user.name : "there";

  const manageBillingBlock = deps.portalUrl
    ? `<p>You can update your payment method or manage your subscription here: <a href="${escapeHtml(deps.portalUrl)}">Manage billing</a>.</p>`
    : "";

  const html = `<!doctype html>
<html>
  <body style="font-family: -apple-system, system-ui, sans-serif; line-height: 1.5;">
    <p>Hi ${escapeHtml(greetingName)},</p>
    <p>We weren't able to charge your payment method for your most recent Rishi invoice (${amount}).</p>
    <p>Stripe will retry the charge over the next few days. If the retries fail, your subscription will be paused and AI features will stop working until billing is sorted out.</p>
    ${manageBillingBlock}
    <p>— Rishi</p>
  </body>
</html>`;

  return {
    from: deps.fromAddress,
    to: user.email,
    subject: "Your Rishi payment failed",
    html,
  };
}

/**
 * Side-effectful send via Resend. Never throws — exceptions are caught
 * and returned as `{ sent: false, reason }` so callers (specifically
 * the Better-Auth `onEvent` hook) can't accidentally fail the Stripe
 * webhook ack. Same rationale as the realtime-usage reporter.
 */
export async function sendPaymentFailedEmail(
  event: Stripe.Event,
  user: ResolvedUser,
  deps: PaymentFailedEmailDeps,
): Promise<{ sent: boolean; reason?: string }> {
  const payload = buildPaymentFailedEmail(event, user, deps);
  if (!payload) return { sent: false, reason: "wrong-event-type" };
  try {
    const resend = new Resend(deps.resendApiKey);
    await resend.emails.send(payload);
    return { sent: true };
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    return { sent: false, reason };
  }
}

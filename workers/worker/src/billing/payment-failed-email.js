import { Resend } from "resend";
function formatUsdFromCents(amountInCents) {
    const dollars = amountInCents / 100;
    return `$${dollars.toFixed(2)}`;
}
function escapeHtml(s) {
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
export function buildPaymentFailedEmail(event, user, deps) {
    if (event.type !== "invoice.payment_failed")
        return null;
    const invoice = event.data.object;
    const amount = formatUsdFromCents(invoice.amount_due ?? 0);
    const greetingName = user.name && user.name.trim().length > 0 ? user.name : "there";
    // hosted_invoice_url is Stripe's public per-invoice URL — no auth needed,
    // can pay directly. Better UX than a portal link (which requires sign-in).
    const payNowBlock = invoice.hosted_invoice_url
        ? `<p><a href="${escapeHtml(invoice.hosted_invoice_url)}">Pay the invoice now</a> to keep your subscription active.</p>`
        : "";
    const html = `<!doctype html>
<html>
  <body style="font-family: -apple-system, system-ui, sans-serif; line-height: 1.5;">
    <p>Hi ${escapeHtml(greetingName)},</p>
    <p>We weren't able to charge your payment method for your most recent Rishi invoice (${amount}).</p>
    <p>Stripe will retry the charge over the next few days. If the retries fail, your subscription will be paused and AI features will stop working until billing is sorted out.</p>
    ${payNowBlock}
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
export async function sendPaymentFailedEmail(event, user, deps) {
    const payload = buildPaymentFailedEmail(event, user, deps);
    if (!payload)
        return { sent: false, reason: "wrong-event-type" };
    try {
        const resend = new Resend(deps.resendApiKey);
        await resend.emails.send(payload);
        return { sent: true };
    }
    catch (err) {
        const reason = err instanceof Error ? err.message : String(err);
        return { sent: false, reason };
    }
}

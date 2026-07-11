import { describe, test, expect, vi, beforeEach } from "vitest";
import { buildPaymentFailedEmail, sendPaymentFailedEmail, } from "./payment-failed-email";
// ─── Resend mocking ───────────────────────────────────────────────────────────
// We mock the SDK at the module level the same way as auth.ts uses it
// (new Resend(apiKey).emails.send({...})). Tests assert the payload
// without making network calls.
const sendSpy = vi.fn();
vi.mock("resend", () => ({
    Resend: class {
        emails = { send: sendSpy };
    },
}));
beforeEach(() => {
    sendSpy.mockReset();
    sendSpy.mockResolvedValue({ data: { id: "re_test" }, error: null });
});
function makeInvoicePaymentFailedEvent(overrides = {}) {
    // Minimal shape covering the fields buildPaymentFailedEmail reads.
    return {
        id: "evt_test",
        type: "invoice.payment_failed",
        data: {
            object: {
                object: "invoice",
                amount_due: overrides.amount_due ?? 250, // $2.50
                currency: "usd",
                customer: overrides.customer ?? "cus_test",
                hosted_invoice_url: overrides.hosted_invoice_url === undefined
                    ? "https://invoice.stripe.com/i/test_abc"
                    : overrides.hosted_invoice_url,
            },
        },
    };
}
const deps = {
    resendApiKey: "re_fake_key",
    fromAddress: "Rishi <auth@fidexa.org>",
};
const user = { email: "u@example.com", name: "Ada" };
describe("buildPaymentFailedEmail", () => {
    test("returns null for non-matching event types", () => {
        const event = { ...makeInvoicePaymentFailedEvent(), type: "invoice.paid" };
        expect(buildPaymentFailedEmail(event, user, deps)).toBeNull();
    });
    test("renders subject + HTML with the user's name and the failed amount as USD", () => {
        const payload = buildPaymentFailedEmail(makeInvoicePaymentFailedEvent({ amount_due: 250 }), user, deps);
        expect(payload).not.toBeNull();
        expect(payload.subject).toMatch(/payment failed/i);
        expect(payload.from).toBe("Rishi <auth@fidexa.org>");
        expect(payload.to).toBe("u@example.com");
        expect(payload.html).toContain("Ada");
        expect(payload.html).toContain("$2.50");
    });
    test("falls back to 'there' when the user has no name", () => {
        const payload = buildPaymentFailedEmail(makeInvoicePaymentFailedEvent(), { email: "u@example.com", name: null }, deps);
        expect(payload.html).toContain("there");
    });
    test("formats amount_due as USD even for sub-dollar invoices", () => {
        const payload = buildPaymentFailedEmail(makeInvoicePaymentFailedEvent({ amount_due: 7 }), user, deps);
        expect(payload.html).toContain("$0.07");
    });
    test("includes the hosted_invoice_url as the Pay now CTA when present", () => {
        const payload = buildPaymentFailedEmail(makeInvoicePaymentFailedEvent({ hosted_invoice_url: "https://invoice.stripe.com/i/test_xyz" }), user, deps);
        expect(payload.html).toContain("https://invoice.stripe.com/i/test_xyz");
        expect(payload.html).toMatch(/pay/i);
    });
    test("omits the Pay link when hosted_invoice_url is null", () => {
        const payload = buildPaymentFailedEmail(makeInvoicePaymentFailedEvent({ hosted_invoice_url: null }), user, deps);
        expect(payload.html).not.toContain("href=");
    });
    test("HTML-escapes a malicious hosted_invoice_url", () => {
        const payload = buildPaymentFailedEmail(makeInvoicePaymentFailedEvent({
            hosted_invoice_url: 'https://example.com/"><script>alert(1)</script>',
        }), user, deps);
        expect(payload.html).not.toContain("<script>");
        expect(payload.html).toContain("&lt;script&gt;");
    });
});
describe("sendPaymentFailedEmail", () => {
    test("calls Resend with the correct from/to/subject/html", async () => {
        const event = makeInvoicePaymentFailedEvent({ amount_due: 250 });
        const result = await sendPaymentFailedEmail(event, user, deps);
        expect(result.sent).toBe(true);
        expect(sendSpy).toHaveBeenCalledTimes(1);
        const arg = sendSpy.mock.calls[0][0];
        expect(arg.from).toBe("Rishi <auth@fidexa.org>");
        expect(arg.to).toBe("u@example.com");
        expect(arg.subject).toMatch(/payment failed/i);
        expect(arg.html).toContain("$2.50");
    });
    test("returns { sent: false, reason: 'wrong-event-type' } for invoice.paid", async () => {
        const event = { ...makeInvoicePaymentFailedEvent(), type: "invoice.paid" };
        const result = await sendPaymentFailedEmail(event, user, deps);
        expect(result).toEqual({ sent: false, reason: "wrong-event-type" });
        expect(sendSpy).not.toHaveBeenCalled();
    });
    test("returns { sent: false, reason } when Resend throws — never lets the exception escape", async () => {
        sendSpy.mockRejectedValueOnce(new Error("rate limited"));
        const result = await sendPaymentFailedEmail(makeInvoicePaymentFailedEvent(), user, deps);
        expect(result.sent).toBe(false);
        expect(result.reason).toMatch(/rate limited/);
    });
});

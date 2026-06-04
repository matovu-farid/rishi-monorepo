import { describe, test, expect, vi, beforeEach } from "vitest";
import type Stripe from "stripe";
import {
  buildPaymentFailedEmail,
  sendPaymentFailedEmail,
  type PaymentFailedEmailDeps,
  type ResolvedUser,
} from "./payment-failed-email";

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

function makeInvoicePaymentFailedEvent(
  overrides: Partial<{ amount_due: number; customer: string }> = {},
): Stripe.Event {
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
      },
    },
  } as unknown as Stripe.Event;
}

const deps: PaymentFailedEmailDeps = {
  resendApiKey: "re_fake_key",
  fromAddress: "Rishi <auth@fidexa.org>",
  portalUrl: "https://app.example/account",
};

const user: ResolvedUser = { email: "u@example.com", name: "Ada" };

describe("buildPaymentFailedEmail", () => {
  test("returns null for non-matching event types", () => {
    const event = { ...makeInvoicePaymentFailedEvent(), type: "invoice.paid" } as Stripe.Event;
    expect(buildPaymentFailedEmail(event, user, deps)).toBeNull();
  });

  test("renders subject + HTML with the user's name and the failed amount as USD", () => {
    const payload = buildPaymentFailedEmail(makeInvoicePaymentFailedEvent({ amount_due: 250 }), user, deps);
    expect(payload).not.toBeNull();
    expect(payload!.subject).toMatch(/payment failed/i);
    expect(payload!.from).toBe("Rishi <auth@fidexa.org>");
    expect(payload!.to).toBe("u@example.com");
    expect(payload!.html).toContain("Ada");
    expect(payload!.html).toContain("$2.50");
  });

  test("falls back to 'there' when the user has no name", () => {
    const payload = buildPaymentFailedEmail(
      makeInvoicePaymentFailedEvent(),
      { email: "u@example.com", name: null },
      deps,
    );
    expect(payload!.html).toContain("there");
  });

  test("formats amount_due as USD even for sub-dollar invoices", () => {
    const payload = buildPaymentFailedEmail(
      makeInvoicePaymentFailedEvent({ amount_due: 7 }),
      user,
      deps,
    );
    expect(payload!.html).toContain("$0.07");
  });

  test("includes the portal URL when provided", () => {
    const payload = buildPaymentFailedEmail(makeInvoicePaymentFailedEvent(), user, deps);
    expect(payload!.html).toContain("https://app.example/account");
    expect(payload!.html).toMatch(/manage billing/i);
  });

  test("omits the Manage billing link when portalUrl is null", () => {
    const payload = buildPaymentFailedEmail(makeInvoicePaymentFailedEvent(), user, {
      ...deps,
      portalUrl: null,
    });
    expect(payload!.html).not.toMatch(/manage billing/i);
    expect(payload!.html).not.toContain("href=");
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
    const event = { ...makeInvoicePaymentFailedEvent(), type: "invoice.paid" } as Stripe.Event;
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

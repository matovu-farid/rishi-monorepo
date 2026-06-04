/**
 * Tests for `checkBillingGate` (T-P1.3 / BILLING-002).
 *
 * `checkBillingGate(response)` MUST:
 *   - Throw a `BillingInactiveError` when given a 402 response whose body is
 *     `{ code: 'BILLING_INACTIVE', subscriptionStatus: ... }`.
 *   - Pass through (no throw) on every other shape, including:
 *       * 200 OK
 *       * 402 with a different / missing code
 *       * 402 whose body fails JSON.parse (MINOR-02 — must not crash)
 *       * 402 with empty body
 *       * 500
 *       * 401 (auth is handled elsewhere)
 *   - Clone the response body so the caller can still read it downstream.
 *
 * These tests intentionally fail until `interceptor.ts` exists.
 */
import { describe, it, expect } from "vitest";
import { checkBillingGate } from "./interceptor";
import { BillingInactiveError } from "./errors";

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("checkBillingGate — throws on BILLING_INACTIVE", () => {
  it("throws BillingInactiveError on 402 + { code: BILLING_INACTIVE }", async () => {
    const res = jsonResponse(
      { code: "BILLING_INACTIVE", subscriptionStatus: "canceled" },
      402,
    );
    await expect(checkBillingGate(res)).rejects.toBeInstanceOf(
      BillingInactiveError,
    );
  });

  it("propagates subscriptionStatus from the response body", async () => {
    const res = jsonResponse(
      { code: "BILLING_INACTIVE", subscriptionStatus: "canceled" },
      402,
    );
    try {
      await checkBillingGate(res);
      throw new Error("checkBillingGate should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(BillingInactiveError);
      expect((err as BillingInactiveError).subscriptionStatus).toBe("canceled");
      expect((err as BillingInactiveError).code).toBe("BILLING_INACTIVE");
    }
  });

  it("handles null subscriptionStatus", async () => {
    const res = jsonResponse(
      { code: "BILLING_INACTIVE", subscriptionStatus: null },
      402,
    );
    try {
      await checkBillingGate(res);
      throw new Error("checkBillingGate should have thrown");
    } catch (err) {
      expect((err as BillingInactiveError).subscriptionStatus).toBeNull();
    }
  });
});

describe("checkBillingGate — passes through", () => {
  it("does not throw on 200 with any body", async () => {
    const res = jsonResponse({ ok: true, data: 42 }, 200);
    await expect(checkBillingGate(res)).resolves.toBeUndefined();
  });

  it("does not throw on 402 with a non-BILLING_INACTIVE body", async () => {
    const res = jsonResponse({ error: "something else" }, 402);
    await expect(checkBillingGate(res)).resolves.toBeUndefined();
  });

  it("does not throw on 402 with an unparseable body (MINOR-02)", async () => {
    // Plain text body — JSON.parse will throw. The interceptor must swallow
    // that and treat it as "not a BILLING_INACTIVE payload".
    const res = new Response("not-json", {
      status: 402,
      headers: { "Content-Type": "text/plain" },
    });
    await expect(checkBillingGate(res)).resolves.toBeUndefined();
  });

  it("does not throw on 402 with an empty body", async () => {
    const res = new Response("", { status: 402 });
    await expect(checkBillingGate(res)).resolves.toBeUndefined();
  });

  it("does not throw on 500", async () => {
    const res = jsonResponse({ error: "server" }, 500);
    await expect(checkBillingGate(res)).resolves.toBeUndefined();
  });

  it("does not throw on 401 (auth is handled elsewhere)", async () => {
    const res = jsonResponse({ error: "unauthorized" }, 401);
    await expect(checkBillingGate(res)).resolves.toBeUndefined();
  });
});

describe("checkBillingGate — body-clone semantics", () => {
  it("leaves the response body readable to the caller after a passthrough", async () => {
    // The interceptor must clone the response before reading its body so the
    // downstream caller can still `await response.json()` (otherwise the
    // ReadableStream is locked / consumed).
    const res = jsonResponse({ ok: true, marker: "still-readable" }, 200);
    await checkBillingGate(res);
    const parsed = (await res.json()) as { ok: boolean; marker: string };
    expect(parsed.ok).toBe(true);
    expect(parsed.marker).toBe("still-readable");
  });

  it("leaves the response body readable after a 402 passthrough", async () => {
    const res = jsonResponse({ error: "something else" }, 402);
    await checkBillingGate(res);
    const parsed = (await res.json()) as { error: string };
    expect(parsed.error).toBe("something else");
  });
});

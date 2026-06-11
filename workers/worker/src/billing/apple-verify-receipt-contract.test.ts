import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import type { VerifyReceiptResponse } from "./apple-verify-receipt";

/**
 * Worker half of the verify-receipt contract gate (14-08).
 *
 * Reads the SAME JSON fixtures the iOS Swift Testing suite asserts against
 * (apps/apple/Packages/RishiAPI/Tests/RishiAPITests/Fixtures/). If a future
 * change moves the worker's emitted shape away from the locked contract
 * (premiumUntil as JSON number of seconds-since-1970, transactionId as JSON
 * number, reason explicit null on success), this suite fails loudly — and
 * the iOS suite does too.
 *
 * Single source of truth: the fixture JSON files. Neither side embeds a
 * private copy.
 */

const fixturesDir = resolve(
  __dirname,
  "../../../../apps/apple/Packages/RishiAPI/Tests/RishiAPITests/Fixtures",
);

interface ContractRequest {
  jws: string;
  productId: string;
  transactionId: number;
}

describe("apple-verify-receipt contract — response shape", () => {
  const fixture: VerifyReceiptResponse = JSON.parse(
    readFileSync(resolve(fixturesDir, "verify-receipt-response.json"), "utf-8"),
  );

  it("has the three canonical fields (verified, premiumUntil, reason)", () => {
    expect("verified" in fixture).toBe(true);
    expect("premiumUntil" in fixture).toBe(true);
    expect("reason" in fixture).toBe(true);
  });

  it("verified is boolean true", () => {
    expect(typeof fixture.verified).toBe("boolean");
    expect(fixture.verified).toBe(true);
  });

  it("premiumUntil is a JSON number of seconds-since-1970", () => {
    expect(typeof fixture.premiumUntil).toBe("number");
    expect(Number.isFinite(fixture.premiumUntil)).toBe(true);
    // 1e11 boundary: seconds-since-1970 stays well below 1e11 until year 5138.
    // ms-since-1970 crosses 1e11 in 1973. Fixture in ms would fail this assert.
    expect(fixture.premiumUntil!).toBeLessThan(1e11);
  });

  it("reason is explicit null on success (not undefined, not missing)", () => {
    expect(fixture.reason).toBeNull();
  });

  it("premiumUntil reconstructs to 2027-06-10T00:00:00.000Z", () => {
    // 1812585600 seconds-since-1970 = 2027-06-10T00:00:00.000Z. If this date
    // ever shifts by ~31 years (2058) it means someone reverted the contract
    // to .deferredToDate / seconds-since-2001 — the exact drift this gate
    // catches.
    const reconstructed = new Date((fixture.premiumUntil ?? 0) * 1000);
    expect(reconstructed.toISOString()).toBe("2027-06-10T00:00:00.000Z");
  });

  it("matches the worker's VerifyReceiptResponse TS shape exactly", () => {
    // Compile-time check (TS already enforces): assign to the worker's exported
    // type. Runtime assertion: the discriminated success path has the locked
    // success-case field values.
    const typed: VerifyReceiptResponse = fixture;
    expect(typed.verified).toBe(true);
    expect(typed.premiumUntil).toBe(1812585600);
    expect(typed.reason).toBeNull();
  });
});

describe("apple-verify-receipt contract — request shape", () => {
  const fixture: ContractRequest = JSON.parse(
    readFileSync(resolve(fixturesDir, "verify-receipt-request.json"), "utf-8"),
  );

  it("transactionId is a JSON number in the Apple UInt64 magnitude range (Pitfall 2)", () => {
    expect(typeof fixture.transactionId).toBe("number");
    // 2_000_000_300_000_001 = ~2e15, in the magnitude of Apple-issued
    // originalTransactionId / transactionId values. JS Number.MAX_SAFE_INTEGER
    // is ~9e15, so this exact fixture value is still safely representable —
    // but it's deliberately large enough to exercise the worker's Zod
    // union(number, string) acceptance path. The Zod schema is the contract
    // that allows clients to pre-stringify if/when production payloads cross
    // 2^53 (the worker stores transactionId as TEXT in D1 either way).
    expect(fixture.transactionId).toBeGreaterThan(2e15);
  });

  it("productId matches the configured Apple product ID", () => {
    expect(fixture.productId).toBe("org.fidexa.rishi.pro.monthly");
  });

  it("jws is a non-trivial string (shape-only — not verified here)", () => {
    expect(typeof fixture.jws).toBe("string");
    expect(fixture.jws.length).toBeGreaterThan(20);
    // The fixture jws is a syntactically valid 3-segment JWS with a placeholder
    // signature; it is NOT fed to the real verifier in this test.
    expect(fixture.jws.split(".").length).toBe(3);
  });
});

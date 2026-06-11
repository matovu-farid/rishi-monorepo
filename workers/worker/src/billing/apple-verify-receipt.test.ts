import { describe, it, expect, vi } from "vitest";
import {
  handleVerifyReceipt,
  type VerifyReceiptDeps,
} from "./apple-verify-receipt";
import { JWSInvalid } from "./jws-verify";

// ms-epoch for 2027-06-11T00:00:00Z
const EXPIRES_MS = 1812585600000;
const EXPIRES_SECONDS = 1812585600;

function makeDeps(
  overrides: Partial<VerifyReceiptDeps> = {},
): VerifyReceiptDeps {
  const rows: Record<
    string,
    { appleTransactionId: string; userId: string; currentPeriodEnd: number }
  > = {};

  const db: VerifyReceiptDeps["db"] = {
    findByTransactionId: vi.fn(async (txId: string) => rows[txId] ?? null),
    upsertSubscription: vi.fn(async (row) => {
      rows[row.appleTransactionId] = {
        appleTransactionId: row.appleTransactionId,
        userId: row.userId,
        currentPeriodEnd: row.currentPeriodEnd.getTime(),
      };
    }),
  };

  const verifyJws = vi.fn(async () => ({
    productId: "org.fidexa.rishi.pro.monthly",
    transactionId: "2000000300000001",
    originalTransactionId: "2000000300000001",
    expiresDate: EXPIRES_MS,
    environment: "Sandbox" as const,
  }));

  return {
    db,
    verifyJws,
    ...overrides,
  };
}

describe("handleVerifyReceipt", () => {
  it("happy path: verifies, upserts, returns {verified:true} with seconds-since-1970", async () => {
    const deps = makeDeps();
    const result = await handleVerifyReceipt({
      deps,
      userId: "u-1",
      body: {
        jws: "<test-jws>",
        productId: "org.fidexa.rishi.pro.monthly",
        transactionId: 2000000300000001,
      },
    });
    expect(result).toEqual({
      verified: true,
      premiumUntil: EXPIRES_SECONDS,
      reason: null,
    });
    expect(deps.verifyJws).toHaveBeenCalledOnce();
    expect(deps.db.upsertSubscription).toHaveBeenCalledOnce();
  });

  it("JWS signature invalid: returns reason jws_signature_invalid, no DB write", async () => {
    const deps = makeDeps({
      verifyJws: vi.fn(async () => {
        throw new JWSInvalid("payload");
      }),
    });
    const result = await handleVerifyReceipt({
      deps,
      userId: "u-1",
      body: { jws: "<bad>", productId: "p", transactionId: 1 },
    });
    expect(result).toEqual({
      verified: false,
      premiumUntil: null,
      reason: "jws_signature_invalid",
    });
    expect(deps.db.upsertSubscription).not.toHaveBeenCalled();
  });

  it("product mismatch: returns reason product_id_mismatch, no DB write", async () => {
    const deps = makeDeps({
      verifyJws: vi.fn(async () => ({
        productId: "org.fidexa.rishi.pro.annual", // != request
        transactionId: "2000000300000001",
        originalTransactionId: "2000000300000001",
        expiresDate: EXPIRES_MS,
        environment: "Sandbox" as const,
      })),
    });
    const result = await handleVerifyReceipt({
      deps,
      userId: "u-1",
      body: {
        jws: "<jws>",
        productId: "org.fidexa.rishi.pro.monthly",
        transactionId: 2000000300000001,
      },
    });
    expect(result.reason).toBe("product_id_mismatch");
    expect(result.verified).toBe(false);
    expect(result.premiumUntil).toBeNull();
    expect(deps.db.upsertSubscription).not.toHaveBeenCalled();
  });

  it("transaction mismatch: returns reason transaction_id_mismatch", async () => {
    const deps = makeDeps({
      verifyJws: vi.fn(async () => ({
        productId: "org.fidexa.rishi.pro.monthly",
        transactionId: "9999999999999999", // != request
        originalTransactionId: "9999999999999999",
        expiresDate: EXPIRES_MS,
        environment: "Sandbox" as const,
      })),
    });
    const result = await handleVerifyReceipt({
      deps,
      userId: "u-1",
      body: {
        jws: "<jws>",
        productId: "org.fidexa.rishi.pro.monthly",
        transactionId: 2000000300000001,
      },
    });
    expect(result.reason).toBe("transaction_id_mismatch");
    expect(result.verified).toBe(false);
    expect(deps.db.upsertSubscription).not.toHaveBeenCalled();
  });

  it("replay (existing row for different user): returns reason replay_detected", async () => {
    const deps = makeDeps();
    (deps.db.findByTransactionId as ReturnType<typeof vi.fn>).mockResolvedValue(
      {
        appleTransactionId: "2000000300000001",
        userId: "u-other",
        currentPeriodEnd: EXPIRES_MS,
      },
    );
    const result = await handleVerifyReceipt({
      deps,
      userId: "u-1",
      body: {
        jws: "<jws>",
        productId: "org.fidexa.rishi.pro.monthly",
        transactionId: 2000000300000001,
      },
    });
    expect(result.reason).toBe("replay_detected");
    expect(result.verified).toBe(false);
    expect(deps.db.upsertSubscription).not.toHaveBeenCalled();
  });

  it("idempotent same-user replay: returns persisted premiumUntil without re-upsert", async () => {
    const deps = makeDeps();
    (deps.db.findByTransactionId as ReturnType<typeof vi.fn>).mockResolvedValue(
      {
        appleTransactionId: "2000000300000001",
        userId: "u-1",
        currentPeriodEnd: EXPIRES_MS,
      },
    );
    const result = await handleVerifyReceipt({
      deps,
      userId: "u-1",
      body: {
        jws: "<jws>",
        productId: "org.fidexa.rishi.pro.monthly",
        transactionId: 2000000300000001,
      },
    });
    expect(result).toEqual({
      verified: true,
      premiumUntil: EXPIRES_SECONDS,
      reason: null,
    });
    // RESEARCH §4.4: short-circuit skips re-upsert
    expect(deps.db.upsertSubscription).not.toHaveBeenCalled();
  });

  it("premiumUntil is JSON number of seconds (not ms, not ISO string)", async () => {
    const deps = makeDeps();
    const result = await handleVerifyReceipt({
      deps,
      userId: "u-1",
      body: {
        jws: "<j>",
        productId: "org.fidexa.rishi.pro.monthly",
        transactionId: 2000000300000001,
      },
    });
    expect(typeof result.premiumUntil).toBe("number");
    expect(result.premiumUntil).toBe(EXPIRES_SECONDS);
  });
});

import { describe, expect, it } from "vitest";
import {
  activeTransactionCount,
  hashAppleIdentity,
  hashAppleOriginalTransaction,
  isRestorableTransaction,
  mergeRetentionSnapshot,
  retentionExpiresAt,
} from "./entitlement-retention";

describe("entitlement retention", () => {
  it("uses separate stable HMAC domains for identities and transactions", async () => {
    const identity = await hashAppleIdentity("apple-sub", "identity-secret");
    const identityAgain = await hashAppleIdentity("apple-sub", "identity-secret");
    const transaction = await hashAppleOriginalTransaction("txn-1", "transaction-secret");
    expect(identity).toEqual(identityAgain);
    expect(identity.identityHash).not.toBe(transaction.originalTransactionHash);
    expect(identity.identityHashVersion).toBe(1);
    expect(transaction.transactionHashVersion).toBe(1);
  });

  it("retains for 24 months after the later deletion or paid-period boundary", () => {
    const deleted = Date.UTC(2026, 0, 1);
    const paidEnd = Date.UTC(2027, 0, 1);
    expect(retentionExpiresAt(deleted, paidEnd)).toBe(Date.UTC(2029, 0, 1));
  });

  it("merges monotonically and never recreates a trial", () => {
    const base = {
      identityHashVersion: 1,
      identityHash: "i",
      trialState: "exhausted" as const,
      trialInitialCredits: 300,
      trialUsedCredits: 300,
      readerActiveUntil: null,
      voiceActiveUntil: null,
      readerCreditsTotal: 0,
      readerCreditsUsed: 0,
      voiceCreditsTotal: 0,
      voiceCreditsUsed: 0,
      readerStatus: null,
      voiceStatus: null,
      deletedAt: new Date(1),
      retentionExpiresAt: new Date(100),
      updatedAt: new Date(100),
    };
    const merged = mergeRetentionSnapshot(
      { ...base, trialState: "exhausted", trialUsedCredits: 300 },
      { ...base, trialState: "active", trialUsedCredits: 0, readerCreditsTotal: 100 },
    );
    expect(merged.trialState).toBe("exhausted");
    expect(merged.trialUsedCredits).toBe(300);
    expect(merged.readerCreditsTotal).toBe(100);
  });

  it("restores only active future transactions", () => {
    const now = Date.now();
    const rows = [
      { status: "active" as const, periodEnd: new Date(now + 1000) },
      { status: "expired" as const, periodEnd: new Date(now + 1000) },
      { status: "active" as const, periodEnd: new Date(now - 1000) },
    ];
    expect(rows.filter((row) => isRestorableTransaction(row, now))).toHaveLength(1);
    expect(activeTransactionCount(rows, now)).toBe(1);
  });
});

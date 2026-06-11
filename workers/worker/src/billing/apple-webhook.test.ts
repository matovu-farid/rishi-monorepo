import { describe, it, expect, vi } from "vitest";
import { handleAppleWebhook, type AppleWebhookDeps } from "./apple-webhook";
import { JWSInvalid } from "./jws-verify";

const EXPIRES_MS = 1812585600000;
const NEW_EXPIRES_MS = 1820000000000;

interface MakeDepsOpts {
  envelope: any;
  tx?: any;
  renewal?: any;
  existingLog?: boolean;
  existingSub?: any;
  verifyThrows?: Error;
}

function makeDeps(
  opts: MakeDepsOpts = { envelope: null },
): AppleWebhookDeps & { _spy: any } {
  const logRows: Record<string, any> = {};
  if (opts.existingLog && opts.envelope) {
    logRows[opts.envelope.notificationUUID] = { processed: true };
  }
  const subRows: Record<string, any> = {};
  if (opts.existingSub)
    subRows[opts.existingSub.appleTransactionId] = opts.existingSub;

  const insertLog = vi.fn(async (row: any) => {
    if (logRows[row.notificationUuid]) {
      // ON CONFLICT DO NOTHING — already present.
      return { inserted: false };
    }
    logRows[row.notificationUuid] = row;
    return { inserted: true };
  });
  const markLogProcessed = vi.fn(async () => {});
  const upsertSub = vi.fn(async (row: any) => {
    subRows[row.appleTransactionId] = row;
  });
  const updateSubStatus = vi.fn(async (txId: string, patch: any) => {
    if (subRows[txId]) Object.assign(subRows[txId], patch);
  });

  const verifyJws = vi.fn(async (jws: string) => {
    if (opts.verifyThrows) throw opts.verifyThrows;
    if (jws === "OUTER") return opts.envelope;
    if (jws === "TXN") return opts.tx;
    if (jws === "RENEW") return opts.renewal;
    return null;
  });

  return {
    verifyJws,
    db: { insertLog, markLogProcessed, upsertSub, updateSubStatus },
    _spy: { insertLog, upsertSub, updateSubStatus, markLogProcessed, verifyJws },
  };
}

const baseEnvelope = (overrides: Partial<any> = {}) => ({
  notificationType: "SUBSCRIBED",
  subtype: "INITIAL_BUY",
  notificationUUID: "uuid-1",
  version: "2.0",
  data: {
    bundleId: "org.fidexa.rishi",
    environment: "Sandbox" as const,
    signedTransactionInfo: "TXN",
    signedRenewalInfo: undefined,
  },
  ...overrides,
});

const baseTx = (overrides: Partial<any> = {}) => ({
  productId: "org.fidexa.rishi.pro.monthly",
  transactionId: "2000000300000001",
  originalTransactionId: "2000000300000001",
  expiresDate: EXPIRES_MS,
  environment: "Sandbox" as const,
  ...overrides,
});

describe("handleAppleWebhook", () => {
  it("SUBSCRIBED/INITIAL_BUY: logs + upserts active subscription", async () => {
    const deps = makeDeps({ envelope: baseEnvelope(), tx: baseTx() });
    const result = await handleAppleWebhook({ deps, signedPayload: "OUTER" });
    expect(result.status).toBe(200);
    expect(result.body).toEqual({ ok: true });
    expect(deps._spy.insertLog).toHaveBeenCalledOnce();
    expect(deps._spy.upsertSub).toHaveBeenCalledOnce();
    const upserted = deps._spy.upsertSub.mock.calls[0][0];
    expect(upserted.status).toBe("active");
    expect(upserted.appleTransactionId).toBe("2000000300000001");
    expect(upserted.currentPeriodEnd.getTime()).toBe(EXPIRES_MS);
  });

  it("DID_RENEW: updates currentPeriodEnd on existing row, status stays active", async () => {
    const deps = makeDeps({
      envelope: baseEnvelope({
        notificationType: "DID_RENEW",
        notificationUUID: "uuid-renew",
        subtype: undefined,
      }),
      tx: baseTx({ expiresDate: NEW_EXPIRES_MS }),
      existingSub: {
        appleTransactionId: "2000000300000001",
        userId: "u1",
        status: "active",
      },
    });
    const result = await handleAppleWebhook({ deps, signedPayload: "OUTER" });
    expect(result.status).toBe(200);
    expect(deps._spy.upsertSub).toHaveBeenCalledOnce();
    const row = deps._spy.upsertSub.mock.calls[0][0];
    expect(row.status).toBe("active");
    expect(row.currentPeriodEnd.getTime()).toBe(NEW_EXPIRES_MS);
  });

  it("REFUND: sets status=refunded, currentPeriodEnd=now", async () => {
    const deps = makeDeps({
      envelope: baseEnvelope({
        notificationType: "REFUND",
        subtype: undefined,
        notificationUUID: "uuid-refund",
      }),
      tx: baseTx(),
      existingSub: {
        appleTransactionId: "2000000300000001",
        userId: "u1",
        status: "active",
      },
    });
    const before = Date.now();
    const result = await handleAppleWebhook({ deps, signedPayload: "OUTER" });
    const after = Date.now();
    expect(result.status).toBe(200);
    expect(deps._spy.updateSubStatus).toHaveBeenCalledOnce();
    const [txId, patch] = deps._spy.updateSubStatus.mock.calls[0];
    expect(txId).toBe("2000000300000001");
    expect(patch.status).toBe("refunded");
    expect(patch.currentPeriodEnd.getTime()).toBeGreaterThanOrEqual(before);
    expect(patch.currentPeriodEnd.getTime()).toBeLessThanOrEqual(after + 1000);
  });

  it("idempotent duplicate UUID: 200 ok, no re-dispatch", async () => {
    const deps = makeDeps({
      envelope: baseEnvelope(),
      tx: baseTx(),
      existingLog: true,
    });
    const result = await handleAppleWebhook({ deps, signedPayload: "OUTER" });
    expect(result.status).toBe(200);
    expect(result.body).toEqual({ ok: true });
    expect(deps._spy.upsertSub).not.toHaveBeenCalled();
    expect(deps._spy.updateSubStatus).not.toHaveBeenCalled();
  });

  it("outer JWS invalid: 400, no log insert", async () => {
    const deps = makeDeps({
      envelope: baseEnvelope(),
      verifyThrows: new JWSInvalid("payload", "bad"),
    });
    const result = await handleAppleWebhook({ deps, signedPayload: "OUTER" });
    expect(result.status).toBe(400);
    expect(result.body).toEqual({ error: "invalid signature" });
    expect(deps._spy.insertLog).not.toHaveBeenCalled();
  });

  it("wrong bundleId: 400", async () => {
    const deps = makeDeps({
      envelope: baseEnvelope({
        data: {
          bundleId: "com.evil.app",
          environment: "Sandbox",
          signedTransactionInfo: "TXN",
        },
      }),
      tx: baseTx(),
    });
    const result = await handleAppleWebhook({ deps, signedPayload: "OUTER" });
    expect(result.status).toBe(400);
    expect(result.body).toEqual({ error: "wrong bundleId" });
    expect(deps._spy.insertLog).not.toHaveBeenCalled();
  });

  it("version not 2.0: 400 unsupported version", async () => {
    const deps = makeDeps({
      envelope: baseEnvelope({ version: "1.0" }),
      tx: baseTx(),
    });
    const result = await handleAppleWebhook({ deps, signedPayload: "OUTER" });
    expect(result.status).toBe(400);
    expect(result.body).toEqual({ error: "unsupported version" });
    expect(deps._spy.insertLog).not.toHaveBeenCalled();
  });

  it("unknown notificationType: 200, logs row but no subscription side effect", async () => {
    const deps = makeDeps({
      envelope: baseEnvelope({
        notificationType: "MYSTERY_BOX_2099",
        subtype: undefined,
        notificationUUID: "uuid-x",
      }),
      tx: baseTx(),
    });
    const result = await handleAppleWebhook({ deps, signedPayload: "OUTER" });
    expect(result.status).toBe(200);
    expect(result.body).toEqual({ ok: true });
    expect(deps._spy.insertLog).toHaveBeenCalledOnce();
    expect(deps._spy.upsertSub).not.toHaveBeenCalled();
    expect(deps._spy.updateSubStatus).not.toHaveBeenCalled();
  });

  it("TEST notificationType: logs row + 200, no inner JWS verify, no dispatch", async () => {
    // Apple's `POST /inApps/v1/notifications/test` delivers a payload with
    // notificationType=TEST and NO signedTransactionInfo / signedRenewalInfo.
    // Verbatim shape observed from sandbox 2026-06:
    //   { notificationType: "TEST", notificationUUID: "...",
    //     data: { bundleId, environment }, version: "2.0", signedDate: ... }
    const deps = makeDeps({
      envelope: {
        notificationType: "TEST",
        notificationUUID: "dfda6a3f-72ca-4d1a-a597-392cba7c0164",
        version: "2.0",
        signedDate: 1781186765131,
        data: {
          bundleId: "org.fidexa.rishi",
          environment: "Sandbox" as const,
          // NO signedTransactionInfo, NO signedRenewalInfo on TEST.
        },
      },
    });
    const result = await handleAppleWebhook({ deps, signedPayload: "OUTER" });
    expect(result.status).toBe(200);
    expect(result.body).toEqual({ ok: true });
    // verifyJws called exactly once — for the outer envelope only.
    // Inner-JWS verify MUST be skipped because there is no signedTransactionInfo.
    expect(deps._spy.verifyJws).toHaveBeenCalledTimes(1);
    // Log row written so the row exists for verification queries, with null txId.
    expect(deps._spy.insertLog).toHaveBeenCalledOnce();
    const logged = deps._spy.insertLog.mock.calls[0][0];
    expect(logged.notificationType).toBe("TEST");
    expect(logged.appleTransactionId).toBeNull();
    // No subscription side effects.
    expect(deps._spy.upsertSub).not.toHaveBeenCalled();
    expect(deps._spy.updateSubStatus).not.toHaveBeenCalled();
  });

  it("non-TEST notification missing signedTransactionInfo: log-only unknown path, 200", async () => {
    // Defense in depth: if Apple ever delivers a non-TEST notification type
    // without an inner transaction JWS (forward-compat for future types),
    // treat it like the dispatcher's unknown branch — log + 200, no side
    // effects, no Apple redelivery.
    const deps = makeDeps({
      envelope: {
        notificationType: "FUTURE_TYPE_2099",
        notificationUUID: "uuid-future",
        version: "2.0",
        data: {
          bundleId: "org.fidexa.rishi",
          environment: "Sandbox" as const,
          // signedTransactionInfo intentionally absent.
        },
      },
    });
    const result = await handleAppleWebhook({ deps, signedPayload: "OUTER" });
    expect(result.status).toBe(200);
    expect(result.body).toEqual({ ok: true });
    expect(deps._spy.verifyJws).toHaveBeenCalledTimes(1);
    expect(deps._spy.insertLog).toHaveBeenCalledOnce();
    const logged = deps._spy.insertLog.mock.calls[0][0];
    expect(logged.notificationType).toBe("FUTURE_TYPE_2099");
    expect(logged.appleTransactionId).toBeNull();
    expect(deps._spy.upsertSub).not.toHaveBeenCalled();
    expect(deps._spy.updateSubStatus).not.toHaveBeenCalled();
  });
});

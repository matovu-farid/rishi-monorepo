import { beforeEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";

const mocks = vi.hoisted(() => ({
  createDb: vi.fn(() => ({ marker: "db" })),
  reconcileAccountR2Page: vi.fn(),
  retryPendingDeletions: vi.fn(),
  purgeExpiredShares: vi.fn(),
  precreateShareLinks: vi.fn(),
  purgeExpiredRetention: vi.fn(),
  redactOwnerlessAppleNotificationLogs: vi.fn(),
}));

vi.mock("./db/drizzle", () => ({ createDb: mocks.createDb }));
vi.mock("./account-r2-reconciliation", () => ({
  ACCOUNT_R2_RECONCILIATION_PREFIXES: ["books/", "covers/"],
  reconcileAccountR2Page: mocks.reconcileAccountR2Page,
}));
vi.mock("./account-deletion", () => ({ retryPendingDeletions: mocks.retryPendingDeletions }));
vi.mock("./routes/shares", async () => {
  const { Hono } = await import("hono");
  return {
    sharesRoutes: new Hono(),
    purgeExpiredShares: mocks.purgeExpiredShares,
    precreateShareLinks: mocks.precreateShareLinks,
  };
});
vi.mock("./entitlement-retention", () => ({
  purgeExpiredRetention: mocks.purgeExpiredRetention,
  redactOwnerlessAppleNotificationLogs: mocks.redactOwnerlessAppleNotificationLogs,
}));

import { scheduled } from "./index";

const bucket = {} as R2Bucket;
const dbBinding = {} as D1Database;
const env = {
  RISHI_DESKTOP_STATE: {} as KVNamespace,
  RATE_LIMIT_KV: {} as KVNamespace,
  APPLE: {} as R2Bucket,
  BOOK_STORAGE: bucket,
  TTS_CACHE: {} as R2Bucket,
  apple_dev: {} as R2Bucket,
  DB: dbBinding,
  CF_VERSION_METADATA: { id: "test", tag: "test", timestamp: "2026-09-16T00:00:00Z" },
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  SHARING_WORKER_WS_URL: "wss://sharing.fidexa.org",
  BOOK_MAX_FILE_BYTES: "838860800",
  BOOK_MAX_PER_USER: "500",
  BOOK_MAX_USER_BYTES: "10737418240",
  ACCESS_TOKEN_SECRET: "test",
  APPLE_APNS_KEY_ID: "test",
  APPLE_APNS_KEY_P8: "test",
  APPLE_IDENTITY_RETENTION_SECRET_CURRENT: "test",
  APPLE_SIWA_CLIENT_ID: "test",
  APPLE_SIWA_KEY_ID: "test",
  APPLE_SIWA_PRIVATE_KEY: "test",
  APPLE_TEAM_ID: "test",
  APPLE_TRANSACTION_HASH_SECRET: "test",
  BETTER_AUTH_SECRET: "test",
  CLOUDFLARE_ACCOUNT_ID: "test",
  DEEPGRAM_KEY: "test",
  ELEVEN_LABS_API_KEY: "test",
  GOOGLE_CLIENT_ID: "test",
  GOOGLE_CLIENT_SECRET: "test",
  JWT_PRIVATE_KEY: "test",
  OPENAI_API_KEY: "test",
  R2_ACCESS_KEY_ID: "test",
  R2_SECRET_ACCESS_KEY: "test",
  REFRESH_TOKEN_SECRET: "test",
  RESEND_API_KEY: "test",
  SHARING_INTERNAL_SECRET: "test",
  SIWA_TOKEN_ENCRYPTION_SECRET: "test",
  STRIPE_SECRET_KEY: "test",
  STRIPE_WEBHOOK_SECRET: "test",
  UPSTASH_REDIS_REST_TOKEN: "test",
  UPSTASH_REDIS_REST_URL: "test",
  VOICE_SESSION_NONCE_SECRET: "test",
  USER_USAGE_LEDGER: {} as Env["USER_USAGE_LEDGER"],
  SHARING_WORKER: {} as Fetcher,
} satisfies Env;

const minuteController = {
  scheduledTime: 1000,
  cron: "* * * * *",
  noRetry: vi.fn(),
} satisfies ScheduledController;

describe("Worker scheduled triggers", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("[W4R-CRON] declares the minute reconciler cron separately from the daily maintenance cron", () => {
    const source = readFileSync(new URL("../wrangler.jsonc", import.meta.url), "utf8");
    expect(source).toContain('"crons": ["17 2 * * *", "* * * * *"]');
  });

  it("[W4R-ISOLATION] minute scheduling attempts both prefixes, skips daily work, and propagates failure", async () => {
    const failure = Object.assign(new Error("books failed"), {
      code: "ACCOUNT_R2_SWEEP_FAILED" as const,
      phase: "list" as const,
      retryable: true as const,
    });
    mocks.reconcileAccountR2Page.mockImplementation(async (_db, _bucket, prefix) => {
      if (prefix === "books/") throw failure;
      return { prefix, scanned: 0, deleted: 0, cycleCompleted: true, checkpoint: "advanced" };
    });

    await expect(scheduled(minuteController, env)).rejects.toBe(failure);

    expect(mocks.createDb).toHaveBeenCalledWith(dbBinding);
    expect(mocks.reconcileAccountR2Page.mock.calls.map((call) => call[2])).toEqual(["books/", "covers/"]);
    expect(mocks.retryPendingDeletions).not.toHaveBeenCalled();
    expect(mocks.purgeExpiredShares).not.toHaveBeenCalled();
    expect(mocks.precreateShareLinks).not.toHaveBeenCalled();
    expect(mocks.purgeExpiredRetention).not.toHaveBeenCalled();
    expect(mocks.redactOwnerlessAppleNotificationLogs).not.toHaveBeenCalled();
  });
});

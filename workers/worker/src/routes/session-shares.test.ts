import { beforeEach, describe, expect, it, vi } from "vitest";

const { dbState, sendSessionInviteEmails, captureWorkerTelemetryError } = vi.hoisted(() => ({
  dbState: { created: false, selectCalls: 0, mode: "create" as "create" | "email" },
  sendSessionInviteEmails: vi.fn(async (_input: { shareUrl: string }) => ({ attempted: 1, sent: 1, failed: 0, results: [] })),
  captureWorkerTelemetryError: vi.fn(),
}));

vi.mock("../middleware", () => ({
  requireAuth: async (c: { set: (key: string, value: string) => void }, next: () => Promise<void>) => {
    c.set("userId", "owner-1");
    await next();
  },
}));

vi.mock("../db/drizzle", () => ({
  createDb: () => ({
    select: () => ({
      from: () => ({
        where: () => ({
          get: async () => {
            dbState.selectCalls += 1;
            if (dbState.mode === "email") return testInvite;
            if (!dbState.created) {
              return dbState.selectCalls === 1 ? undefined : testBook;
            }
            if (dbState.selectCalls === 3) return testInvite;
            if (dbState.selectCalls === 4) return testInviteItem;
            return testBook;
          },
        }),
      }),
    }),
    insert: () => ({
      values: () => ({
        run: async () => {
          dbState.created = true;
        },
      }),
    }),
  }),
}));

vi.mock("../session-invite-email", () => ({ sendSessionInviteEmails }));
vi.mock("../ops/error-reporting", () => ({ captureWorkerTelemetryError }));

import { sessionSharesRoutes } from "./session-shares";

const baseEnv = {
  BETTER_AUTH_SECRET: "test-share-secret",
  CLOUDFLARE_ACCOUNT_ID: "test-account",
  R2_ACCESS_KEY_ID: "test-key",
  R2_SECRET_ACCESS_KEY: "test-secret",
  BOOK_STORAGE_BUCKET_NAME: "rishi-books",
  SHARING_INTERNAL_SECRET: "test-sharing-secret",
  SHARING_WORKER: {
    fetch: vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      const request = JSON.parse(String(init?.body)) as { action: string; payload: { sessionId: string } };
      if (request.action === "createRoom") {
        return Response.json({ sessionId: request.payload.sessionId, roomEpoch: 1, controllerGeneration: 1 });
      }
      if (request.action === "getRoomStatus") {
        return Response.json({
          sessionId: request.payload.sessionId,
          status: "waiting",
          roomEpoch: 1,
          controllerGeneration: 1,
          controllerUserId: "owner-1",
          participants: [],
          maxParticipants: 5,
          removedUserIds: [],
        });
      }
      throw new Error(`unexpected session-sharing action: ${request.action}`);
    }),
  },
};

const testBook = {
  id: "book-1",
  fileR2Key: "books/owner-1/book-1.epub",
  coverR2Key: null,
  fileHash: "book-hash",
  fileSize: 42,
  format: "epub",
};

const testInvite = {
  id: "invite-1",
  idempotencyKey: "invite-1",
  sessionId: "session-1",
  sourceBookId: "book-1",
};

const testInviteItem = { inviteId: "invite-1" };

function makeEnv(publicWebURL?: string) {
  return {
    ...baseEnv,
    ...(publicWebURL === undefined ? {} : { PUBLIC_WEB_URL: publicWebURL }),
  } as unknown as Env;
}

function createInvite(env: Env, idempotencyKey = "invite-1") {
  return sessionSharesRoutes.request("/", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ bookId: "book-1", idempotencyKey }),
  }, env);
}

function emailInvite(env: Env) {
  dbState.mode = "email";
  return sessionSharesRoutes.request("/session-1/email", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ recipients: ["reader@example.com"], idempotencyKey: "email-1" }),
  }, env);
}

beforeEach(() => {
  dbState.created = false;
  dbState.selectCalls = 0;
  dbState.mode = "create";
  baseEnv.SHARING_WORKER.fetch.mockClear();
  sendSessionInviteEmails.mockClear();
  captureWorkerTelemetryError.mockClear();
});

describe("session share links", () => {
  it.each([
    ["production", "https://rishi.fidexa.org"],
    ["e2e", "https://api-e2e.fidexa.org"],
  ])("uses only the configured %s origin for newly created and idempotent invites", async (_environment: string, publicWebURL: string) => {
    const env = makeEnv(publicWebURL);

    const created = await createInvite(env);
    const repeated = await createInvite(env);

    expect(created.status).toBe(201);
    expect(repeated.status).toBe(200);
    const createdBody = await created.json() as { shareURL: string };
    const repeatedBody = await repeated.json() as { shareURL: string };
    expect(new URL(createdBody.shareURL).origin).toBe(publicWebURL);
    expect(new URL(repeatedBody.shareURL).origin).toBe(publicWebURL);
  });

  it.each([
    ["missing", undefined],
    ["malformed", "not a URL"],
    ["non-HTTPS", "http://rishi.fidexa.org"],
    ["user info", "https://reader:secret@rishi.fidexa.org"],
    ["alternate port", "https://rishi.fidexa.org:8443"],
    ["path", "https://rishi.fidexa.org/sharing"],
    ["query", "https://rishi.fidexa.org?next=e2e"],
    ["fragment", "https://rishi.fidexa.org#e2e"],
  ])("fails closed when PUBLIC_WEB_URL is %s", async (_description: string, publicWebURL: string | undefined) => {
    const response = await createInvite(makeEnv(publicWebURL));

    expect(response.status).toBe(503);
    await expect(response.json()).resolves.not.toHaveProperty("shareURL");
    expect(baseEnv.SHARING_WORKER.fetch).not.toHaveBeenCalled();
  });

  it.each([
    ["production", "https://rishi.fidexa.org"],
    ["e2e", "https://api-e2e.fidexa.org"],
  ])("passes only the configured %s origin to session-invite email delivery", async (_environment: string, publicWebURL: string) => {
    const response = await emailInvite(makeEnv(publicWebURL));

    expect(response.status).toBe(200);
    expect(sendSessionInviteEmails).toHaveBeenCalledTimes(1);
    const emailInput = sendSessionInviteEmails.mock.calls[0]?.[0];
    expect(emailInput).toBeDefined();
    expect(new URL(emailInput!.shareUrl).origin).toBe(publicWebURL);
  });

  it.each([
    ["create", () => createInvite(makeEnv("https://rishi.fidexa.org?next=e2e")), "session_share.create"],
    ["email", () => emailInvite(makeEnv("https://rishi.fidexa.org?next=e2e")), "session_share.email"],
  ])("fails closed and reports sanitized telemetry for an invalid PUBLIC_WEB_URL on %s", async (_path: string, request: () => Response | Promise<Response>, operation: string) => {
    const response = await request();

    expect(response.status).toBe(503);
    expect(sendSessionInviteEmails).not.toHaveBeenCalled();
    expect(captureWorkerTelemetryError).toHaveBeenCalledWith(
      expect.any(Error),
      { feature: "shared_reading", operation, error_code: "invalid_public_web_url" },
    );
  });
});

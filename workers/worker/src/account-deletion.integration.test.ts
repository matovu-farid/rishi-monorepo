import { describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import { eq } from "drizzle-orm";
import { createDb } from "./db/drizzle";
import { createTestD1 } from "./test-utils/d1";
import {
  account,
  allowancePeriod,
  appleNotificationsLog,
  appleSubscriptions,
  appleUsers,
  bookPages,
  bookParagraphs,
  bookWords,
  bookmarks,
  books,
  chapterIndexChapters,
  chapterIndexes,
  conversations,
  devices,
  highlights,
  messages,
  passkey,
  session,
  subscription,
  trialGrant,
  usageAuditLog,
  usageReservation,
  user,
  userApiUsage,
  verification,
} from "./db/schema";

vi.mock("jose", async () => {
  const actual = await vi.importActual<typeof import("jose")>("jose");
  return {
    ...actual,
    createRemoteJWKSet: vi.fn(() => ({})),
    jwtVerify: vi.fn(async (token: unknown, ...args: unknown[]) => {
      if (token === "fake-identity-token") {
        return {
          payload: {
            sub: "apple-sub-integration",
            email: "integration@privaterelay.appleid.com",
            email_verified: true,
            is_private_email: true,
          },
        };
      }
      return actual.jwtVerify(token as string, ...(args as [never, never]));
    }),
  };
});

vi.mock("./auth-apple-secret", () => ({
  mintAppleClientSecret: vi.fn(async () => "test-apple-client-secret"),
}));

import authRoutes from "./routes/auth";
import { userRoutes } from "./routes/user";
import { syncRoutes } from "./routes/sync";
import { conversationsRoutes } from "./routes/conversations";
import { messagesRoutes } from "./routes/messages";
import { deleteAccount } from "./account-deletion";
import { encryptSiwaRefreshToken } from "./siwa-token-crypto";

type TestD1 = D1Database & { close: () => void };

function createD1(failOnRun?: (query: string) => boolean): TestD1 {
  return createTestD1(":memory:", {
    failOnRun,
  });
}

describe("DELETE /api/user black-box/white-box account deletion", () => {
  it("creates an Apple user through auth, deletes it through the endpoint, and removes all user data", async () => {
    const d1 = createD1();
    const r2Keys = new Set(["books/shared-book"]);
    const sharedCacheKeys = new Set(["shared-tts-cache-entry"]);
    const ttsCacheDelete = vi.fn(async () => undefined);
    const BOOK_STORAGE = {
      delete: vi.fn(async (key: string) => {
        r2Keys.delete(key);
      }),
      head: vi.fn(async (key: string) => r2Keys.has(key) ? ({ key } as R2Object) : null),
      list: vi.fn(async ({ prefix }: { prefix?: string }) => ({
        objects: [...r2Keys]
          .filter((key) => !prefix || key.startsWith(prefix))
          .map((key) => ({ key })),
        truncated: false,
      })),
    } as unknown as R2Bucket;
    const env = {
      DB: d1,
      BOOK_STORAGE,
      ACCESS_TOKEN_SECRET: "access-secret",
      REFRESH_TOKEN_SECRET: "refresh-secret",
      APPLE_SIWA_CLIENT_ID: "org.fidexa.rishi",
      APPLE_SIWA_KEY_ID: "test-key",
      APPLE_SIWA_PRIVATE_KEY: "test-private-key",
      APPLE_TEAM_ID: "test-team",
      SIWA_TOKEN_ENCRYPTION_SECRET: "test-encryption-secret",
      TTS_CACHE: { delete: ttsCacheDelete },
    } as unknown as Env;
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.endsWith("/auth/token")) {
        return new Response(JSON.stringify({ refresh_token: "apple-refresh-token" }), { status: 200 });
      }
      if (url.endsWith("/auth/revoke")) return new Response(null, { status: 200 });
      throw new Error(`unexpected fetch: ${url}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    const app = new Hono();
    app.route("/auth", authRoutes);
    app.route("/api/sync", syncRoutes);
    app.route("/api/sync/conversations", conversationsRoutes);
    app.route("/api/sync/messages", messagesRoutes);
    app.route("/api/user", userRoutes);

    const authResponse = await app.fetch(new Request("http://test/auth/apple", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        identityToken: "fake-identity-token",
        authorizationCode: btoa("fake-code"),
      }),
    }), env);
    expect(authResponse.status).toBe(200);
    const auth = await authResponse.json() as { accessToken: string; userId: string };
    const tokenExchange = fetchMock.mock.calls.find(([input]) => String(input).endsWith("/auth/token"));
    expect(tokenExchange).toBeTruthy();
    const tokenExchangeRequest = (tokenExchange as unknown as [unknown, RequestInit])[1];
    const tokenExchangeBody = new URLSearchParams(String(tokenExchangeRequest.body));
    expect(tokenExchangeBody.get("code")).toBe("fake-code");
    expect(tokenExchangeBody.get("grant_type")).toBe("authorization_code");
    expect(tokenExchangeBody.get("client_id")).toBe("org.fidexa.rishi");
    const db = createDb(d1);
    const capturedAppleUser = await db.select().from(appleUsers).where(eq(appleUsers.userId, auth.userId)).get();
    expect(capturedAppleUser?.siwaRefreshTokenCiphertext).toBeTruthy();
    expect(capturedAppleUser?.siwaRefreshTokenNonce).toBeTruthy();

    const authHeaders = {
      Authorization: `Bearer ${auth.accessToken}`,
      "Content-Type": "application/json",
      "X-Rishi-Data-Use-Consent": "2026-07-29",
    };
    const wireNow = () => Math.floor((Date.now() - 978_307_200_000) / 1000);
    const userBookFileKey = `books/${auth.userId}/user-book.epub`;
    const userBookCoverKey = `covers/${auth.userId}/user-book.jpg`;
    r2Keys.add(userBookFileKey);
    r2Keys.add(userBookCoverKey);

    const syncResponse = await app.fetch(new Request("http://test/api/sync/push", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({
        changes: [
          {
            kind: "book",
            id: "user-book",
            payload: {
              id: "user-book",
              title: "User book",
              author: "Author",
              format_type: "epub",
              file_r2_key: userBookFileKey,
              file_size: 10,
            },
            updated_at: wireNow(),
            deleted: false,
          },
          {
            kind: "highlight",
            id: "highlight-1",
            payload: {
              id: "highlight-1",
              book_id: "user-book",
              locator_start: "cfi",
              text: "highlight",
              color: "yellow",
            },
            updated_at: wireNow(),
            deleted: false,
          },
          {
            kind: "bookmark",
            id: "bookmark-1",
            payload: {
              id: "bookmark-1",
              book_id: "user-book",
              locator: "cfi",
              label: "Bookmark",
              snippet: "snippet",
            },
            updated_at: wireNow(),
            deleted: false,
          },
          {
            kind: "chapter_index",
            id: "user-book",
            payload: {
              id: "index-1",
              book_id: "user-book",
              content_version: "v1",
              status: "ready",
              model_identifier: "test",
              model_version: "1",
              progress: { completed: 1, total: 1 },
              chapters: [{ id: "c1", name: "Chapter", summary: "Summary", source_position: 1 }],
            },
            updated_at: wireNow(),
            deleted: false,
          },
        ],
      }),
    }), env);
    expect(syncResponse.status).toBe(200);

    const conversationId = "00000000-0000-4000-8000-000000000001";
    const messageId = "00000000-0000-4000-8000-000000000002";
    const conversationResponse = await app.fetch(new Request("http://test/api/sync/conversations", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ conversations: [{
        id: conversationId,
        user_id: auth.userId,
        book_id: "user-book",
        title: "Chat",
        archived: false,
        created_at: wireNow(),
        updated_at: wireNow(),
      }] }),
    }), env);
    expect(conversationResponse.status).toBe(200);

    const messageResponse = await app.fetch(new Request("http://test/api/sync/messages", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ messages: [{
        id: messageId,
        conversation_id: conversationId,
        role: "user",
        content: "Hello",
        created_at: wireNow(),
        updated_at: wireNow(),
      }] }),
    }), env);
    expect(messageResponse.status).toBe(200);

    await db.insert(user).values({
      id: "unrelated-user",
      name: "Unrelated",
      email: "unrelated@example.com",
      emailVerified: true,
      createdAt: new Date(),
      updatedAt: new Date(),
    });
    await db.insert(verification).values({
      id: "verification-user-email",
      identifier: "integration@privaterelay.appleid.com",
      value: "verification-secret",
      expiresAt: new Date(Date.now() + 60_000),
      createdAt: new Date(),
      updatedAt: new Date(),
    });
    await db.insert(user).values({
      id: "cascade-user",
      name: "Cascade test",
      email: "cascade@example.com",
      emailVerified: true,
      createdAt: new Date(),
      updatedAt: new Date(),
    });
    await db.insert(books).values([
      {
        id: "unrelated-book",
        userId: "unrelated-user",
        title: "Unrelated book",
        author: "Author",
        filePath: "unrelated.epub",
        fileR2Key: "books/shared-book",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      },
      {
        id: "cascade-book",
        userId: "cascade-user",
        title: "Cascade book",
        author: "Author",
        filePath: "cascade.epub",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      },
    ]);
    await db.update(books).set({ coverR2Key: userBookCoverKey }).where(eq(books.id, "user-book"));
    await db.insert(bookPages).values({ bookId: "user-book", pageNumber: 1, text: "text", widthPts: 1, heightPts: 1, indexedAt: Date.now() });
    await db.insert(bookWords).values({ bookId: "user-book", pageNumber: 1, idx: 1, text: "text", x: 1, y: 1, w: 1, h: 1 });
    await db.insert(bookParagraphs).values({ bookId: "user-book", pageNumber: 1, paragraphIndex: "1", text: "text" });
    await db.insert(appleSubscriptions).values({ appleTransactionId: "txn-1", appleOriginalTransactionId: "orig-1", userId: auth.userId, productId: "reader", status: "active", currentPeriodEnd: new Date(Date.now() + 1000), environment: "Sandbox", createdAt: new Date(), updatedAt: new Date() });
    await db.insert(appleNotificationsLog).values({ notificationUuid: "notification-1", notificationType: "SUBSCRIBED", userId: auth.userId, appleTransactionId: "txn-1", rawPayload: "private", receivedAt: new Date() });
    await db.insert(devices).values({ id: "device-1", userId: auth.userId, deviceToken: "token", platform: "ios", appVersion: "1", bundleId: "org.fidexa.rishi", topic: "org.fidexa.rishi", createdAt: new Date(), updatedAt: new Date() });
    await db.insert(userApiUsage).values({ userId: auth.userId, voiceChatRequests: 1, ttsRequests: 1, createdAt: Date.now(), updatedAt: Date.now() });
    await db.insert(trialGrant).values({ userId: auth.userId, grantedAt: new Date() });
    await db.insert(allowancePeriod).values({ id: "period-1", userId: auth.userId, plan: "reader", periodStart: new Date(), periodEnd: new Date(Date.now() + 1000), narrationSecondsTotal: 1, voiceChatSecondsTotal: 1, createdAt: new Date() });
    await db.insert(usageReservation).values({ id: "reservation-1", userId: auth.userId, kind: "tts", amount: 1, status: "committed", createdAt: new Date() });
    await db.insert(usageAuditLog).values({ id: "audit-1", userId: auth.userId, eventType: "test", createdAt: new Date() });
    await db.insert(account).values({ id: "account-1", accountId: "apple-sub-integration", providerId: "apple", userId: auth.userId, createdAt: new Date(), updatedAt: new Date() });
    await db.insert(session).values({ id: "session-1", expiresAt: new Date(Date.now() + 1000), token: "session-token", createdAt: new Date(), updatedAt: new Date(), userId: auth.userId });
    await db.insert(subscription).values({ id: "stripe-sub-1", plan: "reader", referenceId: auth.userId });

    await db.insert(bookPages).values({ bookId: "cascade-book", pageNumber: 1, text: "text", widthPts: 1, heightPts: 1, indexedAt: Date.now() });
    await db.insert(conversations).values({ id: "cascade-conversation", bookId: "cascade-book", userId: "cascade-user", title: "Chat", createdAt: Date.now(), updatedAt: Date.now() });
    await db.insert(messages).values({ id: "cascade-message", conversationId: "cascade-conversation", role: "user", content: "Hello", createdAt: Date.now(), updatedAt: Date.now() });
    await db.delete(user).where(eq(user.id, "cascade-user"));
    expect(await db.select().from(books).where(eq(books.userId, "cascade-user")).all()).toHaveLength(0);
    expect(await db.select().from(bookPages).where(eq(bookPages.bookId, "cascade-book")).all()).toHaveLength(0);
    expect(await db.select().from(messages).where(eq(messages.id, "cascade-message")).all()).toHaveLength(0);

    const deletionResponse = await app.fetch(new Request("http://test/api/user", {
      method: "DELETE",
      headers: { Authorization: `Bearer ${auth.accessToken}` },
    }), env);
    expect(deletionResponse.status).toBe(200);
    expect(await deletionResponse.json()).toMatchObject({ ok: true, revocationStatus: "revoked" });

    expect(await db.select().from(user).where(eq(user.id, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(appleUsers).where(eq(appleUsers.userId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(books).where(eq(books.userId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(bookPages).where(eq(bookPages.bookId, "user-book")).all()).toHaveLength(0);
    expect(await db.select().from(bookWords).where(eq(bookWords.bookId, "user-book")).all()).toHaveLength(0);
    expect(await db.select().from(bookParagraphs).where(eq(bookParagraphs.bookId, "user-book")).all()).toHaveLength(0);
    expect(await db.select().from(chapterIndexes).where(eq(chapterIndexes.userId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(chapterIndexChapters).where(eq(chapterIndexChapters.userId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(bookmarks).where(eq(bookmarks.userId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(highlights).where(eq(highlights.userId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(conversations).where(eq(conversations.userId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(messages).where(eq(messages.id, messageId)).all()).toHaveLength(0);
    expect(await db.select().from(appleNotificationsLog).all()).toHaveLength(0);
    expect(await db.select().from(appleSubscriptions).where(eq(appleSubscriptions.userId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(devices).where(eq(devices.userId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(userApiUsage).where(eq(userApiUsage.userId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(trialGrant).where(eq(trialGrant.userId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(allowancePeriod).where(eq(allowancePeriod.userId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(usageReservation).where(eq(usageReservation.userId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(usageAuditLog).where(eq(usageAuditLog.userId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(account).where(eq(account.userId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(session).where(eq(session.userId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(subscription).where(eq(subscription.referenceId, auth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(verification).where(eq(verification.identifier, "integration@privaterelay.appleid.com")).all()).toHaveLength(0);
    expect(await db.select().from(user).where(eq(user.id, "unrelated-user")).all()).toHaveLength(1);
    expect(await db.select().from(books).where(eq(books.id, "unrelated-book")).all()).toHaveLength(1);
    expect(r2Keys).toEqual(new Set(["books/shared-book"]));
    expect(sharedCacheKeys.has("shared-tts-cache-entry")).toBe(true);
    expect(ttsCacheDelete).not.toHaveBeenCalled();

    const blockedResponse = await app.fetch(new Request("http://test/api/user", {
      headers: { Authorization: `Bearer ${auth.accessToken}` },
    }), env);
    expect(blockedResponse.status).toBe(410);

    const retryResponse = await app.fetch(new Request("http://test/api/user", {
      method: "DELETE",
      headers: { Authorization: `Bearer ${auth.accessToken}` },
    }), env);
    expect(retryResponse.status).toBe(200);
    expect(await retryResponse.json()).toMatchObject({ ok: true, alreadyDeleted: true });
    d1.close();
  });

  it("retries an R2 failure while the user row still exists", async () => {
    const d1 = createD1();
    const db = createDb(d1);
    await db.insert(user).values({
      id: "retry-user",
      name: "Retry",
      email: "retry@example.com",
      emailVerified: true,
      createdAt: new Date(),
      updatedAt: new Date(),
    });
    await db.insert(books).values({
      id: "retry-book",
      userId: "retry-user",
      title: "Retry book",
      author: "Author",
      filePath: "retry.epub",
      fileR2Key: "books/retry",
      createdAt: Date.now(),
      updatedAt: Date.now(),
    });

    let failOnce = true;
    const env = {
      DB: d1,
      BOOK_STORAGE: {
        delete: vi.fn(async () => {
          if (failOnce) {
            failOnce = false;
            throw new Error("temporary R2 failure");
          }
        }),
        head: vi.fn(async () => null),
        list: vi.fn(async () => ({ objects: [], truncated: false })),
      },
    } as unknown as Env;

    await expect(deleteAccount(db, env, "retry-user")).rejects.toThrow("temporary R2 failure");
    const resumed = await deleteAccount(db, env, "retry-user");
    expect(resumed.alreadyDeleted).toBe(false);
    expect(await db.select().from(user).where(eq(user.id, "retry-user")).all()).toHaveLength(0);
    d1.close();
  });

  it("sweeps a late user-scoped upload after the parent row is deleted", async () => {
    const d1 = createD1();
    const db = createDb(d1);
    await db.insert(user).values({
      id: "late-upload-user",
      name: "Late upload",
      email: "late-upload@example.com",
      emailVerified: true,
      createdAt: new Date(),
      updatedAt: new Date(),
    });

    const objects = new Set<string>();
    let listCalls = 0;
    const bucket = {
      delete: vi.fn(async (key: string) => objects.delete(key)),
      head: vi.fn(async (key: string) => objects.has(key) ? ({ key } as R2Object) : null),
      list: vi.fn(async ({ prefix }: { prefix?: string }) => {
        listCalls += 1;
        // The first sweep sees nothing. A presigned upload arrives before the
        // post-delete sweep, which must remove it despite no surviving book row.
        if (listCalls === 3) objects.add("books/late-upload-user/late.epub");
        return {
          objects: [...objects]
            .filter((key) => !prefix || key.startsWith(prefix))
            .map((key) => ({ key })),
          truncated: false,
        };
      }),
    } as unknown as R2Bucket;

    await deleteAccount(db, { DB: d1, BOOK_STORAGE: bucket } as unknown as Env, "late-upload-user");
    expect(bucket.delete).toHaveBeenCalledWith("books/late-upload-user/late.epub");
    expect(objects).toEqual(new Set());
    d1.close();
  });

  it("does not claim Stripe cleanup succeeded when its required secret is missing", async () => {
    const d1 = createD1();
    const db = createDb(d1);
    await db.insert(user).values({
      id: "stripe-config-user",
      name: "Stripe config",
      email: "stripe-config@example.com",
      emailVerified: true,
      stripeCustomerId: "cus_required",
      createdAt: new Date(),
      updatedAt: new Date(),
    });

    await expect(deleteAccount(db, {
      DB: d1,
      BOOK_STORAGE: {
        delete: vi.fn(async () => undefined),
        head: vi.fn(async () => null),
        list: vi.fn(async () => ({ objects: [], truncated: false })),
      },
    } as unknown as Env, "stripe-config-user")).rejects.toThrow("STRIPE_SECRET_KEY");
    expect(await db.select().from(user).where(eq(user.id, "stripe-config-user")).all()).toHaveLength(1);
    d1.close();
  });

  it("does not misreport Apple configuration errors as successful revocation", async () => {
    const d1 = createD1();
    const db = createDb(d1);
    const encrypted = await encryptSiwaRefreshToken("refresh-token", "test-encryption-secret");
    await db.insert(user).values({
      id: "apple-config-user",
      name: "Apple config",
      email: "apple-config@example.com",
      emailVerified: true,
      createdAt: new Date(),
      updatedAt: new Date(),
    });
    await db.insert(appleUsers).values({
      id: "apple-config-row",
      appleUserId: "apple-config-sub",
      userId: "apple-config-user",
      email: "apple-config@example.com",
      emailVerified: true,
      privateEmail: false,
      siwaRefreshTokenCiphertext: encrypted.ciphertext,
      siwaRefreshTokenNonce: encrypted.nonce,
      createdAt: new Date(),
      updatedAt: new Date(),
    });
    vi.stubGlobal("fetch", vi.fn(async () => new Response(
      JSON.stringify({ error: "invalid_client" }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    )));

    const result = await deleteAccount(db, {
      DB: d1,
      BOOK_STORAGE: {
        delete: vi.fn(async () => undefined),
        head: vi.fn(async () => null),
        list: vi.fn(async () => ({ objects: [], truncated: false })),
      },
      SIWA_TOKEN_ENCRYPTION_SECRET: "test-encryption-secret",
      APPLE_SIWA_PRIVATE_KEY: "test-private-key",
      APPLE_SIWA_KEY_ID: "test-key",
      APPLE_TEAM_ID: "test-team",
      APPLE_SIWA_CLIENT_ID: "org.fidexa.rishi",
    } as unknown as Env, "apple-config-user");
    expect(result.revocationStatus).toBe("revocation_unavailable");
    expect(await db.select().from(user).where(eq(user.id, "apple-config-user")).all()).toHaveLength(0);
    d1.close();
  });

  it("does not report success when the final D1 delete fails, then resumes after the failure is cleared", async () => {
    let failD1Delete = true;
    const d1 = createD1((query) => failD1Delete && query.toLowerCase().includes('delete from "user"'));
    const db = createDb(d1);
    await db.insert(user).values({
      id: "d1-failure-user",
      name: "D1 failure",
      email: "d1-failure@example.com",
      emailVerified: true,
      createdAt: new Date(),
      updatedAt: new Date(),
    });
    const env = {
      DB: d1,
      BOOK_STORAGE: {
        delete: vi.fn(async () => undefined),
        head: vi.fn(async () => null),
        list: vi.fn(async () => ({ objects: [], truncated: false })),
      },
    } as unknown as Env;

    await expect(deleteAccount(db, env, "d1-failure-user")).rejects.toThrow("Failed query: delete from \"user\"");
    failD1Delete = false;
    await expect(deleteAccount(db, env, "d1-failure-user")).resolves.toMatchObject({ alreadyDeleted: false });
    expect(await db.select().from(user).where(eq(user.id, "d1-failure-user")).all()).toHaveLength(0);
    d1.close();
  });

  it("does not create a new account when Apple authorization exchange fails", async () => {
    const d1 = createD1();
    const env = {
      DB: d1,
      ACCESS_TOKEN_SECRET: "access-secret",
      REFRESH_TOKEN_SECRET: "refresh-secret",
      APPLE_SIWA_CLIENT_ID: "org.fidexa.rishi",
      APPLE_SIWA_KEY_ID: "test-key",
      APPLE_SIWA_PRIVATE_KEY: "test-private-key",
      APPLE_TEAM_ID: "test-team",
      SIWA_TOKEN_ENCRYPTION_SECRET: "test-encryption-secret",
    } as unknown as Env;
    vi.stubGlobal("fetch", vi.fn(async () => new Response("invalid code", { status: 400 })));
    const app = new Hono();
    app.route("/auth", authRoutes);

    const response = await app.fetch(new Request("http://test/auth/apple", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        identityToken: "fake-identity-token",
        authorizationCode: btoa("bad-code"),
      }),
    }), env);
    expect(response.status).toBe(502);
    const db = createDb(d1);
    expect(await db.select().from(user).all()).toHaveLength(0);
    d1.close();
  });

  it("returns an idempotent success when the user row is already absent", async () => {
    const d1 = createD1();
    const db = createDb(d1);
    await db.insert(user).values({
      id: "orphaned-user",
      name: "Orphaned",
      email: "orphaned@example.com",
      emailVerified: true,
      createdAt: new Date(),
      updatedAt: new Date(),
    });
    await db.insert(verification).values({
      id: "orphaned-verification",
      identifier: "orphaned-user",
      value: "secret",
      expiresAt: new Date(Date.now() + 60_000),
      createdAt: new Date(),
      updatedAt: new Date(),
    });
    await db.delete(user).where(eq(user.id, "orphaned-user"));

    const result = await deleteAccount(db, {
      DB: d1,
      BOOK_STORAGE: {
        delete: vi.fn(async () => undefined),
        head: vi.fn(async () => null),
        list: vi.fn(async () => ({ objects: [], truncated: false })),
      },
    } as unknown as Env, "orphaned-user");

    expect(result.alreadyDeleted).toBe(true);
    expect(await db.select().from(verification).where(eq(verification.identifier, "orphaned-user")).all()).toHaveLength(1);
    d1.close();
  });
});

import { afterEach, describe, expect, it, vi } from "vitest";
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
  retainedAppleEntitlement,
  retainedAppleTransaction,
  restoredAppleEntitlement,
  devices,
  deletionState,
  highlights,
  messages,
  passkey,
  session,
  sessionInvites,
  sessionInviteRedemptions,
  sharePackageItems,
  sharePackages,
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
      if (typeof token === "string" && token.startsWith("fake-identity-token:")) {
        const options = args[1] as { nonce?: string } | undefined;
        const tokenNonce = token.slice("fake-identity-token:".length);
        if (!tokenNonce || options?.nonce !== tokenNonce) {
          throw new Error("nonce mismatch or missing");
        }
        return {
          payload: {
            sub: "apple-sub-integration",
            email: "integration@privaterelay.appleid.com",
            email_verified: true,
            is_private_email: true,
            nonce: tokenNonce,
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
import { deleteAccount, retryPendingDeletions } from "./account-deletion";
import { hashAppleIdentity } from "./entitlement-retention";
import { encryptSiwaRefreshToken } from "./siwa-token-crypto";

type TestD1 = D1Database & { close: () => void };
type DeletionDb = Parameters<typeof deleteAccount>[0];
type DeletionEnvironment = Parameters<typeof deleteAccount>[1];
type DeletionMarker = typeof deletionState.$inferSelect;
const PRE_MARKER_UPLOAD_DRAIN_MS = 301_000;

function advancePastDrain(marker: DeletionMarker): void {
  vi.useFakeTimers({ now: Math.max(
    marker.retryAt.getTime(),
    marker.createdAt.getTime() + PRE_MARKER_UPLOAD_DRAIN_MS,
  ) + 1 });
}

async function completeDeletionAfterDrain(
  db: DeletionDb,
  env: DeletionEnvironment,
  userId: string,
  marker: () => Promise<DeletionMarker | undefined>,
) {
  await expect(deleteAccount(db, env, userId)).rejects.toMatchObject({
    code: "ACCOUNT_DELETION_PENDING", status: 503, retryable: true,
  });
  const stored = await marker();
  expect(stored).toMatchObject({ status: "purging" });
  const deletionId = stored!.deletionId;
  advancePastDrain(stored!);
  try {
    const result = await deleteAccount(db, env, userId);
    expect(result.deletionId).toBe(deletionId);
    return result;
  } finally {
    vi.useRealTimers();
  }
}

function markerFor(db: DeletionDb, userId: string) {
  return db.select().from(deletionState).where(eq(deletionState.userId, userId)).get();
}

describe("W4 account deletion queue", () => {
  const connections: TestD1[] = [];
  afterEach(() => { vi.restoreAllMocks(); connections.splice(0).forEach((d1) => d1.close()); });

  async function fixture(beforeRun?: (query: string) => Promise<void>) {
    const d1 = createD1(undefined, beforeRun);
    connections.push(d1);
    const db = createDb(d1);
    const now = new Date();
    await db.insert(user).values(["deleting", "other"].map((id) => ({
      id, name: id, email: `${id}@example.com`, emailVerified: true, createdAt: now, updatedAt: now,
    })));
    await db.insert(books).values(["deleting", "other"].map((id) => ({
      id: `${id}-book`, userId: id, title: "Book", author: "Author", filePath: "book.epub", createdAt: Date.now(), updatedAt: Date.now(),
    })));
    const calls: Array<{ sessionId: string; action: string; payload: Record<string, string> }> = [];
    const fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body));
      calls.push({ sessionId: decodeURIComponent(new URL(String(input)).pathname.split("/").at(-1)!), ...body });
      return Response.json(body.action === "purgeAppleRoom" ? { ok: true } : { ok: true, status: "ended" });
    });
    const ledger = testLedgerBinding().getByName();
    const env = {
      DB: d1, USER_USAGE_LEDGER: { getByName: () => ledger },
      SHARING_INTERNAL_SECRET: "secret", SHARING_WORKER: { fetch },
      BOOK_STORAGE: { delete: vi.fn(async () => undefined), head: vi.fn(async () => null), list: vi.fn(async () => ({ objects: [], truncated: false })) },
    } as unknown as Env;
    async function room(id: string, owner = "deleting", status: "open" | "ended" = "open") {
      await db.insert(sessionInvites).values({ id, sessionId: id, ownerUserId: owner, sourceBookId: `${owner}-book`, idempotencyKey: id, contentHash: "hash", format: "epub", tokenHash: id, status, createdAt: now });
    }
    async function member(id: string, membershipStatus: "pending" | "admitted" | "left" | "removed" = "admitted", userId = "deleting") {
      await db.insert(sessionInviteRedemptions).values({ id: `${id}-${userId}`, inviteId: id, userId, membershipStatus, createdAt: now, updatedAt: now });
    }
    const marker = () => db.select().from(deletionState).where(eq(deletionState.userId, "deleting")).get();
    const due = () => db.update(deletionState).set({ retryAt: new Date(0) }).where(eq(deletionState.userId, "deleting"));
    return { d1, db, env, ledger, fetch, calls, room, member, marker, due };
  }

  it("[W4-MARKER] concurrent requests preserve one marker identity and the lease loser stays pending", async () => {
    const f = await fixture();
    await f.room("owner");
    let release!: () => void;
    let entered!: () => void;
    const started = new Promise<void>((resolve) => { entered = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    f.fetch.mockImplementation(async () => { entered(); await gate; return Response.json({ code: "CONFLICT" }, { status: 409 }); });
    const first = deleteAccount(f.db, f.env, "deleting").catch((error) => error);
    await started;
    const original = await f.marker();
    const secondRun = deleteAccount(f.db, f.env, "deleting").catch((error) => error);
    await new Promise((resolve) => setTimeout(resolve, 20));
    const after = await f.marker();
    release();
    const second = await secondRun;
    await first;
    expect(second).toMatchObject({ code: "ACCOUNT_DELETION_PENDING", status: 503, retryable: true, retryAt: original!.retryAt.getTime() });
    expect(after).toEqual(original);
    expect(f.fetch).toHaveBeenCalledTimes(1);
  });

  it("[W4-MARKER-INSERT] simultaneous marker insertion is due immediately and cannot replace the winning identity", async () => {
    let inserts = 0;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const f = await fixture(async (query) => {
      if (!query.startsWith('insert into "deletion_state"')) return;
      expect(query).toContain("on conflict do nothing");
      if (++inserts === 2) release();
      await gate;
    });
    await f.room("owner");
    f.fetch.mockImplementation(async () => Response.json({ code: "CONFLICT" }, { status: 409 }));
    const results = await Promise.allSettled([deleteAccount(f.db, f.env, "deleting"), deleteAccount(f.db, f.env, "deleting")]);
    expect(inserts).toBe(2);
    expect(results.every((result) => result.status === "rejected")).toBe(true);
    expect(f.fetch).toHaveBeenCalledTimes(1);
    expect(await f.db.select().from(deletionState).all()).toHaveLength(1);
  });

  it.each(["open", "ended"] as const)("[W4-OWNER] revokes then purges %s owner rooms, with durable invite removal", async (status) => {
    const f = await fixture();
    await f.room("owner", "deleting", status);
    await f.member("owner");
    await f.member("owner", "admitted", "other");
    await completeDeletionAfterDrain(f.db, f.env, "deleting", f.marker);
    expect(f.calls.map(({ action }) => action)).toEqual(["revokeAccountReferences", "purgeAppleRoom"]);
    expect(f.calls[0]!.payload).toEqual({ accountUserId: "deleting", deletionOperationId: expect.any(String) });
    expect(await f.db.select().from(sessionInvites).all()).toHaveLength(0);
  });

  it.each(["pending", "admitted", "left"] as const)("[W4-PARTICIPANT] acknowledges %s membership without purging another owner's room", async (membership) => {
    const f = await fixture();
    await f.room("participant", "other");
    await f.member("participant", membership);
    f.ledger.purgeAccountData.mockRejectedValueOnce(new Error("crash before finalization"));
    await expect(deleteAccount(f.db, f.env, "deleting")).rejects.toMatchObject({ code: "ACCOUNT_DELETION_PENDING" });
    expect(f.calls.map(({ action }) => action)).toEqual(["revokeAccountReferences"]);
    expect(await f.db.select().from(sessionInviteRedemptions).get()).toMatchObject({ membershipStatus: "removed" });
    expect(await f.db.select().from(sessionInvites).get()).toMatchObject({ ownerUserId: "other" });
  });

  it.each(["not_found", "SESSION_NOT_FOUND"])("[W4-NOT-FOUND] treats %s as durable acknowledgement", async (status) => {
    const f = await fixture();
    await f.room("owner");
    f.fetch.mockImplementation(async () => status === "not_found"
      ? Response.json({ ok: true, status }) : Response.json({ code: status }, { status: 404 }));
    // Purge still needs its own acknowledgement when the revoke returns a result.
    if (status === "not_found") f.fetch.mockImplementation(async (_input, init) => Response.json(
      JSON.parse(String(init?.body)).action === "purgeAppleRoom" ? { ok: true } : { ok: true, status },
    ));
    await completeDeletionAfterDrain(f.db, f.env, "deleting", f.marker);
  });

  it.each([503, 409])("[W4-RETENTION] HTTP %s retains the room and account and schedules retry", async (status) => {
    const f = await fixture();
    await f.room("owner");
    f.fetch.mockResolvedValue(Response.json({ code: status === 409 ? "CONFLICT" : "SERVICE_UNAVAILABLE" }, { status }));
    await expect(deleteAccount(f.db, f.env, "deleting")).rejects.toMatchObject({ code: status === 409 ? "ACCOUNT_DELETION_CONFLICT" : "ACCOUNT_DELETION_PENDING", status, retryable: true });
    expect(await f.db.select().from(sessionInvites).all()).toHaveLength(1);
    expect(await f.db.select().from(user).where(eq(user.id, "deleting")).get()).toBeTruthy();
    expect((await f.marker())!.retryAt.getTime()).toBeGreaterThan(Date.now());
    expect(f.ledger.purgeAccountData).not.toHaveBeenCalled();
  });

  it("[W4-LOST-RESPONSE] retry retains the stored deletion ID and deterministic room operation ID", async () => {
    const f = await fixture();
    await f.room("owner");
    const payloads: unknown[] = [];
    f.fetch.mockImplementationOnce(async (_input, init) => { payloads.push(JSON.parse(String(init?.body))); throw new Error("lost response after remote commit"); });
    await expect(deleteAccount(f.db, f.env, "deleting")).rejects.toMatchObject({ code: "ACCOUNT_DELETION_PENDING" });
    const original = (await f.marker())!;
    advancePastDrain(original);
    try {
      expect(await retryPendingDeletions(f.db, f.env)).toBe(1);
    } finally {
      vi.useRealTimers();
    }
    expect(f.calls[0]!.payload).toEqual((payloads[0] as { payload: unknown }).payload);
    expect(original.deletionId).toBeTruthy();
  });

  it("[W4-BOUNDED] processes one sorted distinct page, then catches a newly inserted lower ID", async () => {
    const f = await fixture();
    for (let i = 0; i < 27; i++) {
      const id = `room-${String(i).padStart(2, "0")}`;
      await f.room(id);
      await f.member(id);
      await f.member(id, "admitted", "other");
    }
    await expect(deleteAccount(f.db, f.env, "deleting")).rejects.toMatchObject({ code: "ACCOUNT_DELETION_PENDING" });
    expect(f.calls.filter((call) => call.action === "revokeAccountReferences").map((call) => call.sessionId))
      .toEqual(Array.from({ length: 25 }, (_, i) => `room-${String(i).padStart(2, "0")}`));
    expect(await f.db.select().from(sessionInvites).all()).toHaveLength(2);
    await f.room("aaa-new");
    const original = (await f.marker())!;
    advancePastDrain(original);
    try {
      expect(await retryPendingDeletions(f.db, f.env)).toBe(1);
    } finally {
      vi.useRealTimers();
    }
    expect(f.calls.filter((call) => call.action === "revokeAccountReferences").slice(25).map((call) => call.sessionId))
      .toEqual(["aaa-new", "room-25", "room-26"]);
  });

  it("[W4-PURGING] resumes purging after a crash without enumerating rooms or resetting identity", async () => {
    const f = await fixture();
    await f.room("owner");
    f.ledger.purgeAccountData.mockRejectedValueOnce(new Error("crash"));
    await expect(deleteAccount(f.db, f.env, "deleting")).rejects.toMatchObject({ code: "ACCOUNT_DELETION_PENDING" });
    const marker = (await f.marker())!;
    expect(marker.status).toBe("purging");
    advancePastDrain(marker);
    f.fetch.mockClear();
    const queries = vi.spyOn(f.d1, "prepare");
    try {
      const result = await deleteAccount(f.db, f.env, "deleting");
      expect(result.deletionId).toBe(marker.deletionId);
      expect(f.fetch).not.toHaveBeenCalled();
      expect(queries.mock.calls.some(([query]) => query.includes('from "session_invites"'))).toBe(false);
      expect(await f.marker()).toBeUndefined();
    } finally {
      vi.useRealTimers();
    }
    await expect(deleteAccount(f.db, f.env, "deleting")).resolves.toMatchObject({ alreadyDeleted: true });
  });

  it("[W4-TRANSITION-LEASE] losing the pending lease cannot transition to purging", async () => {
    const f = await fixture();
    await f.room("owner", "other");
    await f.member("owner");
    f.fetch.mockImplementationOnce(async () => {
      await f.db.update(deletionState).set({ retryAt: new Date(Date.now() + 300000) }).where(eq(deletionState.userId, "deleting"));
      return Response.json({ ok: true, status: "removed" });
    });
    await expect(deleteAccount(f.db, f.env, "deleting")).rejects.toMatchObject({ code: "ACCOUNT_DELETION_PENDING" });
    expect((await f.marker())!.status).toBe("pending");
    expect(await f.db.select().from(sessionInviteRedemptions).get()).toMatchObject({ membershipStatus: "admitted" });
    expect(f.ledger.purgeAccountData).not.toHaveBeenCalled();
  });

  it("[W4-PURGE-RETRY] lost purge response retains the owner row and retries the same revocation", async () => {
    const f = await fixture();
    await f.room("owner", "deleting", "ended");
    const transport = f.fetch.getMockImplementation()!;
    let lost = false;
    f.fetch.mockImplementation(async (input, init) => {
      const result = await transport(input, init);
      if (!lost && JSON.parse(String(init?.body)).action === "purgeAppleRoom") { lost = true; throw new Error("response lost"); }
      return result;
    });
    await expect(deleteAccount(f.db, f.env, "deleting")).rejects.toMatchObject({ code: "ACCOUNT_DELETION_PENDING" });
    expect(await f.db.select().from(sessionInvites).all()).toHaveLength(1);
    const original = (await f.marker())!;
    advancePastDrain(original);
    try {
      const result = await deleteAccount(f.db, f.env, "deleting");
      expect(result.deletionId).toBe(original.deletionId);
    } finally {
      vi.useRealTimers();
    }
    expect(f.calls[0]!.payload).toEqual(f.calls[2]!.payload);
  });

  it("[W4-ABSENT-FAILURE] reports typed pending when idempotent cleanup fails after account removal", async () => {
    const f = await fixture();
    await f.db.delete(user).where(eq(user.id, "deleting"));
    f.ledger.purgeAccountData.mockRejectedValueOnce(new Error("ledger unavailable"));
    await expect(deleteAccount(f.db, f.env, "deleting")).rejects.toMatchObject({ code: "ACCOUNT_DELETION_PENDING", status: 503, retryable: true });
  });

  it("[W4-LEASE-BATCH] exact lease loss immediately before final batch guards every removal", async () => {
    const f = await fixture();
    await f.db.insert(verification).values({ id: "verification", identifier: "deleting", value: "private", expiresAt: new Date() });
    await f.db.insert(subscription).values({ id: "stripe", plan: "reader", referenceId: "deleting" });
    await f.db.insert(appleNotificationsLog).values({ notificationUuid: "notification", notificationType: "SUBSCRIBED", userId: "deleting", rawPayload: "private", receivedAt: new Date() });
    await f.db.insert(sharePackages).values({ id: "package", senderUserId: "other", recipientUserId: "deleting", tokenHash: "package", kind: "selection", status: "pending", idempotencyKey: "package", expiresAt: new Date(), createdAt: new Date() });
    const batch = f.db.batch.bind(f.db);
    const spy = vi.spyOn(f.db, "batch").mockImplementation(async (queries) => {
      await f.db.update(deletionState).set({ retryAt: new Date(Date.now() + 300000) }).where(eq(deletionState.userId, "deleting"));
      return batch(queries);
    });
    await expect(deleteAccount(f.db, f.env, "deleting")).rejects.toMatchObject({ code: "ACCOUNT_DELETION_PENDING" });
    const marker = (await f.marker())!;
    advancePastDrain(marker);
    try {
      await expect(deleteAccount(f.db, f.env, "deleting")).rejects.toMatchObject({ code: "ACCOUNT_DELETION_PENDING" });
    } finally {
      vi.useRealTimers();
    }
    expect(spy).toHaveBeenCalledTimes(1);
    expect(await f.db.select().from(user).where(eq(user.id, "deleting")).get()).toBeTruthy();
    expect(await f.db.select().from(verification).all()).toHaveLength(1);
    expect(await f.db.select().from(subscription).all()).toHaveLength(1);
    expect(await f.db.select().from(appleNotificationsLog).all()).toHaveLength(1);
    expect(await f.db.select().from(sharePackages).all()).toHaveLength(1);
  });

  it("[W4-LATE-R2-FAILURE] preserves the user and same deletion marker when the late sweep fails", async () => {
    const f = await fixture();
    const objects = new Set<string>();
    let listCalls = 0;
    let failLateDelete = true;
    const bucket = {
      delete: vi.fn(async (key: string) => {
        if (failLateDelete) throw new Error(`late R2 failure for ${key}`);
        objects.delete(key);
      }),
      head: vi.fn(async (key: string) => objects.has(key) ? ({ key } as R2Object) : null),
      list: vi.fn(async ({ prefix }: { prefix?: string }) => {
        listCalls += 1;
        if (listCalls === 3) objects.add("books/deleting/late.epub");
        return {
          objects: [...objects]
            .filter((key) => !prefix || key.startsWith(prefix))
            .map((key) => ({ key })),
          truncated: false,
        };
      }),
    } as unknown as R2Bucket;

    await expect(deleteAccount(f.db, { ...f.env, BOOK_STORAGE: bucket }, "deleting"))
      .rejects.toMatchObject({ code: "ACCOUNT_DELETION_PENDING", status: 503, retryable: true });
    const drainMarker = await f.marker();
    expect(drainMarker?.status).toBe("purging");
    advancePastDrain(drainMarker!);
    let failedMarker: Awaited<ReturnType<typeof f.marker>>;
    try {
      await expect(deleteAccount(f.db, { ...f.env, BOOK_STORAGE: bucket }, "deleting"))
        .rejects.toMatchObject({ code: "ACCOUNT_DELETION_PENDING", status: 503, retryable: true });
      failedMarker = await f.marker();
    } finally {
      vi.useRealTimers();
    }
    expect(await f.db.select().from(user).where(eq(user.id, "deleting")).all()).toHaveLength(1);
    expect(failedMarker).toBeTruthy();
    expect(failedMarker?.deletionId).toBeTruthy();
    expect(objects).toEqual(new Set(["books/deleting/late.epub"]));

    failLateDelete = false;
    advancePastDrain(failedMarker!);
    let resumed: Awaited<ReturnType<typeof deleteAccount>>;
    try {
      resumed = await deleteAccount(f.db, { ...f.env, BOOK_STORAGE: bucket }, "deleting");
    } finally {
      vi.useRealTimers();
    }

    expect(resumed.deletionId).toBe(failedMarker!.deletionId);
    expect(await f.db.select().from(user).where(eq(user.id, "deleting")).all()).toHaveLength(0);
    expect(await f.marker()).toBeUndefined();
    expect(objects).toEqual(new Set());
  });

  it("[W4-UPLOAD-DRAIN] waits for pre-marker upload expiry before the final sweep and delete", async () => {
    const initialTime = new Date("2026-09-16T15:00:00.000Z");
    vi.useFakeTimers();
    vi.setSystemTime(initialTime);
    try {
      const f = await fixture();
      const objects = new Set<string>();
      const booksPrefix = "books/deleting/";
      const coversPrefix = "covers/deleting/";
      let attempt = 0;
      let callsInRun = 0;
      const bucket = {
        delete: vi.fn(async (key: string) => {
          expect(await f.db.select().from(user).where(eq(user.id, "deleting")).all()).toHaveLength(1);
          expect(await f.marker()).toMatchObject({ status: "purging" });
          objects.delete(key);
        }),
        head: vi.fn(async (key: string) => objects.has(key) ? ({ key } as R2Object) : null),
        list: vi.fn(async ({ prefix }: { prefix?: string }) => {
          callsInRun += 1;
          // A pre-marker PUT lands only during the final books-prefix sweep
          // of the first retry that is allowed past the drain deadline.
          if (attempt === 3 && callsInRun === 3) objects.add("books/deleting/pre-marker.epub");
          return {
            objects: [...objects]
              .filter((key) => !prefix || key.startsWith(prefix))
              .map((key) => ({ key })),
            truncated: false,
          };
        }),
      } as unknown as R2Bucket;
      const env = { ...f.env, BOOK_STORAGE: bucket };
      const uploadExpiry = initialTime.getTime() + 300_000;

      attempt = 1;
      callsInRun = 0;
      await expect(deleteAccount(f.db, env, "deleting"))
        .rejects.toMatchObject({ code: "ACCOUNT_DELETION_PENDING", status: 503, retryable: true });
      const firstMarker = await f.marker();
      expect(await f.db.select().from(user).where(eq(user.id, "deleting")).all()).toHaveLength(1);
      expect(firstMarker?.status).toBe("purging");
      expect(firstMarker?.retryAt.getTime()).toBeGreaterThanOrEqual(uploadExpiry);
      const drainDeadline = firstMarker!.retryAt.getTime();

      vi.setSystemTime(new Date(drainDeadline - 1));
      await f.due();
      attempt = 2;
      callsInRun = 0;
      await expect(retryPendingDeletions(f.db, env)).resolves.toBe(0);
      expect(await f.db.select().from(user).where(eq(user.id, "deleting")).all()).toHaveLength(1);
      expect((await f.marker())?.status).toBe("purging");
      expect((await f.marker())?.retryAt.getTime()).toBe(drainDeadline);

      vi.setSystemTime(new Date(drainDeadline));
      attempt = 3;
      callsInRun = 0;
      await expect(retryPendingDeletions(f.db, env)).resolves.toBe(1);
      expect(bucket.delete).toHaveBeenCalledWith("books/deleting/pre-marker.epub");
      expect(objects).toEqual(new Set());
      expect(await f.db.select().from(user).where(eq(user.id, "deleting")).all()).toHaveLength(0);
      expect(await f.marker()).toBeUndefined();
    } finally {
      vi.useRealTimers();
    }
  });
});

function testLedgerBinding() {
  return {
    getByName: () => ({
      markRestorationPending: vi.fn(async () => undefined),
      restoreAccountEntitlements: vi.fn(async () => ({
        trialState: "never_granted" as const,
        trialInitialCredits: 0,
        trialUsedCredits: 0,
        reader: { total: 0, used: 0, activeUntil: null, status: null },
        voice: { total: 0, used: 0, activeUntil: null, status: null },
      })),
      snapshotAccountEntitlements: vi.fn(async () => ({
        trialState: "never_granted" as const,
        trialInitialCredits: 0,
        trialUsedCredits: 0,
        reader: { total: 0, used: 0, activeUntil: null, status: null },
        voice: { total: 0, used: 0, activeUntil: null, status: null },
      })),
      purgeAccountData: vi.fn(async () => ({ purged: true as const })),
    }),
  };
}

function createD1(
  failOnRun?: (query: string) => boolean,
  beforeRun?: (query: string) => void | Promise<void>,
): TestD1 {
  return createTestD1(":memory:", {
    failOnRun,
    beforeRun,
  });
}

describe("DELETE /api/user black-box/white-box account deletion", () => {
  it("removes sender-owned share packages without touching an imported recipient copy", async () => {
    const d1 = createD1();
    const db = createDb(d1);
    const now = new Date();
    await db.insert(user).values([
      {
        id: "share-sender",
        name: "Share Sender",
        email: "share-sender@example.com",
        emailVerified: true,
        createdAt: now,
        updatedAt: now,
      },
      {
        id: "share-recipient",
        name: "Share Recipient",
        email: "share-recipient@example.com",
        emailVerified: true,
        createdAt: now,
        updatedAt: now,
      },
    ]);
    await db.insert(sharePackages).values({
      id: "share-package-1",
      senderUserId: "share-sender",
      recipientUserId: "share-recipient",
      tokenHash: null,
      kind: "selection",
      status: "pending",
      idempotencyKey: "share-request-1",
      expiresAt: new Date(Date.now() + 60_000),
      createdAt: now,
      claimedAt: null,
      claimedBy: null,
    });
    await db.insert(sharePackageItems).values({
      id: "share-item-1",
      packageId: "share-package-1",
      title: "Shared book",
      author: "Author",
      format: "epub",
      fileR2Key: "books/share-sender/shared-book.epub",
      coverR2Key: null,
      fileHash: null,
      fileSize: 12,
      createdAt: now,
    });

    const objects = new Set([
      "books/share-sender/shared-book.epub",
      "books/share-recipient/recipient-book.epub",
      "shares/share-package-1/share-item-1/book.epub",
      "shares/other-package/other-item/book.epub",
    ]);
    const bucket = {
      delete: vi.fn(async (keys: string | string[]) => {
        for (const key of Array.isArray(keys) ? keys : [keys]) objects.delete(key);
      }),
      head: vi.fn(async (key: string) => objects.has(key) ? ({ key } as R2Object) : null),
      list: vi.fn(async ({ prefix }: { prefix?: string }) => ({
        objects: [...objects]
          .filter((key) => !prefix || key.startsWith(prefix))
          .map((key) => ({ key })),
        truncated: false,
      })),
    } as unknown as R2Bucket;

    const env = {
      DB: d1,
      USER_USAGE_LEDGER: testLedgerBinding(),
      BOOK_STORAGE: bucket,
    } as unknown as DeletionEnvironment;
    await completeDeletionAfterDrain(db, env, "share-sender", () => markerFor(db, "share-sender"));

    expect(objects.has("books/share-sender/shared-book.epub")).toBe(false);
    expect(objects.has("shares/share-package-1/share-item-1/book.epub")).toBe(false);
    expect(objects.has("shares/other-package/other-item/book.epub")).toBe(true);
    expect(objects.has("books/share-recipient/recipient-book.epub")).toBe(true);
    expect(await db.select().from(sharePackages).where(eq(sharePackages.id, "share-package-1")).all()).toHaveLength(0);
    d1.close();
  });

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
      USER_USAGE_LEDGER: testLedgerBinding(),
      DB: d1,
      BOOK_STORAGE,
      ACCESS_TOKEN_SECRET: "access-secret",
      REFRESH_TOKEN_SECRET: "refresh-secret",
      APPLE_SIWA_CLIENT_ID: "org.fidexa.rishi",
      APPLE_SIWA_KEY_ID: "test-key",
      APPLE_SIWA_PRIVATE_KEY: "test-private-key",
      APPLE_TEAM_ID: "test-team",
      SIWA_TOKEN_ENCRYPTION_SECRET: "test-encryption-secret",
      APPLE_IDENTITY_RETENTION_SECRET_CURRENT: "test-identity-retention-secret",
      APPLE_TRANSACTION_HASH_SECRET: "test-transaction-hash-secret",
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
        identityToken: "fake-identity-token:test-nonce",
        nonce: "test-nonce",
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
    expect(deletionResponse.status).toBe(503);
    expect(await deletionResponse.json()).toMatchObject({ code: "ACCOUNT_DELETION_PENDING", retryable: true });
    const firstMarker = await markerFor(db, auth.userId);
    expect(firstMarker?.status).toBe("purging");
    advancePastDrain(firstMarker!);
    try {
      const retryDeletionResponse = await app.fetch(new Request("http://test/api/user", {
        method: "DELETE",
        headers: { Authorization: `Bearer ${auth.accessToken}` },
      }), env);
      expect(retryDeletionResponse.status).toBe(200);
      expect(await retryDeletionResponse.json()).toMatchObject({ ok: true, revocationStatus: "revoked" });
    } finally {
      vi.useRealTimers();
    }

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
    expect(await db.select().from(retainedAppleEntitlement).all()).toHaveLength(1);
    const retainedTransactions = await db.select().from(retainedAppleTransaction).all();
    expect(retainedTransactions).toHaveLength(1);
    expect(retainedTransactions[0]?.originalTransactionHash).not.toBe("orig-1");
    expect(await db.select().from(restoredAppleEntitlement).all()).toHaveLength(0);
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
      USER_USAGE_LEDGER: testLedgerBinding(),
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

    await expect(deleteAccount(db, env, "retry-user")).rejects.toMatchObject({ code: "ACCOUNT_DELETION_PENDING", status: 503, retryable: true });
    const failedMarker = await markerFor(db, "retry-user");
    expect(failedMarker?.status).toBe("purging");
    advancePastDrain(failedMarker!);
    try {
      failOnce = false;
      const resumed = await deleteAccount(db, env, "retry-user");
      expect(resumed.deletionId).toBe(failedMarker!.deletionId);
      expect(resumed.alreadyDeleted).toBe(false);
    } finally {
      vi.useRealTimers();
    }
    expect(await db.select().from(user).where(eq(user.id, "retry-user")).all()).toHaveLength(0);
    d1.close();
  });

  it("sweeps a late user-scoped upload before the parent row is deleted", async () => {
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
        // final pre-delete sweep, which must remove it despite no book row.
        if (listCalls === 3) objects.add("books/late-upload-user/late.epub");
        return {
          objects: [...objects]
            .filter((key) => !prefix || key.startsWith(prefix))
            .map((key) => ({ key })),
          truncated: false,
        };
      }),
    } as unknown as R2Bucket;

    const env = { DB: d1, BOOK_STORAGE: bucket, USER_USAGE_LEDGER: testLedgerBinding() } as unknown as DeletionEnvironment;
    await expect(deleteAccount(db, env, "late-upload-user")).rejects.toMatchObject({
      code: "ACCOUNT_DELETION_PENDING", status: 503, retryable: true,
    });
    const marker = await markerFor(db, "late-upload-user");
    expect(marker?.status).toBe("purging");
    advancePastDrain(marker!);
    try {
      const result = await deleteAccount(db, env, "late-upload-user");
      expect(result.deletionId).toBe(marker!.deletionId);
    } finally {
      vi.useRealTimers();
    }
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
      USER_USAGE_LEDGER: testLedgerBinding(),
      BOOK_STORAGE: {
        delete: vi.fn(async () => undefined),
        head: vi.fn(async () => null),
        list: vi.fn(async () => ({ objects: [], truncated: false })),
      },
    } as unknown as Env, "stripe-config-user")).rejects.toMatchObject({ code: "ACCOUNT_DELETION_PENDING", status: 503, retryable: true });
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

    const env = {
      DB: d1,
      USER_USAGE_LEDGER: testLedgerBinding(),
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
      APPLE_IDENTITY_RETENTION_SECRET_CURRENT: "test-identity-retention-secret",
      APPLE_TRANSACTION_HASH_SECRET: "test-transaction-hash-secret",
    } as unknown as DeletionEnvironment;
    const result = await completeDeletionAfterDrain(db, env, "apple-config-user", () => markerFor(db, "apple-config-user"));
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
      USER_USAGE_LEDGER: testLedgerBinding(),
      DB: d1,
      BOOK_STORAGE: {
        delete: vi.fn(async () => undefined),
        head: vi.fn(async () => null),
        list: vi.fn(async () => ({ objects: [], truncated: false })),
      },
    } as unknown as Env;

    await expect(deleteAccount(db, env, "d1-failure-user")).rejects.toMatchObject({ code: "ACCOUNT_DELETION_PENDING", status: 503, retryable: true });
    const drainMarker = await markerFor(db, "d1-failure-user");
    expect(drainMarker?.status).toBe("purging");
    advancePastDrain(drainMarker!);
    let failedMarker: Awaited<ReturnType<typeof markerFor>>;
    try {
      await expect(deleteAccount(db, env, "d1-failure-user")).rejects.toMatchObject({ code: "ACCOUNT_DELETION_PENDING", status: 503, retryable: true });
      failedMarker = await markerFor(db, "d1-failure-user");
      failD1Delete = false;
      advancePastDrain(failedMarker!);
      const result = await deleteAccount(db, env, "d1-failure-user");
      expect(result.deletionId).toBe(failedMarker!.deletionId);
      expect(result.alreadyDeleted).toBe(false);
    } finally {
      vi.useRealTimers();
    }
    expect(await db.select().from(user).where(eq(user.id, "d1-failure-user")).all()).toHaveLength(0);
    d1.close();
  });

  it("does not create a new account when Apple authorization exchange fails", async () => {
    const d1 = createD1();
    const env = {
      USER_USAGE_LEDGER: testLedgerBinding(),
      DB: d1,
      ACCESS_TOKEN_SECRET: "access-secret",
      REFRESH_TOKEN_SECRET: "refresh-secret",
      APPLE_IDENTITY_RETENTION_SECRET_CURRENT: "test-identity-retention-secret",
      APPLE_TRANSACTION_HASH_SECRET: "test-transaction-hash-secret",
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
        identityToken: "fake-identity-token:test-nonce",
        nonce: "test-nonce",
        authorizationCode: btoa("bad-code"),
      }),
    }), env);
    expect(response.status).toBe(502);
    const db = createDb(d1);
    expect(await db.select().from(user).all()).toHaveLength(0);
    d1.close();
  });

  it("recreates an Apple account after deletion without a new authorization code", async () => {
    const d1 = createD1();
    const env = {
      USER_USAGE_LEDGER: testLedgerBinding(),
      DB: d1,
      ACCESS_TOKEN_SECRET: "access-secret",
      REFRESH_TOKEN_SECRET: "refresh-secret",
      APPLE_IDENTITY_RETENTION_SECRET_CURRENT: "test-identity-retention-secret",
      APPLE_TRANSACTION_HASH_SECRET: "test-transaction-hash-secret",
      APPLE_SIWA_CLIENT_ID: "org.fidexa.rishi",
      APPLE_SIWA_KEY_ID: "test-key",
      APPLE_SIWA_PRIVATE_KEY: "test-private-key",
      APPLE_TEAM_ID: "test-team",
      SIWA_TOKEN_ENCRYPTION_SECRET: "test-encryption-secret",
      BOOK_STORAGE: {
        delete: vi.fn(async () => undefined),
        head: vi.fn(async () => null),
        list: vi.fn(async () => ({ objects: [], truncated: false })),
      },
    } as unknown as Env;
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.endsWith("/auth/token")) {
        return new Response(JSON.stringify({ refresh_token: "apple-refresh-token" }), { status: 200 });
      }
      if (url.endsWith("/auth/revoke")) return new Response(null, { status: 200 });
      throw new Error(`unexpected fetch: ${url}`);
    }));

    const app = new Hono();
    app.route("/auth", authRoutes);
    app.route("/api/user", userRoutes);

    const firstAuthResponse = await app.fetch(new Request("http://test/auth/apple", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        identityToken: "fake-identity-token:test-nonce",
        nonce: "test-nonce",
        authorizationCode: btoa("fake-code"),
      }),
    }), env);
    expect(firstAuthResponse.status).toBe(200);
    const firstAuth = await firstAuthResponse.json() as { accessToken: string; userId: string };

    const deleteResponse = await app.fetch(new Request("http://test/api/user", {
      method: "DELETE",
      headers: { Authorization: `Bearer ${firstAuth.accessToken}` },
    }), env);
    const db = createDb(d1);
    expect(deleteResponse.status).toBe(503);
    expect(await deleteResponse.json()).toMatchObject({ code: "ACCOUNT_DELETION_PENDING", retryable: true });
    const firstMarker = await markerFor(db, firstAuth.userId);
    expect(firstMarker?.status).toBe("purging");
    advancePastDrain(firstMarker!);
    try {
      const retryDeleteResponse = await app.fetch(new Request("http://test/api/user", {
        method: "DELETE",
        headers: { Authorization: `Bearer ${firstAuth.accessToken}` },
      }), env);
      expect(retryDeleteResponse.status).toBe(200);
      expect(await retryDeleteResponse.json()).toMatchObject({ ok: true, revocationStatus: "revoked" });
    } finally {
      vi.useRealTimers();
    }
    expect(await db.select().from(user).where(eq(user.id, firstAuth.userId)).all()).toHaveLength(0);
    expect(await db.select().from(appleUsers).where(eq(appleUsers.userId, firstAuth.userId)).all()).toHaveLength(0);

    const recreatedResponse = await app.fetch(new Request("http://test/auth/apple", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        identityToken: "fake-identity-token:test-nonce",
        nonce: "test-nonce",
      }),
    }), env);
    expect(recreatedResponse.status).toBe(200);
    const recreated = await recreatedResponse.json() as { userId: string };
    expect(recreated.userId).not.toBe(firstAuth.userId);

    const recreatedAppleUser = await db.select().from(appleUsers)
      .where(eq(appleUsers.userId, recreated.userId)).get();
    expect(recreatedAppleUser?.siwaRefreshTokenCiphertext).toBeNull();
    expect(recreatedAppleUser?.siwaRefreshTokenNonce).toBeNull();
    d1.close();
  });

  it("allows repeat Apple sign-in with retained entitlements and preserves a populated ledger", async () => {
    const d1 = createD1();
    const existingLedgerState = {
      trialState: "exhausted" as const,
      trialInitialCredits: 300,
      trialUsedCredits: 300,
      reader: { total: 600, used: 120, activeUntil: Date.now() + 86_400_000, status: "active" as const },
      voice: { total: 0, used: 0, activeUntil: null, status: null },
    };
    const ledger = {
      markRestorationPending: vi.fn(async () => undefined),
      restoreAccountEntitlements: vi.fn(async () => {
        throw new Error("cannot restore a non-empty ledger");
      }),
      snapshotAccountEntitlements: vi.fn(async () => structuredClone(existingLedgerState)),
    };
    const env = {
      USER_USAGE_LEDGER: { getByName: vi.fn(() => ledger) },
      DB: d1,
      ACCESS_TOKEN_SECRET: "access-secret",
      REFRESH_TOKEN_SECRET: "refresh-secret",
      APPLE_IDENTITY_RETENTION_SECRET_CURRENT: "test-identity-retention-secret",
      APPLE_TRANSACTION_HASH_SECRET: "test-transaction-hash-secret",
      APPLE_SIWA_CLIENT_ID: "org.fidexa.rishi",
      APPLE_SIWA_KEY_ID: "test-key",
      APPLE_SIWA_PRIVATE_KEY: "test-private-key",
      APPLE_TEAM_ID: "test-team",
    } as unknown as Env;
    const app = new Hono();
    app.route("/auth", authRoutes);
    const signIn = () => app.fetch(new Request("http://test/auth/apple", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        identityToken: "fake-identity-token:test-nonce",
        nonce: "test-nonce",
      }),
    }), env);

    try {
      const firstResponse = await signIn();
      expect(firstResponse.status).toBe(200);

      const identity = await hashAppleIdentity(
        "apple-sub-integration",
        "test-identity-retention-secret",
      );
      const now = new Date();
      const db = createDb(d1);
      await db.insert(retainedAppleEntitlement).values({
        identityHashVersion: identity.identityHashVersion,
        identityHash: identity.identityHash,
        trialState: "active",
        trialInitialCredits: 300,
        trialUsedCredits: 0,
        readerActiveUntil: new Date(Date.now() + 86_400_000),
        voiceActiveUntil: null,
        readerCreditsTotal: 900,
        readerCreditsUsed: 0,
        voiceCreditsTotal: 0,
        voiceCreditsUsed: 0,
        readerStatus: "active",
        voiceStatus: null,
        deletedAt: now,
        retentionExpiresAt: new Date(Date.now() + 86_400_000 * 365),
        updatedAt: now,
      });

      const secondResponse = await signIn();
      expect(secondResponse.status).toBe(200);
      expect(await ledger.snapshotAccountEntitlements()).toEqual(existingLedgerState);
    } finally {
      d1.close();
    }
  });

  it("mirrors the Durable Object snapshot accepted during entitlement restoration", async () => {
    const d1 = createD1();
    const acceptedSnapshot = {
      trialState: "exhausted" as const,
      trialInitialCredits: 300,
      trialUsedCredits: 300,
      reader: { total: 42, used: 7, activeUntil: Date.now() + 86_400_000, status: "active" as const },
      voice: { total: 84, used: 9, activeUntil: Date.now() + 86_400_000, status: "active" as const },
    };
    const ledger = {
      restoreAccountEntitlements: vi.fn(async () => acceptedSnapshot),
      snapshotAccountEntitlements: vi.fn(async () => acceptedSnapshot),
    };
    const env = {
      USER_USAGE_LEDGER: { getByName: vi.fn(() => ledger) },
      DB: d1,
      ACCESS_TOKEN_SECRET: "access-secret",
      REFRESH_TOKEN_SECRET: "refresh-secret",
      APPLE_IDENTITY_RETENTION_SECRET_CURRENT: "test-identity-retention-secret",
      APPLE_TRANSACTION_HASH_SECRET: "test-transaction-hash-secret",
      APPLE_SIWA_CLIENT_ID: "org.fidexa.rishi",
      APPLE_SIWA_KEY_ID: "test-key",
      APPLE_SIWA_PRIVATE_KEY: "test-private-key",
      APPLE_TEAM_ID: "test-team",
    } as unknown as Env;
    const identity = await hashAppleIdentity(
      "apple-sub-integration",
      "test-identity-retention-secret",
    );
    const now = new Date();
    const db = createDb(d1);
    await db.insert(retainedAppleEntitlement).values({
      identityHashVersion: identity.identityHashVersion,
      identityHash: identity.identityHash,
      trialState: "active",
      trialInitialCredits: 300,
      trialUsedCredits: 0,
      readerActiveUntil: new Date(Date.now() + 86_400_000),
      voiceActiveUntil: new Date(Date.now() + 86_400_000),
      readerCreditsTotal: 900,
      readerCreditsUsed: 0,
      voiceCreditsTotal: 900,
      voiceCreditsUsed: 0,
      readerStatus: "active",
      voiceStatus: "active",
      deletedAt: now,
      retentionExpiresAt: new Date(Date.now() + 86_400_000 * 365),
      updatedAt: now,
    });

    const app = new Hono();
    app.route("/auth", authRoutes);
    const response = await app.fetch(new Request("http://test/auth/apple", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        identityToken: "fake-identity-token:test-nonce",
        nonce: "test-nonce",
      }),
    }), env);

    expect(response.status).toBe(200);
    const auth = await response.json() as { userId: string };
    const mirrored = await db.select().from(allowancePeriod)
      .where(eq(allowancePeriod.userId, auth.userId)).get();
    expect(mirrored).toMatchObject({
      plan: "combined",
      narrationSecondsTotal: 42,
      narrationSecondsUsed: 7,
      voiceChatSecondsTotal: 84,
      voiceChatSecondsUsed: 9,
    });
    d1.close();
  });

  it("rejects an explicitly empty Apple authorization code before creating an account", async () => {
    const d1 = createD1();
    const env = {
      USER_USAGE_LEDGER: testLedgerBinding(),
      DB: d1,
      ACCESS_TOKEN_SECRET: "access-secret",
      REFRESH_TOKEN_SECRET: "refresh-secret",
    } as unknown as Env;
    const app = new Hono();
    app.route("/auth", authRoutes);

    const response = await app.fetch(new Request("http://test/auth/apple", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        identityToken: "fake-identity-token:test-nonce",
        nonce: "test-nonce",
        authorizationCode: "",
      }),
    }), env);

    expect(response.status).toBe(400);
    expect(await createDb(d1).select().from(user).all()).toHaveLength(0);
    d1.close();
  });

  it("treats a null Apple authorization code as absent", async () => {
    const d1 = createD1();
    const env = {
      USER_USAGE_LEDGER: testLedgerBinding(),
      DB: d1,
      ACCESS_TOKEN_SECRET: "access-secret",
      REFRESH_TOKEN_SECRET: "refresh-secret",
      APPLE_IDENTITY_RETENTION_SECRET_CURRENT: "test-identity-retention-secret",
      APPLE_TRANSACTION_HASH_SECRET: "test-transaction-hash-secret",
    } as unknown as Env;
    const app = new Hono();
    app.route("/auth", authRoutes);

    const response = await app.fetch(new Request("http://test/auth/apple", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        identityToken: "fake-identity-token:test-nonce",
        nonce: "test-nonce",
        authorizationCode: null,
      }),
    }), env);

    expect(response.status).toBe(200);
    const recreated = await createDb(d1).select().from(appleUsers).get();
    expect(recreated?.siwaRefreshTokenCiphertext).toBeNull();
    expect(recreated?.siwaRefreshTokenNonce).toBeNull();
    d1.close();
  });

  it("recreates an account without exchanging a code when token encryption is unavailable", async () => {
    const d1 = createD1();
    const env = {
      USER_USAGE_LEDGER: testLedgerBinding(),
      DB: d1,
      ACCESS_TOKEN_SECRET: "access-secret",
      REFRESH_TOKEN_SECRET: "refresh-secret",
      APPLE_IDENTITY_RETENTION_SECRET_CURRENT: "test-identity-retention-secret",
      APPLE_TRANSACTION_HASH_SECRET: "test-transaction-hash-secret",
    } as unknown as Env;
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
    const app = new Hono();
    app.route("/auth", authRoutes);

    const response = await app.fetch(new Request("http://test/auth/apple", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        identityToken: "fake-identity-token:test-nonce",
        nonce: "test-nonce",
        authorizationCode: btoa("stale-or-unexchangeable-code"),
      }),
    }), env);

    expect(response.status).toBe(200);
    expect(fetchSpy).not.toHaveBeenCalled();
    const appleRow = await createDb(d1).select().from(appleUsers).get();
    expect(appleRow?.siwaRefreshTokenCiphertext).toBeNull();
    expect(appleRow?.siwaRefreshTokenNonce).toBeNull();
    d1.close();
  });

  it("converges concurrent no-code Apple recreations on one user", async () => {
    let userInsertCount = 0;
    let releaseUserInserts!: () => void;
    const bothUserInserts = new Promise<void>((resolve) => {
      releaseUserInserts = resolve;
    });
    const d1 = createD1(undefined, async (query) => {
      if (query.toLowerCase().includes('insert into "user"')) {
        userInsertCount += 1;
        if (userInsertCount === 2) releaseUserInserts();
        await bothUserInserts;
      }
    });
    const env = {
      USER_USAGE_LEDGER: testLedgerBinding(),
      DB: d1,
      ACCESS_TOKEN_SECRET: "access-secret",
      REFRESH_TOKEN_SECRET: "refresh-secret",
      APPLE_IDENTITY_RETENTION_SECRET_CURRENT: "test-identity-retention-secret",
      APPLE_TRANSACTION_HASH_SECRET: "test-transaction-hash-secret",
    } as unknown as Env;
    const app = new Hono();
    app.route("/auth", authRoutes);

    const makeRequest = () => app.fetch(new Request("http://test/auth/apple", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        identityToken: "fake-identity-token:test-nonce",
        nonce: "test-nonce",
      }),
    }), env);
    const [firstResponse, secondResponse] = await Promise.all([makeRequest(), makeRequest()]);
    expect(firstResponse.status).toBe(200);
    expect(secondResponse.status).toBe(200);
    const first = await firstResponse.json() as { userId: string };
    const second = await secondResponse.json() as { userId: string };
    expect(first.userId).toBe(second.userId);

    const db = createDb(d1);
    expect(await db.select().from(user).all()).toHaveLength(1);
    expect(await db.select().from(appleUsers).all()).toHaveLength(1);
    d1.close();
  });

  it("rejects a nonce mismatch before creating an account", async () => {
    const d1 = createD1();
    const env = {
      DB: d1,
      ACCESS_TOKEN_SECRET: "access-secret",
      REFRESH_TOKEN_SECRET: "refresh-secret",
    } as unknown as Env;
    const app = new Hono();
    app.route("/auth", authRoutes);

    const response = await app.fetch(new Request("http://test/auth/apple", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        identityToken: "fake-identity-token:test-nonce",
        nonce: "wrong-nonce",
      }),
    }), env);

    expect(response.status).toBe(401);
    expect(await createDb(d1).select().from(user).all()).toHaveLength(0);
    d1.close();
  });

  it("rejects a missing nonce before creating an account", async () => {
    const d1 = createD1();
    const env = {
      DB: d1,
      ACCESS_TOKEN_SECRET: "access-secret",
      REFRESH_TOKEN_SECRET: "refresh-secret",
    } as unknown as Env;
    const app = new Hono();
    app.route("/auth", authRoutes);

    const response = await app.fetch(new Request("http://test/auth/apple", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ identityToken: "fake-identity-token" }),
    }), env);

    expect(response.status).toBe(400);
    expect(await createDb(d1).select().from(user).all()).toHaveLength(0);
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
      USER_USAGE_LEDGER: testLedgerBinding(),
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

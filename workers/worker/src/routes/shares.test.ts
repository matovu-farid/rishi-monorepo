import { Effect } from "effect";
import { describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";

import { createDb } from "../db/drizzle";
import { createTestD1, type TestD1 } from "../test-utils/d1";
import { signAccessToken } from "../jwt";
import {
  books,
  sharePackageItems,
  sharePackageRedemptions,
  shareLinkSlots,
  sharePackages,
  user,
  usernames,
} from "../db/schema";
import { hashShareToken } from "../shares/shareTokens";
import { AI_DATA_CONSENT_HEADER, AI_DATA_CONSENT_VERSION } from "../middleware/ai-data-consent";
import { precreateShareLinks, purgeExpiredShares, sharesRoutes } from "./shares";

const baseEnv = {
  ACCESS_TOKEN_SECRET: "access-secret",
  REFRESH_TOKEN_SECRET: "refresh-secret",
  BETTER_AUTH_SECRET: "share-secret",
  CLOUDFLARE_ACCOUNT_ID: "test-account",
  R2_ACCESS_KEY_ID: "test-key",
  R2_SECRET_ACCESS_KEY: "test-secret",
} as unknown as Env;

type FakeBucket = R2Bucket & {
  objects: Set<string>;
  put: ReturnType<typeof vi.fn>;
};

function fakeBucket(sourceKeys: string[] = []): FakeBucket {
  const objects = new Set(sourceKeys);
  const bucket = {
    objects,
    get: vi.fn(async (key: string) => objects.has(key)
      ? {
          body: new ReadableStream(),
          httpMetadata: { contentType: "application/epub+zip" },
          customMetadata: { fixture: "share-test" },
        }
      : null),
    put: vi.fn(async (key: string) => { objects.add(key); }),
    list: vi.fn(async ({ prefix }: { prefix?: string } = {}) => ({
      objects: [...objects]
        .filter((key) => !prefix || key.startsWith(prefix))
        .map((key) => ({ key })),
      truncated: false,
    })),
    delete: vi.fn(async (keys: string | string[]) => {
      for (const key of Array.isArray(keys) ? keys : [keys]) objects.delete(key);
    }),
  } as unknown as FakeBucket;
  return bucket;
}

function testUser(id: string, name: string) {
  const now = new Date();
  return {
    id,
    name,
    email: `${id}@example.com`,
    emailVerified: true,
    createdAt: now,
    updatedAt: now,
  };
}

function testBook(
  userId: string,
  id = "book-1",
  overrides: Partial<Pick<typeof books.$inferInsert, "format" | "fileR2Key" | "coverR2Key" | "isDeleted" | "title">> = {},
): typeof books.$inferInsert {
  const now = Date.now();
  return {
    id,
    userId,
    title: "The Shared Book",
    author: "A. Reader",
    filePath: "The Shared Book.epub",
    format: "epub",
    fileR2Key: `books/${userId}/${id}.epub`,
    coverR2Key: null,
    fileHash: "book-hash",
    fileSize: 42,
    createdAt: now,
    updatedAt: now,
    isDeleted: false,
    ...overrides,
  };
}

async function authHeader(env: Env, userId: string): Promise<string> {
  return `Bearer ${await Effect.runPromise(signAccessToken(env, { userId }))}`;
}

function consentHeaders(authorization: string, includeConsent = true): HeadersInit {
  return {
    Authorization: authorization,
    "Content-Type": "application/json",
    ...(includeConsent ? { [AI_DATA_CONSENT_HEADER]: AI_DATA_CONSENT_VERSION } : {}),
  };
}

function closeD1(d1: TestD1) {
  d1.close();
}

describe("book sharing schema", () => {
  it("defines durable prepared share slots", () => {
    expect(Object.keys(shareLinkSlots)).toEqual(expect.arrayContaining([
      "id", "ownerUserId", "bookId", "access", "activePackageId", "generation", "createdAt", "updatedAt",
    ]));
  });

  it("prepares reusable public and one-time links for an owned book", async () => {
    const d1 = createTestD1();
    const db = createDb(d1);
    await db.insert(user).values(testUser("alice", "Alice")).run();
    await db.insert(books).values(testBook("alice")).run();
    const authorization = await authHeader(baseEnv, "alice");
    const response = await sharesRoutes.fetch(new Request("https://api.example.test/prepare", {
      method: "POST",
      headers: consentHeaders(authorization),
      body: JSON.stringify({ book_ids: ["book-1"] }),
    }), { ...baseEnv, DB: d1, BOOK_STORAGE: fakeBucket() } as Env);
    expect(response.status).toBe(200);
    const body = await response.json() as { links: Array<{ book_id: string; public: unknown; one_time: unknown }>; skipped: unknown[] };
    expect(body.skipped).toEqual([]);
    expect(body.links).toHaveLength(1);
    expect(body.links[0]).toEqual(expect.objectContaining({ book_id: "book-1" }));
    expect(body.links[0]?.public).toBeDefined();
    expect(body.links[0]?.one_time).toBeDefined();
    expect(await db.select().from(shareLinkSlots)).toHaveLength(2);
    closeD1(d1);
  });

  it("precreates missing links for eligible books without a user request", async () => {
    const d1 = createTestD1();
    const db = createDb(d1);
    await db.insert(user).values(testUser("alice", "Alice")).run();
    await db.insert(books).values(testBook("alice")).run();

    const result = await precreateShareLinks(db, baseEnv);

    expect(result).toEqual({ processed: 1, prepared: 1, skipped: 0 });
    expect(await db.select().from(shareLinkSlots)).toHaveLength(2);
    expect(await db.select().from(sharePackages)).toHaveLength(2);
    closeD1(d1);
  });

  it("never reuses a claimed one-time prepared link", async () => {
    const d1 = createTestD1();
    const db = createDb(d1);
    const env = { ...baseEnv, DB: d1, BOOK_STORAGE: fakeBucket(["books/alice/book-1.epub"]) } as unknown as Env;

    try {
      await db.insert(user).values([
        testUser("alice", "Alice"),
        testUser("bob", "Bob"),
        testUser("carol", "Carol"),
      ]);
      await db.insert(books).values(testBook("alice"));

      const aliceAuth = await authHeader(env, "alice");
      const prepare = () => sharesRoutes.fetch(new Request("https://api.example.test/prepare", {
        method: "POST",
        headers: consentHeaders(aliceAuth),
        body: JSON.stringify({ book_ids: ["book-1"] }),
      }), env);
      const firstResponse = await prepare();
      expect(firstResponse.status).toBe(200);
      const firstBody = await firstResponse.json() as {
        links: Array<{ one_time: { id: string; generation: number; link: string } }>;
      };
      const firstLink = firstBody.links[0]!.one_time;
      const firstToken = new URL(firstLink.link).searchParams.get("token");
      expect(firstToken).toBeTruthy();

      const bobAuth = await authHeader(env, "bob");
      const firstRedeem = await sharesRoutes.fetch(new Request("https://api.example.test/redeem", {
        method: "POST",
        headers: consentHeaders(bobAuth, false),
        body: JSON.stringify({ token: firstToken }),
      }), env);
      expect(firstRedeem.status).toBe(200);

      const secondResponse = await prepare();
      expect(secondResponse.status).toBe(200);
      const secondBody = await secondResponse.json() as typeof firstBody;
      const secondLink = secondBody.links[0]!.one_time;
      expect(secondLink.id).not.toBe(firstLink.id);
      expect(secondLink.generation).toBeGreaterThan(firstLink.generation);
      expect(secondLink.link).not.toBe(firstLink.link);

      const carolAuth = await authHeader(env, "carol");
      const oldLinkRetry = await sharesRoutes.fetch(new Request("https://api.example.test/redeem", {
        method: "POST",
        headers: consentHeaders(carolAuth, false),
        body: JSON.stringify({ token: firstToken }),
      }), env);
      expect(oldLinkRetry.status).toBe(409);
      expect(await oldLinkRetry.json()).toEqual({
        error: "SHARE_ALREADY_CLAIMED",
        code: "SHARE_ALREADY_CLAIMED",
      });
    } finally {
      closeD1(d1);
    }
  });

  it("renews an expired public request with the same stable idempotency key", async () => {
    const d1 = createTestD1();
    const db = createDb(d1);
    const env = { ...baseEnv, DB: d1, BOOK_STORAGE: fakeBucket(["books/alice/book-1.epub"]) } as unknown as Env;

    try {
      await db.insert(user).values(testUser("alice", "Alice"));
      await db.insert(books).values(testBook("alice"));
      await db.insert(sharePackages).values({
        id: "expired-public-package",
        senderUserId: "alice",
        recipientUserId: null,
        tokenHash: await hashShareToken("expired-public-token"),
        kind: "single",
        access: "public",
        status: "pending",
        idempotencyKey: "stable-public-request",
        expiresAt: new Date(Date.now() - 1_000),
        createdAt: new Date(Date.now() - 10_000),
        claimedAt: null,
        claimedBy: null,
      });
      await db.insert(sharePackageItems).values({
        id: "expired-public-item",
        packageId: "expired-public-package",
        title: "The Shared Book",
        author: "A. Reader",
        format: "epub",
        fileR2Key: "books/alice/book-1.epub",
        coverR2Key: null,
        fileHash: "book-hash",
        fileSize: 42,
        createdAt: new Date(),
      });

      const authorization = await authHeader(env, "alice");
      const response = await sharesRoutes.fetch(new Request("https://api.example.test/", {
        method: "POST",
        headers: consentHeaders(authorization),
        body: JSON.stringify({
          idempotency_key: "stable-public-request",
          kind: "single",
          book_ids: ["book-1"],
          delivery: "link",
          access: "public",
        }),
      }), env);

      expect(response.status).toBe(201);
      const body = await response.json() as { id: string; link: string };
      expect(body.id).not.toBe("expired-public-package");
      expect(await db.select().from(sharePackages).where(eq(sharePackages.id, "expired-public-package"))).toHaveLength(0);
    } finally {
      closeD1(d1);
    }
  });

  it("defines the package and item tables with the claim fields", () => {
    expect(sharePackages).toBeDefined();
    expect(sharePackageItems).toBeDefined();

    expect(Object.keys(sharePackages)).toEqual(
      expect.arrayContaining([
        "id",
        "senderUserId",
        "recipientUserId",
        "tokenHash",
        "kind",
        "access",
        "status",
        "idempotencyKey",
        "expiresAt",
        "claimedAt",
        "claimedBy",
      ]),
    );
    expect(Object.keys(sharePackageItems)).toEqual(
      expect.arrayContaining([
        "id",
        "packageId",
        "title",
        "author",
        "format",
        "fileR2Key",
        "coverR2Key",
        "fileHash",
        "fileSize",
      ]),
    );

    expect(sharePackages.recipientUserId.notNull).toBe(false);
    expect(sharePackages.tokenHash.notNull).toBe(false);
    expect(sharePackages.access.notNull).toBe(true);
    expect(sharePackageItems.author.notNull).toBe(false);
    expect(sharePackageItems.fileHash.notNull).toBe(false);
  });

  it("keeps preview public but rejects an incomplete bearer link", async () => {
    const response = await sharesRoutes.fetch(
      new Request("https://api.example.test/preview"),
      {} as Env,
    );

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({
      error: "SHARE_INVALID_REQUEST",
      code: "SHARE_INVALID_REQUEST",
    });
  });

  it("does not expose authenticated share operations without auth", async () => {
    const response = await sharesRoutes.fetch(
      new Request("https://api.example.test/redeem", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token: "token-token-token-token" }),
      }),
      {} as Env,
    );

    expect(response.status).toBe(401);
  });

  it("creates a link package from a synced book and returns the same package for a repeated idempotency key", async () => {
    const d1 = createTestD1();
    const db = createDb(d1);
    const bucket = fakeBucket(["books/alice/book-1.epub"]);
    const env = { ...baseEnv, DB: d1, BOOK_STORAGE: bucket } as unknown as Env;

    try {
      await db.insert(user).values(testUser("alice", "Alice Reader"));
      await db.insert(usernames).values({
        userId: "alice",
        username: "alice",
        createdAt: new Date(),
        updatedAt: new Date(),
      });
      await db.insert(books).values(testBook("alice"));
      const authorization = await authHeader(env, "alice");
      const requestBody = {
        idempotency_key: "request-1",
        kind: "single",
        book_ids: ["book-1"],
        delivery: "link",
        access: "one_time",
      };

      const first = await sharesRoutes.fetch(new Request("https://api.example.test/", {
        method: "POST",
        headers: consentHeaders(authorization),
        body: JSON.stringify(requestBody),
      }), env);
      const firstBody = await first.json() as {
        id: string;
        link: string;
        preview: { count: number; items: Array<{ title: string; format: string }> };
      };

      expect(first.status).toBe(201);
      expect(firstBody.preview).toMatchObject({
        count: 1,
        items: [{ title: "The Shared Book", format: "epub" }],
      });
      expect(firstBody.link).toMatch(/^https:\/\/rishi\.fidexa\.org\/sharing\/join\?token=/);
      expect(bucket.put).not.toHaveBeenCalled();
      expect((await db.select().from(sharePackageItems))[0]?.fileR2Key)
        .toBe("books/alice/book-1.epub");

      const second = await sharesRoutes.fetch(new Request("https://api.example.test/", {
        method: "POST",
        headers: consentHeaders(authorization),
        body: JSON.stringify(requestBody),
      }), env);
      const secondBody = await second.json() as typeof firstBody;

      expect(second.status).toBe(200);
      expect(secondBody.id).toBe(firstBody.id);
      expect(secondBody.link).toBe(firstBody.link);
      expect(bucket.put).not.toHaveBeenCalled();
      expect(await db.select().from(sharePackages)).toHaveLength(1);
      expect(await db.select().from(sharePackageItems)).toHaveLength(1);
    } finally {
      closeD1(d1);
    }
  });

  it("rejects the removed username and inbox contracts", async () => {
    const d1 = createTestD1();
    const db = createDb(d1);
    const bucket = fakeBucket();
    const env = { ...baseEnv, DB: d1, BOOK_STORAGE: bucket } as unknown as Env;

    try {
      await db.insert(user).values(testUser("alice", "Alice Reader"));
      const senderAuth = await authHeader(env, "alice");
      const createResponse = await sharesRoutes.fetch(new Request("https://api.example.test/", {
        method: "POST",
        headers: consentHeaders(senderAuth),
        body: JSON.stringify({
          idempotency_key: "username-request-1",
          kind: "single",
          book_ids: ["book-1"],
          delivery: "username",
          recipient_username: "bob",
        }),
      }), env);
      expect(createResponse.status).toBe(400);
      const inbox = await sharesRoutes.fetch(new Request("https://api.example.test/inbox", {
        headers: consentHeaders(senderAuth),
      }), env);
      expect(inbox.status).toBe(404);
    } finally {
      closeD1(d1);
    }
  });

  it("claims a bearer package once, is idempotent for the same user, and rejects a different claimant", async () => {
    const d1 = createTestD1();
    const db = createDb(d1);
    const bucket = fakeBucket(["books/alice/book-1.epub"]);
    const env = { ...baseEnv, DB: d1, BOOK_STORAGE: bucket } as unknown as Env;

    try {
      await db.insert(user).values([
        testUser("alice", "Alice Reader"),
        testUser("bob", "Bob Reader"),
        testUser("carol", "Carol Reader"),
        testUser("dave", "Dave Reader"),
      ]);
      await db.insert(usernames).values([
        "alice",
        "bob",
        "carol",
      ].map((username) => ({
        userId: username,
        username,
        createdAt: new Date(),
        updatedAt: new Date(),
      })));
      await db.insert(books).values([
        testBook("alice"),
        testBook("bob", "bob-book"),
      ]);
      const senderAuth = await authHeader(env, "alice");
      const createResponse = await sharesRoutes.fetch(new Request("https://api.example.test/", {
        method: "POST",
        headers: consentHeaders(senderAuth),
        body: JSON.stringify({
          idempotency_key: "bearer-request-1",
          kind: "single",
          book_ids: ["book-1"],
          delivery: "link",
          access: "one_time",
        }),
      }), env);
      const created = await createResponse.json() as { link: string; id: string };
      const token = new URL(created.link).searchParams.get("token");
      expect(token).toBeTruthy();

      const creatorAuth = await authHeader(env, "alice");
      const creatorRedeem = await sharesRoutes.fetch(new Request("https://api.example.test/redeem", {
        method: "POST",
        headers: consentHeaders(creatorAuth),
        body: JSON.stringify({ token }),
      }), env);
      expect(creatorRedeem.status).toBe(200);
      expect(await creatorRedeem.json()).toEqual({ id: created.id, items: [] });
      expect((await db.select().from(sharePackages))[0]?.status).toBe("pending");

      const bobAuth = await authHeader(env, "bob");
      const packageAccept = await sharesRoutes.fetch(new Request(`https://api.example.test/${created.id}/accept`, {
        method: "POST",
        headers: consentHeaders(bobAuth),
      }), env);
      expect(packageAccept.status).toBe(404);

      const redeem = () => sharesRoutes.fetch(new Request("https://api.example.test/redeem", {
        method: "POST",
        headers: consentHeaders(bobAuth),
        body: JSON.stringify({ token }),
      }), env);
      const first = await redeem();
      expect(first.status).toBe(200);
      expect(await first.json()).toEqual({ id: created.id, items: [] });
      expect((await db.select().from(sharePackages))[0]?.status).toBe("pending");

      const carolAuth = await authHeader(env, "carol");
      const carolRedeem = await sharesRoutes.fetch(new Request("https://api.example.test/redeem", {
        method: "POST",
        headers: consentHeaders(carolAuth),
        body: JSON.stringify({ token }),
      }), env);
      expect(carolRedeem.status).toBe(200);
      const carolBody = await carolRedeem.json();
      expect(carolBody).toMatchObject({ id: created.id, items: [{ title: "The Shared Book" }] });

      const repeated = await sharesRoutes.fetch(new Request("https://api.example.test/redeem", {
        method: "POST",
        headers: consentHeaders(carolAuth),
        body: JSON.stringify({ token }),
      }), env);
      expect(repeated.status).toBe(200);
      expect(await repeated.json()).toEqual(carolBody);

      const daveAuth = await authHeader(env, "dave");
      const crossUser = await sharesRoutes.fetch(new Request("https://api.example.test/redeem", {
        method: "POST",
        headers: consentHeaders(daveAuth),
        body: JSON.stringify({ token }),
      }), env);
      expect(crossUser.status).toBe(409);
      expect(await crossUser.json()).toEqual({
        error: "SHARE_ALREADY_CLAIMED",
        code: "SHARE_ALREADY_CLAIMED",
      });
    } finally {
      closeD1(d1);
    }
  });

  it("allows exactly one winner when two users redeem the same one-time link concurrently", async () => {
    const d1 = createTestD1();
    const db = createDb(d1);
    const bucket = fakeBucket(["books/alice/book-1.epub"]);
    const env = { ...baseEnv, DB: d1, BOOK_STORAGE: bucket } as unknown as Env;

    try {
      await db.insert(user).values([
        testUser("alice", "Alice Reader"),
        testUser("bob", "Bob Reader"),
        testUser("carol", "Carol Reader"),
      ]);
      await db.insert(books).values(testBook("alice"));
      const senderAuth = await authHeader(env, "alice");
      const createdResponse = await sharesRoutes.fetch(new Request("https://api.example.test/", {
        method: "POST",
        headers: consentHeaders(senderAuth),
        body: JSON.stringify({
          idempotency_key: "concurrent-request",
          kind: "single",
          book_ids: ["book-1"],
          delivery: "link",
          access: "one_time",
        }),
      }), env);
      const created = await createdResponse.json() as { id: string; link: string };
      const token = new URL(created.link).searchParams.get("token");
      const bobAuth = await authHeader(env, "bob");
      const carolAuth = await authHeader(env, "carol");
      const redeem = (authorization: string) => sharesRoutes.fetch(new Request("https://api.example.test/redeem", {
        method: "POST",
        headers: consentHeaders(authorization),
        body: JSON.stringify({ token }),
      }), env);

      const responses = await Promise.all([redeem(bobAuth), redeem(carolAuth)]);
      expect(responses.map((response) => response.status).sort()).toEqual([200, 409]);
      expect((await db.select().from(sharePackages))[0]?.claimedBy).toMatch(/^(bob|carol)$/);
    } finally {
      closeD1(d1);
    }
  });

  it("allows different users to redeem a public link and is idempotent per user", async () => {
    const d1 = createTestD1();
    const db = createDb(d1);
    const bucket = fakeBucket(["books/alice/book-1.epub"]);
    const env = { ...baseEnv, DB: d1, BOOK_STORAGE: bucket } as unknown as Env;

    try {
      await db.insert(user).values([
        testUser("alice", "Alice Reader"),
        testUser("bob", "Bob Reader"),
        testUser("carol", "Carol Reader"),
      ]);
      await db.insert(books).values([
        testBook("alice"),
        testBook("bob", "bob-book"),
      ]);
      const senderAuth = await authHeader(env, "alice");
      const createdResponse = await sharesRoutes.fetch(new Request("https://api.example.test/", {
        method: "POST",
        headers: consentHeaders(senderAuth),
        body: JSON.stringify({
          idempotency_key: "public-request",
          kind: "single",
          book_ids: ["book-1"],
          delivery: "link",
          access: "public",
        }),
      }), env);
      expect(createdResponse.status).toBe(201);
      const created = await createdResponse.json() as { id: string; link: string };
      const token = new URL(created.link).searchParams.get("token");
      const redeem = (authorization: string) => sharesRoutes.fetch(new Request("https://api.example.test/redeem", {
        method: "POST",
        headers: consentHeaders(authorization),
        body: JSON.stringify({ token }),
      }), env);

      const senderSelfRedeem = await redeem(senderAuth);
      expect(senderSelfRedeem.status).toBe(200);
      expect(await senderSelfRedeem.json()).toEqual({ id: created.id, items: [] });
      expect(await db.select().from(sharePackageRedemptions)).toHaveLength(0);

      const bobAuth = await authHeader(env, "bob");
      const carolAuth = await authHeader(env, "carol");
      const [bobFirst, carolFirst] = await Promise.all([redeem(bobAuth), redeem(carolAuth)]);
      expect(bobFirst.status).toBe(200);
      expect(await bobFirst.json()).toMatchObject({ id: created.id, items: [] });
      expect(carolFirst.status).toBe(200);
      const carolBody = await carolFirst.json() as {
        id: string;
        items: Array<{ id: string; title: string }>;
      };
      expect(carolBody.items).toHaveLength(1);
      const carolRetry = await redeem(carolAuth);
      expect(carolRetry.status).toBe(200);
      const carolRetryBody = await carolRetry.json() as typeof carolBody;
      expect(carolRetryBody.id).toBe(carolBody.id);
      expect(carolRetryBody.items).toHaveLength(carolBody.items.length);
      expect(carolRetryBody.items[0]).toMatchObject({
        id: carolBody.items[0].id,
        title: carolBody.items[0].title,
      });
      expect(await db.select().from(sharePackageRedemptions)).toHaveLength(1);
    } finally {
      closeD1(d1);
    }
  });

  it("rejects cross-user, unsupported, and unsynced source books without creating a package", async () => {
    const d1 = createTestD1();
    const db = createDb(d1);
    const bucket = fakeBucket(["books/alice/book-1.epub"]);
    const env = { ...baseEnv, DB: d1, BOOK_STORAGE: bucket } as unknown as Env;

    try {
      await db.insert(user).values([testUser("alice", "Alice Reader"), testUser("bob", "Bob Reader")]);
      await db.insert(books).values([
        testBook("alice", "book-1"),
        testBook("bob", "book-2"),
        testBook("alice", "book-3", { format: "txt" }),
        testBook("alice", "book-4", { fileR2Key: null }),
      ]);
      const authorization = await authHeader(env, "alice");
      for (const bookID of ["book-2", "book-3", "book-4"]) {
        const response = await sharesRoutes.fetch(new Request("https://api.example.test/", {
          method: "POST",
          headers: consentHeaders(authorization),
          body: JSON.stringify({
            idempotency_key: `not-ready-${bookID}`,
          kind: "single",
          book_ids: [bookID],
          delivery: "link",
          access: "one_time",
          }),
        }), env);
        expect(response.status).toBe(422);
        expect(await response.json()).toEqual({ error: "SHARE_BOOK_NOT_READY", code: "SHARE_BOOK_NOT_READY" });
      }
      expect(await db.select().from(sharePackages)).toHaveLength(0);
    } finally {
      closeD1(d1);
    }
  });

  it("preserves a multi-book snapshot and exposes only metadata in public preview", async () => {
    const d1 = createTestD1();
    const db = createDb(d1);
    const bucket = fakeBucket([
      "books/alice/book-1.epub",
      "books/alice/book-2.epub",
      "covers/alice/book-2.jpg",
    ]);
    const env = { ...baseEnv, DB: d1, BOOK_STORAGE: bucket } as unknown as Env;

    try {
      await db.insert(user).values(testUser("alice", "Alice Reader"));
      await db.insert(books).values([
        testBook("alice", "book-1"),
        testBook("alice", "book-2", { coverR2Key: "covers/alice/book-2.jpg" }),
      ]);
      const authorization = await authHeader(env, "alice");
      const response = await sharesRoutes.fetch(new Request("https://api.example.test/", {
        method: "POST",
        headers: consentHeaders(authorization),
        body: JSON.stringify({
          idempotency_key: "selection-request",
          kind: "selection",
          book_ids: ["book-1", "book-2"],
          delivery: "link",
          access: "one_time",
        }),
      }), env);
      const body = await response.json() as { id: string; link: string; preview: { count: number } };
      expect(response.status).toBe(201);
      expect(body.preview.count).toBe(2);
      expect(bucket.put).not.toHaveBeenCalled();

      const preview = await sharesRoutes.fetch(new Request(`https://api.example.test/preview?token=${encodeURIComponent(new URL(body.link).searchParams.get("token")!)}`), env);
      const previewBody = await preview.json() as { count: number; items: Array<Record<string, unknown>> };
      expect(preview.status).toBe(200);
      expect(previewBody.count).toBe(2);
      expect(previewBody.items.every((item) => !("file_url" in item))).toBe(true);
    } finally {
      closeD1(d1);
    }
  });

  it("returns SHARE_EXPIRED for an expired bearer package", async () => {
    const d1 = createTestD1();
    const db = createDb(d1);
    const sourceKey = "books/alice/expired-book.epub";
    const bucket = fakeBucket([sourceKey]);
    const env = { ...baseEnv, DB: d1, BOOK_STORAGE: bucket } as unknown as Env;
    const token = "expired-share-token-1234567890";

    try {
      await db.insert(user).values([
        testUser("alice", "Alice Reader"),
        testUser("bob", "Bob Reader"),
      ]);
      await db.insert(usernames).values(["alice", "bob"].map((username) => ({
        userId: username,
        username,
        createdAt: new Date(),
        updatedAt: new Date(),
      })));
      await db.insert(books).values(testBook("alice", "expired-book", { fileR2Key: sourceKey }));
      await db.insert(sharePackages).values({
        id: "expired-package",
        senderUserId: "alice",
        recipientUserId: null,
        tokenHash: await hashShareToken(token),
        kind: "single",
        access: "one_time",
        status: "pending",
        idempotencyKey: "expired-request",
        expiresAt: new Date(Date.now() - 10_000),
        createdAt: new Date(Date.now() - 10_000),
        claimedAt: null,
        claimedBy: null,
      });
      await db.insert(sharePackageItems).values({
        id: "expired-item",
        packageId: "expired-package",
        title: "Expired Book",
        author: "A. Reader",
        format: "epub",
        fileR2Key: sourceKey,
        coverR2Key: null,
        fileHash: null,
        fileSize: 42,
        createdAt: new Date(),
      });

      const authorization = await authHeader(env, "bob");
      const response = await sharesRoutes.fetch(new Request("https://api.example.test/redeem", {
        method: "POST",
        headers: consentHeaders(authorization),
        body: JSON.stringify({ token }),
      }), env);

      expect(response.status).toBe(410);
      expect(await response.json()).toEqual({
        error: "SHARE_EXPIRED",
        code: "SHARE_EXPIRED",
      });
      expect((await db.select().from(sharePackages).where(eq(sharePackages.id, "expired-package")))[0]?.status)
        .toBe("expired");
      expect(await purgeExpiredShares(db, bucket)).toBe(1);
      expect(await db.select().from(sharePackages).where(eq(sharePackages.id, "expired-package"))).toHaveLength(0);
      expect(bucket.objects.has(sourceKey)).toBe(true);
    } finally {
      closeD1(d1);
    }
  });

  it("rejects every authenticated share operation without current data-use consent", async () => {
    const d1 = createTestD1();
    const db = createDb(d1);
    const env = { ...baseEnv, DB: d1, BOOK_STORAGE: fakeBucket() } as unknown as Env;

    try {
      await db.insert(user).values([
        testUser("alice", "Alice Reader"),
        testUser("bob", "Bob Reader"),
      ]);
      await db.insert(usernames).values(["alice", "bob"].map((username) => ({
        userId: username,
        username,
        createdAt: new Date(),
        updatedAt: new Date(),
      })));
      await db.insert(sharePackages).values({
        id: "consent-package",
        senderUserId: "alice",
        recipientUserId: "bob",
        tokenHash: await hashShareToken("consent-share-token-1234567890"),
        kind: "single",
        status: "pending",
        idempotencyKey: "consent-request",
        expiresAt: new Date(Date.now() + 60_000),
        createdAt: new Date(),
        claimedAt: null,
        claimedBy: null,
      });
      const authorization = await authHeader(env, "bob");
      const headers = consentHeaders(authorization, false);

      const requests = [
        new Request("https://api.example.test/", {
          method: "POST",
          headers,
          body: JSON.stringify({
            idempotency_key: "new-consent-request",
          kind: "single",
          book_ids: ["book-1"],
          delivery: "link",
          access: "one_time",
          }),
        }),
        new Request("https://api.example.test/redeem", {
          method: "POST",
          headers,
          body: JSON.stringify({ token: "consent-share-token-1234567890" }),
        }),
      ];

      const createResponse = await sharesRoutes.fetch(requests[0]!, env);
      expect(createResponse.status).toBe(428);
      expect(await createResponse.json()).toEqual({ error: "AI_DATA_CONSENT_REQUIRED" });

      const redeemResponse = await sharesRoutes.fetch(requests[1]!, env);
      expect(redeemResponse.status).toBe(200);
      expect(await redeemResponse.json()).toEqual({ id: "consent-package", items: [] });
    } finally {
      closeD1(d1);
    }
  });

  it("allows a recipient to redeem an explicitly shared one-time book without AI consent", async () => {
    const d1 = createTestD1();
    const db = createDb(d1);
    const env = { ...baseEnv, DB: d1, BOOK_STORAGE: fakeBucket() } as unknown as Env;

    try {
      await db.insert(user).values([
        testUser("alice", "Alice Reader"),
        testUser("bob", "Bob Reader"),
      ]);
      const token = "private-share-token-without-consent";
      await db.insert(sharePackages).values({
        id: "private-consent-free-package",
        senderUserId: "alice",
        recipientUserId: null,
        tokenHash: await hashShareToken(token),
        kind: "single",
        access: "one_time",
        status: "pending",
        idempotencyKey: "private-consent-free-request",
        expiresAt: new Date(Date.now() + 60_000),
        createdAt: new Date(),
        claimedAt: null,
        claimedBy: null,
      });
      await db.insert(sharePackageItems).values({
        id: "private-consent-free-item",
        packageId: "private-consent-free-package",
        title: "Shared Book",
        author: "Alice Reader",
        format: "epub",
        fileSize: 1,
        fileHash: "shared-book-hash",
        fileR2Key: "books/alice/shared-book.epub",
        coverR2Key: null,
        createdAt: new Date(),
      });

      const authorization = await authHeader(env, "bob");
      const response = await sharesRoutes.fetch(new Request("https://api.example.test/redeem", {
        method: "POST",
        headers: consentHeaders(authorization, false),
        body: JSON.stringify({ token }),
      }), env);

      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({
        id: "private-consent-free-package",
        items: [{ id: "private-consent-free-item", title: "Shared Book" }],
      });
    } finally {
      closeD1(d1);
    }
  });
});

import { describe, expect, it, vi } from "vitest";

import { createDb } from "./db/drizzle";
import { books, deletionState, sessionInviteItems, sessionInvites, sharePackageItems, sharePackages, user } from "./db/schema";
import { createTestD1, type TestD1 } from "./test-utils/d1";
import {
  ACCOUNT_R2_CHECKPOINT_PREFIX,
  reconcileAccountR2Page,
  type AccountR2Prefix,
  type AccountR2SweepError,
  type AccountR2SweepResult,
} from "./account-r2-reconciliation";

type StoredObject = { body: string; etag: string };
type StoredCheckpoint = {
  version: 1;
  revision: string;
  cursor: string | null;
  cycleStartedAt: number;
  cycleCompletedAt: number | null;
};

function fakeBucket(initialKeys: string[] = []) {
  const objects = new Map<string, StoredObject>(initialKeys.map((key, index) => [key, {
    body: `object-${index}`,
    etag: `object-etag-${index}`,
  }]));
  let etagCounter = 0;
  let cursorCounter = 0;
  const cursorBoundaries = new Map<string, string>();
  const bucket = {
    objects,
    cursorBoundaries,
    list: vi.fn(async ({ prefix, cursor, limit }: { prefix?: string; cursor?: string; limit?: number } = {}) => {
      const keys = [...objects.keys()]
        .filter((key) => !prefix || key.startsWith(prefix))
        .sort();
      const boundary = cursor ? cursorBoundaries.get(cursor) : undefined;
      if (cursor && !boundary) throw new Error("unknown opaque cursor");
      const eligible = boundary ? keys.filter((key) => key > boundary) : keys;
      const page = eligible.slice(0, limit ?? 1000);
      const truncated = page.length < eligible.length;
      let nextCursor: string | undefined;
      if (truncated) {
        nextCursor = `opaque-cursor-${++cursorCounter}`;
        cursorBoundaries.set(nextCursor, page[page.length - 1]);
      }
      return {
        objects: page.map((key) => ({ key })),
        truncated,
        cursor: nextCursor,
      };
    }),
    head: vi.fn(async (key: string) => {
      const object = objects.get(key);
      return object ? { key, etag: object.etag } : null;
    }),
    get: vi.fn(async (key: string) => {
      const object = objects.get(key);
      return object ? { key, etag: object.etag, text: async () => object.body } : null;
    }),
    put: vi.fn(async (key: string, value: string, options?: { onlyIf?: { etagMatches?: string; etagDoesNotMatch?: string } }) => {
      const current = objects.get(key);
      const onlyIf = options?.onlyIf;
      if (onlyIf?.etagMatches !== undefined && current?.etag !== onlyIf.etagMatches) return null;
      if (onlyIf?.etagDoesNotMatch === "*" && current) return null;
      const etag = `checkpoint-etag-${++etagCounter}`;
      objects.set(key, { body: value, etag });
      return { key, etag };
    }),
    delete: vi.fn(async (key: string) => {
      objects.delete(key);
    }),
  };
  return bucket;
}

function fixture() {
  const d1 = createTestD1();
  return { d1, db: createDb(d1) };
}

async function addUser(db: ReturnType<typeof createDb>, id: string) {
  const now = new Date();
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: true, createdAt: now, updatedAt: now });
}

function close(d1: TestD1) {
  d1.close();
}

function checkpoint(bucket: ReturnType<typeof fakeBucket>, prefix: AccountR2Prefix): StoredCheckpoint | undefined {
  const raw = bucket.objects.get(`${ACCOUNT_R2_CHECKPOINT_PREFIX}${prefix.slice(0, -1)}.json`)?.body;
  return raw ? JSON.parse(raw) as StoredCheckpoint : undefined;
}

describe("account R2 reconciliation", () => {
  it("[W4R-LATE] deletes a post-cascade late arrival for an absent owner", async () => {
    const { d1, db } = fixture();
    const bucket = fakeBucket(["books/gone/late.epub"]);

    const result: AccountR2SweepResult = await reconcileAccountR2Page(
      db,
      bucket as unknown as R2Bucket,
      "books/",
      1000,
    );

    expect(bucket.objects.has("books/gone/late.epub")).toBe(false);
    expect(result).toEqual({
      prefix: "books/",
      scanned: 1,
      deleted: 1,
      cycleCompleted: true,
      checkpoint: "advanced",
    });
    close(d1);
  });

  it("[W4R-BEHIND] resets the cursor at cycle completion so earlier arrivals are found", async () => {
    const { d1, db } = fixture();
    const bucket = fakeBucket(["books/gone/a.epub"]);
    await reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 1000);
    expect(checkpoint(bucket, "books/")?.cursor).toBeNull();
    bucket.objects.set("books/gone/0-before.epub", { body: "late", etag: "late" });

    await reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 2000);

    expect(bucket.objects.has("books/gone/0-before.epub")).toBe(false);
    close(d1);
  });

  it("[W4R-OVERWRITE] deletes an orphan recreated at the same key in a later cycle", async () => {
    const { d1, db } = fixture();
    const key = "books/gone/book.epub";
    const bucket = fakeBucket([key]);
    await reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 1000);
    expect(bucket.objects.has(key)).toBe(false);
    bucket.objects.set(key, { body: "overwritten", etag: "replacement-etag" });

    const result = await reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 2000);

    expect(bucket.objects.has(key)).toBe(false);
    expect(bucket.delete).toHaveBeenCalledTimes(2);
    expect(result.cycleCompleted).toBe(true);
    close(d1);
  });

  it("[W4R-LIVE] protects a live owner with no book row", async () => {
    const { d1, db } = fixture();
    const bucket = fakeBucket(["books/alice/orphan.epub"]);
    await addUser(db, "alice");

    await reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 1000);

    expect(bucket.objects.has("books/alice/orphan.epub")).toBe(true);
    close(d1);
  });

  it("[W4R-DELETING] protects an owner while the deletion fence is present", async () => {
    const { d1, db } = fixture();
    const bucket = fakeBucket(["books/alice/orphan.epub"]);
    await addUser(db, "alice");
    const now = new Date();
    await db.insert(deletionState).values({
      userId: "alice", deletionId: "deletion-1", ledgerName: "alice", status: "purging",
      retryAt: now, createdAt: now, updatedAt: now,
    });

    await reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 1000);

    expect(bucket.objects.has("books/alice/orphan.epub")).toBe(true);
    close(d1);
  });

  it("[W4R-KEYS] only considers literal owner descendants under the selected prefix", async () => {
    const { d1, db } = fixture();
    const invalid = ["books/gone", "books//empty-owner.epub", "books/gone/"];
    const valid = "books/gone/valid.epub";
    const bucket = fakeBucket([...invalid, valid]);

    await reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 1000);

    expect(bucket.objects.has(valid)).toBe(false);
    expect(invalid.every((key) => bucket.objects.has(key))).toBe(true);
    close(d1);
  });

  it("[W4R-REFS] preserves active books, share packages, and session invite items", async () => {
    const { d1, db } = fixture();
    const keys = ["books/gone/library.epub", "books/gone/share.epub", "books/gone/session.epub"];
    const bucket = fakeBucket(keys);
    await addUser(db, "ref-owner");
    await db.insert(books).values({
      id: "book-1", userId: null, title: "Book", author: "Author", filePath: "book.epub", format: "epub",
      fileR2Key: keys[0], coverR2Key: null, fileSize: 1, createdAt: 1, updatedAt: 1, isDeleted: false,
    });
    await db.insert(sharePackages).values({
      id: "package-1", senderUserId: "ref-owner", recipientUserId: null, tokenHash: null, kind: "single",
      access: "one_time", status: "pending", idempotencyKey: "key-1", expiresAt: new Date(1000), createdAt: new Date(1), claimedAt: null, claimedBy: null,
    });
    await db.insert(sharePackageItems).values({
      id: "share-item-1", packageId: "package-1", title: "Book", author: "Author", format: "epub", fileR2Key: keys[1], coverR2Key: null, fileSize: 1, createdAt: new Date(1),
    });
    await db.insert(sessionInvites).values({
      id: "invite-1", ownerUserId: "ref-owner", idempotencyKey: "invite-key", sessionId: "session-1", sourceBookId: "book-1",
      contentHash: "hash", format: "epub", tokenHash: "token", status: "open", createdAt: new Date(1), endedAt: null,
    });
    await db.insert(sessionInviteItems).values({
      id: "session-item-1", inviteId: "invite-1", fileR2Key: keys[2], coverR2Key: null, fileHash: "hash", fileSize: 1, createdAt: new Date(1),
    });

    await reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 1000);

    expect(keys.every((key) => bucket.objects.has(key))).toBe(true);
    close(d1);
  });

  it("[W4R-LIMIT] lists and processes at most 100 objects", async () => {
    const { d1, db } = fixture();
    const keys = Array.from({ length: 101 }, (_, index) => `books/gone/${String(index).padStart(3, "0")}.epub`);
    const bucket = fakeBucket(keys);

    await reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 1000);

    expect(bucket.list).toHaveBeenCalledWith({ prefix: "books/", limit: 100 });
    expect(bucket.delete).toHaveBeenCalledTimes(100);
    expect(bucket.objects.has(keys[100])).toBe(true);
    close(d1);
  });

  it("[W4R-RESTART] resumes a partial page after a fresh process", async () => {
    const { d1, db } = fixture();
    const bucket = fakeBucket(Array.from({ length: 101 }, (_, index) => `books/gone/${String(index).padStart(3, "0")}.epub`));
    await reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 1000);
    const opaqueCursor = checkpoint(bucket, "books/")?.cursor;
    expect(opaqueCursor).toMatch(/^opaque-cursor-/);
    const resumed = await reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 2000);

    expect(resumed.deleted).toBe(1);
    expect(bucket.list).toHaveBeenNthCalledWith(2, { prefix: "books/", limit: 100, cursor: opaqueCursor });
    expect([...bucket.objects.keys()].filter((key) => key.startsWith("books/"))).toHaveLength(0);
    close(d1);
  });

  it("[W4R-MALFORMED] fails closed and conditionally resets malformed checkpoint state", async () => {
    const { d1, db } = fixture();
    const bucket = fakeBucket(["books/gone/orphan.epub"]);
    const key = `${ACCOUNT_R2_CHECKPOINT_PREFIX}books.json`;
    bucket.objects.set(key, { body: JSON.stringify({ version: 99, ownerId: "must-not-persist" }), etag: "bad-etag" });

    await expect(reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 1000))
      .rejects.toMatchObject({ code: "ACCOUNT_R2_SWEEP_FAILED", phase: "checkpoint", retryable: true });

    expect(bucket.objects.has("books/gone/orphan.epub")).toBe(true);
    expect(bucket.put).toHaveBeenCalledWith(key, expect.any(String), expect.objectContaining({ onlyIf: { etagMatches: "bad-etag" } }));
    close(d1);
  });

  it("[W4R-DELETE] does not advance the checkpoint after a delete failure and replays safely", async () => {
    const { d1, db } = fixture();
    const bucket = fakeBucket(["books/gone/a.epub", "books/gone/b.epub"]);
    bucket.delete.mockImplementationOnce(async (key: string) => {
      bucket.objects.delete(key);
      throw new Error("delete failed after partial success");
    });

    await expect(reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 1000))
      .rejects.toMatchObject({ code: "ACCOUNT_R2_SWEEP_FAILED", phase: "delete", retryable: true });
    expect(checkpoint(bucket, "books/")).toBeUndefined();
    await reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 2000);
    expect(bucket.objects.has("books/gone/a.epub")).toBe(false);
    expect(bucket.objects.has("books/gone/b.epub")).toBe(false);
    close(d1);
  });

  it("[W4R-CAS] reports checkpoint contention without overwriting another writer", async () => {
    const { d1, db } = fixture();
    const bucket = fakeBucket(["books/gone/a.epub"]);
    bucket.put.mockImplementationOnce(async () => null);

    await expect(reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 1000))
      .resolves.toMatchObject({ checkpoint: "contended", cycleCompleted: true });
    await expect(reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 2000)).resolves.toMatchObject({ deleted: 0 });
    close(d1);
  });

  it("[W4R-WRAP] completes and starts a new cycle without retaining a stale cursor", async () => {
    const { d1, db } = fixture();
    const bucket = fakeBucket(["books/gone/a.epub"]);
    await reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 1000);
    const first = checkpoint(bucket, "books/");
    for (let index = 0; index < 101; index += 1) {
      const key = `books/gone/${String(index).padStart(3, "0")}.epub`;
      bucket.objects.set(key, { body: key, etag: `cycle-2-${index}` });
    }
    await reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 2000);
    const second = checkpoint(bucket, "books/");

    expect(first?.cursor).toBeNull();
    expect(second?.cursor).toMatch(/^opaque-cursor-/);
    expect(typeof first?.revision).toBe("string");
    expect(second?.revision).not.toBe(first?.revision);
    expect(second?.cycleStartedAt).toBe(2000);
    expect(second?.cycleCompletedAt).toBe(1000);

    const final = await reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 3000);
    expect(final.cycleCompleted).toBe(true);
    expect(checkpoint(bucket, "books/")?.cycleCompletedAt).toBe(3000);
    close(d1);
  });

  it("[W4R-ERROR] exposes retryable phased sweep errors", async () => {
    const { d1, db } = fixture();
    const bucket = fakeBucket();
    bucket.list.mockRejectedValueOnce(new Error("list unavailable"));

    let caught: AccountR2SweepError | undefined;
    try {
      await reconcileAccountR2Page(db, bucket as unknown as R2Bucket, "books/", 1000);
    } catch (error) {
      caught = error as AccountR2SweepError;
    }

    expect(caught).toMatchObject({
      code: "ACCOUNT_R2_SWEEP_FAILED",
      phase: "list",
      retryable: true,
    });
    close(d1);
  });
});

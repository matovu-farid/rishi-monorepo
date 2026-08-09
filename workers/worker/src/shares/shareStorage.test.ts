import { describe, expect, it, vi } from "vitest";

import { createDb } from "../db/drizzle";
import { books, sharePackageItems, sharePackages, user } from "../db/schema";
import { createTestD1 } from "../test-utils/d1";
import { deleteUnreferencedR2Objects } from "./shareReferences";

function bucketWithObjects(initial: string[]) {
  const objects = new Set(initial);
  return {
    delete: vi.fn(async (keys: string | string[]) => {
      for (const key of Array.isArray(keys) ? keys : [keys]) objects.delete(key);
    }),
    has(key: string) { return objects.has(key); },
  };
}

describe("share R2 storage", () => {
  it("keeps a source object while its library book is active", async () => {
    const d1 = createTestD1();
    const db = createDb(d1);
    const sourceKey = "books/alice/book.epub";
    const bucket = bucketWithObjects([sourceKey]);
    await db.insert(user).values({
      id: "alice",
      name: "Alice",
      email: "alice@example.com",
      emailVerified: true,
      createdAt: new Date(),
      updatedAt: new Date(),
    });
    await db.insert(sharePackages).values({
      id: "share-package-1",
      senderUserId: "alice",
      recipientUserId: null,
      tokenHash: null,
      kind: "single",
      status: "pending",
      idempotencyKey: "share-request-1",
      expiresAt: new Date(Date.now() + 60_000),
      createdAt: new Date(),
      claimedAt: null,
      claimedBy: null,
    });
    await db.insert(books).values({
      id: "book-1",
      userId: "alice",
      title: "Book",
      author: "Author",
      filePath: "book.epub",
      format: "epub",
      fileR2Key: sourceKey,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      isDeleted: false,
    });

    await expect(deleteUnreferencedR2Objects(db, bucket as unknown as R2Bucket, [sourceKey]))
      .resolves.toEqual([]);
    expect(bucket.has(sourceKey)).toBe(true);
    d1.close();
  });

  it("deletes a source object only after the library and share references are gone", async () => {
    const d1 = createTestD1();
    const db = createDb(d1);
    const sourceKey = "books/alice/book.epub";
    const bucket = bucketWithObjects([sourceKey]);
    await db.insert(user).values({
      id: "alice",
      name: "Alice",
      email: "alice@example.com",
      emailVerified: true,
      createdAt: new Date(),
      updatedAt: new Date(),
    });
    await db.insert(sharePackages).values({
      id: "share-package-1",
      senderUserId: "alice",
      recipientUserId: null,
      tokenHash: null,
      kind: "single",
      status: "pending",
      idempotencyKey: "share-request-1",
      expiresAt: new Date(Date.now() + 60_000),
      createdAt: new Date(),
      claimedAt: null,
      claimedBy: null,
    });
    await db.insert(sharePackageItems).values({
      id: "share-item-1",
      packageId: "share-package-1",
      title: "Book",
      author: "Author",
      format: "epub",
      fileR2Key: sourceKey,
      coverR2Key: null,
      fileHash: null,
      fileSize: 1,
      createdAt: new Date(),
    });

    await expect(deleteUnreferencedR2Objects(db, bucket as unknown as R2Bucket, [sourceKey]))
      .resolves.toEqual([]);
    expect(bucket.has(sourceKey)).toBe(true);

    await db.delete(sharePackageItems);
    await expect(deleteUnreferencedR2Objects(db, bucket as unknown as R2Bucket, [sourceKey]))
      .resolves.toEqual([sourceKey]);
    expect(bucket.has(sourceKey)).toBe(false);
    d1.close();
  });
});

import { describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { getTableConfig } from "drizzle-orm/sqlite-core";
import { createDb, type WorkerDb } from "./drizzle";
import { createTestD1 } from "../test-utils/d1";
import * as schema from "./schema";

type Table = Parameters<typeof getTableConfig>[0];

function table(name: string): Table {
  const candidate = (schema as unknown as Record<string, unknown>)[name];
  if (!candidate) throw new Error(`Missing schema export: ${name}`);
  return candidate as Table;
}

function columnNames(target: Table) {
  return getTableConfig(target).columns.map((column) => column.name).sort();
}

function indexShape(target: Table) {
  return getTableConfig(target).indexes.map((index) => ({
    name: index.config.name,
    unique: index.config.unique,
    columns: index.config.columns.map((column) => (column as { name?: string }).name ?? ""),
  }));
}

function foreignKeys(target: Table) {
  return getTableConfig(target).foreignKeys.map((foreignKey) => ({
    table: foreignKey.reference().foreignTable,
    onDelete: foreignKey.onDelete,
  }));
}

async function seedUser(db: WorkerDb, id: string, email: string) {
  await db.insert(schema.user).values({
    id,
    name: id,
    email,
    emailVerified: true,
    createdAt: new Date(1),
    updatedAt: new Date(1),
  });
}

async function seedBook(db: WorkerDb, id: string, userId: string) {
  await db.insert(schema.books).values({
    id,
    userId,
    title: "Shared book",
    author: "Author",
    filePath: "/books/shared.epub",
    format: "epub",
    createdAt: 1,
    updatedAt: 1,
  });
}

async function seedInvite(
  db: WorkerDb,
  id: string,
  ownerUserId: string,
  sourceBookId: string,
  idempotencyKey = `request-${id}`,
) {
  await db.insert(schema.sessionInvites).values({
    id,
    ownerUserId,
    sessionId: `session-${id}`,
    sourceBookId,
    contentHash: "hash-1",
    format: "epub",
    tokenHash: `token-${id}`,
    idempotencyKey,
    status: "open",
    createdAt: new Date(1),
  });
}

async function seedInviteItem(db: WorkerDb, id: string, inviteId: string) {
  await db.insert(schema.sessionInviteItems).values({
    id,
    inviteId,
    fileR2Key: `books/${inviteId}.epub`,
    coverR2Key: `covers/${inviteId}.jpg`,
    fileHash: "hash-1",
    fileSize: 42,
    createdAt: new Date(1),
  });
}

describe("session-sharing D1 schema", () => {
  it("defines dedicated invite tables and preserves ordinary share tables", () => {
    const invite = table("sessionInvites");
    const item = table("sessionInviteItems");
    const redemption = table("sessionInviteRedemptions");
    const delivery = table("sessionInviteDeliveries");

    expect(getTableConfig(invite).name).toBe("session_invites");
    expect(columnNames(invite)).toEqual([
      "content_hash",
      "created_at",
      "ended_at",
      "format",
      "id",
      "idempotency_key",
      "owner_user_id",
      "session_id",
      "source_book_id",
      "status",
      "token_hash",
    ]);
    expect(indexShape(invite)).toEqual([
      { name: "session_invites_owner_status_idx", unique: false, columns: ["owner_user_id", "status"] },
      { name: "session_invites_owner_idempotency_uniq", unique: true, columns: ["owner_user_id", "idempotency_key"] },
      { name: "session_invites_source_book_id_idx", unique: false, columns: ["source_book_id"] },
      { name: "session_invites_session_id_uniq", unique: true, columns: ["session_id"] },
      { name: "session_invites_token_hash_uniq", unique: true, columns: ["token_hash"] },
    ]);

    expect(columnNames(item)).toEqual([
      "cover_r2_key",
      "created_at",
      "file_hash",
      "file_r2_key",
      "file_size",
      "id",
      "invite_id",
    ]);
    expect(indexShape(item)).toEqual([
      { name: "session_invite_items_invite_id_uniq", unique: true, columns: ["invite_id"] },
    ]);

    expect(columnNames(redemption)).toEqual([
      "book_status",
      "created_at",
      "id",
      "invite_id",
      "last_admission_ticket_id",
      "membership_status",
      "updated_at",
      "user_id",
    ]);
    expect(indexShape(redemption)).toEqual([
      { name: "session_invite_redemptions_invite_user_uniq", unique: true, columns: ["invite_id", "user_id"] },
      { name: "session_invite_redemptions_invite_status_idx", unique: false, columns: ["invite_id", "membership_status"] },
      { name: "session_invite_redemptions_user_status_idx", unique: false, columns: ["user_id", "membership_status"] },
    ]);

    expect(columnNames(delivery)).toEqual([
      "created_at",
      "error_code",
      "id",
      "idempotency_key",
      "invite_id",
      "provider_message_id",
      "recipient_email",
      "sent_at",
      "status",
      "updated_at",
    ]);
    expect(indexShape(delivery)).toEqual([
      { name: "session_invite_deliveries_invite_email_uniq", unique: true, columns: ["invite_id", "recipient_email"] },
      { name: "session_invite_deliveries_invite_status_idx", unique: false, columns: ["invite_id", "status"] },
      { name: "session_invite_deliveries_idempotency_key_uniq", unique: true, columns: ["idempotency_key"] },
    ]);

    expect(getTableConfig(schema.sharePackages).name).toBe("share_packages");
    expect(getTableConfig(schema.sharePackageRedemptions).name).toBe("share_package_redemptions");
    expect(indexShape(schema.sharePackageRedemptions)).toContainEqual({
      name: "share_package_redemptions_package_user_uniq",
      unique: true,
      columns: ["package_id", "user_id"],
    });
  });

  it("uses cascading ownership and child relationships without crossing database domains", () => {
    const invite = table("sessionInvites");
    const item = table("sessionInviteItems");
    const redemption = table("sessionInviteRedemptions");
    const delivery = table("sessionInviteDeliveries");

    expect(foreignKeys(invite)).toEqual([
      { table: schema.user, onDelete: "cascade" },
      { table: schema.books, onDelete: "cascade" },
    ]);
    expect(foreignKeys(item)).toEqual([{ table: invite, onDelete: "cascade" }]);
    expect(foreignKeys(redemption)).toEqual([
      { table: invite, onDelete: "cascade" },
      { table: schema.user, onDelete: "cascade" },
    ]);
    expect(foreignKeys(delivery)).toEqual([{ table: invite, onDelete: "cascade" }]);
  });

  it("rejects duplicate invite users and duplicate invite email/idempotency keys", async () => {
    const d1 = createTestD1();
    try {
      const db = createDb(d1);
      await seedUser(db, "owner", "owner@example.com");
      await seedUser(db, "reader", "reader@example.com");
      await seedBook(db, "book-1", "owner");
      await seedInvite(db, "invite-1", "owner", "book-1");
      await seedInviteItem(db, "item-1", "invite-1");

      const now = new Date(1);
      await db.insert(schema.sessionInviteRedemptions).values({
        id: "redemption-1",
        inviteId: "invite-1",
        userId: "reader",
        bookStatus: "pending",
        membershipStatus: "pending",
        createdAt: now,
        updatedAt: now,
      });
      await expect(
        db.insert(schema.sessionInviteRedemptions).values({
          id: "redemption-2",
          inviteId: "invite-1",
          userId: "reader",
          bookStatus: "pending",
          membershipStatus: "pending",
          createdAt: now,
          updatedAt: now,
        }),
      ).rejects.toThrow();

      await db.insert(schema.sessionInviteDeliveries).values({
        id: "delivery-1",
        inviteId: "invite-1",
        recipientEmail: "recipient@example.com",
        status: "pending",
        idempotencyKey: "delivery-key-1",
        createdAt: now,
        updatedAt: now,
      });
      await expect(
        db.insert(schema.sessionInviteDeliveries).values({
          id: "delivery-2",
          inviteId: "invite-1",
          recipientEmail: "recipient@example.com",
          status: "pending",
          idempotencyKey: "delivery-key-2",
          createdAt: now,
          updatedAt: now,
        }),
      ).rejects.toThrow();
      await expect(
        db.insert(schema.sessionInviteDeliveries).values({
          id: "delivery-3",
          inviteId: "invite-1",
          recipientEmail: "other@example.com",
          status: "pending",
          idempotencyKey: "delivery-key-1",
          createdAt: now,
          updatedAt: now,
        }),
      ).rejects.toThrow();

      await expect(
        db.insert(schema.sessionInvites).values({
          id: "invite-duplicate-idempotency",
          ownerUserId: "owner",
          sessionId: "session-duplicate-idempotency",
          sourceBookId: "book-1",
          contentHash: "hash-1",
          format: "epub",
          tokenHash: "token-duplicate-idempotency",
          idempotencyKey: "request-invite-1",
          status: "open",
          createdAt: now,
        }),
      ).rejects.toThrow();

      await seedBook(db, "book-2", "reader");
      await seedInvite(db, "invite-reader", "reader", "book-2", "request-invite-1");
    } finally {
      d1.close();
    }
  });

  it("cascades owner invite records while preserving another account's invite records", async () => {
    const d1 = createTestD1();
    try {
      const db = createDb(d1);
      await seedUser(db, "owner-1", "owner-1@example.com");
      await seedUser(db, "owner-2", "owner-2@example.com");
      await seedUser(db, "reader", "reader@example.com");
      await seedBook(db, "book-1", "owner-1");
      await seedBook(db, "book-2", "owner-2");
      await seedInvite(db, "invite-1", "owner-1", "book-1");
      await seedInvite(db, "invite-2", "owner-2", "book-2");
      await seedInviteItem(db, "item-1", "invite-1");
      await seedInviteItem(db, "item-2", "invite-2");

      const now = new Date(1);
      await db.insert(schema.sessionInviteRedemptions).values({
        id: "redemption-1",
        inviteId: "invite-1",
        userId: "reader",
        bookStatus: "ready",
        membershipStatus: "admitted",
        createdAt: now,
        updatedAt: now,
      });
      await db.insert(schema.sessionInviteDeliveries).values({
        id: "delivery-1",
        inviteId: "invite-1",
        recipientEmail: "reader@example.com",
        status: "sent",
        idempotencyKey: "delivery-key-1",
        createdAt: now,
        updatedAt: now,
      });

      await db.delete(schema.user).where(eq(schema.user.id, "owner-1"));

      const deletedOwnerRows = await db
        .select({ id: schema.sessionInvites.id })
        .from(schema.sessionInvites)
        .where(eq(schema.sessionInvites.ownerUserId, "owner-1"))
        .all();
      const deletedChildRows = await db.select({ id: schema.sessionInviteItems.id })
        .from(schema.sessionInviteItems)
        .where(eq(schema.sessionInviteItems.inviteId, "invite-1"))
        .all();
      const deletedRedemptionRows = await db.select({ id: schema.sessionInviteRedemptions.id })
        .from(schema.sessionInviteRedemptions)
        .where(eq(schema.sessionInviteRedemptions.inviteId, "invite-1"))
        .all();
      const deletedDeliveryRows = await db.select({ id: schema.sessionInviteDeliveries.id })
        .from(schema.sessionInviteDeliveries)
        .where(eq(schema.sessionInviteDeliveries.inviteId, "invite-1"))
        .all();
      const preservedRows = await db
        .select({ id: schema.sessionInvites.id })
        .from(schema.sessionInvites)
        .where(eq(schema.sessionInvites.ownerUserId, "owner-2"))
        .all();

      expect(deletedOwnerRows).toHaveLength(0);
      expect(deletedChildRows).toHaveLength(0);
      expect(deletedRedemptionRows).toHaveLength(0);
      expect(deletedDeliveryRows).toHaveLength(0);
      expect(preservedRows).toHaveLength(1);
    } finally {
      d1.close();
    }
  });
});

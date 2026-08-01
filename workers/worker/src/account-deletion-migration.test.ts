import { describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { integer, sqliteTable, text } from "drizzle-orm/sqlite-core";
import { createDb } from "./db/drizzle";
import {
  appleUsers,
  bookPages,
  books,
  conversations,
  messages,
  user,
} from "./db/schema";
import { createTestD1, getTestMigrationFiles } from "./test-utils/d1";

const legacyAppleUsers = sqliteTable("apple_users", {
  id: text("id").primaryKey(),
  appleUserId: text("apple_user_id").notNull(),
  userId: text("user_id"),
  email: text("email"),
  emailVerified: integer("email_verified", { mode: "boolean" }).notNull(),
  privateEmail: integer("private_email", { mode: "boolean" }).notNull(),
  createdAt: integer("created_at").notNull(),
  updatedAt: integer("updated_at").notNull(),
});

describe("account deletion migration", () => {
  it("preserves representative pre-existing rows while adding cascades", async () => {
    const migrationFiles = getTestMigrationFiles();
    const targetMigration = migrationFiles.find((name) => name.includes("account_deletion"));
    expect(targetMigration).toBeDefined();

    const d1 = createTestD1(":memory:", {
      migrations: migrationFiles.filter((name) => name < targetMigration!),
    });
    const db = createDb(d1);
    const timestamp = new Date(1_000);

    await db.insert(user).values({
      id: "pre-existing-user",
      name: "Existing",
      email: "existing@example.com",
      emailVerified: true,
      createdAt: timestamp,
      updatedAt: timestamp,
    });
    await db.insert(books).values({
      id: "pre-existing-book",
      userId: "pre-existing-user",
      title: "Book",
      author: "Author",
      filePath: "book.epub",
      createdAt: 1_000,
      updatedAt: 1_000,
    });
    await db.insert(bookPages).values({
      bookId: "pre-existing-book",
      pageNumber: 1,
      text: "text",
      widthPts: 1,
      heightPts: 1,
      indexedAt: 1_000,
    });
    await db.insert(conversations).values({
      id: "pre-existing-conversation",
      bookId: "pre-existing-book",
      userId: "pre-existing-user",
      title: "Chat",
      createdAt: 1_000,
      updatedAt: 1_000,
    });
    await db.insert(messages).values({
      id: "pre-existing-message",
      conversationId: "pre-existing-conversation",
      role: "user",
      content: "Hello",
      createdAt: 1_000,
      updatedAt: 1_000,
    });
    await db.insert(legacyAppleUsers).values({
      id: "pre-existing-apple",
      appleUserId: "pre-existing-apple-sub",
      userId: "pre-existing-user",
      email: "existing@example.com",
      emailVerified: true,
      privateEmail: false,
      createdAt: 1_000,
      updatedAt: 1_000,
    });

    d1.applyMigrations([targetMigration!]);

    expect(await db.select({ id: user.id }).from(user).where(eq(user.id, "pre-existing-user")).all()).toHaveLength(1);
    expect(await db.select({ id: books.id }).from(books).where(eq(books.id, "pre-existing-book")).all()).toHaveLength(1);
    expect(await db.select({ bookId: bookPages.bookId }).from(bookPages).where(eq(bookPages.bookId, "pre-existing-book")).all()).toHaveLength(1);
    expect(await db.select({ id: conversations.id }).from(conversations).where(eq(conversations.id, "pre-existing-conversation")).all()).toHaveLength(1);
    expect(await db.select({ id: messages.id }).from(messages).where(eq(messages.id, "pre-existing-message")).all()).toHaveLength(1);
    expect(await db.select({ id: appleUsers.id }).from(appleUsers).where(eq(appleUsers.id, "pre-existing-apple")).all()).toHaveLength(1);

    await db.delete(user).where(eq(user.id, "pre-existing-user"));
    expect(await db.select({ id: books.id }).from(books).where(eq(books.id, "pre-existing-book")).all()).toHaveLength(0);
    expect(await db.select({ bookId: bookPages.bookId }).from(bookPages).where(eq(bookPages.bookId, "pre-existing-book")).all()).toHaveLength(0);
    expect(await db.select({ id: messages.id }).from(messages).where(eq(messages.id, "pre-existing-message")).all()).toHaveLength(0);
    d1.close();
  });
});

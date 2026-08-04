import { describe, expect, it } from "vitest";
import { getTableConfig } from "drizzle-orm/sqlite-core";
import { createTestD1 } from "../test-utils/d1";
import {
  account,
  allowancePeriod,
  appleNotificationsLog,
  appleUsers,
  appleSubscriptions,
  chapterIndexChapters,
  chapterIndexes,
  bookPages,
  bookParagraphs,
  bookWords,
  bookmarks,
  books,
  conversations,
  devices,
  highlights,
  messages,
  passkey,
  session,
  user,
  trialGrant,
  usageAuditLog,
  usageReservation,
  userApiUsage,
  usernames,
} from "./schema";

function userCascade(table: Parameters<typeof getTableConfig>[0]) {
  const config = getTableConfig(table);
  return config.foreignKeys.filter((foreignKey) => foreignKey.reference().foreignTable === user);
}

describe("user-owned database relationships", () => {
  const userOwnedTables = [
    ["apple_users", "user_id"],
    ["books", "user_id"],
    ["chapter_indexes", "user_id"],
    ["chapter_index_chapters", "user_id"],
    ["highlights", "user_id"],
    ["bookmarks", "user_id"],
    ["apple_notifications_log", "user_id"],
    ["account", "user_id"],
    ["conversations", "user_id"],
    ["apple_subscriptions", "user_id"],
    ["devices", "user_id"],
    ["trial_grant", "user_id"],
    ["allowance_period", "user_id"],
    ["usage_reservation", "user_id"],
    ["usage_audit_log", "user_id"],
    ["user_api_usage", "user_id"],
    ["session", "user_id"],
    ["passkey", "user_id"],
    ["usernames", "user_id"],
  ] as const;

  it("cascade user deletion through every user-owned table", () => {
    for (const table of [
      appleUsers,
      books,
      chapterIndexes,
      chapterIndexChapters,
      highlights,
      bookmarks,
      appleNotificationsLog,
      account,
      conversations,
      appleSubscriptions,
      devices,
      trialGrant,
      allowancePeriod,
      usageReservation,
      usageAuditLog,
      userApiUsage,
      session,
      passkey,
      usernames,
    ]) {
      expect(userCascade(table).some((foreignKey) => foreignKey.onDelete === "cascade")).toBe(true);
    }
  });

  it("cascade book and conversation child deletion", () => {
    for (const table of [bookPages, bookWords, bookParagraphs, bookmarks, highlights]) {
      expect(getTableConfig(table).foreignKeys.some((foreignKey) =>
        foreignKey.reference().foreignTable === books && foreignKey.onDelete === "cascade",
      )).toBe(true);
    }
    expect(getTableConfig(messages).foreignKeys.some((foreignKey) =>
      foreignKey.reference().foreignTable === conversations && foreignKey.onDelete === "cascade",
    )).toBe(true);
  });

  it("migration artifacts preserve CASCADE for every user-owned foreign key", async () => {
    const d1 = createTestD1();
    try {
      for (const [table, column] of userOwnedTables) {
        const result = await d1
          .prepare(`PRAGMA foreign_key_list("${table}")`)
          .all<{ table: string; from: string; on_delete: string }>();
        expect(result.results.some((foreignKey) =>
          foreignKey.table === "user" &&
          foreignKey.from === column &&
          foreignKey.on_delete.toUpperCase() === "CASCADE",
        )).toBe(true);
      }
    } finally {
      d1.close();
    }
  });
});

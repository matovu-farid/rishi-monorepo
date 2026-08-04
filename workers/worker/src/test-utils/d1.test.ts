import { describe, expect, it } from "vitest";
import { getTestMigrationFiles, readTestMigration } from "./d1";

describe("test D1 migration discovery", () => {
  it("discovers readable legacy files and nested Drizzle migrations in application order", () => {
    const files = getTestMigrationFiles();
    expect(files).toContain("0001_usage_ledger.sql");
    expect(files).toContain("20260803145911_classy_sleepwalker/migration.sql");
    expect(files.indexOf("0001_usage_ledger.sql")).toBeLessThan(
      files.indexOf("20260803145911_classy_sleepwalker/migration.sql"),
    );
    expect(readTestMigration("20260713060447_superb_starjammers/migration.sql")).toContain(
      "CREATE TABLE `apple_notifications_log`",
    );
    expect(readTestMigration("20260803145911_classy_sleepwalker/migration.sql")).toContain(
      "CREATE TABLE `usernames`",
    );
  });
});

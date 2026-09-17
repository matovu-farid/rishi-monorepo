import { count, gt, isNull } from "drizzle-orm";
import { integer, sqliteTable, text } from "drizzle-orm/sqlite-core";
import { expect, it } from "vitest";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { createDb } from "./drizzle";
import { books, sessionInvites, user } from "./schema";
import { createTestD1, getTestMigrationFiles } from "../test-utils/d1";

const firstMigration = "20260820112725_session_invites_from_prod_session_only/migration.sql";
const idempotencyMigration = "20260820121338_session_invites_idempotency/migration.sql";
const appliedHistoricalMigrations = [firstMigration, idempotencyMigration];

const predecessorSessionInvites = sqliteTable("session_invites", {
  id: text("id").primaryKey(),
  ownerUserId: text("owner_user_id").notNull(),
  sessionId: text("session_id").notNull(),
  sourceBookId: text("source_book_id").notNull(),
  contentHash: text("content_hash").notNull(),
  format: text("format").notNull(),
  tokenHash: text("token_hash").notNull(),
  status: text("status").notNull().default("open"),
  createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
  endedAt: integer("ended_at", { mode: "timestamp" }),
});

function migrationsThrough(name: string): string[] {
  const migrations = getTestMigrationFiles();
  const index = migrations.indexOf(name);
  if (index < 0) throw new Error(`Missing migration: ${name}`);
  return migrations.slice(0, index + 1);
}

async function assertFinalState(rows: number): Promise<void> {
  const d1 = createTestD1();
  try {
    const db = createDb(d1);
    const [{ value: rowCount }] = await db.select({ value: count() }).from(sessionInvites).all();
    const nullRows = await db.select({ id: sessionInvites.id }).from(sessionInvites)
      .where(isNull(sessionInvites.idempotencyKey)).all();
    const duplicateRows = await db.select({
      ownerUserId: sessionInvites.ownerUserId,
      idempotencyKey: sessionInvites.idempotencyKey,
      value: count(),
    }).from(sessionInvites)
      .groupBy(sessionInvites.ownerUserId, sessionInvites.idempotencyKey)
      .having(gt(count(), 1)).all();

    expect(rowCount).toBe(rows);
    expect(nullRows).toHaveLength(0);
    expect(duplicateRows).toHaveLength(0);
  } finally {
    d1.close();
  }
}

it("migrates fresh predecessor without data loss", async () => {
  await assertFinalState(0);
});

it("migrates first-empty predecessor without data loss", async () => {
  const d1 = createTestD1(":memory:", { migrations: migrationsThrough(firstMigration) });
  try {
    d1.applyMigrations([idempotencyMigration]);
    const db = createDb(d1);
    const [{ value }] = await db.select({ value: count() }).from(sessionInvites).all();
    expect(value).toBe(0);
  } finally {
    d1.close();
  }
});

it("blocks a populated intermediate predecessor without data loss", async () => {
  const d1 = createTestD1(":memory:", { migrations: migrationsThrough(firstMigration) });
  try {
    const db = createDb(d1);
    await db.insert(user).values({
      id: "owner",
      name: "Owner",
      email: "owner@example.com",
      emailVerified: true,
      createdAt: new Date(1),
      updatedAt: new Date(1),
    });
    await db.insert(books).values({
      id: "book",
      userId: "owner",
      title: "Shared book",
      author: "Author",
      filePath: "/books/shared.epub",
      format: "epub",
      createdAt: 1,
      updatedAt: 1,
    });
    await db.insert(predecessorSessionInvites).values(
      ["one", "two", "three"].map((id) => ({
        id,
        ownerUserId: "owner",
        sessionId: `session-${id}`,
        sourceBookId: "book",
        contentHash: `hash-${id}`,
        format: "epub",
        tokenHash: `token-${id}`,
        createdAt: new Date(1),
      })),
    );

    expect(() => d1.applyMigrations([idempotencyMigration])).toThrow();
    const [{ value }] = await db.select({ value: count() }).from(predecessorSessionInvites).all();
    expect(value).toBe(3);
  } finally {
    d1.close();
  }
});

it("keeps both applied historical migrations in the deployable and test chains", () => {
  const wranglerConfig = readFileSync(resolve(import.meta.dirname, "../../wrangler.jsonc"), "utf8");
  expect(getTestMigrationFiles()).toEqual(expect.arrayContaining(appliedHistoricalMigrations));
  for (const migration of appliedHistoricalMigrations) expect(wranglerConfig).toContain(migration);
});

it("writes a fail-closed canonical migration snapshot before no-op generation", () => {
  const root = mkdtempSync(join(tmpdir(), "rishi-w1-pattern-"));
  const before = join(root, "before.json");

  try {
    const result = spawnSync("bun", ["run", "scripts/verify-migration-pattern.ts", "--snapshot-before", before], {
      cwd: resolve(import.meta.dirname, "../.."),
      encoding: "utf8",
    });

    expect(result.status, result.stderr).toBe(0);
    expect(JSON.parse(readFileSync(before, "utf8"))).toMatchObject({
      version: 1,
      activeNestedMigrations: expect.arrayContaining(appliedHistoricalMigrations),
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

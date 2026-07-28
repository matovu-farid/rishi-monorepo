// Apple IAP schema introspection tests (Wave 0 RED → GREEN gate).
//
// These tests pin the SQLite/D1 Drizzle shape that every downstream Phase-14
// plan (verify-receipt, webhook, /me) imports. They MUST fail until
// `packages/shared/src/schema.ts` exports `appleSubscriptions` and
// `appleNotificationsLog` with the exact column/PK/FK contract documented
// in `.planning/phases/14-iap-backend/14-CONTEXT.md`.
//
// Regression guard: the existing Stripe `subscription` table is NOT touched
// and the Apple table name is the literal string `apple_subscriptions`
// (NOT `subscription` or `subscriptions`), so this schema can coexist with
// the legacy Stripe path that `/api/billing/me` falls back to.

import { describe, it, expect } from "vitest";
import { getTableConfig } from "drizzle-orm/sqlite-core";
import {
  appleSubscriptions,
  appleNotificationsLog,
  subscription,
  user,
} from "../db/schema";

describe("apple_subscriptions schema", () => {
  const cfg = getTableConfig(appleSubscriptions);

  it("table name is apple_subscriptions (no collision with Stripe `subscription`)", () => {
    expect(cfg.name).toBe("apple_subscriptions");
    // Sibling Stripe table must still exist with its unprefixed name.
    expect(getTableConfig(subscription).name).toBe("subscription");
  });

  it("primary key is apple_transaction_id (text — UInt64 stored as string)", () => {
    const pk = cfg.columns.find((c) => c.primary);
    expect(pk).toBeDefined();
    expect(pk!.name).toBe("apple_transaction_id");
    expect(pk!.dataType).toBe("string");
  });

  it("user_id references user.id with cascade delete", () => {
    const fk = cfg.foreignKeys[0];
    expect(fk).toBeDefined();
    expect(fk.reference().foreignTable).toBe(user);
    expect(fk.onDelete).toBe("cascade");
  });

  it("environment column accepts only Sandbox or Production", () => {
    const env = cfg.columns.find((c) => c.name === "environment");
    expect(env).toBeDefined();
    // Drizzle stashes the enum values on the column instance for text({enum})
    expect((env as unknown as { enumValues: string[] }).enumValues).toEqual([
      "Sandbox",
      "Production",
    ]);
  });

  it("status column accepts only the four lifecycle states", () => {
    const st = cfg.columns.find((c) => c.name === "status");
    expect(st).toBeDefined();
    expect((st as unknown as { enumValues: string[] }).enumValues).toEqual([
      "active",
      "in_grace",
      "expired",
      "refunded",
    ]);
  });

  it("exposes apple_original_transaction_id, product_id, current_period_end, auto_renew, created_at, updated_at", () => {
    const names = cfg.columns.map((c) => c.name).sort();
    expect(names).toEqual(
      [
        "apple_original_transaction_id",
        "apple_transaction_id",
        "app_account_token",
        "auto_renew",
        "created_at",
        "current_period_end",
        "environment",
        "product_id",
        "status",
        "updated_at",
        "user_id",
      ].sort(),
    );
  });
});

describe("apple_notifications_log schema", () => {
  const cfg = getTableConfig(appleNotificationsLog);

  it("table name is apple_notifications_log", () => {
    expect(cfg.name).toBe("apple_notifications_log");
  });

  it("primary key is notification_uuid (idempotency key)", () => {
    const pk = cfg.columns.find((c) => c.primary);
    expect(pk).toBeDefined();
    expect(pk!.name).toBe("notification_uuid");
  });

  it("raw_payload column is text and NOT NULL (JSON-encoded — SQLite has no jsonb)", () => {
    const raw = cfg.columns.find((c) => c.name === "raw_payload");
    expect(raw).toBeDefined();
    expect(raw!.dataType).toBe("string");
    expect(raw!.notNull).toBe(true);
  });

  it("user_id is nullable and references user.id", () => {
    const uid = cfg.columns.find((c) => c.name === "user_id");
    expect(uid).toBeDefined();
    expect(uid!.notNull).toBe(false);
    // FK on the user_id column points to the user table.
    const fk = cfg.foreignKeys.find((f) =>
      f.reference().columns.some((c) => c.name === "user_id"),
    );
    expect(fk).toBeDefined();
    expect(fk!.reference().foreignTable).toBe(user);
  });
});

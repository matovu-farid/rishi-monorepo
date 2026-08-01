import { describe, expect, it } from "vitest";
import { getTableConfig } from "drizzle-orm/sqlite-core";
import {
  retainedAppleEntitlement,
  retainedAppleTransaction,
  restoredAppleEntitlement,
  deletionState,
  user,
} from "./schema";

function columnNames(table: Parameters<typeof getTableConfig>[0]) {
  return getTableConfig(table).columns.map((column) => column.name).sort();
}

function indexShape(table: Parameters<typeof getTableConfig>[0]) {
  return getTableConfig(table).indexes.map((index) => ({
    name: index.config.name,
    unique: index.config.unique,
    columns: index.config.columns.map((column) => (column as { name?: string }).name ?? ""),
  }));
}

describe("Apple entitlement retention schema", () => {
  it("keeps the retained entitlement aggregate without a user foreign key", () => {
    expect(getTableConfig(retainedAppleEntitlement).name).toBe(
      "retained_apple_entitlement",
    );
    expect(columnNames(retainedAppleEntitlement)).toEqual([
      "deleted_at",
      "identity_hash",
      "identity_hash_version",
      "reader_active_until",
      "reader_credits_total",
      "reader_credits_used",
      "reader_status",
      "retention_expires_at",
      "trial_initial_credits",
      "trial_state",
      "trial_used_credits",
      "updated_at",
      "voice_active_until",
      "voice_credits_total",
      "voice_credits_used",
      "voice_status",
    ]);
    expect(getTableConfig(retainedAppleEntitlement).foreignKeys).toHaveLength(0);
    expect(indexShape(retainedAppleEntitlement)).toEqual([
      {
        name: "retained_apple_entitlement_identity_uniq",
        unique: true,
        columns: ["identity_hash_version", "identity_hash"],
      },
    ]);
  });

  it("keeps transaction history keyed by the versioned environment-aware hash", () => {
    expect(getTableConfig(retainedAppleTransaction).name).toBe(
      "retained_apple_transaction",
    );
    expect(columnNames(retainedAppleTransaction)).toEqual([
      "environment",
      "feature",
      "identity_hash",
      "identity_hash_version",
      "last_event_at",
      "original_transaction_hash",
      "period_end",
      "retention_expires_at",
      "status",
      "transaction_hash_version",
      "updated_at",
    ]);
    expect(getTableConfig(retainedAppleTransaction).foreignKeys).toHaveLength(0);
    expect(indexShape(retainedAppleTransaction)).toEqual([
      {
        name: "retained_apple_transaction_key_uniq",
        unique: true,
        columns: [
          "transaction_hash_version",
          "environment",
          "original_transaction_hash",
        ],
      },
    ]);
  });

  it("makes only the live restored binding user-owned and cascading", () => {
    const config = getTableConfig(restoredAppleEntitlement);
    expect(config.name).toBe("restored_apple_entitlement");
    expect(columnNames(restoredAppleEntitlement)).toEqual([
      "environment",
      "feature",
      "identity_hash",
      "identity_hash_version",
      "original_transaction_hash",
      "period_end",
      "status",
      "transaction_hash_version",
      "updated_at",
      "user_id",
    ]);
    expect(config.foreignKeys).toHaveLength(1);
    expect(config.foreignKeys[0].reference().foreignTable).toBe(user);
    expect(config.foreignKeys[0].onDelete).toBe("cascade");
    expect(indexShape(restoredAppleEntitlement)).toEqual([
      {
        name: "restored_apple_entitlement_key_uniq",
        unique: true,
        columns: ["user_id", "transaction_hash_version", "environment", "original_transaction_hash"],
      },
    ]);
  });

  it("keeps the deletion fence user-owned", () => {
    const config = getTableConfig(deletionState);
    expect(config.name).toBe("deletion_state");
    expect(config.foreignKeys).toHaveLength(1);
    expect(config.foreignKeys[0].reference().foreignTable).toBe(user);
    expect(config.foreignKeys[0].onDelete).toBe("cascade");
  });
});

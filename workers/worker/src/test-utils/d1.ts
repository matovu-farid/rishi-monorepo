import { DatabaseSync } from "node:sqlite";
import { readdirSync, readFileSync } from "node:fs";

type BoundStatement = {
  bind: (...values: unknown[]) => BoundStatement;
  run: () => Promise<D1Result>;
  first: <T = Record<string, unknown>>() => Promise<T | null>;
  all: <T = Record<string, unknown>>() => Promise<D1Result<T>>;
  raw: <T = unknown[]>() => Promise<T>;
};

export type TestD1 = D1Database & {
  close: () => void;
  applyMigrations: (names: string[]) => void;
};

type TestD1Options = {
  migrations?: string[];
  failOnRun?: (query: string) => boolean;
  beforeRun?: (query: string) => void | Promise<void>;
};

const migrationsDirectory = new URL("../../drizzle/migrations/", import.meta.url);

export function getTestMigrationFiles(): string[] {
  const entries = readdirSync(migrationsDirectory, { withFileTypes: true });
  const legacy = entries
    .filter((entry) => entry.isFile() && /^\d+_.+\.sql$/.test(entry.name))
    .map((entry) => entry.name)
    .sort((left, right) => left.localeCompare(right, undefined, { numeric: true }));
  const nested = entries
    .filter((entry) => entry.isDirectory() && /^\d+_.+$/.test(entry.name))
    .map((entry) => `${entry.name}/migration.sql`)
    .filter((name) => {
      try {
        readFileSync(new URL(name.replace(/\/migration\.sql$/, "/snapshot.json"), migrationsDirectory), "utf8");
        return true;
      } catch {
        return false;
      }
    })
    .sort((left, right) => left.localeCompare(right, undefined, { numeric: true }));

  const hasLegacyBase = legacy.some((name) => name.startsWith("0000_"));
  const hasLegacyEntitlement = legacy.some((name) => name.startsWith("0007_"));
  const nestedToApply = nested.filter((name) => {
    // These timestamped directories are pre-existing full-schema replacements
    // for applied top-level history. Do not replay them when their authoritative
    // top-level migration is present; Wrangler excludes them for the same reason.
    if (hasLegacyBase && name.startsWith("20260713060447_")) return false;
    if (hasLegacyEntitlement && name.startsWith("20260801174843_")) return false;
    return true;
  });
  return [...legacy, ...nestedToApply];
}

export function readTestMigration(name: string): string {
  return readFileSync(new URL(name, migrationsDirectory), "utf8");
}

export function createTestD1(
  databasePath = ":memory:",
  options: TestD1Options = {},
): TestD1 {
  const sqlite = new DatabaseSync(databasePath);
  for (const migration of options.migrations ?? getTestMigrationFiles()) {
    sqlite.exec(readTestMigration(migration));
  }

  const d1 = {
    prepare(query: string): BoundStatement {
      let values: unknown[] = [];
      const statement: BoundStatement = {
        bind(...boundValues) {
          values = boundValues;
          return statement;
        },
        async run() {
          await options.beforeRun?.(query);
          if (options.failOnRun?.(query)) {
            throw new Error("temporary D1 failure");
          }
          const result = sqlite.prepare(query).run(...values as never[]);
          return {
            success: true,
            meta: { changes: Number(result.changes) },
          } as D1Result;
        },
        async first<T>() {
          return (sqlite.prepare(query).get(...values as never[]) as T | undefined) ?? null;
        },
        async all<T>() {
          const results = sqlite.prepare(query).all(...values as never[]) as T[];
          return {
            success: true,
            results,
            meta: { changes: 0 },
          } as D1Result<T>;
        },
        async raw<T>() {
          const rows = sqlite.prepare(query).all(...values as never[]) as Record<string, unknown>[];
          return rows.map((row) => Object.values(row)) as T;
        },
      };
      return statement;
    },
    async batch(statements: BoundStatement[]) {
      const [first, ...rest] = statements;
      if (!first) return [];
      return [await first.run(), ...await Promise.all(rest.map((statement) => statement.run()))];
    },
    close() {
      sqlite.close();
    },
    applyMigrations(names: string[]) {
      for (const name of names) {
        sqlite.exec(readTestMigration(name));
      }
    },
  } as unknown as TestD1;

  return d1;
}

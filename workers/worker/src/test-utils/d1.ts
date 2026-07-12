import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";

type BoundStatement = {
  bind: (...values: unknown[]) => BoundStatement;
  run: () => Promise<D1Result>;
  first: <T = Record<string, unknown>>() => Promise<T | null>;
  all: <T = Record<string, unknown>>() => Promise<D1Result<T>>;
  raw: <T = unknown[]>() => Promise<T>;
};

export function createTestD1(
  databasePath = ":memory:",
): D1Database & { close: () => void } {
  const sqlite = new DatabaseSync(databasePath);
  for (const migration of [
    "../../drizzle/migrations/0000_thick_madrox.sql",
    "../../drizzle/migrations/0011_user_api_usage.sql",
  ]) {
    sqlite.exec(readFileSync(new URL(migration, import.meta.url), "utf8"));
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
          const result = sqlite.prepare(query).run(...values);
          return {
            success: true,
            meta: { changes: Number(result.changes) },
          } as D1Result;
        },
        async first<T>() {
          return (sqlite.prepare(query).get(...values) as T | undefined) ?? null;
        },
        async all<T>() {
          const results = sqlite.prepare(query).all(...values) as T[];
          return {
            success: true,
            results,
            meta: { changes: 0 },
          } as D1Result<T>;
        },
        async raw<T>() {
          const rows = sqlite.prepare(query).all(...values) as Record<string, unknown>[];
          return rows.map((row) => Object.values(row)) as T;
        },
      };
      return statement;
    },
    close() {
      sqlite.close();
    },
  } as unknown as D1Database & { close: () => void };

  return d1;
}

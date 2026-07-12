import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
export function createTestD1(databasePath = ":memory:") {
    const sqlite = new DatabaseSync(databasePath);
    for (const migration of [
        "../../drizzle/migrations/0000_thick_madrox.sql",
        "../../drizzle/migrations/0011_user_api_usage.sql",
    ]) {
        sqlite.exec(readFileSync(new URL(migration, import.meta.url), "utf8"));
    }
    const d1 = {
        prepare(query) {
            let values = [];
            const statement = {
                bind(...boundValues) {
                    values = boundValues;
                    return statement;
                },
                async run() {
                    const result = sqlite.prepare(query).run(...values);
                    return {
                        success: true,
                        meta: { changes: Number(result.changes) },
                    };
                },
                async first() {
                    return sqlite.prepare(query).get(...values) ?? null;
                },
                async all() {
                    const results = sqlite.prepare(query).all(...values);
                    return {
                        success: true,
                        results,
                        meta: { changes: 0 },
                    };
                },
                async raw() {
                    const rows = sqlite.prepare(query).all(...values);
                    return rows.map((row) => Object.values(row));
                },
            };
            return statement;
        },
        close() {
            sqlite.close();
        },
    };
    return d1;
}

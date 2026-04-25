import { ipcMain } from "electron";
import { getDb } from "../database/index.js";

export function registerDbHandlers(): void {
  ipcMain.handle(
    "db:query",
    async (_event, sql: string, params?: unknown[]) => {
      try {
        const db = getDb();
        const stmt = db.prepare(sql);
        return params ? stmt.all(...params) : stmt.all();
      } catch (error) {
        throw new Error(
          `Database query failed: ${error instanceof Error ? error.message : String(error)}`
        );
      }
    }
  );

  ipcMain.handle(
    "db:run",
    async (_event, sql: string, params?: unknown[]) => {
      try {
        const db = getDb();
        const stmt = db.prepare(sql);
        const result = params ? stmt.run(...params) : stmt.run();
        return {
          changes: result.changes,
          lastInsertRowid: Number(result.lastInsertRowid),
        };
      } catch (error) {
        throw new Error(
          `Database run failed: ${error instanceof Error ? error.message : String(error)}`
        );
      }
    }
  );
}

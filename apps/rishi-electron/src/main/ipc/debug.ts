import { ipcMain, app } from "electron";
import * as fs from "node:fs/promises";
import * as path from "node:path";

function getErrorDumpPath(): string {
  return path.join(app.getPath("userData"), "error-dump.json");
}

function getStateDumpPath(): string {
  return path.join(app.getPath("userData"), "state-dump.json");
}

export function registerDebugHandlers(): void {
  ipcMain.handle("debug:dumpError", async (_event, error: unknown) => {
    try {
      const dumpPath = getErrorDumpPath();
      const timestamp = new Date().toISOString();

      // Read existing dump if present, append new error
      let existingDumps: unknown[] = [];
      try {
        const existing = await fs.readFile(dumpPath, "utf-8");
        const parsed = JSON.parse(existing);
        existingDumps = Array.isArray(parsed) ? parsed : [parsed];
      } catch {
        // No existing dump
      }

      existingDumps.push({ ...((error as object) ?? {}), timestamp });

      await fs.writeFile(
        dumpPath,
        JSON.stringify(existingDumps, null, 2)
      );
    } catch (err) {
      throw new Error(
        `Failed to dump error: ${err instanceof Error ? err.message : String(err)}`
      );
    }
  });

  ipcMain.handle("debug:readErrorDump", async () => {
    try {
      const dumpPath = getErrorDumpPath();

      try {
        await fs.access(dumpPath);
      } catch {
        return "[]";
      }

      return await fs.readFile(dumpPath, "utf-8");
    } catch (error) {
      throw new Error(
        `Failed to read error dump: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  });

  ipcMain.handle("debug:clearErrorDump", async () => {
    try {
      const dumpPath = getErrorDumpPath();
      await fs.unlink(dumpPath).catch(() => {});
    } catch (error) {
      throw new Error(
        `Failed to clear error dump: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  });

  // ── State dump ──────────────────────────────────────────────────────

  ipcMain.handle("debug:dumpState", async (_event, json: string) => {
    try {
      const dumpPath = getStateDumpPath();
      await fs.writeFile(dumpPath, json, "utf-8");
    } catch (error) {
      throw new Error(
        `Failed to dump state: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  });

  ipcMain.handle("debug:readStateDump", async () => {
    try {
      const dumpPath = getStateDumpPath();
      try {
        await fs.access(dumpPath);
      } catch {
        return "{}";
      }
      return await fs.readFile(dumpPath, "utf-8");
    } catch (error) {
      throw new Error(
        `Failed to read state dump: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  });
}

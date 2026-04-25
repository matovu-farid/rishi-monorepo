import { ipcMain, app, shell } from "electron";
import * as os from "node:os";

export function registerUtilHandlers(): void {
  ipcMain.handle("util:isDev", async () => {
    return !app.isPackaged;
  });

  ipcMain.handle("util:getDevBypassSecret", async () => {
    return process.env.DEV_BYPASS_SECRET ?? null;
  });

  ipcMain.handle("util:getRealtimeClientSecret", async () => {
    try {
      const baseUrl = process.env.REALTIME_WORKER_URL || "https://rishi-worker.faridmato90.workers.dev";
      const url = `${baseUrl}/api/realtime/client_secrets`;

      // Try to get auth token for authenticated request
      let authToken: string | null = null;
      try {
        const { safeStorage } = await import("electron");
        const fs = await import("node:fs/promises");
        const path = await import("node:path");
        const tokenPath = path.join(app.getPath("userData"), "auth-token.enc");
        const encrypted = await fs.readFile(tokenPath);
        authToken = safeStorage.decryptString(encrypted);
      } catch {
        // No token available
      }

      const headers: Record<string, string> = {};
      if (authToken) headers["Authorization"] = `Bearer ${authToken}`;

      const response = await fetch(url, {
        method: "GET",
        headers,
      });

      if (!response.ok) {
        throw new Error(
          `Worker API responded with status ${response.status}`
        );
      }

      const data = (await response.json()) as { client_secret?: { value?: string } };
      const secret = data?.client_secret?.value;
      if (!secret) {
        throw new Error("No client_secret in worker response");
      }

      return secret;
    } catch (error) {
      throw new Error(
        `Failed to get realtime client secret: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  });

  ipcMain.handle("util:getOsInfo", async () => {
    return {
      platform: process.platform,
      arch: process.arch,
      version: os.release(),
    };
  });

  ipcMain.handle("shell:openExternal", async (_event, url: string) => {
    try {
      // Basic URL validation to prevent opening arbitrary protocols
      const parsed = new URL(url);
      if (!["http:", "https:", "mailto:"].includes(parsed.protocol)) {
        throw new Error(`Unsupported protocol: ${parsed.protocol}`);
      }
      await shell.openExternal(url);
    } catch (error) {
      throw new Error(
        `Failed to open external URL: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  });
}

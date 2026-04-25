/**
 * Electron updater module.
 * Uses window.electron IPC to communicate with the main process
 * which handles electron-updater.
 */
import { create } from "zustand";
import { devtools } from "zustand/middleware";

export type UpdateStatus =
  | { kind: "idle" }
  | { kind: "checking" }
  | { kind: "downloading"; downloaded: number; total: number }
  | { kind: "installing" }
  | { kind: "error"; message: string };

interface UpdateState {
  status: UpdateStatus;
  setStatus: (status: UpdateStatus) => void;
}

export const useUpdateStore = create<UpdateState>()(
  devtools(
    (set) => ({
      status: { kind: "idle" } as UpdateStatus,
      setStatus: (status) => set({ status }),
    }),
    { name: "update-store" }
  )
);

export function renderStatus(status: UpdateStatus): string | null {
  switch (status.kind) {
    case "idle":
      return null;
    case "checking":
      return "Checking for updates\u2026";
    case "downloading": {
      const pct = status.total > 0
        ? Math.floor((status.downloaded / status.total) * 100)
        : 0;
      return `Downloading\u2026 ${pct}%`;
    }
    case "installing":
      return "Installing\u2026";
    case "error":
      return "Update failed. See console for details.";
  }
}

let checkInFlight = false;

export async function checkForUpdates(_opts?: { silent: boolean }): Promise<void> {
  if (checkInFlight) return;

  checkInFlight = true;
  useUpdateStore.getState().setStatus({ kind: "checking" });

  try {
    // In Electron, the main process handles auto-updates via electron-updater.
    // We just signal it to check and let the main process manage the lifecycle.
    // If checkForUpdates is exposed on the API, call it; otherwise no-op.
    if (typeof (window.electron as any)?.checkForUpdates === "function") {
      const result = await (window.electron as any).checkForUpdates();

      if (!result || !result.updateAvailable) {
        useUpdateStore.getState().setStatus({ kind: "idle" });
        return;
      }

      useUpdateStore.getState().setStatus({
        kind: "downloading",
        downloaded: 0,
        total: result.totalSize ?? 0,
      });
    } else {
      // electron-updater handles updates automatically in the main process
      useUpdateStore.getState().setStatus({ kind: "idle" });
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.warn("[updater] failed:", msg);
    useUpdateStore.getState().setStatus({ kind: "idle" });
  } finally {
    checkInFlight = false;
  }
}

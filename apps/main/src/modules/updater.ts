import { check, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import { ask, message } from "@tauri-apps/plugin-dialog";
import { platform } from "@tauri-apps/plugin-os";
import { getVersion } from "@tauri-apps/api/app";
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

export async function checkForUpdates(opts: { silent: boolean }): Promise<void> {
  if (checkInFlight) return;

  const p = platform();
  if (p !== "macos" && p !== "windows" && p !== "linux") return;

  checkInFlight = true;
  useUpdateStore.getState().setStatus({ kind: "checking" });

  try {
    const update: Update | null = await check();

    if (!update) {
      useUpdateStore.getState().setStatus({ kind: "idle" });
      if (!opts.silent) {
        const v = await getVersion();
        await message(`You're on the latest version (v${v}).`, {
          title: "No updates available",
          kind: "info",
        });
      }
      return;
    }

    const accepted = await ask(
      `Rishi v${update.version} is available. Install and restart now?`,
      {
        title: "Update available",
        kind: "info",
        okLabel: "Install",
        cancelLabel: "Later",
      }
    );
    if (!accepted) {
      useUpdateStore.getState().setStatus({ kind: "idle" });
      return;
    }

    let downloaded = 0;
    let total = 0;
    await update.downloadAndInstall((event) => {
      switch (event.event) {
        case "Started":
          total = event.data.contentLength ?? 0;
          useUpdateStore.getState().setStatus({
            kind: "downloading",
            downloaded: 0,
            total,
          });
          break;
        case "Progress":
          downloaded += event.data.chunkLength;
          useUpdateStore.getState().setStatus({
            kind: "downloading",
            downloaded,
            total,
          });
          break;
        case "Finished":
          useUpdateStore.getState().setStatus({ kind: "installing" });
          break;
      }
    });

    await relaunch();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.warn("[updater] failed:", msg);
    if (opts.silent) {
      useUpdateStore.getState().setStatus({ kind: "idle" });
    } else {
      useUpdateStore.getState().setStatus({ kind: "error", message: msg });
      checkInFlight = false;
      await message(
        "Unable to check for updates. Please check your connection.",
        { title: "Update check failed", kind: "error" }
      );
    }
  } finally {
    checkInFlight = false;
  }
}

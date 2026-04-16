import { check, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import { ask, message } from "@tauri-apps/plugin-dialog";
import { platform } from "@tauri-apps/plugin-os";
import { getVersion } from "@tauri-apps/api/app";
import { atom } from "jotai";
import { customStore } from "@/stores/jotai";

export type UpdateStatus =
  | { kind: "idle" }
  | { kind: "checking" }
  | { kind: "downloading"; downloaded: number; total: number }
  | { kind: "installing" }
  | { kind: "error"; message: string };

export const updateStatusAtom = atom<UpdateStatus>({ kind: "idle" });

export function renderStatus(status: UpdateStatus): string | null {
  switch (status.kind) {
    case "idle":
      return null;
    case "checking":
      return "Checking for updates…";
    case "downloading": {
      const pct = status.total > 0
        ? Math.floor((status.downloaded / status.total) * 100)
        : 0;
      return `Downloading… ${pct}%`;
    }
    case "installing":
      return "Installing…";
    case "error":
      return "Update failed. See console for details.";
  }
}

let checkInFlight = false;

export async function checkForUpdates(opts: { silent: boolean }): Promise<void> {
  if (checkInFlight) return;

  // Defense-in-depth: plugin-process / plugin-updater aren't bundled for mobile.
  // apps/mobile doesn't import this module today, but the guard prevents
  // crashes if that ever changes (e.g., via a shared packages/ layer).
  const p = platform();
  if (p !== "macos" && p !== "windows" && p !== "linux") return;

  checkInFlight = true;
  customStore.set(updateStatusAtom, { kind: "checking" });

  try {
    const update: Update | null = await check();

    if (!update) {
      customStore.set(updateStatusAtom, { kind: "idle" });
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
      customStore.set(updateStatusAtom, { kind: "idle" });
      return;
    }

    let downloaded = 0;
    let total = 0;
    await update.downloadAndInstall((event) => {
      switch (event.event) {
        case "Started":
          total = event.data.contentLength ?? 0;
          customStore.set(updateStatusAtom, {
            kind: "downloading",
            downloaded: 0,
            total,
          });
          break;
        case "Progress":
          downloaded += event.data.chunkLength;
          customStore.set(updateStatusAtom, {
            kind: "downloading",
            downloaded,
            total,
          });
          break;
        case "Finished":
          customStore.set(updateStatusAtom, { kind: "installing" });
          break;
      }
    });

    await relaunch();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.warn("[updater] failed:", msg);
    if (opts.silent) {
      // Silent mode: reset to idle so the popover doesn't persistently show
      // "Update failed" for a check the user never initiated.
      customStore.set(updateStatusAtom, { kind: "idle" });
    } else {
      customStore.set(updateStatusAtom, { kind: "error", message: msg });
      // Release the in-flight guard *before* the blocking error dialog so
      // that a user who clicks "Check for Updates" again from the popover
      // (possible on Linux WMs where message() isn't modal) isn't no-op'd.
      // The finally block re-assigns the same value, which is idempotent.
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

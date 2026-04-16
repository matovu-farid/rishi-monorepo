import { atom } from "jotai";

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

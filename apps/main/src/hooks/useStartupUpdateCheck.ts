import { useEffect } from "react";
import { checkForUpdates } from "@/modules/updater";

/**
 * Runs one silent update check per app session, shortly after mount.
 * Silent failures are swallowed so the user is never disturbed on startup.
 * See docs/superpowers/specs/2026-04-16-auto-updater-design.md.
 */
export function useStartupUpdateCheck(): void {
  useEffect(() => {
    void checkForUpdates({ silent: true });
  }, []);
}

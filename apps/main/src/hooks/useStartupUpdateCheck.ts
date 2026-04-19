import { useEffect } from "react";
import { checkForUpdates } from "@/modules/updater";

/**
 * Runs a silent update check on app launch.
 * If an update is found it downloads, installs, and relaunches automatically.
 */
export function useStartupUpdateCheck(): void {
  useEffect(() => {
    void checkForUpdates({ silent: true });
  }, []);
}

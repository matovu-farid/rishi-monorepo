import { useEffect } from 'react'
import { checkForUpdates } from '../modules/updater'

/**
 * Runs a silent update check on app launch.
 * If an update is found, the main process handles download/install
 * via electron-updater.
 */
export function useStartupUpdateCheck(): void {
  useEffect(() => {
    void checkForUpdates({ silent: true })
  }, [])
}

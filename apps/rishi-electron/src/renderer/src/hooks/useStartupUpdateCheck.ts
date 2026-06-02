import { useEffect } from 'react'
import { checkForUpdates } from '../modules/updater'

/**
 * Runs a silent update check on app launch. Respects the user's
 * `autoUpdateEnabled` preference (default true) — when opted out, the
 * silent check is skipped. The user can still trigger a manual check
 * from the application menu.
 *
 * If an update is found, the main process downloads it in the background
 * and electron-updater applies it on the next app quit
 * (`autoInstallOnAppQuit`). No user prompts are shown — the flow is
 * seamless.
 */
export function useStartupUpdateCheck(): void {
  useEffect(() => {
    let cancelled = false
    async function run(): Promise<void> {
      const raw = await window.electron.getStoreValue('autoUpdateEnabled')
      const enabled = typeof raw === 'boolean' ? raw : true
      if (cancelled || !enabled) return
      await checkForUpdates({ silent: true })
    }
    void run()
    return () => {
      cancelled = true
    }
  }, [])
}

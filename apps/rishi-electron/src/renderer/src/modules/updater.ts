/**
 * Electron updater module.
 * Uses window.electron IPC to communicate with the main process
 * which handles electron-updater.
 */
import { create } from 'zustand'
import { devtools } from 'zustand/middleware'

export type UpdateStatus =
  | { kind: 'idle' }
  | { kind: 'checking' }
  | { kind: 'available'; version: string }
  | { kind: 'downloading'; percent: number; transferred: number; total: number }
  | { kind: 'ready'; version: string }
  | { kind: 'installing' }
  | { kind: 'error'; message: string }

interface UpdateState {
  status: UpdateStatus
  setStatus: (status: UpdateStatus) => void
}

export const useUpdateStore = create<UpdateState>()(
  devtools(
    (set) => ({
      status: { kind: 'idle' },
      setStatus: (status) => set({ status })
    }),
    { name: 'update-store' }
  )
)

export function renderStatus(status: UpdateStatus): string | null {
  switch (status.kind) {
    case 'idle':
      return null
    case 'checking':
      return 'Checking for updates\u2026'
    case 'available':
      return `Update v${status.version} available`
    case 'downloading': {
      const pct = Math.floor(status.percent)
      return `Downloading\u2026 ${pct}%`
    }
    case 'ready':
      return `v${status.version} ready to install`
    case 'installing':
      return 'Installing\u2026'
    case 'error':
      return 'Update failed. See console for details.'
  }
}

let listenersRegistered = false

/**
 * Register one-time listeners for autoUpdater events forwarded from main process.
 */
function ensureListeners(): void {
  if (listenersRegistered || !window.electron) return
  listenersRegistered = true

  const { setStatus } = useUpdateStore.getState()

  window.electron.on('update-available', (info: unknown) => {
    const data = info as { version?: string } | undefined
    setStatus({ kind: 'available', version: data?.version ?? 'unknown' })
  })

  window.electron.on('update-not-available', () => {
    setStatus({ kind: 'idle' })
  })

  window.electron.on('download-progress', (progress: unknown) => {
    const data = progress as {
      percent?: number
      transferred?: number
      total?: number
    }
    setStatus({
      kind: 'downloading',
      percent: data?.percent ?? 0,
      transferred: data?.transferred ?? 0,
      total: data?.total ?? 0
    })
  })

  window.electron.on('update-downloaded', (info: unknown) => {
    const data = info as { version?: string } | undefined
    setStatus({ kind: 'ready', version: data?.version ?? 'unknown' })
  })

  window.electron.on('update-error', (error: unknown) => {
    const msg = typeof error === 'string' ? error : String(error)
    console.warn('[updater] error from main process:', msg)
    setStatus({ kind: 'error', message: msg })
  })
}

let checkInFlight = false

export async function checkForUpdates(_opts?: { silent: boolean }): Promise<void> {
  if (checkInFlight) return
  if (!window.electron) return

  ensureListeners()

  checkInFlight = true
  useUpdateStore.getState().setStatus({ kind: 'checking' })

  try {
    const result = await window.electron.checkForUpdates()

    if (!result?.updateAvailable) {
      // update-not-available event from main will also fire,
      // but set idle immediately for responsive UI
      useUpdateStore.getState().setStatus({ kind: 'idle' })
    }
    // If update IS available, the 'update-available' event from main will
    // set the correct status with version info.
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    console.warn('[updater] checkForUpdates failed:', msg)
    useUpdateStore.getState().setStatus({ kind: 'error', message: msg })
  } finally {
    // Why: single-flight guard. The early-return at the top of this function is the
    // sole gate; checkInFlight transitions true → false here serially with no other
    // writers. The eslint rule cannot see the gate pattern.
    // eslint-disable-next-line require-atomic-updates
    checkInFlight = false
  }
}

export async function downloadUpdate(): Promise<void> {
  if (!window.electron) return

  try {
    await window.electron.downloadUpdate()
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    console.warn('[updater] downloadUpdate failed:', msg)
    useUpdateStore.getState().setStatus({ kind: 'error', message: msg })
  }
}

export function installUpdate(): void {
  if (!window.electron) return

  useUpdateStore.getState().setStatus({ kind: 'installing' })
  void window.electron.installUpdate()
}

export type SyncStatus = 'not-synced' | 'syncing' | 'synced' | 'error' | 'offline'

type SyncStatusListener = (status: SyncStatus, lastSyncAt: number | null) => void

let status: SyncStatus = 'not-synced'
let lastSyncAt: number | null = null
const listeners = new Set<SyncStatusListener>()

function notifyListeners(): void {
  for (const listener of listeners) {
    listener(status, lastSyncAt)
  }
}

export function setSyncStatus(newStatus: SyncStatus): void {
  status = newStatus
  if (newStatus === 'synced') {
    lastSyncAt = Date.now()
  }
  notifyListeners()
}

export function onSyncStatusChange(listener: SyncStatusListener): () => void {
  listeners.add(listener)
  // Immediately call with current state
  listener(status, lastSyncAt)
  return () => {
    listeners.delete(listener)
  }
}

export function getSyncStatus(): { status: SyncStatus; lastSyncAt: number | null } {
  return { status, lastSyncAt }
}

import { useState, useEffect } from 'react'
import { onSyncStatusChange, type SyncStatus } from '@/lib/sync/status'

export function useSyncStatus(): { status: SyncStatus; lastSyncAt: number | null } {
  const [status, setStatus] = useState<SyncStatus>('not-synced')
  const [lastSyncAt, setLastSyncAt] = useState<number | null>(null)

  useEffect(() => {
    const unsubscribe = onSyncStatusChange((newStatus, newLastSyncAt) => {
      setStatus(newStatus)
      setLastSyncAt(newLastSyncAt)
    })
    return unsubscribe
  }, [])

  return { status, lastSyncAt }
}

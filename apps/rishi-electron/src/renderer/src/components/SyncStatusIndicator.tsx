import { useEffect, useState } from 'react'
import { getSyncService } from '@/services'
import type { SyncStatus } from '@/services/sync'

export function SyncStatusIndicator() {
  const [status, setStatus] = useState<SyncStatus>(() => getSyncService().getStatus().status)

  useEffect(() => {
    return getSyncService().onStatusChange((snapshot) => {
      setStatus(snapshot.status)
    })
  }, [])

  if (status === 'synced' || status === 'not-synced') return null

  const labels: Record<string, { text: string; color: string }> = {
    syncing: { text: 'Syncing...', color: 'text-blue-500' },
    error: { text: 'Sync error', color: 'text-red-500' },
    offline: { text: 'Offline', color: 'text-gray-400' }
  }

  const label = labels[status] as { text: string; color: string } | undefined
  if (!label) return null

  return (
    <div className={`text-xs ${label.color} flex items-center gap-1`}>
      {status === 'syncing' && (
        <span className="animate-spin inline-block w-3 h-3 border border-current border-t-transparent rounded-full" />
      )}
      {label.text}
    </div>
  )
}

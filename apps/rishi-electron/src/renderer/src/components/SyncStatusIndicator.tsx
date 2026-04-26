import { useEffect, useState } from 'react'
import { onSyncStatusChange } from '@/modules/sync-triggers'

export function SyncStatusIndicator() {
  const [status, setStatus] = useState<string>('not-synced')

  useEffect(() => {
    return onSyncStatusChange(setStatus)
  }, [])

  if (status === 'synced' || status === 'not-synced') return null

  const labels: Record<string, { text: string; color: string }> = {
    syncing: { text: 'Syncing...', color: 'text-blue-500' },
    error: { text: 'Sync error', color: 'text-red-500' },
    offline: { text: 'Offline', color: 'text-gray-400' }
  }

  const label = labels[status]
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

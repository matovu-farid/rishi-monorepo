import { useEffect, useState } from 'react'
import { getBookImportService } from '@/services'

/**
 * Shows "Indexing..." with a spinner whenever the book-import service is
 * embedding chunks into the vector store. Mounted in the bottom-right of
 * the app shell, mirroring the SyncStatusIndicator (bottom-left). Hides
 * itself when no indexing is in flight.
 *
 * Listens to ImportProgressEvent: 'indexing' / 'indexed' from book-import.
 */
type IndexingPhase = 'idle' | 'indexing' | 'failed'

export function IndexingStatusIndicator() {
  const [phase, setPhase] = useState<IndexingPhase>('idle')

  useEffect(() => {
    return getBookImportService().onImportProgress((event) => {
      if (event.kind === 'indexing') setPhase('indexing')
      else if (event.kind === 'indexed') setPhase(event.ok ? 'idle' : 'failed')
    })
  }, [])

  if (phase === 'idle') return null

  const labels: Record<Exclude<IndexingPhase, 'idle'>, { text: string; color: string }> = {
    indexing: { text: 'Indexing...', color: 'text-blue-500' },
    failed: { text: 'Indexing failed', color: 'text-red-500' }
  }
  const label = labels[phase]

  return (
    <div className={`text-xs ${label.color} flex items-center gap-1`}>
      {phase === 'indexing' && (
        <span className="animate-spin inline-block w-3 h-3 border border-current border-t-transparent rounded-full" />
      )}
      {label.text}
    </div>
  )
}

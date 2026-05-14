import { useState, useEffect } from 'react'
import { Settings } from 'lucide-react'
import { Popover, PopoverTrigger, PopoverContent } from '@/components/ui/popover'
import {
  checkForUpdates,
  downloadUpdate,
  installUpdate,
  renderStatus,
  useUpdateStore
} from '@/modules/updater'

export function UpdateMenu() {
  const status = useUpdateStore((s) => s.status)
  const [version, setVersion] = useState<string>('')

  useEffect(() => {
    window.electron
      .getAppVersion()
      .then(setVersion)
      .catch((err: unknown) => console.warn('[UpdateMenu] getAppVersion failed:', err))
  }, [])

  const busy =
    status.kind === 'checking' || status.kind === 'downloading' || status.kind === 'installing'

  const statusLine = renderStatus(status)

  return (
    <Popover>
      <PopoverTrigger
        aria-label="App settings"
        className="p-2 rounded-md hover:bg-black/10 text-black"
      >
        <Settings size={20} />
        {(status.kind === 'available' || status.kind === 'ready') && (
          <span className="absolute top-1 right-1 w-2 h-2 bg-blue-600 rounded-full" />
        )}
      </PopoverTrigger>
      <PopoverContent align="end" className="w-64">
        <div className="text-sm text-muted-foreground mb-3">
          Rishi {version ? `v${version}` : ''}
        </div>

        {/* Primary action button changes based on state */}
        {status.kind === 'available' ? (
          <button
            type="button"
            onClick={() => void downloadUpdate()}
            className="w-full rounded-md border px-3 py-1.5 text-sm hover:bg-black/5"
          >
            Download Update
          </button>
        ) : status.kind === 'ready' ? (
          <button
            type="button"
            onClick={() => installUpdate()}
            className="w-full rounded-md border border-blue-600 bg-blue-600 text-white px-3 py-1.5 text-sm hover:bg-blue-700"
          >
            Restart &amp; Install
          </button>
        ) : (
          <button
            type="button"
            disabled={busy}
            onClick={() => void checkForUpdates({ silent: false })}
            className="w-full rounded-md border px-3 py-1.5 text-sm hover:bg-black/5 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {busy ? 'Checking\u2026' : 'Check for Updates'}
          </button>
        )}

        {/* Download progress bar */}
        {status.kind === 'downloading' && (
          <div className="mt-2">
            <div className="w-full bg-gray-200 rounded-full h-1.5">
              <div
                className="bg-blue-600 h-1.5 rounded-full transition-all duration-300"
                style={{ width: `${Math.floor(status.percent)}%` }}
              />
            </div>
          </div>
        )}

        {statusLine ? <div className="mt-2 text-xs text-muted-foreground">{statusLine}</div> : null}
      </PopoverContent>
    </Popover>
  )
}

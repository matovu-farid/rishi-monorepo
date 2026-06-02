import type React from 'react'
export type FileTransferRowProps = {
  peerName: string
  sent: number
  total: number
  failed?: boolean
}
export function FileTransferRow({
  peerName,
  sent,
  total,
  failed
}: FileTransferRowProps): React.JSX.Element {
  const pct = total > 0 ? Math.round((sent / total) * 100) : 0
  return (
    <div className="text-xs py-1">
      <div className="flex justify-between">
        <span>{peerName}</span>
        <span>{failed ? 'failed' : `${pct}%`}</span>
      </div>
      <div className="h-1 bg-muted rounded mt-1">
        <div
          className={`h-1 rounded ${failed ? 'bg-destructive' : 'bg-primary'}`}
          style={{ width: `${pct}%` }}
        />
      </div>
    </div>
  )
}

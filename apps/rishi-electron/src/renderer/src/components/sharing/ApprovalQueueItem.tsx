import type React from 'react'
export type ApprovalQueueItemProps = {
  displayName: string
  onApprove: () => void
  onReject: () => void
}
export function ApprovalQueueItem(p: ApprovalQueueItemProps): React.JSX.Element {
  return (
    <div className="flex items-center justify-between py-1">
      <span className="text-sm">{p.displayName}</span>
      <div className="flex gap-2 text-sm">
        <button onClick={p.onApprove} className="underline">
          Approve
        </button>
        <button onClick={p.onReject} className="underline">
          Reject
        </button>
      </div>
    </div>
  )
}

import React from 'react'

export type ApprovalWaitingScreenProps = {
  hostName: string
  onCancel: () => void
}

export function ApprovalWaitingScreen({
  hostName,
  onCancel
}: ApprovalWaitingScreenProps): React.JSX.Element {
  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-live="polite"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60"
    >
      <div className="rounded-md bg-background p-6 shadow-lg max-w-sm w-full text-center">
        <h2 className="text-lg font-semibold mb-2">Waiting for {hostName}</h2>
        <p className="text-sm text-muted-foreground mb-4">
          The host is reviewing your request to join the reading session.
        </p>
        <button
          type="button"
          onClick={onCancel}
          className="px-4 py-2 rounded-md border bg-background hover:bg-accent"
        >
          Cancel
        </button>
      </div>
    </div>
  )
}

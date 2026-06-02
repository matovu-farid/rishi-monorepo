import type React from 'react'
export type KickedDialogProps = { reason: string; onDismiss: () => void }
export function KickedDialog({ reason, onDismiss }: KickedDialogProps): React.JSX.Element {
  return (
    <div
      role="dialog"
      aria-modal="true"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60"
    >
      <div className="rounded-md bg-background p-6 shadow-lg max-w-sm w-full">
        <h2 className="text-lg font-semibold mb-2">You were removed from the session</h2>
        <p className="text-sm text-muted-foreground mb-4">{reason}</p>
        <button onClick={onDismiss} className="px-4 py-2 rounded border">
          OK
        </button>
      </div>
    </div>
  )
}

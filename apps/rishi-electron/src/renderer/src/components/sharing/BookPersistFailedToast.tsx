import type React from 'react'

export type BookPersistFailedToastProps = {
  message: string
  onDismiss: () => void
}

/**
 * Surfaces a `saveTransferredBook` IPC failure to the viewer. Mirrors
 * `RoleTransferToast` styling — auto-dismissed after ~5s by the host
 * component's useEffect.
 */
export function BookPersistFailedToast({
  message,
  onDismiss
}: BookPersistFailedToastProps): React.JSX.Element {
  return (
    <div
      role="alert"
      aria-live="polite"
      className="fixed bottom-4 right-4 bg-destructive text-destructive-foreground px-3 py-2 rounded"
    >
      {message}
      <button onClick={onDismiss} className="ml-3 underline text-xs">
        OK
      </button>
    </div>
  )
}

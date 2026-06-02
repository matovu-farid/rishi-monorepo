import type React from 'react'
export type RoleTransferToastProps = { message: string; onDismiss: () => void }
export function RoleTransferToast({
  message,
  onDismiss
}: RoleTransferToastProps): React.JSX.Element {
  return (
    <div
      role="status"
      aria-live="polite"
      className="fixed bottom-4 right-4 bg-foreground text-background px-3 py-2 rounded"
    >
      {message}
      <button onClick={onDismiss} className="ml-3 underline text-xs">
        OK
      </button>
    </div>
  )
}

import type React from 'react'
import { useState } from 'react'
export type StartSessionPopoverProps = {
  onStart: (opts: { requiresApproval: boolean }) => void
  onCancel: () => void
}
export function StartSessionPopover({
  onStart,
  onCancel
}: StartSessionPopoverProps): React.JSX.Element {
  const [requiresApproval, setRequiresApproval] = useState(true)
  return (
    <div className="p-4 space-y-3 bg-background border rounded shadow w-64">
      <label className="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          checked={requiresApproval}
          onChange={(e) => setRequiresApproval(e.target.checked)}
        />
        Require approval to join
      </label>
      <div className="flex justify-end gap-2">
        <button onClick={onCancel} className="px-3 py-1 text-sm">
          Cancel
        </button>
        <button
          onClick={() => onStart({ requiresApproval })}
          className="px-3 py-1 bg-primary text-primary-foreground rounded text-sm"
        >
          Start
        </button>
      </div>
    </div>
  )
}

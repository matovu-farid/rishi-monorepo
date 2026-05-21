import { Trash2 } from 'lucide-react'
import { Button } from '../ui/Button'

export interface SelectionActionBarProps {
  count: number
  onSelectAll: () => void
  onDelete: () => void
  onCancel: () => void
}

export function SelectionActionBar({
  count,
  onSelectAll,
  onDelete,
  onCancel
}: SelectionActionBarProps): React.JSX.Element {
  return (
    <div
      role="toolbar"
      aria-label="Selection actions"
      className="fixed bottom-4 left-1/2 -translate-x-1/2 z-40 flex items-center gap-2 bg-white border border-gray-200 shadow-lg rounded-full px-4 py-2"
    >
      <span className="text-sm font-medium text-gray-700 mr-1">{count} selected</span>
      <Button variant="ghost" onClick={onSelectAll}>
        Select All
      </Button>
      <Button
        variant="ghost"
        onClick={onDelete}
        disabled={count === 0}
        startIcon={<Trash2 size={16} />}
        className="text-red-600 hover:text-red-700"
      >
        Delete
      </Button>
      <Button variant="ghost" onClick={onCancel}>
        Cancel
      </Button>
    </div>
  )
}

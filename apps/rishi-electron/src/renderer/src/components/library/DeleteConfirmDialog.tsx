import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '../ui/dialog'
import { Button } from '../ui/Button'

export interface DeleteConfirmDialogProps {
  open: boolean
  count: number
  onCancel: () => void
  onConfirm: () => void
  isDeleting: boolean
}

export function DeleteConfirmDialog({
  open,
  count,
  onCancel,
  onConfirm,
  isDeleting
}: DeleteConfirmDialogProps): React.JSX.Element {
  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (!next && !isDeleting) onCancel()
      }}
    >
      <DialogContent showCloseButton={false}>
        <DialogHeader>
          <DialogTitle>
            Delete {count} {count === 1 ? 'book' : 'books'}?
          </DialogTitle>
          <DialogDescription>This cannot be undone.</DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="ghost" onClick={onCancel} disabled={isDeleting} autoFocus>
            Cancel
          </Button>
          <Button
            onClick={onConfirm}
            disabled={isDeleting}
            className="bg-red-600 text-white hover:bg-red-700"
          >
            {isDeleting ? 'Deleting…' : 'Delete'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

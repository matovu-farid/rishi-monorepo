import React, { useState, useCallback } from 'react'
import { StartSessionPopover } from './StartSessionPopover'
import { useSessionMachine } from '@/hooks/useSessionMachine'

export type SessionEntryButtonProps = {
  /**
   * Numeric book id (matches the `Book.id` column). Used to look up
   * `fileHash` and `format` via IPC at the moment the host clicks Start, so
   * the toolbar doesn't have to thread those fields through every reader
   * view.
   */
  bookId: number
}

/**
 * Thin entry-point wrapper that pairs a "Share" button, the
 * `StartSessionPopover`, and the `useSessionMachine` hook.
 *
 * Kept intentionally small so the reader toolbar can wire sharing in via a
 * single conditional render gated by `isSharingEnabled()`. All session-life
 * cycle UI lives downstream of the machine (SessionPanel, etc.) — this
 * component is responsible only for "the moment the host clicks Share".
 */
export function SessionEntryButton({ bookId }: SessionEntryButtonProps): React.JSX.Element {
  const [open, setOpen] = useState(false)
  const { send } = useSessionMachine()

  const onStart = useCallback(
    ({ requiresApproval }: { requiresApproval: boolean }) => {
      setOpen(false)
      void (async () => {
        const [{ jwt }, book] = await Promise.all([
          window.electron.sharing.getSigningJwt(),
          window.electron.getBook(bookId)
        ])
        if (!book || !book.fileHash) return
        const format = book.format
        if (format !== 'epub' && format !== 'pdf') return
        send({
          type: 'CREATE_SESSION',
          me: { userId: 'self', displayName: 'self', authToken: jwt },
          bookContext: {
            bookId: String(book.id),
            contentHash: book.fileHash,
            format
          },
          requiresApproval
        })
      })()
    },
    [send, bookId]
  )

  const onCancel = useCallback(() => setOpen(false), [])

  return (
    <div className="relative">
      <button
        type="button"
        aria-label="Share this book"
        aria-haspopup="dialog"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
        className="px-3 py-1 text-sm rounded bg-primary text-primary-foreground"
      >
        Share
      </button>
      {open && (
        <div className="absolute right-0 mt-2 z-50" role="dialog">
          <StartSessionPopover onStart={onStart} onCancel={onCancel} />
        </div>
      )}
    </div>
  )
}

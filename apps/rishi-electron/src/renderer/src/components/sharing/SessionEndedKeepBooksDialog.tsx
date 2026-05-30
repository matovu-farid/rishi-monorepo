import React, { useEffect, useRef } from 'react'

export type KeepableBook = {
  dbBookId: number
  title: string
  fromDisplayName: string
  localPath: string
}

export type SessionEndedKeepBooksDialogProps = {
  books: KeepableBook[]
  onKeep: () => void
  onDiscard: () => void
}

export function SessionEndedKeepBooksDialog({
  books,
  onKeep,
  onDiscard
}: SessionEndedKeepBooksDialogProps): React.JSX.Element {
  const keepRef = useRef<HTMLButtonElement | null>(null)
  useEffect(() => {
    keepRef.current?.focus()
  }, [])
  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="keep-books-title"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60"
    >
      <div className="rounded-md bg-background p-6 shadow-lg max-w-md w-full">
        <h2 id="keep-books-title" className="text-lg font-semibold mb-2">
          Keep these books in your library?
        </h2>
        <p className="text-sm text-muted-foreground mb-3">
          You received the following {books.length === 1 ? 'book' : 'books'} during this reading
          session.
        </p>
        <ul className="mb-4 space-y-1 text-sm max-h-48 overflow-auto">
          {books.map((b) => (
            <li key={b.dbBookId} className="flex justify-between border-b py-1 last:border-b-0">
              <span className="font-medium truncate">{b.title}</span>
              <span className="text-muted-foreground ml-2 shrink-0">from {b.fromDisplayName}</span>
            </li>
          ))}
        </ul>
        <div className="flex justify-end gap-2">
          <button
            type="button"
            onClick={onDiscard}
            className="px-4 py-2 rounded border text-sm"
          >
            Discard
          </button>
          <button
            ref={keepRef}
            type="button"
            onClick={onKeep}
            className="px-4 py-2 rounded bg-primary text-primary-foreground text-sm"
          >
            Keep
          </button>
        </div>
      </div>
    </div>
  )
}

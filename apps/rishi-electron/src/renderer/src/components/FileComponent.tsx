import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import Loader from './Loader'
import { toast } from 'sonner'
import { Button } from './ui/Button'
import { Trash2, Plus, Search, BookOpen, Check, Square, CheckSquare } from 'lucide-react'
// chooseFiles moved into BookDiscoveryModal
import type { Book } from '@/lib/api'
import { deleteBook, getBooks } from '@/lib/api'
import { getBookImportService, getVoiceChatService } from '@/services'
import { prefetchTTSForBooks } from '@/modules/ttsPrefetch'
import {
  resolveDroppedFilePaths,
  DroppedFilesError,
  getFilesFromDropEvent
} from '@/modules/handleDroppedFiles'
import { useEffect, useMemo, useState, useCallback } from 'react'
import { useDropzone } from 'react-dropzone'
import { usePdfStore } from '@/stores/pdfStore'
import { LoginButton } from './LoginButton'
import { BookDiscoveryModal } from './BookDiscoveryModal'
import { HelpMenu } from './HelpMenu'
import { evictPdf } from '@/services/reader-cache/pdf-cache'
import { evictEpub } from '@/services/reader-cache/epub-cache'
import { useBookSelection } from './library/useBookSelection'
import { SelectionActionBar } from './library/SelectionActionBar'

// Module-level caches survive library remounts (e.g., navigating back from a
// reader). Two pieces are needed to avoid the white flash on re-entry:
//   1. URL cache: skips re-running URL.createObjectURL on every mount.
//   2. Image cache: holds a detached HTMLImageElement per cover. Keeping a
//      live Image reference prevents the browser from evicting the decoded
//      pixels when the visible <img> unmounts. On remount the new <img> hits
//      the same blob URL and the browser reuses the warm decode → paints on
//      first frame instead of flashing white.
// Both entries are released in revokeCachedCoverUrl when a book is deleted.
const coverUrlCache = new Map<number, string>()
const coverImageCache = new Map<number, HTMLImageElement>()

function getCachedCoverUrl(book: Book): string | null {
  const cached = coverUrlCache.get(book.id)
  if (cached) return cached
  const url = bytesToBlobUrl(book.cover)
  if (!url) return null
  coverUrlCache.set(book.id, url)
  const preload = new Image()
  preload.src = url
  void preload.decode().catch(() => {})
  coverImageCache.set(book.id, preload)
  return url
}

function revokeCachedCoverUrl(bookId: number): void {
  const url = coverUrlCache.get(bookId)
  if (url) {
    URL.revokeObjectURL(url)
    coverUrlCache.delete(bookId)
  }
  coverImageCache.delete(bookId)
}

function bytesToBlobUrl(bytes: number[]): string | null {
  if (bytes.length === 0) return null
  const uint8Array = new Uint8Array(bytes)
  let mimeType = 'image/jpeg'
  if (uint8Array.length >= 8) {
    if (uint8Array[0] === 0x89 && uint8Array[1] === 0x50) mimeType = 'image/png'
    else if (uint8Array[0] === 0xff && uint8Array[1] === 0xd8) mimeType = 'image/jpeg'
    else if (uint8Array[0] === 0x47 && uint8Array[1] === 0x49) mimeType = 'image/gif'
    else if (uint8Array[0] === 0x52 && uint8Array[1] === 0x49 && uint8Array[8] === 0x57)
      mimeType = 'image/webp'
  }
  return URL.createObjectURL(new Blob([uint8Array], { type: mimeType }))
}

function BookCoverImage({ book }: { book: Book }) {
  // Read from module cache during render — no state, no effect, no flash.
  // The cache outlives this component, so remounts hit it instead of
  // re-decoding bytes and triggering a placeholder paint.
  const coverUrl = getCachedCoverUrl(book)

  if (!coverUrl) {
    return (
      <div className="w-full aspect-[5/7] bg-gradient-to-br from-gray-100 to-gray-200 rounded-lg flex items-center justify-center shadow-sm">
        <BookOpen className="w-1/4 h-1/4 text-gray-300" strokeWidth={1.5} />
      </div>
    )
  }

  return (
    <img
      className="w-full aspect-[5/7] object-cover rounded-lg shadow-lg"
      src={coverUrl}
      alt={book.title}
      // sync: paint the cover in the same frame the <img> mounts.
      // Without this, the new <img> mounts with an empty raster on the
      // first paint and the decoded pixels arrive a frame later — that's
      // the brief white flash on library re-entry.
      decoding="sync"
    />
  )
}

export default function FileComponent(): React.JSX.Element {
  const setAllBooks = usePdfStore((s) => s.setAllBooks)
  const removeBook = usePdfStore((s) => s.removeBook)
  const queryClient = useQueryClient()
  const [newBookId, setNewBookId] = useState<string | null>(null)
  const [discoveryOpen, setDiscoveryOpen] = useState(false)
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number; book: Book } | null>(null)
  const [searchQuery, setSearchQuery] = useState('')
  const [lastReadBookId, setLastReadBookId] = useState<string | null>(null)

  const selection = useBookSelection()

  const openBookInNewWindow = useCallback((bookId: number) => {
    void (
      window as unknown as { electron: { openBook(id: number): Promise<void> } }
    ).electron.openBook(bookId)
  }, [])

  useEffect(() => {
    if (newBookId) openBookInNewWindow(Number(newBookId))
  }, [newBookId, openBookInNewWindow])

  const {
    isPending,
    error,
    data: books,
    isError
  } = useQuery({
    queryKey: ['books'],
    queryFn: async () => {
      getVoiceChatService().prewarmKey()
      return getBooks()
    }
  })

  // Run side-effects when fresh book data arrives. Keeping these out of
  // queryFn means the query closure stays stable (no setAllBooks/queryClient
  // dependency), and we still re-run on every successful refetch because
  // `books` identity changes.
  useEffect(() => {
    if (!books) return
    const pdfIds = books.filter((b) => b.kind === 'pdf').map((b) => b.id)
    setAllBooks(pdfIds)
    books.forEach((book) => {
      void queryClient.prefetchQuery({
        queryKey: ['book', book.id.toString()],
        queryFn: () => book
      })
    })
    void prefetchTTSForBooks(books)
  }, [books, setAllBooks, queryClient])

  const deleteBookMutation = useMutation({
    mutationKey: ['deleteBook'],
    mutationFn: async ({ book }: { book: Book }) => {
      await deleteBook({ bookId: book.id })
      removeBook(book.id)
      revokeCachedCoverUrl(book.id)
      evictPdf(book.id)
      evictEpub(book.id)
    },
    onError: (err) => {
      console.error('Error deleting book:', err)
      toast.error("Can't remove book")
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['books'] })
    }
  })

  const processFilePaths = async (filePaths: string[]) => {
    const svc = getBookImportService()
    const results = await svc.importBatch(filePaths)

    let lastSuccess: { ok: true; bookId: number } | null = null
    for (const r of results) {
      if (!r.ok) {
        toast.error(`Failed to import ${r.filePath}: ${r.error}`)
        continue
      }
      lastSuccess = { ok: true, bookId: r.bookId }
    }

    await queryClient.invalidateQueries({ queryKey: ['books'] })
    if (lastSuccess) {
      setNewBookId(null)
      setTimeout(() => setNewBookId(String(lastSuccess.bookId)), 0)
    }
  }

  // React Dropzone for drag-and-drop (replaces Tauri drag-drop).
  // `getFilesFromEvent` overrides react-dropzone's default extractor so we
  // get the original drag-drop File objects — required for Electron's
  // `webUtils.getPathForFile` to return an absolute path.
  const { getRootProps, getInputProps, isDragActive } = useDropzone({
    noClick: true,
    getFilesFromEvent: getFilesFromDropEvent,
    accept: {
      'application/epub+zip': ['.epub'],
      'application/pdf': ['.pdf'],
      'application/x-mobipocket-ebook': ['.mobi', '.azw3']
    },
    onDrop: (files) => {
      try {
        const paths = resolveDroppedFilePaths(files, window.electron.getPathForFile)
        void processFilePaths(paths)
      } catch (err) {
        if (err instanceof DroppedFilesError) {
          toast.error(err.message)
          return
        }
        throw err
      }
    }
  })

  useEffect(() => {
    const handleClick = () => setContextMenu(null)
    document.addEventListener('click', handleClick)
    return () => document.removeEventListener('click', handleClick)
  }, [])

  useEffect(() => {
    try {
      const stored = localStorage.getItem('lastReadBookId')
      // Why: hydrating from external (localStorage) into React state — legitimate async-like read
      // eslint-disable-next-line react-hooks/set-state-in-effect
      if (stored) setLastReadBookId(stored)
    } catch {
      // no-op
    }
  }, [])

  useEffect(() => {
    const handler = () => {
      try {
        setLastReadBookId(localStorage.getItem('lastReadBookId'))
      } catch {
        // no-op
      }
    }
    window.addEventListener('lastReadBookChanged', handler)
    return () => window.removeEventListener('lastReadBookChanged', handler)
  }, [])

  const filteredBooks = useMemo(() => {
    if (!books) return []
    if (!searchQuery.trim()) return books
    const q = searchQuery.toLowerCase()
    return books.filter(
      (b) => b.title.toLowerCase().includes(q) || b.author.toLowerCase().includes(q)
    )
  }, [books, searchQuery])

  const lastReadBook = useMemo(() => {
    if (!lastReadBookId || !books) return null
    return books.find((b) => b.id.toString() === lastReadBookId) ?? null
  }, [lastReadBookId, books])

  if (isError) return <div className="w-full h-full place-items-center grid">{error.message}</div>
  if (isPending)
    return (
      <div className="w-full h-full place-items-center grid">
        <Loader />
      </div>
    )

  return (
    <div {...getRootProps()} className="w-full h-full flex flex-col overflow-hidden">
      <input {...getInputProps()} />
      <div data-electron-drag-region className="px-4 pt-10 pb-2 flex items-center gap-2 flex-none">
        <div className="relative flex-1 max-w-xs">
          <Search
            size={16}
            className="absolute left-2.5 top-1/2 -translate-y-1/2 text-gray-400 pointer-events-none"
          />
          <input
            type="text"
            placeholder="Search library..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="w-full bg-gray-100 text-gray-900 placeholder-gray-400 text-sm rounded-lg pl-8 pr-3 py-1.5 border-none focus:outline-none focus:ring-1 focus:ring-gray-300"
          />
        </div>
        <div className="flex-1" />
        <div data-tour="import-books" className="flex items-center gap-1">
          <Button
            variant="ghost"
            className="cursor-pointer"
            startIcon={<Plus size={20} />}
            onClick={() => setDiscoveryOpen(true)}
          >
            Add Book
          </Button>
        </div>
        <Button
          variant="ghost"
          className="cursor-pointer"
          onClick={() => {
            if (selection.selectMode) selection.exitSelectMode()
            else selection.enterSelectMode()
          }}
          startIcon={selection.selectMode ? <CheckSquare size={20} /> : <Square size={20} />}
        >
          {selection.selectMode ? 'Cancel' : 'Select'}
        </Button>
        <LoginButton />
        <HelpMenu />
      </div>

      <div className="flex-1 min-h-0 overflow-y-auto overflow-x-hidden">
        {lastReadBook ? (
          <div className="px-5 mb-4">
            <p className="text-xs text-gray-400 uppercase tracking-wider mb-2">Reading Now</p>
            <button
              type="button"
              onClick={() => openBookInNewWindow(lastReadBook.id)}
              className="flex items-center gap-4 bg-gray-50 rounded-xl p-3 hover:bg-gray-100 transition-colors w-full text-left"
            >
              <div className="w-16 shrink-0">
                <BookCoverImage book={lastReadBook} />
              </div>
              <div className="min-w-0">
                <p className="text-sm font-medium text-gray-900 truncate">{lastReadBook.title}</p>
                <p className="text-xs text-gray-500 truncate">{lastReadBook.author}</p>
              </div>
            </button>
          </div>
        ) : null}

        <div
          data-tour="book-grid"
          style={
            filteredBooks.length > 0
              ? {
                  display: 'grid',
                  gridTemplateColumns: 'repeat(auto-fill, minmax(150px, 1fr))',
                  gridAutoFlow: 'row'
                }
              : {}
          }
          className={
            filteredBooks.length > 0
              ? 'w-full p-5 gap-x-6 gap-y-8 items-start cursor-pointer'
              : 'grid place-items-center gap-3 rounded-3xl w-[50vw] h-[50vh] p-5 mx-auto'
          }
        >
          {isDragActive && books.length === 0 ? (
            <p>Drop the files here ...</p>
          ) : filteredBooks.length > 0 ? (
            filteredBooks.map((book) => {
              const isSelected = selection.selectedIds.has(book.id)
              return (
                <div
                  key={book.id}
                  className={`flex flex-col gap-1 relative transition-transform duration-200 ease-out hover:scale-[1.03] ${
                    isSelected ? 'ring-2 ring-blue-500 rounded-lg' : ''
                  }`}
                  onContextMenu={(e) => {
                    e.preventDefault()
                    setContextMenu({ x: e.clientX, y: e.clientY, book })
                  }}
                >
                  <button
                    type="button"
                    aria-label={selection.selectMode ? `Select ${book.title}` : undefined}
                    onClick={(e) => {
                      if (e.shiftKey && selection.selectMode) {
                        e.preventDefault()
                        selection.extendTo(
                          book.id,
                          filteredBooks.map((b) => b.id)
                        )
                        return
                      }
                      if (e.metaKey || e.ctrlKey) {
                        e.preventDefault()
                        if (!selection.selectMode) {
                          selection.enterSelectMode(book.id)
                        } else {
                          selection.toggle(book.id)
                        }
                        return
                      }
                      if (selection.selectMode) {
                        e.preventDefault()
                        selection.toggle(book.id)
                        return
                      }
                      openBookInNewWindow(book.id)
                    }}
                    className="block bg-transparent w-full p-0 border-0 cursor-pointer relative"
                  >
                    <BookCoverImage book={book} />
                    {selection.selectMode ? (
                      <span
                        className={`absolute top-2 left-2 w-5 h-5 rounded-full flex items-center justify-center ${
                          isSelected ? 'bg-blue-600 text-white' : 'bg-white/90 border border-gray-300'
                        }`}
                        aria-hidden="true"
                      >
                        {isSelected ? <Check size={14} strokeWidth={3} /> : null}
                      </span>
                    ) : null}
                  </button>
                  <p className="text-xs font-medium text-gray-900 truncate mt-1">{book.title}</p>
                  <p className="text-xs text-gray-500 truncate">{book.author}</p>
                </div>
              )
            })
          ) : (
            <div className="text-center">
              <p className="mb-4">No books yet. Add your first book!</p>
              <p className="text-sm text-gray-500">
                You can also drag and drop EPUB, PDF, or MOBI files here
              </p>
            </div>
          )}
        </div>
      </div>

      {contextMenu ? (
        <div
          className="fixed z-50 bg-white rounded-lg shadow-lg border border-gray-200 py-1 min-w-[140px]"
          style={{ top: contextMenu.y, left: contextMenu.x }}
        >
          <button
            className="flex items-center gap-2 px-3 py-2 text-sm text-gray-700 hover:bg-gray-50 w-full text-left rounded"
            onClick={() => {
              selection.enterSelectMode(contextMenu.book.id)
              setContextMenu(null)
            }}
          >
            <CheckSquare size={16} /> Select
          </button>
          <button
            className="flex items-center gap-2 px-3 py-2 text-sm text-red-600 hover:bg-red-50 w-full text-left rounded"
            onClick={() => {
              deleteBookMutation.mutate({ book: contextMenu.book })
              setContextMenu(null)
            }}
          >
            <Trash2 size={16} /> Delete
          </button>
        </div>
      ) : null}
      <BookDiscoveryModal open={discoveryOpen} onClose={() => setDiscoveryOpen(false)} />
      {selection.selectMode ? (
        <SelectionActionBar
          count={selection.selectedIds.size}
          onSelectAll={() => selection.selectAll(filteredBooks)}
          onDelete={() => {}}
          onCancel={() => selection.exitSelectMode()}
        />
      ) : null}
    </div>
  )
}

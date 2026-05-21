import { useEffect, useMemo, useRef, useState } from 'react'
import { X, BookOpen, DownloadCloud, FolderOpen, Loader2, FilePlus } from 'lucide-react'
import { toast } from 'sonner'
import { useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/Button'
import { ClipLoader } from 'react-spinners'
import { chooseFiles } from '@/modules/chooseFiles'
import {
  getBookImportService,
  type DiscoveredBook,
  type ImportResult,
  type ScanProgress
} from '@/services'

// Above this many selected books, surface a confirmation step so a stray
// "select all" can't kick off a 100+ book import without acknowledgement.
const BULK_CONFIRM_THRESHOLD = 20

function basename(path: string): string {
  const parts = path.split(/[\\/]/)
  return parts[parts.length - 1] || path
}

function summarizeBatchResults(results: ImportResult[]): {
  ok: number
  failed: number
  message: string
} {
  const ok = results.filter((r) => r.ok).length
  const failed = results.length - ok
  const message =
    failed === 0
      ? `Imported ${ok} book${ok === 1 ? '' : 's'}`
      : ok === 0
        ? `Failed to import ${failed} book${failed === 1 ? '' : 's'}`
        : `Imported ${ok}, failed ${failed}`
  return { ok, failed, message }
}

interface BookDiscoveryModalProps {
  open: boolean
  onClose: () => void
}

type ScanMode = 'default' | 'full'

function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

interface FolderCheckboxProps {
  checked: boolean
  indeterminate: boolean
  onChange: () => void
  label: string
}

function FolderCheckbox({ checked, indeterminate, onChange, label }: FolderCheckboxProps) {
  const ref = useRef<HTMLInputElement>(null)
  useEffect(() => {
    if (ref.current) ref.current.indeterminate = indeterminate && !checked
  }, [indeterminate, checked])
  return (
    <input
      ref={ref}
      type="checkbox"
      checked={checked}
      onChange={onChange}
      aria-label={label}
      className="w-4 h-4 accent-gray-700 cursor-pointer"
    />
  )
}

export function BookDiscoveryModal({ open, onClose }: BookDiscoveryModalProps) {
  const queryClient = useQueryClient()
  const [books, setBooks] = useState<DiscoveredBook[]>([])
  const [filter, setFilter] = useState('')
  const [scanning, setScanning] = useState(false)
  const [scanComplete, setScanComplete] = useState(false)
  const [progress, setProgress] = useState<ScanProgress | null>(null)
  const [mode, setMode] = useState<ScanMode>('default')
  const [selectedPaths, setSelectedPaths] = useState<Set<string>>(new Set())
  const [confirmOpen, setConfirmOpen] = useState(false)

  async function runImport(filePaths: string[]): Promise<ImportResult[]> {
    const results = await getBookImportService().importBatch(filePaths)
    await queryClient.invalidateQueries({ queryKey: ['books'] })
    return results
  }

  const handleBrowseFiles = async () => {
    try {
      const filePaths = await chooseFiles()
      if (filePaths.length === 0) return

      const label =
        filePaths.length === 1 ? `"${basename(filePaths[0])}"` : `${filePaths.length} books`

      setFilter('')
      toast.promise(runImport(filePaths), {
        loading: `Importing ${label}...`,
        success: (results) => summarizeBatchResults(results).message,
        error: `Failed to import ${label}`
      })
      void handleClose()
    } catch (err) {
      console.error('Failed to open file picker:', err)
    }
  }

  useEffect(() => {
    if (!open) return
    const svc = getBookImportService()

    // Why: resetting local state before kicking off external discovery subscription
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setBooks([])
    setProgress(null)
    setScanComplete(false)
    setScanning(true)
    setSelectedPaths(new Set())

    const unsub = svc.onDiscoveryEvent((event) => {
      if (event.kind === 'book-found') {
        setBooks((prev) => [...prev, event.book])
      } else if (event.kind === 'progress') {
        setProgress(event.progress)
      } else if (event.kind === 'complete') {
        setScanning(false)
        setScanComplete(true)
        setProgress(null)
      } else {
        console.error('[discovery] scanner error:', event.error)
        setScanning(false)
      }
    })

    svc.startDiscovery(mode)

    return () => {
      unsub()
      void svc.cancelDiscovery()
    }
  }, [open, mode])

  const handleModeChange = (newMode: ScanMode) => {
    if (newMode === mode) return
    setMode(newMode)
  }

  const handleClose = async () => {
    await getBookImportService().cancelDiscovery()
    setBooks([])
    setFilter('')
    setScanning(false)
    setScanComplete(false)
    setProgress(null)
    setSelectedPaths(new Set())
    setConfirmOpen(false)
    onClose()
  }

  const toggleBookSelected = (filepath: string) => {
    setSelectedPaths((prev) => {
      const next = new Set(prev)
      if (next.has(filepath)) next.delete(filepath)
      else next.add(filepath)
      return next
    })
  }

  const toggleFolderSelected = (folderBooks: DiscoveredBook[]) => {
    setSelectedPaths((prev) => {
      const next = new Set(prev)
      const allSelected = folderBooks.every((b) => next.has(b.filepath))
      if (allSelected) folderBooks.forEach((b) => next.delete(b.filepath))
      else folderBooks.forEach((b) => next.add(b.filepath))
      return next
    })
  }

  const performImport = (paths: string[]) => {
    if (paths.length === 0) return
    const pathSet = new Set(paths)

    setBooks((prev) => prev.filter((b) => !pathSet.has(b.filepath)))
    setSelectedPaths((prev) => {
      const next = new Set(prev)
      paths.forEach((p) => next.delete(p))
      return next
    })
    setFilter('')

    const count = paths.length
    toast.promise(runImport(paths), {
      loading: `Importing ${count} book${count === 1 ? '' : 's'}...`,
      success: (results) => summarizeBatchResults(results).message,
      error: `Failed to import ${count} book${count === 1 ? '' : 's'}`
    })
  }

  const handleImportClick = () => {
    if (selectedPaths.size === 0) return
    if (selectedPaths.size > BULK_CONFIRM_THRESHOLD) {
      setConfirmOpen(true)
      return
    }
    performImport(Array.from(selectedPaths))
  }

  const handleConfirmImport = () => {
    const paths = Array.from(selectedPaths)
    setConfirmOpen(false)
    performImport(paths)
  }

  const filteredBooks = books.filter((b) => {
    if (!filter.trim()) return true
    const q = filter.toLowerCase()
    return (
      b.filename.toLowerCase().includes(q) ||
      (b.title ?? '').toLowerCase().includes(q) ||
      (b.author ?? '').toLowerCase().includes(q)
    )
  })

  const grouped = useMemo(() => {
    return filteredBooks.reduce<Record<string, DiscoveredBook[]>>((acc, book) => {
      const bucket = acc[book.folder] as DiscoveredBook[] | undefined
      if (!bucket) acc[book.folder] = [book]
      else bucket.push(book)
      return acc
    }, {})
  }, [filteredBooks])

  if (!open) return null

  const selectedCount = selectedPaths.size
  const importDisabled = selectedCount === 0

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* Backdrop */}
      <div className="absolute inset-0 bg-black/30 backdrop-blur-sm" onClick={handleClose} />

      {/* Modal */}
      <div className="relative z-10 flex flex-col w-full max-w-2xl max-h-[85vh] bg-white rounded-xl shadow-2xl border border-gray-200 overflow-hidden">
        {/* Header */}
        <div className="flex items-center justify-between px-5 py-4 border-b border-gray-200">
          <div className="flex items-center gap-2">
            <BookOpen size={20} className="text-gray-600" />
            <h2 className="text-lg font-semibold text-gray-900">Add Book</h2>
            {scanning ? (
              <span className="ml-1 flex items-center gap-1 text-xs text-gray-400">
                <Loader2 size={12} className="animate-spin" />
                Scanning...
              </span>
            ) : null}
          </div>
          <div className="flex items-center gap-2">
            <Button
              variant="ghost"
              size="sm"
              startIcon={<FilePlus size={16} />}
              onClick={handleBrowseFiles}
              className="text-gray-600 hover:text-gray-900"
            >
              Browse Files
            </Button>
            <button
              onClick={handleClose}
              className="text-gray-400 hover:text-gray-600 transition-colors rounded-md p-1 hover:bg-gray-100"
            >
              <X size={18} />
            </button>
          </div>
        </div>

        {/* Controls */}
        <div className="px-5 py-3 border-b border-gray-200 space-y-3">
          {/* Mode toggle */}
          <div className="flex gap-4 text-sm">
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="scan-mode"
                value="default"
                checked={mode === 'default'}
                onChange={() => handleModeChange('default')}
                className="accent-gray-600"
              />
              <span className="text-gray-700">
                Common folders <span className="text-gray-400">(fast)</span>
              </span>
            </label>
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="scan-mode"
                value="full"
                checked={mode === 'full'}
                onChange={() => handleModeChange('full')}
                className="accent-gray-600"
              />
              <span className="text-gray-700">
                Search entire computer <span className="text-gray-400">(slower)</span>
              </span>
            </label>
          </div>

          {/* Filter */}
          <input
            type="text"
            placeholder="Filter by title, author, or filename..."
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
            autoFocus
            className="w-full bg-gray-50 text-gray-900 placeholder-gray-400 text-sm rounded-lg px-3 py-2 border border-gray-200 focus:outline-none focus:ring-2 focus:ring-gray-300 focus:border-transparent"
          />

          {/* Progress indicator */}
          {progress ? (
            <div className="text-xs text-gray-500 truncate">
              <span className="text-gray-400">Scanning:</span>{' '}
              <span className="text-gray-600">{progress.folder}</span>
              {progress.total > 0 && (
                <span className="ml-2 text-gray-400">
                  ({progress.scanned}/{progress.total})
                </span>
              )}
            </div>
          ) : null}
        </div>

        {/* Results */}
        <div className="flex-1 overflow-y-auto px-5 py-3 min-h-0">
          {scanning && filteredBooks.length === 0 ? (
            <div className="flex flex-col items-center justify-center h-40 gap-3 text-gray-400">
              <ClipLoader color="#9ca3af" size={24} />
              <p className="text-sm">Scanning for books...</p>
            </div>
          ) : scanComplete && filteredBooks.length === 0 ? (
            <div className="flex flex-col items-center justify-center h-40 gap-2 text-gray-400">
              <BookOpen size={36} className="opacity-30" />
              <p className="text-sm">No books found</p>
            </div>
          ) : (
            Object.entries(grouped).map(([folder, folderBooks]) => {
              const selectedInFolder = folderBooks.filter((b) =>
                selectedPaths.has(b.filepath)
              ).length
              const allSelected = selectedInFolder === folderBooks.length
              const someSelected = selectedInFolder > 0 && !allSelected
              return (
                <div key={folder} className="mb-5">
                  <label className="flex items-center gap-2 mb-2 cursor-pointer">
                    <FolderCheckbox
                      checked={allSelected}
                      indeterminate={someSelected}
                      onChange={() => toggleFolderSelected(folderBooks)}
                      label={`Select all books in ${folder}`}
                    />
                    <FolderOpen size={14} className="text-gray-400 shrink-0" />
                    <span className="text-xs text-gray-400 truncate">{folder}</span>
                  </label>
                  <div className="space-y-1.5">
                    {folderBooks.map((book) => {
                      const checked = selectedPaths.has(book.filepath)
                      return (
                        <label
                          key={book.filepath}
                          className="flex items-center gap-3 bg-gray-50 hover:bg-gray-100 rounded-lg px-3 py-2.5 cursor-pointer transition-colors"
                        >
                          <input
                            type="checkbox"
                            checked={checked}
                            onChange={() => toggleBookSelected(book.filepath)}
                            aria-label={`Select ${book.filename}`}
                            className="w-4 h-4 accent-gray-700 cursor-pointer"
                          />
                          <div className="flex-1 min-w-0">
                            <p className="text-sm font-medium text-gray-900 truncate">
                              {book.title ?? book.filename}
                            </p>
                            <div className="flex items-center gap-2 mt-0.5">
                              {book.author ? (
                                <span className="text-xs text-gray-500 truncate">
                                  {book.author}
                                </span>
                              ) : null}
                              <span className="text-xs text-gray-400 uppercase">
                                {book.format}
                              </span>
                              <span className="text-xs text-gray-400">
                                {formatFileSize(book.fileSize)}
                              </span>
                            </div>
                          </div>
                        </label>
                      )
                    })}
                  </div>
                </div>
              )
            })
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between px-5 py-3 border-t border-gray-200 bg-gray-50/80">
          <span className="text-sm text-gray-400">
            {filteredBooks.length > 0
              ? `${filteredBooks.length} book${filteredBooks.length !== 1 ? 's' : ''} found`
              : scanComplete
                ? 'Scan complete'
                : scanning
                  ? 'Scanning...'
                  : ''}
          </span>
          <div className="flex items-center gap-2">
            <Button variant="ghost" size="sm" onClick={handleClose} className="text-gray-500">
              Cancel
            </Button>
            <Button
              variant="default"
              size="sm"
              startIcon={<DownloadCloud size={15} />}
              onClick={handleImportClick}
              disabled={importDisabled}
            >
              Import Selected ({selectedCount})
            </Button>
          </div>
        </div>

        {/* Bulk-import confirmation */}
        {confirmOpen && (
          <div className="absolute inset-0 z-20 flex items-center justify-center bg-black/40">
            <div
              role="dialog"
              aria-modal="true"
              aria-label="Confirm bulk import"
              className="bg-white rounded-xl shadow-2xl border border-gray-200 max-w-md w-full mx-6 p-5"
            >
              <h3 className="text-base font-semibold text-gray-900 mb-2">
                Import {selectedCount} books?
              </h3>
              <p className="text-sm text-gray-600 mb-5">
                You&apos;re about to import{' '}
                <span className="font-medium text-gray-900">{selectedCount}</span> books. This may
                take a while and use significant storage. You can keep editing your selection if
                that&apos;s not what you meant.
              </p>
              <div className="flex justify-end gap-2">
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => setConfirmOpen(false)}
                  className="text-gray-600"
                >
                  Keep editing
                </Button>
                <Button
                  variant="default"
                  size="sm"
                  startIcon={<DownloadCloud size={15} />}
                  onClick={handleConfirmImport}
                >
                  Import {selectedCount}
                </Button>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

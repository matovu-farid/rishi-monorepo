import { useState, useEffect } from 'react'
import { X, BookOpen, Download, DownloadCloud, FolderOpen, Loader2, FilePlus } from 'lucide-react'
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

export function BookDiscoveryModal({ open, onClose }: BookDiscoveryModalProps) {
  const queryClient = useQueryClient()
  const [books, setBooks] = useState<DiscoveredBook[]>([])
  const [filter, setFilter] = useState('')
  const [scanning, setScanning] = useState(false)
  const [scanComplete, setScanComplete] = useState(false)
  const [progress, setProgress] = useState<ScanProgress | null>(null)
  const [mode, setMode] = useState<ScanMode>('default')
  const [importingPaths, setImportingPaths] = useState<Set<string>>(new Set())

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
        filePaths.length === 1
          ? `"${basename(filePaths[0])}"`
          : `${filePaths.length} books`

      setFilter('')
      toast.promise(runImport(filePaths), {
        loading: `Importing ${label}...`,
        success: (results) => summarizeBatchResults(results).message,
        error: `Failed to import ${label}`
      })
      handleClose()
    } catch (err) {
      console.error('Failed to open file picker:', err)
    }
  }

  useEffect(() => {
    if (!open) return
    const svc = getBookImportService()

    setBooks([])
    setProgress(null)
    setScanComplete(false)
    setScanning(true)

    const unsub = svc.onDiscoveryEvent((event) => {
      if (event.kind === 'book-found') {
        setBooks((prev) => [...prev, event.book])
      } else if (event.kind === 'progress') {
        setProgress(event.progress)
      } else if (event.kind === 'complete') {
        setScanning(false)
        setScanComplete(true)
        setProgress(null)
      } else if (event.kind === 'error') {
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
    setMode(newMode) // useEffect on `mode` will restart discovery
  }

  const handleClose = async () => {
    await getBookImportService().cancelDiscovery()
    setBooks([])
    setFilter('')
    setScanning(false)
    setScanComplete(false)
    setProgress(null)
    setImportingPaths(new Set())
    onClose()
  }

  const handleImport = (book: DiscoveredBook) => {
    setImportingPaths((prev) => new Set(prev).add(book.filepath))
    setBooks((prev) => prev.filter((b) => b.filepath !== book.filepath))
    setFilter('')

    const label = `"${book.title ?? book.filename}"`
    toast.promise(runImport([book.filepath]), {
      loading: `Importing ${label}...`,
      success: (results) => {
        const r = results[0]
        if (!r || !r.ok) return `Failed to import ${label}`
        return `Imported ${label}`
      },
      error: `Failed to import ${label}`
    })
  }

  const handleImportAll = () => {
    const toImport = filteredBooks
    if (toImport.length === 0) return

    const newPaths = new Set(importingPaths)
    toImport.forEach((b) => newPaths.add(b.filepath))
    setImportingPaths(newPaths)
    setBooks((prev) => prev.filter((b) => !newPaths.has(b.filepath)))
    setFilter('')

    const count = toImport.length
    toast.promise(runImport(toImport.map((b) => b.filepath)), {
      loading: `Importing ${count} book${count === 1 ? '' : 's'}...`,
      success: (results) => summarizeBatchResults(results).message,
      error: `Failed to import ${count} book${count === 1 ? '' : 's'}`
    })
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

  const grouped = filteredBooks.reduce<Record<string, DiscoveredBook[]>>((acc, book) => {
    if (!acc[book.folder]) acc[book.folder] = []
    acc[book.folder].push(book)
    return acc
  }, {})

  if (!open) return null

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
            {scanning && (
              <span className="ml-1 flex items-center gap-1 text-xs text-gray-400">
                <Loader2 size={12} className="animate-spin" />
                Scanning...
              </span>
            )}
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
          {progress && (
            <div className="text-xs text-gray-500 truncate">
              <span className="text-gray-400">Scanning:</span>{' '}
              <span className="text-gray-600">{progress.folder}</span>
              {progress.total > 0 && (
                <span className="ml-2 text-gray-400">
                  ({progress.scanned}/{progress.total})
                </span>
              )}
            </div>
          )}
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
            Object.entries(grouped).map(([folder, folderBooks]) => (
              <div key={folder} className="mb-5">
                <div className="flex items-center gap-1.5 mb-2">
                  <FolderOpen size={14} className="text-gray-400 shrink-0" />
                  <span className="text-xs text-gray-400 truncate">{folder}</span>
                </div>
                <div className="space-y-1.5">
                  {folderBooks.map((book) => (
                    <div
                      key={book.filepath}
                      className="flex items-center gap-3 bg-gray-50 hover:bg-gray-100 rounded-lg px-3 py-2.5 group transition-colors"
                    >
                      <div className="flex-1 min-w-0">
                        <p className="text-sm font-medium text-gray-900 truncate">
                          {book.title ?? book.filename}
                        </p>
                        <div className="flex items-center gap-2 mt-0.5">
                          {book.author && (
                            <span className="text-xs text-gray-500 truncate">{book.author}</span>
                          )}
                          <span className="text-xs text-gray-400 uppercase">{book.format}</span>
                          <span className="text-xs text-gray-400">
                            {formatFileSize(book.fileSize)}
                          </span>
                        </div>
                      </div>
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => handleImport(book)}
                        startIcon={<Download size={14} />}
                        className="shrink-0 text-gray-500 hover:text-gray-700 hover:bg-gray-200 opacity-0 group-hover:opacity-100 transition-opacity"
                      >
                        Import
                      </Button>
                    </div>
                  ))}
                </div>
              </div>
            ))
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
            {filteredBooks.length > 0 && (
              <Button
                variant="default"
                size="sm"
                startIcon={<DownloadCloud size={15} />}
                onClick={handleImportAll}
              >
                Import All ({filteredBooks.length})
              </Button>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}

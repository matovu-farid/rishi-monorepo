import { useState, useEffect, useRef, useCallback } from 'react'
import { invoke } from '@tauri-apps/api/core'
import { listen, UnlistenFn } from '@tauri-apps/api/event'
import { X, BookOpen, Download, DownloadCloud, FolderOpen, Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/Button'
import { Spinner } from '@/components/ui/Spinner'

interface DiscoveredBook {
  filepath: string
  filename: string
  title: string | null
  author: string | null
  format: string
  fileSize: number
  folder: string
  fileHash: string | null
}

interface ScanProgress {
  folder: string
  scanned: number
  total: number
}

interface BookDiscoveryModalProps {
  open: boolean
  onClose: () => void
  onImport: (filepath: string) => void
}

type ScanMode = 'default' | 'full'

function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

export function BookDiscoveryModal({ open, onClose, onImport }: BookDiscoveryModalProps) {
  const [books, setBooks] = useState<DiscoveredBook[]>([])
  const [filter, setFilter] = useState('')
  const [scanning, setScanning] = useState(false)
  const [scanComplete, setScanComplete] = useState(false)
  const [progress, setProgress] = useState<ScanProgress | null>(null)
  const [mode, setMode] = useState<ScanMode>('default')
  const [importingPaths, setImportingPaths] = useState<Set<string>>(new Set())

  const unlistenRefs = useRef<UnlistenFn[]>([])

  const cleanupListeners = useCallback(() => {
    unlistenRefs.current.forEach((fn) => fn())
    unlistenRefs.current = []
  }, [])

  const startScan = useCallback(async (scanMode: ScanMode) => {
    setBooks([])
    setProgress(null)
    setScanComplete(false)
    setScanning(true)

    try {
      await invoke('scan_for_books', { mode: scanMode })
    } catch (err) {
      console.error('Failed to start scan:', err)
    } finally {
      setScanning(false)
      setScanComplete(true)
    }
  }, [])

  useEffect(() => {
    if (!open) return

    let cancelled = false

    const setup = async () => {
      const [unlistenResult, unlistenProgress, unlistenComplete] = await Promise.all([
        listen<DiscoveredBook>('scan-result', (event) => {
          if (cancelled) return
          setBooks((prev) => [...prev, event.payload])
        }),
        listen<ScanProgress>('scan-progress', (event) => {
          if (cancelled) return
          setProgress(event.payload)
        }),
        listen<void>('scan-complete', () => {
          if (cancelled) return
          setScanning(false)
          setScanComplete(true)
          setProgress(null)
        }),
      ])

      unlistenRefs.current = [unlistenResult, unlistenProgress, unlistenComplete]

      if (!cancelled) {
        startScan('default')
      }
    }

    setup()

    return () => {
      cancelled = true
      cleanupListeners()
      invoke('cancel_scan').catch(() => {})
    }
  }, [open, startScan, cleanupListeners])

  const handleModeChange = async (newMode: ScanMode) => {
    if (newMode === mode) return
    setMode(newMode)
    await invoke('cancel_scan').catch(() => {})
    startScan(newMode)
  }

  const handleClose = async () => {
    await invoke('cancel_scan').catch(() => {})
    cleanupListeners()
    setBooks([])
    setFilter('')
    setScanning(false)
    setScanComplete(false)
    setProgress(null)
    setImportingPaths(new Set())
    onClose()
  }

  const handleImport = (filepath: string) => {
    setImportingPaths((prev) => new Set(prev).add(filepath))
    setBooks((prev) => prev.filter((b) => b.filepath !== filepath))
    onImport(filepath)
  }

  const handleImportAll = () => {
    const toImport = filteredBooks
    const newPaths = new Set(importingPaths)
    toImport.forEach((b) => newPaths.add(b.filepath))
    setImportingPaths(newPaths)
    setBooks((prev) => prev.filter((b) => !newPaths.has(b.filepath)))
    toImport.forEach((b) => onImport(b.filepath))
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
      <div
        className="absolute inset-0 bg-black/30 backdrop-blur-sm"
        onClick={handleClose}
      />

      {/* Modal */}
      <div className="relative z-10 flex flex-col w-full max-w-2xl max-h-[85vh] bg-white rounded-xl shadow-2xl border border-gray-200 overflow-hidden">
        {/* Header */}
        <div className="flex items-center justify-between px-5 py-4 border-b border-gray-200">
          <div className="flex items-center gap-2">
            <BookOpen size={20} className="text-gray-600" />
            <h2 className="text-lg font-semibold text-gray-900">Import from Computer</h2>
            {scanning && (
              <span className="ml-1 flex items-center gap-1 text-xs text-gray-400">
                <Loader2 size={12} className="animate-spin" />
                Scanning…
              </span>
            )}
          </div>
          <button
            onClick={handleClose}
            className="text-gray-400 hover:text-gray-600 transition-colors rounded-md p-1 hover:bg-gray-100"
            aria-label="Close"
          >
            <X size={18} />
          </button>
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
              <span className="text-gray-700">Common folders <span className="text-gray-400">(fast)</span></span>
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
              <span className="text-gray-700">Search entire computer <span className="text-gray-400">(slower)</span></span>
            </label>
          </div>

          {/* Filter */}
          <input
            type="text"
            placeholder="Filter by title, author, or filename…"
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
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
              <Spinner size="large" />
              <p className="text-sm">Scanning for books…</p>
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
                          <span className="text-xs text-gray-400">{formatFileSize(book.fileSize)}</span>
                        </div>
                      </div>
                      <Button
                        variant="ghost"
                        size="small"
                        onClick={() => handleImport(book.filepath)}
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
              ? 'Scanning…'
              : ''}
          </span>
          <div className="flex items-center gap-2">
            <Button variant="ghost" size="small" onClick={handleClose} className="text-gray-500">
              Cancel
            </Button>
            {filteredBooks.length > 0 && (
              <Button
                variant="primary"
                size="small"
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

import { create } from 'zustand'

export type IndexingStatus = 'idle' | 'running' | 'done' | 'error'

export interface IndexingEntry {
  done: number
  total: number
  status: IndexingStatus
  error?: string
}

interface IndexingState {
  byBookId: Record<number, IndexingEntry>
  start: (bookId: number, total: number) => void
  advance: (bookId: number) => void
  finish: (bookId: number) => void
  error: (bookId: number, message: string) => void
  reset: () => void
  getStatus: (bookId: number) => IndexingStatus
  isReady: (bookId: number) => boolean
  progress: (bookId: number) => number
}

export const useIndexingStore = create<IndexingState>()((set, get) => ({
  byBookId: {},

  start: (bookId, total) =>
    set((state) => ({
      byBookId: {
        ...state.byBookId,
        [bookId]: { done: 0, total, status: 'running' }
      }
    })),

  advance: (bookId) =>
    set((state) => {
      const entry = state.byBookId[bookId] as IndexingEntry | undefined
      if (!entry) return state
      const done = Math.min(entry.done + 1, entry.total)
      return {
        byBookId: { ...state.byBookId, [bookId]: { ...entry, done } }
      }
    }),

  finish: (bookId) =>
    set((state) => {
      const entry = state.byBookId[bookId] as IndexingEntry | undefined
      if (!entry) return state
      return {
        byBookId: {
          ...state.byBookId,
          [bookId]: { ...entry, done: entry.total, status: 'done', error: undefined }
        }
      }
    }),

  error: (bookId, message) =>
    set((state) => {
      const entry = state.byBookId[bookId] ?? { done: 0, total: 0, status: 'error' as const }
      return {
        byBookId: {
          ...state.byBookId,
          [bookId]: { ...entry, status: 'error', error: message }
        }
      }
    }),

  reset: () => set({ byBookId: {} }),

  getStatus: (bookId) => (get().byBookId[bookId] as IndexingEntry | undefined)?.status ?? 'idle',

  isReady: (bookId) => (get().byBookId[bookId] as IndexingEntry | undefined)?.status === 'done',

  progress: (bookId) => {
    const entry = get().byBookId[bookId] as IndexingEntry | undefined
    if (!entry || entry.total === 0) return 0
    return entry.done / entry.total
  }
}))

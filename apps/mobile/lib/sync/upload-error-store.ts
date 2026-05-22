/**
 * Tiny zustand store + helper for surfacing upload-cap errors from the
 * background upload pipeline (book-import → file-sync.uploadBookFile)
 * to whichever screen has the global snackbar mounted (library, tabs root).
 *
 * The book-import adapter runs in a non-React context, so it cannot call
 * useUndoSnackbar.show directly. Instead it sets state on this store; the
 * library / tabs root subscribes and renders the snackbar.
 *
 * Errors are mapped from UploadLimitError (see file-sync.ts). We deliberately
 * reuse the existing UndoSnackbar component (per memory:
 * `feedback_electron_only` — share copy patterns, don't introduce new libs).
 */
import { create } from 'zustand'
import type { UploadLimitError } from '@/lib/sync/file-sync'

type UploadErrorCode = UploadLimitError['code']

/**
 * STA-019: an upload-cap snackbar now offers an actionable next step.
 * The store carries the kind so the snackbar host can route to the
 * appropriate destination (settings for storage, library for book count).
 * The label is kept here (not the component) so copy variants stay in
 * one place and translations have a single binding point.
 */
export type UploadErrorActionKind = 'manage-storage' | 'manage-books'

export interface UploadErrorAction {
  kind: UploadErrorActionKind
  label: string
}

export interface UploadErrorNotice {
  /** Discriminator so the UI can render a single snackbar bar at a time. */
  id: number
  message: string
  code: UploadErrorCode
  /**
   * Action surfaced as a button on the snackbar. Null/undefined means the
   * notice is purely informational (no actionable next step).
   */
  action: UploadErrorAction | null
}

interface UploadErrorState {
  current: UploadErrorNotice | null
  /** Surface an upload-cap error to whichever screen is rendering. */
  show: (err: { code: UploadErrorCode; limit: number; current?: number }) => void
  dismiss: () => void
}

let nextId = 1

export function formatUploadLimitMessage(err: {
  code: UploadErrorCode
  limit: number
  current?: number
}): string {
  switch (err.code) {
    case 'FILE_TOO_LARGE': {
      // Limit is in bytes; render MB for human friendliness.
      const mb = Math.round(err.limit / (1024 * 1024))
      return `This file is larger than ${mb} MB and cannot be synced to your library.`
    }
    case 'BOOK_LIMIT_REACHED':
      return `You've reached the ${err.limit}-book sync limit. Remove a book to add more.`
    case 'STORAGE_LIMIT_REACHED': {
      const gb = Math.round(err.limit / (1024 * 1024 * 1024))
      return `Your sync storage is full (${gb} GB limit reached).`
    }
    default:
      return 'Upload failed due to a storage limit.'
  }
}

/**
 * Return the canonical action for an upload-limit error. The action label
 * doubles as the snackbar CTA copy; `kind` tells the host where to route
 * the user (storage panel in Settings vs. their book list in the Library).
 *
 * Returns null when the error has no actionable destination. Today every
 * known cap maps to either Settings (storage / file-size) or Library
 * (book count), so this currently never returns null — kept as a Maybe so
 * we can drop in new cap kinds without churning the signature.
 */
export function formatUploadLimitAction(err: {
  code: UploadErrorCode
  limit: number
  current?: number
}): UploadErrorAction | null {
  switch (err.code) {
    case 'BOOK_LIMIT_REACHED':
      return { kind: 'manage-books', label: 'Manage Library' }
    case 'STORAGE_LIMIT_REACHED':
    case 'FILE_TOO_LARGE':
      return { kind: 'manage-storage', label: 'Manage Storage' }
    default:
      return null
  }
}

export const useUploadErrorStore = create<UploadErrorState>((set) => ({
  current: null,
  show: (err) =>
    set({
      current: {
        id: nextId++,
        code: err.code,
        message: formatUploadLimitMessage(err),
        action: formatUploadLimitAction(err),
      },
    }),
  dismiss: () => set({ current: null }),
}))

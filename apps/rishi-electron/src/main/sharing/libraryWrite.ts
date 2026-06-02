import { promises as fs } from 'node:fs'
import { join } from 'node:path'
import { app } from 'electron'
import type Database from 'better-sqlite3'
import { getDb } from '../database/index.js'
import type {
  SharingSaveTransferredBookParams,
  SharingSaveTransferredBookResult
} from '../../preload/ipc-contract.js'

const SUPPORTED: Record<'epub' | 'pdf', string> = { epub: '.epub', pdf: '.pdf' }

export const SHARED_SESSION_SOURCE = 'shared-session' as const

/**
 * Canonical on-disk root for books received via P2P sharing. Exposed so the
 * IPC layer can validate that `discardTransferredBook(localPath)` points at
 * a file inside this directory — preventing a compromised renderer from
 * passing an arbitrary path like `/etc/passwd` and unlinking it.
 */
export function getSharedLibraryDir(): string {
  return join(app.getPath('userData'), 'shared-reading-library')
}

/**
 * Persist a book received via a P2P sharing session to disk and the local
 * library. The file is written to a dedicated `shared-reading-library/`
 * sub-directory under userData, keyed by content hash so duplicate
 * transfers de-dupe on disk. The `books` row carries sharing-provenance
 * columns (`source`, `received_from_user_id`, `received_at`) so the UI
 * can render a "received via sharing" badge and offer keep/discard at
 * session end.
 */
export async function saveTransferredBook(
  params: SharingSaveTransferredBookParams
): Promise<SharingSaveTransferredBookResult> {
  const dir = getSharedLibraryDir()
  await fs.mkdir(dir, { recursive: true })
  const ext = SUPPORTED[params.format]
  const localPath = join(dir, `${params.contentHash}${ext}`)
  await fs.writeFile(localPath, new Uint8Array(params.blob))

  const db = getDb()
  const result = db
    .prepare(
      `
    INSERT INTO books (
      kind, cover, title, filepath, file_hash, file_size, format,
      source, received_from_user_id, received_at
    ) VALUES (?, x'00', ?, ?, ?, ?, ?, ?, ?, ?)
  `
    )
    .run(
      params.format,
      params.title,
      localPath,
      params.contentHash,
      params.blob.length,
      params.format,
      SHARED_SESSION_SOURCE,
      params.receivedFromUserId,
      params.receivedAt
    )
  return { localPath, dbBookId: Number(result.lastInsertRowid) }
}

/**
 * Returns true if a book file matching `contentHash` already exists in
 * the shared-reading-library directory (for either supported format).
 * Used by the sharing flow to skip redundant downloads.
 */
export async function hasBookFile(params: { contentHash: string }): Promise<boolean> {
  const dir = getSharedLibraryDir()
  for (const ext of Object.values(SUPPORTED)) {
    try {
      await fs.access(join(dir, `${params.contentHash}${ext}`))
      return true
    } catch {
      /* fall through to next extension */
    }
  }
  return false
}

/**
 * Discard a previously-transferred book: delete the DB row and unlink
 * the on-disk file. Used when the recipient chooses NOT to keep books
 * at session end.
 *
 * The DELETE is provenance-guarded on `source = SHARED_SESSION_SOURCE`
 * so a renderer-side bug (or a compromised renderer crossing the IPC
 * trust boundary) cannot wipe arbitrary library rows by passing an
 * unrelated book id. Rows with any other `source` are a no-op DELETE.
 * The on-disk unlink still runs because a stale shared-session file
 * may legitimately outlive its DB row.
 */
export async function _discardTransferredBookWithDb(
  db: Database.Database,
  params: { dbBookId: number; localPath: string }
): Promise<void> {
  db.prepare(`DELETE FROM books WHERE id = ? AND source = ?`).run(
    params.dbBookId,
    SHARED_SESSION_SOURCE
  )
  try {
    await fs.unlink(params.localPath)
  } catch {
    // why: file may already be gone (recipient cleared it manually, or
    // a prior discard partially completed); non-fatal.
  }
}

export async function discardTransferredBook(params: {
  dbBookId: number
  localPath: string
}): Promise<void> {
  return _discardTransferredBookWithDb(getDb(), params)
}

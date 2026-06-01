import { promises as fs } from 'node:fs'
import { createHash } from 'node:crypto'
import { findBookByHash, type Book } from '../database/queries.js'

const SUPPORTED_FORMATS = new Set(['epub', 'pdf'])

export interface SharingReadBookBytesParams {
  bookId: string
  contentHash: string
}

export interface SharingReadBookBytesResult {
  bytes: number[]
  format: 'epub' | 'pdf'
}

export interface ReadBookBytesDeps {
  findByHash: (hash: string) => Book | undefined
}

/**
 * Pure-variant for unit testing. Production callers should use
 * `readBookBytes` which binds `findBookByHash` from the live DB.
 *
 * Looks up a book by content hash (== `file_hash` in the books table),
 * reads its file from disk, verifies the SHA-256 of the bytes equals the
 * caller-provided `contentHash`, and returns the bytes plus the supported
 * format. The hash recheck protects against on-disk corruption — without
 * it a corrupted host file would propagate silently to viewers over the
 * data channel.
 */
export async function _readBookBytesWithDeps(
  params: SharingReadBookBytesParams,
  deps: ReadBookBytesDeps
): Promise<SharingReadBookBytesResult> {
  const book = deps.findByHash(params.contentHash)
  if (!book) {
    throw new Error(`readBookBytes: not_found for contentHash=${params.contentHash}`)
  }
  if (!SUPPORTED_FORMATS.has(book.format)) {
    throw new Error(`readBookBytes: unsupported_format=${book.format}`)
  }
  const raw = await fs.readFile(book.filepath)
  const actual = createHash('sha256').update(raw).digest('hex')
  if (actual !== params.contentHash) {
    throw new Error(
      `readBookBytes: hash_mismatch (expected=${params.contentHash} actual=${actual})`
    )
  }
  return {
    bytes: Array.from(raw),
    format: book.format as 'epub' | 'pdf'
  }
}

export async function readBookBytes(
  params: SharingReadBookBytesParams
): Promise<SharingReadBookBytesResult> {
  return _readBookBytesWithDeps(params, { findByHash: findBookByHash })
}

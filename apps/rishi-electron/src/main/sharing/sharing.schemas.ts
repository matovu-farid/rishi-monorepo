/**
 * Zod schemas for the `sharing:*` IPC payloads.
 *
 * Mirrors the `sync.schemas.ts` pattern. Each `handle('sharing:X', ...)` in
 * `main/ipc/sharing.ts` calls `XSchema.parse(params)` before invoking the
 * underlying handler — a malformed or hostile renderer payload throws
 * synchronously and is surfaced back to the caller via the IPC error path,
 * never reaching SQLite or the filesystem.
 *
 * `discardTransferredBookSchema.localPath` carries an extra path-traversal
 * guard: the resolved absolute path must live inside `getSharedLibraryDir()`,
 * so a compromised renderer can't pass `/etc/passwd` and trick the main
 * process into unlinking arbitrary files.
 */
import path from 'node:path'
import { z } from 'zod'
import { getSharedLibraryDir } from './libraryWrite.js'

const hex64 = z
  .string()
  .min(1)
  .regex(/^[0-9a-f]{64}$/i, 'contentHash must be 64 hex chars (SHA-256)')

const byte = z.number().int().min(0).max(255)

export const saveTransferredBookSchema = z.object({
  bookId: z.string().min(1),
  contentHash: hex64,
  format: z.enum(['epub', 'pdf']),
  blob: z.array(byte),
  receivedFromUserId: z.string().min(1),
  receivedAt: z.number().int().positive(),
  title: z.string().max(500)
})

export const discardTransferredBookSchema = z
  .object({
    dbBookId: z.number().int().positive(),
    localPath: z.string().min(1)
  })
  .superRefine((val, ctx) => {
    const sharedDir = path.resolve(getSharedLibraryDir())
    const resolved = path.resolve(val.localPath)
    const rel = path.relative(sharedDir, resolved)
    // Reject if the resolved path escapes sharedDir (relative starts with
    // `..` or is absolute, e.g. on Windows a different drive letter).
    if (rel === '' || rel.startsWith('..') || path.isAbsolute(rel)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['localPath'],
        message: `localPath must be inside the shared-reading-library directory (got ${val.localPath})`
      })
    }
  })

export const hasBookFileSchema = z.object({
  contentHash: hex64
})

export const readBookBytesSchema = z.object({
  bookId: z.string().min(1),
  contentHash: hex64
})

export const readReconnectSchema = z.object({
  userId: z.string().min(1)
})

export const writeReconnectSchema = z.object({
  userId: z.string().min(1),
  sessionId: z.string().min(1),
  reconnectToken: z.string().min(1),
  wsUrl: z.string().url(),
  reservedUntil: z.number().int().positive()
})

export const clearReconnectSchema = z.object({
  userId: z.string().min(1)
})

export type SaveTransferredBookInput = z.infer<typeof saveTransferredBookSchema>
export type DiscardTransferredBookInput = z.infer<typeof discardTransferredBookSchema>
export type HasBookFileInput = z.infer<typeof hasBookFileSchema>
export type ReadBookBytesInput = z.infer<typeof readBookBytesSchema>
export type ReadReconnectInput = z.infer<typeof readReconnectSchema>
export type WriteReconnectInput = z.infer<typeof writeReconnectSchema>
export type ClearReconnectInput = z.infer<typeof clearReconnectSchema>

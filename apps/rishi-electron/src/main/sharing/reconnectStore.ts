import { app } from 'electron'
import { promises as fs } from 'node:fs'
import { join } from 'node:path'
import { atomicWriteFile } from '../utils/atomicWrite.js'

/**
 * Per-user persistence for the most recent sharing-session reconnect
 * payload. Used by the reborn-host flow: the previous Electron process
 * was hard-killed, so the in-memory `sessionMachine` is gone — on
 * relaunch the renderer asks main for the last-known payload so it can
 * dispatch `RECONNECT_SESSION` and resume in the worker's reserved slot.
 *
 * Storage layout: a single JSON file under `userData/sharing-reconnect/<userId>.json`.
 * The reconnect token itself is HMAC-signed by the worker (see
 * `tokens.ts`) and only verifies for the same userId, so disk-at-rest
 * leakage doesn't grant impersonation. We keep the file mode at 0600
 * regardless.
 *
 * Cleared on graceful session end (entry to `ending` state) and on
 * `KICKED` / `SESSION_ENDED`.
 */

const DIR = 'sharing-reconnect'

export interface ReconnectPayload {
  sessionId: string
  reconnectToken: string
  wsUrl: string
  /** Epoch ms by which the worker will evict the reserved slot. */
  reservedUntil: number
  /** Epoch ms when this payload was written; debug only. */
  storedAt: number
}

function safeFileName(userId: string): string {
  // userIds come from Better Auth (`u_<uuid-ish>`) so they're already
  // filesystem-safe; sanitise defensively in case a future provider
  // introduces `/` or `..`.
  return userId.replace(/[^a-zA-Z0-9_-]/g, '_')
}

function dirPath(): string {
  return join(app.getPath('userData'), DIR)
}

function filePath(userId: string): string {
  return join(dirPath(), `${safeFileName(userId)}.json`)
}

export async function writeReconnect(userId: string, payload: Omit<ReconnectPayload, 'storedAt'>): Promise<void> {
  await fs.mkdir(dirPath(), { recursive: true })
  const body: ReconnectPayload = { ...payload, storedAt: Date.now() }
  await atomicWriteFile(filePath(userId), JSON.stringify(body), { mode: 0o600 })
}

export async function readReconnect(userId: string): Promise<ReconnectPayload | null> {
  try {
    const raw = await fs.readFile(filePath(userId), 'utf-8')
    const parsed = JSON.parse(raw) as ReconnectPayload
    // Drop stale payloads — the worker has already evicted the slot, so
    // the token wouldn't verify anyway. Keep this check generous: the
    // worker's reservedUntil is the authoritative deadline.
    if (typeof parsed.reservedUntil === 'number' && parsed.reservedUntil <= Date.now()) {
      return null
    }
    return parsed
  } catch (err: unknown) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return null
    console.warn('[reconnect-store] read failed', err)
    return null
  }
}

export async function clearReconnect(userId: string): Promise<void> {
  try {
    await fs.unlink(filePath(userId))
  } catch (err: unknown) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') {
      console.warn('[reconnect-store] clear failed', err)
    }
  }
}

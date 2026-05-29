import { safeStorage, app } from 'electron'
import { promises as fs } from 'node:fs'
import { join } from 'node:path'
import { atomicWriteFile } from '../utils/atomicWrite.js'

const FILE = 'session.enc'

function path() {
  return join(app.getPath('userData'), FILE)
}

/**
 * Reads the encrypted session token from disk and decrypts via safeStorage.
 * Returns null if no token is stored or decryption fails (e.g. keychain reset).
 */
export async function readSession(): Promise<string | null> {
  try {
    const buf = await fs.readFile(path())
    if (!safeStorage.isEncryptionAvailable()) {
      // Linux without libsecret — fall back to plaintext (Electron's documented behavior)
      return buf.toString('utf-8')
    }
    return safeStorage.decryptString(buf)
  } catch (err: unknown) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return null
    console.warn('[session-store] read failed', err)
    return null
  }
}

export async function writeSession(token: string): Promise<void> {
  // Atomic write: a crash mid-fs.writeFile previously left session.enc
  // half-written, which decrypts to garbage and manifests as a silent
  // logout on next launch. tmp+rename guarantees that the only ever-
  // observable state is the old token (rename never happened) or the
  // new token in full (rename completed).
  if (safeStorage.isEncryptionAvailable()) {
    const enc = safeStorage.encryptString(token)
    await atomicWriteFile(path(), enc, { mode: 0o600 })
  } else {
    await atomicWriteFile(path(), token, { mode: 0o600 })
  }
}

export async function clearSession(): Promise<void> {
  try {
    await fs.unlink(path())
  } catch (err: unknown) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err
  }
}

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { promises as fs } from 'node:fs'
import os from 'node:os'
import path from 'node:path'

// `electron` is a peer dependency at runtime; stub the surface we need
// (`app.getPath('userData')`) so the unit test runs in plain Node.
let tmpDir = ''
vi.mock('electron', () => ({
  app: {
    getPath: (key: string): string => {
      if (key !== 'userData') throw new Error(`unexpected getPath(${key})`)
      return tmpDir
    }
  }
}))

import {
  readReconnect,
  writeReconnect,
  clearReconnect
} from '../reconnectStore.js'

describe('reconnectStore', () => {
  beforeEach(async () => {
    tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'rishi-reconnect-'))
  })
  afterEach(async () => {
    await fs.rm(tmpDir, { recursive: true, force: true })
  })

  it('round-trips a payload for a given user', async () => {
    const reservedUntil = Date.now() + 60_000
    await writeReconnect('u_alice', {
      sessionId: 's_1',
      reconnectToken: 'rt_abc',
      wsUrl: 'wss://x/v1/sessions/s_1/wss',
      reservedUntil
    })
    const out = await readReconnect('u_alice')
    expect(out).not.toBeNull()
    expect(out?.sessionId).toBe('s_1')
    expect(out?.reconnectToken).toBe('rt_abc')
    expect(out?.wsUrl).toBe('wss://x/v1/sessions/s_1/wss')
    expect(out?.reservedUntil).toBe(reservedUntil)
    expect(out?.storedAt).toBeTypeOf('number')
  })

  it('returns null when no payload exists for the user', async () => {
    expect(await readReconnect('u_ghost')).toBeNull()
  })

  it('drops payloads whose reservedUntil has elapsed', async () => {
    await writeReconnect('u_alice', {
      sessionId: 's_old',
      reconnectToken: 'rt_old',
      wsUrl: 'wss://x',
      // 1s in the past
      reservedUntil: Date.now() - 1000
    })
    expect(await readReconnect('u_alice')).toBeNull()
  })

  it('isolates payloads per user', async () => {
    await writeReconnect('u_alice', {
      sessionId: 's_a', reconnectToken: 'rt_a', wsUrl: 'w_a',
      reservedUntil: Date.now() + 60_000
    })
    await writeReconnect('u_bob', {
      sessionId: 's_b', reconnectToken: 'rt_b', wsUrl: 'w_b',
      reservedUntil: Date.now() + 60_000
    })
    expect((await readReconnect('u_alice'))?.sessionId).toBe('s_a')
    expect((await readReconnect('u_bob'))?.sessionId).toBe('s_b')
  })

  it('clearReconnect removes the payload', async () => {
    await writeReconnect('u_alice', {
      sessionId: 's_1', reconnectToken: 'rt', wsUrl: 'w',
      reservedUntil: Date.now() + 60_000
    })
    await clearReconnect('u_alice')
    expect(await readReconnect('u_alice')).toBeNull()
  })

  it('clearReconnect is idempotent (no-op when file missing)', async () => {
    await expect(clearReconnect('u_never_written')).resolves.toBeUndefined()
  })

  it('sanitises adversarial userIds before using them as filenames', async () => {
    // A userId with `..` or `/` must not escape the reconnect dir. The
    // sanitiser replaces anything outside [A-Za-z0-9_-] with `_`.
    const bad = '../../etc/passwd'
    await writeReconnect(bad, {
      sessionId: 's_1', reconnectToken: 'rt', wsUrl: 'w',
      reservedUntil: Date.now() + 60_000
    })
    // The reconnect file lives under tmpDir/sharing-reconnect/ — verify
    // we never wrote outside that directory.
    const dir = path.join(tmpDir, 'sharing-reconnect')
    const entries = await fs.readdir(dir)
    expect(entries.length).toBe(1)
    // Round-trip should still work via the same input.
    expect((await readReconnect(bad))?.sessionId).toBe('s_1')
  })
})

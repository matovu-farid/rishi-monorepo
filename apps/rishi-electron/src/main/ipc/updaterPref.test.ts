import { describe, it, expect, beforeEach } from 'vitest'
import * as fs from 'node:fs/promises'
import * as os from 'node:os'
import * as path from 'node:path'
import { readAutoUpdatePref } from './updaterPref'

describe('readAutoUpdatePref', () => {
  let dir: string

  beforeEach(async () => {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'rishi-updater-test-'))
  })

  it('returns true when the store file does not exist', async () => {
    expect(await readAutoUpdatePref(dir)).toBe(true)
  })

  it('returns true when the store file exists but the key is missing', async () => {
    await fs.writeFile(path.join(dir, 'settings-store.json'), JSON.stringify({ foo: 'bar' }))
    expect(await readAutoUpdatePref(dir)).toBe(true)
  })

  it('returns true when the stored value is non-boolean garbage', async () => {
    await fs.writeFile(
      path.join(dir, 'settings-store.json'),
      JSON.stringify({ autoUpdateEnabled: 'maybe' })
    )
    expect(await readAutoUpdatePref(dir)).toBe(true)
  })

  it('returns false when the user has opted out', async () => {
    await fs.writeFile(
      path.join(dir, 'settings-store.json'),
      JSON.stringify({ autoUpdateEnabled: false })
    )
    expect(await readAutoUpdatePref(dir)).toBe(false)
  })

  it('returns true when the user has explicitly opted in', async () => {
    await fs.writeFile(
      path.join(dir, 'settings-store.json'),
      JSON.stringify({ autoUpdateEnabled: true })
    )
    expect(await readAutoUpdatePref(dir)).toBe(true)
  })

  it('returns true (fail-safe) when the store file is corrupt JSON', async () => {
    await fs.writeFile(path.join(dir, 'settings-store.json'), '{ this is not json')
    expect(await readAutoUpdatePref(dir)).toBe(true)
  })
})

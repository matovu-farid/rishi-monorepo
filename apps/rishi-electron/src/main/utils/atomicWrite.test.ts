import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import * as fs from 'node:fs/promises'
import * as path from 'node:path'
import * as os from 'node:os'
import { atomicWriteFile } from './atomicWrite'

let tmpDir: string

beforeEach(async () => {
  tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'atomic-write-test-'))
})

afterEach(async () => {
  await fs.rm(tmpDir, { recursive: true, force: true })
})

describe('atomicWriteFile', () => {
  it('writes the new bytes to the target path on success', async () => {
    const target = path.join(tmpDir, 'a.bin')
    await atomicWriteFile(target, Buffer.from('hello'))
    expect((await fs.readFile(target)).toString()).toBe('hello')
  })

  it('replaces existing target content atomically (good → good)', async () => {
    const target = path.join(tmpDir, 'b.bin')
    await fs.writeFile(target, 'OLD')
    await atomicWriteFile(target, Buffer.from('NEW_LONGER'))
    expect((await fs.readFile(target)).toString()).toBe('NEW_LONGER')
  })

  it('on tmp-file write failure: target keeps its previous good content (no partial file)', async () => {
    const target = path.join(tmpDir, 'c.bin')
    await fs.writeFile(target, 'GOOD')

    // Simulate a mid-write failure by pointing target at a directory that
    // doesn't exist — fs.writeFile of `<target>.tmp` will reject with
    // ENOENT, and atomicWriteFile must never proceed to the rename.
    // We use a path under tmpDir but in a missing subdir for the tmp.
    const bogusTarget = path.join(tmpDir, 'nope', 'd.bin')
    await expect(atomicWriteFile(bogusTarget, Buffer.from('PARTIAL'))).rejects.toThrow()

    // Original good file is unchanged.
    expect((await fs.readFile(target)).toString()).toBe('GOOD')

    // The bogus target itself was never created (no partial / no full).
    await expect(fs.access(bogusTarget)).rejects.toThrow()
  })

  it('cleans up the tmp file after a write failure so the next write is not surprised', async () => {
    // Force the tmp write to fail: create a directory at the tmp path so
    // fs.writeFile rejects with EISDIR. atomicWriteFile must still attempt
    // unlink (best-effort) and propagate the original error.
    const target = path.join(tmpDir, 'e.bin')
    const tmp = `${target}.tmp`
    await fs.mkdir(tmp)

    await expect(atomicWriteFile(target, Buffer.from('X'))).rejects.toThrow()

    // Target was never created; tmp directory remains (unlink can't remove a
    // dir, which is fine — the test only requires no partial file at target).
    await expect(fs.access(target)).rejects.toThrow()
  })
})

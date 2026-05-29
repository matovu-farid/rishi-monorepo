import * as fs from 'node:fs/promises'

/**
 * Atomically write `data` to `targetPath`.
 *
 * Strategy: write a sibling `<targetPath>.tmp` and `rename(2)` it over the
 * target. POSIX rename is atomic on the same filesystem; Windows
 * `MoveFileEx` with the same volume is also atomic for our purposes.
 * If the process dies before the rename, the original file is untouched —
 * the previously-good state is never replaced by a partial write.
 *
 * Mirrors the pattern already used by `ipc/store.ts:writeStoreAtomic` so
 * the three other writers (session-store, vectordb persist, fs IPC) share
 * one tested implementation.
 *
 * Errors from the tmp-file write are propagated; on failure we make a
 * best-effort attempt to unlink the half-written tmp file so the next
 * write isn't surprised by stale garbage.
 */
export async function atomicWriteFile(
  targetPath: string,
  data: Buffer | Uint8Array | string,
  options?: { mode?: number }
): Promise<void> {
  const tmp = `${targetPath}.tmp`
  try {
    await fs.writeFile(tmp, data, options)
  } catch (err) {
    // Best-effort cleanup; swallow secondary errors so the original cause
    // is what the caller sees.
    await fs.unlink(tmp).catch(() => {})
    throw err
  }
  await fs.rename(tmp, targetPath)
}

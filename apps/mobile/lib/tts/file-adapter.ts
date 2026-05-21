/**
 * Mobile implementation of `TtsIpcChannels` and a `makeAudioUri` adapter
 * for the shared TTS service. Uses Expo SDK 54's new `File` / `Directory`
 * / `Paths` API.
 *
 * Why this lives in `lib/tts/` and not `lib/storage/`: the contracts are
 * shaped specifically for the TTS service (recursive directory delete,
 * file stats with `mtimeMs`, etc.) and aren't generally useful elsewhere.
 *
 * Pure platform glue — no network, no auth, no state.
 */
import { File, Directory, Paths } from 'expo-file-system'
import type { TtsIpcChannels } from '@rishi/shared/tts/types'

// ── Path helpers ─────────────────────────────────────────────────────────────
//
// expo-file-system requires `file:///` URIs. The shared cache passes raw
// paths like `<appData>/tts-cache/<bookId>/<hash>.mp3`, where `<appData>`
// is whatever `getAppDataPath()` returns. To keep round-trips safe we
// hand back the cache directory URI (already `file:///…`), and accept
// either a URI or a plain path as input.
function toUri(path: string): string {
  if (path.startsWith('file://')) return path
  // Some callers may pass an absolute path without the scheme.
  return `file://${path}`
}

// ── makeAudioUri ─────────────────────────────────────────────────────────────
//
// Writes the bytes to a stable per-(bookId, cfiRange) file under the
// app's cache directory and returns the `file://` URI. expo-audio's
// `createAudioPlayer({ uri })` and `replace({ uri })` accept this form
// natively, so the URI returned here is what the player consumes.
//
// We intentionally do NOT share storage with the shared TTS cache here:
// the shared cache writes its own copy at the canonical
// `<cache>/tts-cache/<bookId>/<hash>.mp3` location. This helper is the
// "give me a URL the audio engine can play right now" shim, and is
// allowed to point at the same on-disk bytes.
import md5 from 'md5'

export async function makeAudioUriMobile(
  bytes: Uint8Array,
  ctx: { bookId: string; cfiRange: string },
): Promise<string> {
  const root = new Directory(Paths.cache, 'tts-playback', ctx.bookId)
  if (!root.exists) {
    root.create({ intermediates: true, idempotent: true })
  }
  const file = new File(root, `${md5(ctx.cfiRange)}.mp3`)
  // Always overwrite — the bytes can be different (text-hash mirror), and
  // expo-audio reads off-disk lazily so we don't want to leak stale data.
  if (file.exists) file.delete()
  file.create()
  file.write(bytes)
  return file.uri
}

// ── TtsIpcChannels (cache backend) ───────────────────────────────────────────
//
// The shared cache builds paths like `<appData>/tts-cache/<bookId>/<hash>.mp3`.
// `getAppDataPath()` returns the cache-directory URI (without trailing slash)
// so the path concatenation in the cache module produces valid URIs.
export const mobileTtsIpc: TtsIpcChannels = {
  async getAppDataPath(): Promise<string> {
    // Paths.cache.uri ends with `/` on RN — strip it so the cache appends
    // `/tts-cache` cleanly without producing `//`.
    const uri = Paths.cache.uri
    return uri.endsWith('/') ? uri.slice(0, -1) : uri
  },

  async mkdir(path: string): Promise<void> {
    const dir = new Directory(toUri(path))
    dir.create({ intermediates: true, idempotent: true })
  },

  async exists(path: string): Promise<boolean> {
    // The shared cache passes BOTH file paths and directory paths through
    // this — File.exists / Directory.exists both work for arbitrary URIs
    // (returns false if the path doesn't exist at all).
    const uri = toUri(path)
    return new File(uri).exists || new Directory(uri).exists
  },

  async writeFile(path: string, data: Uint8Array): Promise<void> {
    const file = new File(toUri(path))
    if (file.exists) file.delete()
    file.create()
    file.write(data)
  },

  async readFile(path: string): Promise<ArrayBuffer> {
    const file = new File(toUri(path))
    const bytes = await file.bytes()
    return bytes.buffer.slice(
      bytes.byteOffset,
      bytes.byteOffset + bytes.byteLength,
    ) as ArrayBuffer
  },

  async copyFile(src: string, dest: string): Promise<void> {
    const srcFile = new File(toUri(src))
    const destFile = new File(toUri(dest))
    // expo-file-system's `copy` copies INTO a directory or to a target file.
    // To overwrite, delete first when the destination exists.
    if (destFile.exists) destFile.delete()
    srcFile.copy(destFile)
  },

  async removeFile(path: string): Promise<void> {
    const uri = toUri(path)
    const file = new File(uri)
    if (file.exists) {
      file.delete()
      return
    }
    const dir = new Directory(uri)
    if (dir.exists) dir.delete()
  },

  async getDirSize(path: string): Promise<number> {
    const dir = new Directory(toUri(path))
    if (!dir.exists) return 0
    return dir.size ?? 0
  },

  async getCacheFileStats(
    dir: string,
  ): Promise<Array<{ path: string; size: number; mtimeMs: number }>> {
    const root = new Directory(toUri(dir))
    if (!root.exists) return []
    const out: Array<{ path: string; size: number; mtimeMs: number }> = []
    // Recursive walk: each top-level entry may be a per-book directory.
    const stack: Directory[] = [root]
    while (stack.length) {
      const d = stack.pop()!
      for (const entry of d.list()) {
        if (entry instanceof Directory) {
          stack.push(entry)
        } else {
          out.push({
            path: entry.uri,
            size: entry.size ?? 0,
            mtimeMs: entry.modificationTime ?? 0,
          })
        }
      }
    }
    return out
  },
}

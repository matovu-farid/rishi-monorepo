import { describe, it, expect, vi } from 'vitest'
import {
  resolveDroppedFilePaths,
  DroppedFilesError,
  getFilesFromDropEvent
} from './handleDroppedFiles'

function makeFile(name: string): File {
  return new File(['x'], name, { type: 'application/octet-stream' })
}

describe('resolveDroppedFilePaths', () => {
  it('returns absolute paths from getPathForFile for each file', () => {
    const files = [makeFile('a.epub'), makeFile('b.pdf')]
    const getPathForFile = vi.fn((f: File) => `/abs/${f.name}`)

    const paths = resolveDroppedFilePaths(files, getPathForFile)

    expect(paths).toEqual(['/abs/a.epub', '/abs/b.pdf'])
    expect(getPathForFile).toHaveBeenCalledTimes(2)
  })

  it('filters out files whose path resolves to an empty string', () => {
    const files = [makeFile('a.epub'), makeFile('b.pdf')]
    const getPathForFile = vi.fn((f: File) => (f.name === 'a.epub' ? '/abs/a.epub' : ''))

    const paths = resolveDroppedFilePaths(files, getPathForFile)

    expect(paths).toEqual(['/abs/a.epub'])
  })

  it('throws DroppedFilesError when every path is empty — the symptom of the silent drop-failure bug', () => {
    // Reproduces the user-visible bug: dropping returns no usable paths and
    // the import pipeline silently no-ops. The helper must surface this so
    // FileComponent can show a toast instead of swallowing the failure.
    const files = [makeFile('a.epub'), makeFile('b.pdf')]
    const getPathForFile = vi.fn(() => '')

    expect(() => resolveDroppedFilePaths(files, getPathForFile)).toThrow(DroppedFilesError)
  })

  it('throws DroppedFilesError when getPathForFile is missing (stale preload bridge)', () => {
    // Repro: dev-mode preload bundle hasn't been rebuilt, so
    // `window.electron.getPathForFile` is `undefined`. Invoking it crashes
    // inside `.map()` and the unhandled error is currently swallowed.
    const files = [makeFile('a.epub')]
    const missing = undefined as unknown as (file: File) => string

    expect(() => resolveDroppedFilePaths(files, missing)).toThrow(DroppedFilesError)
  })

  it('returns an empty array (without throwing) when no files were dropped', () => {
    const getPathForFile = vi.fn()
    expect(resolveDroppedFilePaths([], getPathForFile)).toEqual([])
    expect(getPathForFile).not.toHaveBeenCalled()
  })
})

describe('getFilesFromDropEvent', () => {
  it('returns the original dataTransfer.files for drop events, preserving the OS-path binding', async () => {
    // react-dropzone's default path (file-selector) calls
    // `item.getAsFileSystemHandle().getFile()` in secure contexts. That
    // returns a *new* File that loses the binding `webUtils.getPathForFile`
    // relies on. Our extractor must hand back the originals from
    // `dataTransfer.files` so the bridge can resolve their absolute paths.
    const a = makeFile('a.epub')
    const b = makeFile('b.pdf')
    const event = { dataTransfer: { files: [a, b] } } as unknown as DragEvent

    const result = await getFilesFromDropEvent(event)

    expect(result).toEqual([a, b])
    expect(result[0]).toBe(a)
    expect(result[1]).toBe(b)
  })

  it('returns target.files for <input type=file> change events', async () => {
    const file = makeFile('a.epub')
    const event = {
      target: { files: [file] }
    } as unknown as Event

    const result = await getFilesFromDropEvent(event)

    expect(result).toEqual([file])
    expect(result[0]).toBe(file)
  })

  it('returns [] when the event carries no files', async () => {
    const result = await getFilesFromDropEvent({} as Event)
    expect(result).toEqual([])
  })
})

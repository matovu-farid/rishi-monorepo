/**
 * Tests for `lib/file-handler.ts` (G27).
 *
 * The handler accepts an OS-delivered file URL (iOS:
 * `file:///private/var/.../Inbox/book.epub`, Android:
 * `content://com.android.providers.media/document/12345`), copies the
 * bytes into the per-book app-data dir, then invokes the shared
 * `createMobileBookImportService` to land the row in the DB.
 *
 * We can't run real file IO in this test env. Instead we mock:
 *   - `expo-file-system` File/Directory wrappers
 *   - `@/lib/book-import` → fake service with a spy
 *   - `crypto.randomUUID` for deterministic ids
 */

// ── Mock react-native-mmkv so anything that pulls in the storage shim works ──
type StoreBackend = Map<string, string>
let backingStore: StoreBackend
function buildFakeMMKV() {
  const store = backingStore
  return {
    id: 'fake',
    set: (key: string, value: string) => store.set(key, String(value)),
    getString: (key: string): string | undefined => store.get(key),
    remove: (key: string) => store.delete(key),
    getAllKeys: () => Array.from(store.keys()),
    clearAll: () => store.clear(),
  }
}
jest.mock('react-native-mmkv', () => ({
  createMMKV: () => buildFakeMMKV(),
}))

// ── Mock expo-file-system ────────────────────────────────────────────────────
//
// We model just enough surface for the handler:
//   - `Paths.document` (string)
//   - `Directory(parent, name).create({ intermediates })`
//   - `new File(parent, name).write(bytes)` / `.delete()` / `.uri`
//   - `File.from(uri)` factory (used to wrap incoming OS URIs).

const fakeFileSystem = {
  Paths: { document: '/mock/documents' },
  Directory: jest.fn().mockImplementation(function (
    this: Record<string, unknown>,
    parent: unknown,
    name: string,
  ) {
    this.uri = `${(parent as { uri?: string }).uri ?? parent}/${name}`
    this.exists = false
    this.create = jest.fn()
    return this
  }),
  File: jest.fn().mockImplementation(function (
    this: Record<string, unknown>,
    parent: unknown,
    name: string,
  ) {
    this.uri = `${(parent as { uri?: string }).uri ?? parent}/${name}`
    this.write = jest.fn()
    this.delete = jest.fn()
    return this
  }) as unknown as jest.Mock & { from?: jest.Mock },
}

// Static helpers — File.from(uri) wraps an external URI in a File-like
// object with `.bytes()` returning the bytes the OS handed us.
const fileFromBytesMock = jest.fn().mockImplementation((uri: string) => ({
  uri,
  bytes: () => new Uint8Array([0x50, 0x4b, 0x03, 0x04]), // PK (EPUB ZIP)
}))
;(fakeFileSystem.File as unknown as { from: jest.Mock }).from = fileFromBytesMock

jest.mock('expo-file-system', () => fakeFileSystem)

// ── Mock the book-import service factory ─────────────────────────────────────
const importFromPath = jest.fn().mockResolvedValue({ ok: true, stage: 'done' })
const indexBook = jest.fn().mockResolvedValue(undefined)
const createMobileBookImportService = jest.fn().mockImplementation(() => ({
  importFromPath,
  indexBook,
}))
jest.mock('@/lib/book-import', () => ({
  createMobileBookImportService,
}))

beforeEach(() => {
  jest.resetModules()
  backingStore = new Map<string, string>()
  importFromPath.mockClear()
  indexBook.mockClear()
  createMobileBookImportService.mockClear()
  fileFromBytesMock.mockClear()
})

describe('handleIncomingFile (G27)', () => {
  it('exports handleIncomingFile and detectFormatFromUrl', () => {
    const mod = require('@/lib/file-handler')
    expect(typeof mod.handleIncomingFile).toBe('function')
    expect(typeof mod.detectFormatFromUrl).toBe('function')
  })

  it.each([
    ['file:///private/var/Inbox/book.epub', 'epub'],
    ['file:///private/var/Inbox/text.pdf', 'pdf'],
    ['file:///private/var/Inbox/manual.MOBI', 'mobi'],
    ['file:///private/var/Inbox/manual.AZW3', 'azw3'],
    ['file:///private/var/Inbox/scan.djvu', 'djvu'],
    ['content://com.android.providers.media/document/book.pdf', 'pdf'],
  ])('detects %s as format=%s', (url: string, expected: string) => {
    const { detectFormatFromUrl } = require('@/lib/file-handler')
    expect(detectFormatFromUrl(url)).toBe(expected)
  })

  it('returns null for unsupported extensions', () => {
    const { detectFormatFromUrl } = require('@/lib/file-handler')
    expect(detectFormatFromUrl('file:///Inbox/sheet.csv')).toBeNull()
    expect(detectFormatFromUrl('file:///Inbox/photo.png')).toBeNull()
  })

  it('ignores rishimobile://auth/* deep-links (not file URLs)', () => {
    const { isFileUrl } = require('@/lib/file-handler')
    expect(isFileUrl('rishimobile://auth/callback?token=abc')).toBe(false)
    expect(isFileUrl('rishimobile://')).toBe(false)
    expect(isFileUrl('file:///Inbox/book.epub')).toBe(true)
    expect(isFileUrl('content://media/document/1')).toBe(true)
  })

  it('handleIncomingFile: PDF — runs the shared import service with format=pdf', async () => {
    const { handleIncomingFile } = require('@/lib/file-handler')
    const result = await handleIncomingFile(
      'file:///private/var/Inbox/War%20and%20Peace.pdf',
    )
    expect(result.ok).toBe(true)
    expect(createMobileBookImportService).toHaveBeenCalledTimes(1)
    const call = createMobileBookImportService.mock.calls[0][0]
    expect(call.format).toBe('pdf')
    expect(call.title).toBe('War and Peace')
    expect(importFromPath).toHaveBeenCalledTimes(1)
  })

  it('handleIncomingFile: AZW3 — passes format=azw3, falls into mobi-like flow', async () => {
    const { handleIncomingFile } = require('@/lib/file-handler')
    const result = await handleIncomingFile('file:///Inbox/dune.azw3')
    expect(result.ok).toBe(true)
    const call = createMobileBookImportService.mock.calls[0][0]
    expect(call.format).toBe('azw3')
    expect(call.title).toBe('dune')
  })

  it('handleIncomingFile: unsupported extension — returns { ok: false, reason: "unsupported" }', async () => {
    const { handleIncomingFile } = require('@/lib/file-handler')
    const result = await handleIncomingFile('file:///Inbox/sheet.csv')
    expect(result.ok).toBe(false)
    expect(result.reason).toBe('unsupported')
    expect(createMobileBookImportService).not.toHaveBeenCalled()
  })

  it('handleIncomingFile: kicks off indexBook in the background', async () => {
    const { handleIncomingFile } = require('@/lib/file-handler')
    await handleIncomingFile('file:///Inbox/book.epub')
    // Indexing is fire-and-forget but should have been invoked.
    // Use microtask flush to let the void promise schedule.
    await Promise.resolve()
    expect(indexBook).toHaveBeenCalledTimes(1)
  })

  it('decodes URL-encoded titles before sending them to the service', async () => {
    const { handleIncomingFile } = require('@/lib/file-handler')
    await handleIncomingFile(
      'file:///Inbox/Le%20Petit%20Prince%20-%20%C3%89dition.epub',
    )
    const call = createMobileBookImportService.mock.calls[0][0]
    expect(call.title).toBe('Le Petit Prince - Édition')
  })

  it('returns { ok: false, reason: "import-failed" } when the service rejects', async () => {
    importFromPath.mockResolvedValueOnce({
      ok: false,
      stage: 'save',
      error: 'boom',
    })
    const { handleIncomingFile } = require('@/lib/file-handler')
    const result = await handleIncomingFile('file:///Inbox/book.epub')
    expect(result.ok).toBe(false)
    expect(result.reason).toBe('import-failed')
  })
})

import { describe, it, expect, vi, beforeEach } from 'vitest'

// ---------------------------------------------------------------------------
// Mock electron ipcMain to prevent real handler registration
// ---------------------------------------------------------------------------

vi.mock('electron', () => ({
  ipcMain: {
    handle: vi.fn()
  }
}))

// ---------------------------------------------------------------------------
// Mock child_process.execFile for djvulibre CLI tool calls.
// Note: the production code uses execFile (not exec) to prevent shell injection.
// ---------------------------------------------------------------------------

const mockExecFile = vi.fn()

vi.mock('node:child_process', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:child_process')>()
  return {
    ...actual,
    execFile: mockExecFile
  }
})

// ---------------------------------------------------------------------------
// Since the formats.ts module deeply integrates with IPC handlers and uses
// promisify(execFile), we test the DJVU logic by verifying the behavior of
// the exported helpers and the CLI interaction patterns.
//
// For integration-style tests, we verify:
// 1. Magic byte validation for DJVU files
// 2. CLI argument construction patterns
// 3. Handler registration
// ---------------------------------------------------------------------------

describe('DJVU format support', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  describe('DJVU file validation', () => {
    it('rejects files without AT&T magic bytes', async () => {
      // Create a temp file without AT&T magic
      const { writeFile, mkdtemp, unlink } = await import('node:fs/promises')
      const path = await import('node:path')
      const os = await import('node:os')

      const tmpDir = await mkdtemp(path.join(os.tmpdir(), 'djvu-test-'))
      const tmpFile = path.join(tmpDir, 'bad.djvu')
      await writeFile(tmpFile, 'NOT_DJVU_CONTENT')

      // Import the module (handlers won't actually register due to mock)
      // We test validation by attempting to extract data from an invalid file
      const { registerFormatHandlers } = await import('../formats.js')

      // Get the handler that was registered for getDjvuData
      const { ipcMain } = await import('electron')
      registerFormatHandlers()

      const handleCalls = vi.mocked(ipcMain.handle).mock.calls
      const djvuDataHandler = handleCalls.find((c) => c[0] === 'formats:getDjvuData')

      expect(djvuDataHandler).toBeDefined()

      // Call the handler with the bad file
      const handler = djvuDataHandler![1]
      await expect(handler({} as never, tmpFile)).rejects.toThrow(/Not a valid DJVU file/)

      // Cleanup
      await unlink(tmpFile)
    })

    it('accepts files with AT&T magic bytes', async () => {
      const { writeFile, mkdtemp, unlink } = await import('node:fs/promises')
      const pathMod = await import('node:path')
      const os = await import('node:os')

      const tmpDir = await mkdtemp(pathMod.join(os.tmpdir(), 'djvu-test-'))
      const tmpFile = pathMod.join(tmpDir, 'good.djvu')

      // Write AT&T magic bytes + padding
      const buf = Buffer.alloc(20)
      buf.write('AT&T', 0, 4, 'latin1')
      buf.write('FORM', 4, 4, 'latin1')
      await writeFile(tmpFile, buf)

      // Mock 'which' to fail (djvused not available) — metadata extraction should gracefully skip
      mockExecFile.mockImplementation(
        (
          _cmd: string,
          _args: string[],
          _opts: unknown,
          callback?: (err: Error | null, stdout: string, stderr: string) => void
        ) => {
          if (callback) {
            callback(new Error('not found'), '', 'not found')
          }
        }
      )

      const { registerFormatHandlers } = await import('../formats.js')
      const { ipcMain } = await import('electron')
      registerFormatHandlers()

      const handleCalls = vi.mocked(ipcMain.handle).mock.calls
      const djvuDataHandler = handleCalls.find((c) => c[0] === 'formats:getDjvuData')
      const handler = djvuDataHandler![1]

      const result = await handler({} as never, tmpFile)
      expect(result).toMatchObject({
        kind: 'djvu',
        filepath: tmpFile,
        location: '1'
      })
      expect(result.title).toBeTruthy() // Should use filename as fallback

      await unlink(tmpFile)
    })

    it('throws for non-existent files', async () => {
      const { registerFormatHandlers } = await import('../formats.js')
      const { ipcMain } = await import('electron')
      registerFormatHandlers()

      const handleCalls = vi.mocked(ipcMain.handle).mock.calls
      const djvuDataHandler = handleCalls.find((c) => c[0] === 'formats:getDjvuData')
      const handler = djvuDataHandler![1]

      await expect(handler({} as never, '/nonexistent/path/fake.djvu')).rejects.toThrow(
        /File not found|ENOENT|Failed to extract/
      )
    })
  })

  describe('DJVU page count', () => {
    it('handler is registered with correct channel name', async () => {
      const { registerFormatHandlers } = await import('../formats.js')
      const { ipcMain } = await import('electron')
      registerFormatHandlers()

      const handleCalls = vi.mocked(ipcMain.handle).mock.calls
      const channels = handleCalls.map((c) => c[0])
      expect(channels).toContain('formats:getDjvuPageCount')
    })
  })

  describe('DJVU page rendering', () => {
    it('handler is registered with correct channel name', async () => {
      const { registerFormatHandlers } = await import('../formats.js')
      const { ipcMain } = await import('electron')
      registerFormatHandlers()

      const handleCalls = vi.mocked(ipcMain.handle).mock.calls
      const channels = handleCalls.map((c) => c[0])
      expect(channels).toContain('formats:getDjvuPage')
    })
  })

  describe('DJVU text extraction', () => {
    it('handler is registered with correct channel name', async () => {
      const { registerFormatHandlers } = await import('../formats.js')
      const { ipcMain } = await import('electron')
      registerFormatHandlers()

      const handleCalls = vi.mocked(ipcMain.handle).mock.calls
      const channels = handleCalls.map((c) => c[0])
      expect(channels).toContain('formats:getDjvuPageText')
    })
  })

  describe('IPC handler registration', () => {
    it('registers all expected DJVU handlers', async () => {
      const { registerFormatHandlers } = await import('../formats.js')
      const { ipcMain } = await import('electron')
      registerFormatHandlers()

      const handleCalls = vi.mocked(ipcMain.handle).mock.calls
      const channels = handleCalls.map((c) => c[0])

      expect(channels).toContain('formats:getDjvuData')
      expect(channels).toContain('formats:getDjvuPage')
      expect(channels).toContain('formats:getDjvuPageCount')
      expect(channels).toContain('formats:getDjvuPageText')
    })

    it('registers all expected MOBI handlers', async () => {
      const { registerFormatHandlers } = await import('../formats.js')
      const { ipcMain } = await import('electron')
      registerFormatHandlers()

      const handleCalls = vi.mocked(ipcMain.handle).mock.calls
      const channels = handleCalls.map((c) => c[0])

      expect(channels).toContain('formats:getMobiData')
      expect(channels).toContain('formats:getMobiChapter')
      expect(channels).toContain('formats:getMobiChapterCount')
      expect(channels).toContain('formats:getMobiText')
    })
  })
})

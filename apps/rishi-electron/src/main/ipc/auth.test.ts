import { describe, it, expect, vi, beforeEach } from 'vitest'

// ---------------------------------------------------------------------------
// Mock electron modules
// ---------------------------------------------------------------------------

const mockHandle = vi.fn()
const mockGetPath = vi.fn().mockReturnValue('/tmp/test-userdata')

vi.mock('electron', () => ({
  ipcMain: { handle: (...args: unknown[]) => mockHandle(...args) },
  app: { getPath: (...args: unknown[]) => mockGetPath(...args) }
}))

const mockReadFile = vi.fn()
const mockWriteFile = vi.fn()
const mockAccess = vi.fn()
const mockUnlink = vi.fn()

vi.mock('node:fs/promises', () => ({
  readFile: (...args: unknown[]) => mockReadFile(...args),
  writeFile: (...args: unknown[]) => mockWriteFile(...args),
  access: (...args: unknown[]) => mockAccess(...args),
  unlink: (...args: unknown[]) => mockUnlink(...args)
}))

import { registerAuthHandlers } from './auth.js'

type HandlerFn = (...args: unknown[]) => Promise<unknown>

function getHandler(channel: string): HandlerFn {
  const call = mockHandle.mock.calls.find((c: unknown[]) => c[0] === channel)
  if (!call) throw new Error(`No handler registered for channel "${channel}"`)
  return call[1] as HandlerFn
}

describe('auth IPC handlers', () => {
  beforeEach(() => {
    vi.resetAllMocks()
    mockGetPath.mockReturnValue('/tmp/test-userdata')
    mockWriteFile.mockResolvedValue(undefined)
    mockUnlink.mockResolvedValue(undefined)
    registerAuthHandlers()
  })

  describe('auth:clear', () => {
    it('removes the cached user file', async () => {
      const handler = getHandler('auth:clear')
      await handler({})
      expect(mockUnlink).toHaveBeenCalledWith(expect.stringContaining('user.json'))
    })

    it('does not throw when the user file is missing', async () => {
      mockUnlink.mockRejectedValueOnce(new Error('ENOENT'))
      const handler = getHandler('auth:clear')
      await expect(handler({})).resolves.toBeUndefined()
    })
  })

  describe('auth:getUserFromStore', () => {
    it('returns null when no user file exists', async () => {
      mockAccess.mockRejectedValueOnce(new Error('ENOENT'))
      const handler = getHandler('auth:getUserFromStore')
      const result = await handler({})
      expect(result).toBeNull()
    })

    it('returns the cached user when present', async () => {
      const user = { id: 'user_123', hasImage: false, firstName: 'Test' }
      mockAccess.mockResolvedValueOnce(undefined)
      mockReadFile.mockResolvedValueOnce(JSON.stringify(user))
      const handler = getHandler('auth:getUserFromStore')
      const result = await handler({})
      expect(result).toEqual(user)
    })
  })

  describe('auth:saveUserToStore', () => {
    it('writes the user to disk as pretty JSON', async () => {
      const user = { id: 'user_123', hasImage: true }
      const handler = getHandler('auth:saveUserToStore')
      await handler({}, user)
      expect(mockWriteFile).toHaveBeenCalledWith(
        expect.stringContaining('user.json'),
        JSON.stringify(user, null, 2)
      )
    })
  })
})

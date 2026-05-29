import { describe, it, expect, vi, beforeEach } from 'vitest'

// updateStoredCoverImage relies on @/lib/api.{getBook,updateBookCover}.
// Stub both so the test doesn't need the real IPC surface.
vi.mock('@/lib/api', () => ({
  getBook: vi.fn(async () => ({
    id: 1,
    kind: 'pdf',
    version: 0,
    coverKind: 'fallback'
  })),
  updateBookCover: vi.fn(async () => undefined)
}))

const { revokeCachedCoverUrlSpy } = vi.hoisted(() => ({
  revokeCachedCoverUrlSpy: vi.fn()
}))
vi.mock('@/components/library/coverCache', () => ({
  revokeCachedCoverUrl: revokeCachedCoverUrlSpy
}))

import { updateCoverImage } from './updateStoredCoverImage'

beforeEach(() => {
  revokeCachedCoverUrlSpy.mockClear()
})

describe('updateCoverImage — cover cache invalidation', () => {
  it('revokes the cached cover url after writing new cover bytes', async () => {
    // Minimal Blob shim — arrayBuffer() is all updateCoverImage reads.
    const blob = {
      arrayBuffer: vi.fn(async () => new Uint8Array([0x89, 0x50]).buffer)
    } as unknown as Blob

    await updateCoverImage(blob, 1)

    expect(revokeCachedCoverUrlSpy).toHaveBeenCalledWith(1)
  })
})

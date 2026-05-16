import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { MutableRefObject } from 'react'
import { renderHook, waitFor } from '@testing-library/react'

// Intercept publishBookmarksToMenu so we can assert it was called once the
// sync id resolves. The bookmark-storage module also exports other helpers
// the hook should NOT call, so stub the whole module surface defensively.
const publishBookmarksToMenu = vi.fn(async (_id: string) => undefined)
vi.mock('@/modules/bookmark-storage', () => ({
  publishBookmarksToMenu: (id: string) => publishBookmarksToMenu(id)
}))

// Wave 3 will create src/renderer/src/hooks/reader/useBookSyncId.ts. Until
// then this dynamic import resolves to a module-not-found rejection, which
// is the expected red-phase failure mode.
type BookSyncIdHook = (bookId: number) => {
  bookSyncId: string
  bookSyncIdRef: MutableRefObject<string | null>
}

// Build the specifier from parts so vite's import-analysis can't statically
// resolve it at transform time — the hook file is created in Wave 3.
const HOOK_PATH = '@/hooks/' + 'reader/useBookSyncId'

async function loadHook(): Promise<BookSyncIdHook> {
  const mod = (await import(/* @vite-ignore */ HOOK_PATH)) as {
    useBookSyncId: BookSyncIdHook
  }
  return mod.useBookSyncId
}

const electron = (): { booksGetSyncId: ReturnType<typeof vi.fn> } =>
  (window as unknown as { electron: { booksGetSyncId: ReturnType<typeof vi.fn> } }).electron

beforeEach(() => {
  publishBookmarksToMenu.mockClear()
  electron().booksGetSyncId.mockReset()
})

describe('useBookSyncId', () => {
  it('calls window.electron.booksGetSyncId(bookId) on mount', async () => {
    electron().booksGetSyncId.mockResolvedValue('sync-123')
    const useBookSyncId = await loadHook()
    renderHook(() => useBookSyncId(42))
    expect(electron().booksGetSyncId).toHaveBeenCalledWith(42)
  })

  it('exposes the resolved sync id via state and ref', async () => {
    electron().booksGetSyncId.mockResolvedValue('sync-abc')
    const useBookSyncId = await loadHook()
    const { result } = renderHook(() => useBookSyncId(7))
    await waitFor(() => {
      expect(result.current.bookSyncId).toBe('sync-abc')
    })
    expect(result.current.bookSyncIdRef.current).toBe('sync-abc')
  })

  it('publishes bookmarks to the menu once the sync id is non-empty', async () => {
    electron().booksGetSyncId.mockResolvedValue('sync-xyz')
    const useBookSyncId = await loadHook()
    renderHook(() => useBookSyncId(11))
    await waitFor(() => {
      expect(publishBookmarksToMenu).toHaveBeenCalledWith('sync-xyz')
    })
    expect(publishBookmarksToMenu).toHaveBeenCalledTimes(1)
  })

  it('does not publish bookmarks when the sync id is null/empty', async () => {
    electron().booksGetSyncId.mockResolvedValue(null)
    const useBookSyncId = await loadHook()
    const { result } = renderHook(() => useBookSyncId(99))
    // Give the microtask queue a chance to flush.
    await new Promise<void>((resolve) => {
      setTimeout(resolve, 0)
    })
    expect(publishBookmarksToMenu).not.toHaveBeenCalled()
    expect(result.current.bookSyncId).toBe('')
  })
})
